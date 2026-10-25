defmodule Bluez.Radio do
  @moduledoc """
  Exclusive transmit leases, one per controller: whoever wants to put
  advertisements on air — through `Bluez.Mgmt` or `Bluez.Advertiser` —
  first `acquire/1`s the controller, sends with the returned lease, and
  `release/1`s it (or exits) when done.

  Why: a controller's advertising instances are one shared namespace, and
  the two transmit paths can't see each other's use of it the way the
  kernel does — `bluetoothd` allocates D-Bus instances from its own
  bookkeeping, blind to the ones `Bluez.Mgmt` adds directly. With a single
  holder issuing every send on a controller, one call at a time, each path
  can check the other's state exactly before acting (no snapshot races),
  and everything the holder put on air has one well-defined lifetime.

  Rules:

    * One lease per controller. `acquire/1` by another process returns
      `{:error, {:held_by, pid}}`; the same holder acquiring again gets its
      existing lease back.
    * Only the holder may send: `Bluez.Mgmt` and `Bluez.Advertiser` refuse
      a lease presented by any other process (`{:error, :not_lease_holder}`).
      Its calls are synchronous, so the holder's sends are serialized.
    * The lease ends on `release/1` or when the holder exits. Every
      advertisement sent under it is then taken off air (subscribers —
      the transmitters — get `{:radio_lease_ended, ref}`).
    * The controller stays reserved until that is done: each subscriber
      reports `drained/2` once nothing sent under the old lease is still
      in flight (a registration BlueZ hasn't answered, a removal the
      kernel hasn't confirmed), so a successor's sends can't be
      overwritten or removed by the old lease's leftovers. `acquire/1`
      waits for it (`:wait`); a subscriber that never reports is given up
      on after 30 s.
    * If the Radio itself stops, every lease ends with it: the
      transmitters (which monitor it) take everything off air, and sends
      return `{:error, :lease_expired}` until a new lease is acquired.

  The controller defaults to the adapter `Bluez.Client` resolved
  (`Bluez.DevicePath.resolved_adapter_path/0`); until it has,
  `acquire/1` returns `{:error, :no_adapter_index}` rather than lease the
  `hci0` fallback. Pass `adapter_index:` to pick one explicitly.
  """

  use GenServer
  require Logger

  alias Bluez.{DevicePath, Hci}

  # How long acquire/1 waits by default for the previous lease to drain,
  # and how often it checks.
  @acquire_wait 5_000
  @acquire_poll_ms 20

  # Cap on a drain: a subscriber that never reports drained/2 can't hold
  # the controller forever.
  @drain_timeout 30_000

  defmodule Lease do
    @moduledoc """
    A transmit lease on one controller (`Bluez.Radio.acquire/1`). Opaque
    apart from `:index`, the controller it covers.
    """
    @enforce_keys [:radio, :index, :ref, :holder]
    defstruct [:radio, :index, :ref, :holder]

    @type t :: %__MODULE__{
            radio: pid(),
            index: 0..0xFFFE,
            ref: reference(),
            holder: pid()
          }
  end

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Acquire the transmit lease on a controller for the calling process.

  Options: `:adapter_index` (default: the adapter `Bluez.Client`
  resolved), `:wait` — ms to wait for the previous lease's work to drain
  (default 5000), `:server` (default `Bluez.Radio`).

  Returns `{:ok, lease}`, `{:error, {:held_by, pid}}`, `{:error, :draining}`
  (still draining after `:wait`), `{:error, :no_adapter_index}`,
  `{:error, {:invalid, "adapter_index"}}` or `{:error, :not_running}`.
  """
  @spec acquire(keyword()) :: {:ok, Lease.t()} | {:error, term()}
  def acquire(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :wait, @acquire_wait)

    with {:ok, index} <- index(opts), do: acquire_until(server, index, deadline)
  end

  # Polled rather than queued in the server: a waiter that gives up must
  # never be handed a lease it no longer expects.
  defp acquire_until(server, index, deadline) do
    case call(server, {:acquire, index, self()}, {:error, :not_running}, :infinity) do
      {:error, :draining} = draining ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@acquire_poll_ms)
          acquire_until(server, index, deadline)
        else
          draining
        end

      other ->
        other
    end
  end

  @doc """
  End a lease, taking everything sent under it off air. `:ok` also when
  already ended. Any process holding the lease struct may end it (e.g. a
  supervising process revoking it); only sending is holder-only.
  """
  @spec release(Lease.t()) :: :ok
  def release(%Lease{radio: radio} = lease), do: call(radio, {:release, lease}, :ok)

  @doc "Whether `lease` is still the current lease on its controller."
  @spec valid?(Lease.t()) :: boolean()
  def valid?(%Lease{radio: radio} = lease), do: call(radio, {:valid?, lease}, false)

  @doc """
  `:ok` when the calling process holds `lease` (and it is a lease at
  all), else `{:error, :not_lease_holder}`. The transmitters check this
  in the caller before sending; validity is checked again server-side.
  """
  @spec check_holder(term()) :: :ok | {:error, :not_lease_holder}
  def check_holder(%Lease{holder: holder}) when holder == self(), do: :ok
  def check_holder(_lease), do: {:error, :not_lease_holder}

  @doc """
  Subscribe the calling process to `{:radio_lease_ended, ref}` messages
  (the transmitters do this). Returns `{:ok, radio_pid}` — leases from
  any other Radio never notify the subscriber, so it should refuse them —
  or `{:error, :not_running}`.
  """
  @spec subscribe(GenServer.server()) :: {:ok, pid()} | {:error, :not_running}
  def subscribe(server \\ __MODULE__), do: call(server, :subscribe, {:error, :not_running})

  @doc """
  Report (from a subscriber) that nothing sent under the ended lease
  `ref` is in flight any more. The controller is free once every
  subscriber has.
  """
  @spec drained(GenServer.server(), reference()) :: :ok
  def drained(server, ref), do: GenServer.cast(server, {:drained, ref, self()})

  @doc "The process holding the lease on controller `index`, or `nil`."
  @spec holder(non_neg_integer(), GenServer.server()) :: pid() | nil
  def holder(index, server \\ __MODULE__), do: call(server, {:holder, index}, nil)

  # MGMT's controller index is 16 bits, and 0xFFFF means "no controller":
  # anything outside would wrap onto another controller's lease.
  defguardp valid_index?(index) when is_integer(index) and index in 0..0xFFFE

  defp index(opts) do
    case Keyword.fetch(opts, :adapter_index) do
      {:ok, index} when valid_index?(index) ->
        {:ok, index}

      {:ok, _bad} ->
        {:error, {:invalid, "adapter_index"}}

      :error ->
        with {:ok, path} <- DevicePath.resolved_adapter_path(),
             {:ok, index} when valid_index?(index) <- Hci.adapter_index(path) do
          {:ok, index}
        else
          _unresolved -> {:error, :no_adapter_index}
        end
    end
  end

  # `catch :exit` idiom (see `Bluez`): not running → the given default.
  # Acquisition waits without a timeout: a timed-out request stays queued,
  # and would grant a lease the caller believes it never got. The Radio's
  # handlers never block, so the wait is short.
  defp call(server, request, default, timeout \\ 5_000) do
    GenServer.call(server, request, timeout)
  catch
    :exit, _reason -> default
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    state = %{
      # Test seam.
      drain_timeout: Keyword.get(opts, :drain_timeout, @drain_timeout),
      # index => %Lease{}
      leases: %{},
      # holder monitor ref => index
      monitors: %{},
      # pid => monitor ref
      subscribers: %{},
      # index => %{ref, pending}: the subscribers yet to report the ended
      # lease drained.
      draining: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:acquire, index, holder}, _from, state) do
    case state.leases do
      %{^index => %Lease{holder: ^holder} = lease} ->
        {:reply, {:ok, lease}, state}

      %{^index => %Lease{holder: other}} ->
        {:reply, {:error, {:held_by, other}}, state}

      _free when is_map_key(state.draining, index) ->
        {:reply, {:error, :draining}, state}

      _free ->
        lease = %Lease{radio: self(), index: index, ref: make_ref(), holder: holder}
        mon = Process.monitor(holder)

        state = %{
          state
          | leases: Map.put(state.leases, index, lease),
            monitors: Map.put(state.monitors, mon, index)
        }

        {:reply, {:ok, lease}, state}
    end
  end

  def handle_call({:release, %Lease{index: index, ref: ref}}, _from, state) do
    case state.leases do
      %{^index => %Lease{ref: ^ref}} -> {:reply, :ok, end_lease(state, index)}
      _other -> {:reply, :ok, state}
    end
  end

  def handle_call({:valid?, %Lease{index: index, ref: ref}}, _from, state),
    do: {:reply, match?(%{^index => %Lease{ref: ^ref}}, state.leases), state}

  def handle_call(:subscribe, {pid, _tag}, state) do
    if Map.has_key?(state.subscribers, pid) do
      {:reply, {:ok, self()}, state}
    else
      mon = Process.monitor(pid)
      {:reply, {:ok, self()}, %{state | subscribers: Map.put(state.subscribers, pid, mon)}}
    end
  end

  def handle_call({:holder, index}, _from, state) do
    holder =
      case state.leases do
        %{^index => %Lease{holder: holder}} -> holder
        _free -> nil
      end

    {:reply, holder, state}
  end

  @impl GenServer
  def handle_info({:DOWN, mon, :process, pid, _reason}, state) do
    case Map.pop(state.monitors, mon) do
      # A lease holder exited: its lease ends with it.
      {index, monitors} when is_integer(index) ->
        {:noreply, end_lease(%{state | monitors: monitors}, index)}

      # A subscriber exited: it has nothing left in flight.
      {nil, _monitors} ->
        state = %{state | subscribers: Map.delete(state.subscribers, pid)}
        {:noreply, Enum.reduce(Map.keys(state.draining), state, &drained(&2, &1, pid))}
    end
  end

  def handle_info({:drain_timeout, index, ref}, state) do
    case state.draining do
      %{^index => %{ref: ^ref, pending: pending}} ->
        Logger.warning(
          "Bluez.Radio: hci#{index} still draining after #{state.drain_timeout} ms " <>
            "(#{inspect(MapSet.to_list(pending))}); freeing it"
        )

        {:noreply, %{state | draining: Map.delete(state.draining, index)}}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def handle_cast({:drained, ref, pid}, state) do
    case Enum.find(state.draining, fn {_index, drain} -> drain.ref == ref end) do
      {index, _drain} -> {:noreply, drained(state, index, pid)}
      nil -> {:noreply, state}
    end
  end

  defp drained(state, index, pid) do
    %{pending: pending} = drain = state.draining[index]
    pending = MapSet.delete(pending, pid)

    if MapSet.size(pending) == 0,
      do: %{state | draining: Map.delete(state.draining, index)},
      else: put_in(state.draining[index], %{drain | pending: pending})
  end

  defp end_lease(state, index) do
    {%Lease{ref: ref}, leases} = Map.pop(state.leases, index)

    monitors =
      case Enum.find(state.monitors, fn {_mon, i} -> i == index end) do
        {mon, _index} ->
          Process.demonitor(mon, [:flush])
          Map.delete(state.monitors, mon)

        nil ->
          state.monitors
      end

    # The transmitters take everything sent under the lease off air; the
    # controller stays reserved until each reports drained/2.
    subscribers = Map.keys(state.subscribers)
    Enum.each(subscribers, &send(&1, {:radio_lease_ended, ref}))

    draining =
      if subscribers == [] do
        state.draining
      else
        Process.send_after(self(), {:drain_timeout, index, ref}, state.drain_timeout)
        Map.put(state.draining, index, %{ref: ref, pending: MapSet.new(subscribers)})
      end

    %{state | leases: leases, monitors: monitors, draining: draining}
  end
end
