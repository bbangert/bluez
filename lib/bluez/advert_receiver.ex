defmodule Bluez.AdvertReceiver do
  @moduledoc """
  Verbatim LE advertising reports, read straight off the controller's HCI
  event stream and fanned out through the `on_report:` fun.

  `Bluez.Client` sees adverts only through BlueZ's `Device1` properties,
  which dedupe, merge and reorder AD content per device — fine for sensor
  relaying, useless for protocols that put an opaque payload in the raw
  AD (an ordered 16-bit UUID list with repeated values, for example).
  This process opens an `HCI_CHANNEL_RAW` socket on the adapter
  (`Bluez.Hci.open/2`) with a kernel filter that passes only LE Meta
  events, and decodes each legacy or extended advertising report
  (`Bluez.Hci.decode_raw/1`) into a `t:Bluez.Hci.adv_report/0`.

  It only *listens*: the raw channel receives a copy of every event the
  controller sends while `bluetoothd`/`Bluez.Client` own scanning, so it
  never conflicts with them — and reports only arrive while something is
  scanning (`Bluez.Client` in `:passive` or `:active` mode). Two
  caveats follow from that:

    * Controllers that offload advertisement-monitor filtering (MSFT/AOSP
      extensions) may drop non-matching adverts in passive mode before
      they reach the host; use `:active` mode where every advert matters.
    * With `DuplicateData=false` (the Client's active-mode filter) the
      controller filters duplicate reports. Most compare address *and*
      data, so a changed payload still gets through; some compare the
      address alone and then also suppress changed payloads from an
      address they've already reported. Protocols that need every packet
      from one device should be verified on the target controller.

  ## Options

    * `on_report:` — `fun(report) -> any`, called in this process for every
      report (default: discard). Keep it fast: it runs on the receive
      path. Raises crash this process (the supervisor restarts it).
    * `adapter_index:` — controller index to listen on; default: the
      adapter `Bluez.Client` resolves (`Bluez.DevicePath.resolved_adapter_path/0`).
      Until it has, the receiver waits rather than listen on the `hci0`
      fallback; afterwards it re-checks every 2 s and moves its socket if
      the selection changes (e.g. a radio switch).
    * `name:` — registered name (default `Bluez.AdvertReceiver`).

  When the socket can't be opened (no adapter yet, no Bluetooth in the
  kernel) or dies (adapter unplugged), the receiver stays up and retries
  with a backoff instead of crash-looping its supervisor.
  """

  use GenServer
  require Logger

  alias Bluez.{DevicePath, Hci}

  @retry_ms 2_000
  @adapter_check_ms 2_000
  # Bounded drain per wakeup so a flood of reports can't starve the mailbox.
  @drain_batch 64

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Whether the receiver currently holds an open HCI socket. `false` when
  it is retrying or not running (`catch :exit` idiom, see `Bluez`).
  """
  @spec listening?(GenServer.server()) :: boolean()
  def listening?(server \\ __MODULE__) do
    GenServer.call(server, :listening?)
  catch
    :exit, _ -> false
  end

  # The controller index is 16 bits in sockaddr_hci, and 0xFFFF means "no
  # controller": anything outside would wrap onto another controller.
  defguardp valid_index?(index) when is_integer(index) and index in 0..0xFFFE

  @impl GenServer
  def init(opts) do
    case Keyword.get(opts, :adapter_index) do
      nil -> init_state(opts)
      index when valid_index?(index) -> init_state(opts)
      _bad -> {:stop, {:invalid_option, :adapter_index}}
    end
  end

  defp init_state(opts) do
    state = %{
      sock: nil,
      on_report: Keyword.get(opts, :on_report, fn _report -> :ok end),
      adapter_index: Keyword.get(opts, :adapter_index),
      # Test seam: fun(index) -> {:ok, socket} | {:error, reason}.
      open: Keyword.get(opts, :open, &Hci.open(:raw, &1)),
      retry_ms: Keyword.get(opts, :retry_ms, @retry_ms),
      adapter_check_ms: Keyword.get(opts, :adapter_check_ms, @adapter_check_ms),
      # The controller the open socket is bound to.
      bound_index: nil
    }

    # Following the selected adapter: re-check periodically and move when
    # Bluez.Client's resolution changes (open/1 waits for the first one).
    if state.adapter_index == nil, do: schedule_adapter_check(state)

    {:ok, state, {:continue, :open}}
  end

  @impl GenServer
  def handle_continue(:open, state), do: {:noreply, open(state)}

  @impl GenServer
  def handle_call(:listening?, _from, state), do: {:reply, state.sock != nil, state}

  @impl GenServer
  # Guarded: a socket opened meanwhile must not be replaced (and leaked).
  def handle_info(:reopen, %{sock: nil} = state), do: {:noreply, open(state)}

  def handle_info(:check_adapter, state) do
    schedule_adapter_check(state)

    # Unresolved (a Client restart in progress) keeps the current socket;
    # only a different resolved controller moves it.
    case {state.sock, index(state)} do
      {sock, {:ok, index}} when sock != nil and index != state.bound_index ->
        Logger.info("Bluez.AdvertReceiver: selected adapter changed to hci#{index}, moving")
        :socket.close(sock)
        {:noreply, open(%{state | sock: nil, bound_index: nil})}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:"$socket", sock, :select, _handle}, %{sock: sock} = state),
    do: {:noreply, drain(state, @drain_batch)}

  # The pending select was aborted (socket closed under us): without this
  # nothing re-arms the socket and the receiver goes silently deaf.
  def handle_info({:"$socket", sock, :abort, {_handle, reason}}, %{sock: sock} = state) do
    :socket.close(sock)
    {:noreply, retry(%{state | sock: nil, bound_index: nil}, {:abort, reason})}
  end

  def handle_info(:drain, %{sock: sock} = state) when sock != nil,
    do: {:noreply, drain(state, @drain_batch)}

  def handle_info(_other, state), do: {:noreply, state}

  defp open(state) do
    with {:ok, index} <- index(state),
         {:ok, sock} <- state.open.(index) do
      Logger.info("Bluez.AdvertReceiver: listening for LE advertising reports on hci#{index}")
      drain(%{state | sock: sock, bound_index: index}, @drain_batch)
    else
      {:error, reason} -> retry(state, reason)
      :error -> retry(state, :adapter_not_resolved)
    end
  end

  defp index(%{adapter_index: index}) when is_integer(index), do: {:ok, index}

  # A resolved index out of range counts as unresolved (keep waiting).
  defp index(_state) do
    with {:ok, path} <- DevicePath.resolved_adapter_path(),
         {:ok, index} when valid_index?(index) <- Hci.adapter_index(path) do
      {:ok, index}
    else
      _unresolved -> :error
    end
  end

  defp schedule_adapter_check(state),
    do: Process.send_after(self(), :check_adapter, state.adapter_check_ms)

  defp retry(state, reason) do
    Logger.debug("Bluez.AdvertReceiver: HCI socket unavailable (#{inspect(reason)}), retrying")
    Process.send_after(self(), :reopen, state.retry_ms)
    state
  end

  # Read until the socket would block (re-arming the select), the batch is
  # spent (yield via :drain), or it errors (adapter gone → reopen later).
  defp drain(state, 0) do
    send(self(), :drain)
    state
  end

  defp drain(state, budget) do
    case :socket.recv(state.sock, 0, [], :nowait) do
      {:ok, packet} ->
        packet |> Hci.decode_raw() |> Enum.each(state.on_report)
        drain(state, budget - 1)

      {:select, _info} ->
        state

      {:error, reason} ->
        :socket.close(state.sock)
        retry(%{state | sock: nil, bound_index: nil}, reason)
    end
  end
end
