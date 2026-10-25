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
    * If the Radio itself stops, every lease ends with it: the
      transmitters (which monitor it) take everything off air, and sends
      return `{:error, :lease_expired}` until a new lease is acquired.

  The controller defaults to the adapter `Bluez.Client` resolved
  (`Bluez.DevicePath.resolved_adapter_path/0`); until it has,
  `acquire/1` returns `{:error, :no_adapter_index}` rather than lease the
  `hci0` fallback. Pass `adapter_index:` to pick one explicitly.
  """

  use GenServer

  alias Bluez.{DevicePath, Hci}

  defmodule Lease do
    @moduledoc """
    A transmit lease on one controller (`Bluez.Radio.acquire/1`). Opaque
    apart from `:index`, the controller it covers.
    """
    @enforce_keys [:radio, :index, :ref, :holder]
    defstruct [:radio, :index, :ref, :holder]

    @type t :: %__MODULE__{
            radio: pid(),
            index: non_neg_integer(),
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
  resolved), `:server` (default `Bluez.Radio`).

  Returns `{:ok, lease}`, `{:error, {:held_by, pid}}`,
  `{:error, :no_adapter_index}`, `{:error, {:invalid, "adapter_index"}}`
  or `{:error, :not_running}`.
  """
  @spec acquire(keyword()) :: {:ok, Lease.t()} | {:error, term()}
  def acquire(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    with {:ok, index} <- index(opts) do
      call(server, {:acquire, index, self()}, {:error, :not_running})
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

  @doc "The process holding the lease on controller `index`, or `nil`."
  @spec holder(non_neg_integer(), GenServer.server()) :: pid() | nil
  def holder(index, server \\ __MODULE__), do: call(server, {:holder, index}, nil)

  defp index(opts) do
    case Keyword.fetch(opts, :adapter_index) do
      {:ok, index} when is_integer(index) and index >= 0 ->
        {:ok, index}

      {:ok, _bad} ->
        {:error, {:invalid, "adapter_index"}}

      :error ->
        with {:ok, path} <- DevicePath.resolved_adapter_path(),
             {:ok, index} <- Hci.adapter_index(path) do
          {:ok, index}
        else
          :error -> {:error, :no_adapter_index}
        end
    end
  end

  # `catch :exit` idiom (see `Bluez`): not running → the given default.
  defp call(server, request, default) do
    GenServer.call(server, request)
  catch
    :exit, _reason -> default
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    # leases: index => %Lease{}; monitors: holder monitor ref => index;
    # subscribers: pid => monitor ref.
    {:ok, %{leases: %{}, monitors: %{}, subscribers: %{}}}
  end

  @impl GenServer
  def handle_call({:acquire, index, holder}, _from, state) do
    case state.leases do
      %{^index => %Lease{holder: ^holder} = lease} ->
        {:reply, {:ok, lease}, state}

      %{^index => %Lease{holder: other}} ->
        {:reply, {:error, {:held_by, other}}, state}

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

      {nil, _monitors} ->
        {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

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

    # The transmitters take everything sent under the lease off air.
    Enum.each(Map.keys(state.subscribers), &send(&1, {:radio_lease_ended, ref}))
    %{state | leases: leases, monitors: monitors}
  end
end
