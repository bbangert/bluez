defmodule Bluez.Radio do
  @moduledoc """
  Exclusive ownership of a controller for advertising: a process that
  wants to put advertisements on air `acquire/1`s the controller, sends
  with the returned lease, and `release/1`s it (or exits) when done.

  Rules:

    * **One owner per controller.** `acquire/1` by another process returns
      `{:error, {:held_by, pid}}`; the owner acquiring again gets its
      existing lease back. Only the owner may send with the lease
      (`{:error, :not_lease_holder}` otherwise), so its sends are
      serialized.
    * **One transmit mode per controller.** The first acquire on a
      controller fixes its `mode:` for as long as this process runs; a
      later acquire asking for another mode gets
      `{:error, {:mode, current}}`. A controller's advertising instances
      are allocated by whichever path sends — the kernel MGMT API or, in a
      future `:dbus` mode, `bluetoothd` — and two allocators that can't see
      each other would overwrite each other's advertisements. The only
      mode today is `:mgmt` (`Bluez.Mgmt`).
    * **Ending the lease takes everything off air.** On `release/1`, the
      owner exiting, or this process stopping, the transmitter removes
      every advertisement sent under the lease (subscribers get
      `{:radio_lease_ended, ref}`).

  The controller defaults to the adapter `Bluez.Client` resolved
  (`Bluez.DevicePath.resolved_adapter_path/0`); until it has, `acquire/1`
  returns `{:error, :no_adapter_index}` rather than lease the `hci0`
  fallback. Pass `adapter_index:` to pick one explicitly.
  """

  use GenServer

  alias Bluez.{DevicePath, Hci}

  @modes [:mgmt]

  defmodule Lease do
    @moduledoc """
    A controller lease (`Bluez.Radio.acquire/1`). Opaque apart from
    `:index`, the controller it covers, and `:mode`.
    """
    @enforce_keys [:radio, :index, :mode, :ref, :holder]
    defstruct [:radio, :index, :mode, :ref, :holder]

    @type t :: %__MODULE__{
            radio: pid(),
            index: 0..0xFFFE,
            mode: :mgmt,
            ref: reference(),
            holder: pid()
          }
  end

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Acquire a controller for the calling process.

  Options: `:mode` (default `:mgmt`, the only one so far),
  `:adapter_index` (default: the adapter `Bluez.Client` resolved),
  `:server` (default `Bluez.Radio`).

  Returns `{:ok, lease}`, `{:error, {:held_by, pid}}`,
  `{:error, {:mode, current}}`, `{:error, :no_adapter_index}`,
  `{:error, {:invalid, option}}` or `{:error, :not_running}`.
  """
  @spec acquire(keyword()) :: {:ok, Lease.t()} | {:error, term()}
  def acquire(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    mode = Keyword.get(opts, :mode, :mgmt)

    with :ok <- check_mode(mode),
         {:ok, index} <- index(opts) do
      # No timeout: a timed-out request would stay queued and could grant a
      # lease its caller believes it never got. The handlers never block.
      call(server, {:acquire, index, mode, self()}, {:error, :not_running}, :infinity)
    end
  end

  @doc """
  End a lease, taking everything sent under it off air. `:ok` also when
  already ended. Any process holding the lease struct may end it (e.g. a
  supervising process revoking it); only sending is owner-only.
  """
  @spec release(Lease.t()) :: :ok
  def release(%Lease{radio: radio} = lease), do: call(radio, {:release, lease}, :ok)

  @doc "Whether `lease` is still the current lease on its controller."
  @spec valid?(Lease.t()) :: boolean()
  def valid?(%Lease{radio: radio} = lease), do: call(radio, {:valid?, lease}, false)

  @doc """
  `:ok` when the calling process holds `lease` and it is for `mode`, else
  `{:error, :not_lease_holder}` or `{:error, {:mode, lease_mode}}`. The
  transmitters check this in the caller before sending.
  """
  @spec check_holder(term(), atom()) :: :ok | {:error, term()}
  def check_holder(%Lease{holder: holder, mode: mode}, mode) when holder == self(), do: :ok

  def check_holder(%Lease{holder: holder, mode: other}, _mode) when holder == self(),
    do: {:error, {:mode, other}}

  def check_holder(_lease, _mode), do: {:error, :not_lease_holder}

  @doc """
  Subscribe the calling process (a transmitter) to
  `{:radio_lease_ended, ref}` messages. Returns `{:ok, radio_pid}` —
  leases from any other Radio never notify it, so it should refuse
  them — or `{:error, :not_running}`.
  """
  @spec subscribe(GenServer.server()) :: {:ok, pid()} | {:error, :not_running}
  def subscribe(server \\ __MODULE__), do: call(server, :subscribe, {:error, :not_running})

  @doc "The process holding controller `index`, or `nil`."
  @spec holder(non_neg_integer(), GenServer.server()) :: pid() | nil
  def holder(index, server \\ __MODULE__), do: call(server, {:holder, index}, nil)

  defp check_mode(mode) when mode in @modes, do: :ok
  defp check_mode(_mode), do: {:error, {:invalid, "mode"}}

  # MGMT's controller index is 16 bits, and 0xFFFF means "no controller":
  # anything outside would wrap onto another controller.
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
  defp call(server, request, default, timeout \\ 5_000) do
    GenServer.call(server, request, timeout)
  catch
    :exit, _reason -> default
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(_opts) do
    state = %{
      # index => %Lease{}
      leases: %{},
      # index => mode, fixed by the first acquire
      modes: %{},
      # holder monitor ref => index
      monitors: %{},
      # subscriber pid => monitor ref
      subscribers: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:acquire, index, mode, holder}, _from, state) do
    case {Map.get(state.modes, index, mode), state.leases} do
      {current, _leases} when current != mode ->
        {:reply, {:error, {:mode, current}}, state}

      {_mode, %{^index => %Lease{holder: ^holder} = lease}} ->
        {:reply, {:ok, lease}, state}

      {_mode, %{^index => %Lease{holder: other}}} ->
        {:reply, {:error, {:held_by, other}}, state}

      {_mode, _free} ->
        lease = %Lease{radio: self(), index: index, mode: mode, ref: make_ref(), holder: holder}
        mon = Process.monitor(holder)

        state = %{
          state
          | leases: Map.put(state.leases, index, lease),
            modes: Map.put(state.modes, index, mode),
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
      # An owner exited: its lease ends with it.
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

    Enum.each(Map.keys(state.subscribers), &send(&1, {:radio_lease_ended, ref}))
    %{state | leases: leases, monitors: monitors}
  end
end
