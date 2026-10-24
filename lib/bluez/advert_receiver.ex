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
    * With `DuplicateData=false` (the Client's active-mode filter) some
      controllers filter duplicates by address alone. Payload-carrying
      protocols that change their data per packet are unaffected.

  ## Options

    * `on_report:` — `fun(report) -> any`, called in this process for every
      report (default: discard). Keep it fast: it runs on the receive
      path. Raises crash this process (the supervisor restarts it).
    * `adapter_index:` — controller index to listen on; default: resolved
      from `Bluez.DevicePath.adapter_path/0` at each (re)open.
    * `name:` — registered name (default `Bluez.AdvertReceiver`).

  When the socket can't be opened (no adapter yet, no Bluetooth in the
  kernel) or dies (adapter unplugged), the receiver stays up and retries
  with a backoff instead of crash-looping its supervisor.
  """

  use GenServer
  require Logger

  alias Bluez.{DevicePath, Hci}

  @retry_ms 2_000
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

  @impl GenServer
  def init(opts) do
    state = %{
      sock: nil,
      on_report: Keyword.get(opts, :on_report, fn _report -> :ok end),
      adapter_index: Keyword.get(opts, :adapter_index),
      # Test seam: fun(index) -> {:ok, socket} | {:error, reason}.
      open: Keyword.get(opts, :open, &Hci.open(:raw, &1)),
      retry_ms: Keyword.get(opts, :retry_ms, @retry_ms)
    }

    {:ok, state, {:continue, :open}}
  end

  @impl GenServer
  def handle_continue(:open, state), do: {:noreply, open(state)}

  @impl GenServer
  def handle_call(:listening?, _from, state), do: {:reply, state.sock != nil, state}

  @impl GenServer
  def handle_info(:reopen, state), do: {:noreply, open(state)}

  def handle_info({:"$socket", sock, :select, _handle}, %{sock: sock} = state),
    do: {:noreply, drain(state, @drain_batch)}

  def handle_info(:drain, %{sock: sock} = state) when sock != nil,
    do: {:noreply, drain(state, @drain_batch)}

  def handle_info(_other, state), do: {:noreply, state}

  defp open(state) do
    with {:ok, index} <- index(state),
         {:ok, sock} <- state.open.(index) do
      Logger.info("Bluez.AdvertReceiver: listening for LE advertising reports on hci#{index}")
      drain(%{state | sock: sock}, @drain_batch)
    else
      {:error, reason} -> retry(state, reason)
      :error -> retry(state, :no_adapter_index)
    end
  end

  defp index(%{adapter_index: index}) when is_integer(index), do: {:ok, index}
  defp index(_state), do: Hci.adapter_index(DevicePath.adapter_path())

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
        retry(%{state | sock: nil}, reason)
    end
  end
end
