defmodule Bluez.HciUser do
  @moduledoc """
  Exclusive access to one controller over an `HCI_CHANNEL_USER` socket:
  this process sends HCI commands and hands every event to an owner
  process, with neither the kernel's HCI core nor `bluetoothd` in between.

  For a protocol that drives the radio hard (continuous scanning without
  duplicate filtering, advertising windows of a few seconds each) the
  BlueZ path costs CPU in `bluetoothd` and adds kernel-side advertising
  bookkeeping per frame. The user channel avoids both, at a price:

    * **The controller leaves BlueZ.** While the socket is bound the kernel
      removes its index from MGMT (Index Removed), so `bluetoothd` drops
      the adapter and nothing else (`Bluez.Client`, `Bluez.Mgmt`,
      `Bluez.AdvertReceiver`) can use it. Closing the socket — `close/1`,
      this process stopping, the owner exiting — hands the index back
      (Index Added), and `bluetoothd` takes it over and powers it on again
      by itself.
    * **You run the controller.** Nothing initializes it for you: reset
      it, set the event masks and configure scanning/advertising yourself.
      The kernel still runs the vendor setup (firmware download) when it
      opens the transport.

  ## Bring-up

  `start_link/1` resolves the controller (`:index`, or `:address` through
  MGMT), powers it off through MGMT (the kernel only binds a controller
  that is down; skip with `power_off_first: false`), then binds the user
  channel. Any failure is returned as `{:error, reason}`, and the process
  exits normally (so a linked caller doesn't crash): `{:resolve, reason}`
  (`:not_found` when no controller has the address), `{:power_off,
  reason}` (a MGMT status such as `:invalid_index`, or a socket error),
  or `{:bind, reason}` (e.g. `:ebusy`).

  The sequence that brought up a Realtek RTL8761B (UB500 dongle) on a
  Raspberry Pi 3, every command answering status 0x00:

   1. MGMT Set Powered off, then bind (done by `start_link/1`).
   2. `reset/2` (~11 ms).
   3. `read_bd_addr/2` — check it is the controller you meant.
   4. `read_local_version/2` — on the RTL8761B, `lmp_subversion` 0xD922
      means the kernel's firmware patch is loaded (0x8761 is the
      unpatched ROM). It survived the power-off and Reset.
   5. `le_read_local_supported_features/2` (`Bluez.HciUser.Codec.le_features/1`
      names the bits) and, if needed, `le_read_num_supported_adv_sets/2`.
      The latter counts as an *extended* advertising command: a
      controller refuses legacy advertising/scanning commands once an
      extended one was issued, until the next Reset — so reset again
      before step 6 if you sent it.
   6. `set_event_mask/3` with `0x20001FFFFFFFFFFF` (the default events
      plus LE Meta, bit 61) and `le_set_event_mask/3` with `0x1F`
      (legacy advertising reports among the first five LE events).
   7. `le_set_scan_parameters/3` (`type: :passive, interval_ms: 30,
      window_ms: 30`) and `le_set_scan_enable(server, true, false)` —
      continuous passive scanning, every report delivered.
   8. To transmit (legacy): `le_set_advertising_parameters/3` (e.g.
      `type: :adv_ind, min_interval_ms: 20, max_interval_ms: 30`),
      `le_set_advertising_data/3`, `le_set_advertising_enable/3` with
      `true`, then `false` when the window ends. Scanning carries on
      meanwhile.

  ## Commands

  `command/4` sends any command and returns its outcome, correlated by
  opcode: `{:ok, return_params}` (Command Complete, return parameters
  *without* the leading Status byte), `{:ok, :pending}` (Command Status
  with status 0: the command runs on and reports through its own event),
  `{:error, {:status, code}}` for a non-zero HCI status, `{:error,
  :timeout}` or `{:error, :closed}`. Every command assumes the first
  return parameter is the Status, as for every command in the Core spec
  that returns Command Complete.

  Exactly one command is in flight at a time (as in the Linux kernel), so
  a reply always belongs to the command it answers; the rest wait in a
  queue, sent in call order. On top of that the controller's
  `Num_HCI_Command_Packets` credits from every Command Complete/Status
  are honoured: while it grants none, nothing is sent. When it grants no
  credit with nothing in flight for `:ncmd_timeout` ms (default 4 000,
  the kernel's), one credit is restored and the owner gets
  `:command_stall` — a sign the controller is wedged (reset it).

  Each command's timeout (default 2 000 ms, the kernel's) is a deadline
  fixed when `command/4` is called, so time spent in this process's
  mailbox and queue counts. A command whose deadline passes before it is
  sent returns `{:error, :timeout}` and is never sent. One whose deadline
  passes **in flight** — unanswered, or a send the socket couldn't take
  in time — is a controller fault: its caller gets `{:error, :timeout}`
  and the channel closes (`{:closed, :command_timeout}` or
  `{:closed, :send_timeout}`, see "Events"), because a late reply could
  otherwise be taken for a later command's.

  ## Events

  The owner (default: the process calling `start_link/1`) receives
  `{:bluez_hci_user, server, event}` messages, `server` being this
  process's pid:

    * `{:adv_report, report}` — one per legacy or extended LE advertising
      report (`t:Bluez.Hci.adv_report/0`, AD bytes verbatim).
    * `{:hardware_error, code}` — Hardware Error event: the controller
      needs a Reset (pending commands are left to their timeouts).
    * `:command_stall` — see "Commands".
    * `{:event, code, params}` — every other event (Command
      Complete/Status excepted), LE Meta subevents included with the
      subevent code first in `params`. Data packets (ACL, SCO, ISO) are
      dropped.
    * `{:closed, reason}` — the socket failed: `reason` is the error the
      socket reported, passed through unchanged (unplugging a USB dongle
      surfaces as a socket error), `:eof` for an empty read,
      `{:abort, reason}` for an aborted select, or `:command_timeout` /
      `:send_timeout` for a command that timed out in flight. Always the last message;
      not sent when the socket is closed on purpose (`close/1`, the owner
      exiting).

  On `{:closed, _}` every queued and in-flight command returns `{:error,
  :closed}` (the one that timed out: `{:error, :timeout}`) and the
  process **stops** (exit reason `:normal`): to re-bind
  — after an unplug, once the controller is back — start a new one (find
  its new index by address with `find_index/2`). It also stops, closing
  the socket, when the owner exits.

  ## Start options

    * `:index` — controller index to bind, or
    * `:address` — the controller's public address (integer packed
      MSB-first, or `"AA:BB:CC:DD:EE:FF"`), resolved with `find_index/2`.
    * `:owner` — pid that receives the events (default: the caller).
    * `:power_off_first` — MGMT Set Powered off before binding (default
      `true`).
    * `:ncmd_timeout` — see "Commands" (default `4_000` ms).
    * `:mgmt_timeout` — patience per MGMT command during bring-up
      (default `2_000` ms).
    * `:name` — optional registered name.

  The child spec is `restart: :temporary`: the owner decides when to
  bind again, and runs the bring-up after it. Binding needs
  `CAP_NET_ADMIN` (root on Nerves).
  """

  use GenServer, restart: :temporary
  require Logger

  alias Bluez.{Advert, Hci}
  alias Bluez.HciUser.Codec

  @command_timeout 2_000
  @reset_timeout 5_000
  @ncmd_timeout 4_000
  @mgmt_timeout 2_000
  # Bounded drain per wakeup so a flood of reports can't starve the mailbox.
  @drain_batch 64

  @typedoc "Event delivered to the owner as `{:bluez_hci_user, server, event}`."
  @type event ::
          {:adv_report, Hci.adv_report()}
          | {:hardware_error, byte()}
          | :command_stall
          | {:event, byte(), binary()}
          | {:closed, term()}

  @typedoc "Outcome of `command/4`."
  @type result ::
          {:ok, binary() | :pending}
          | {:error, {:status, byte()} | :timeout | :closed}

  @typedoc "Outcome of the commands whose return parameters are only a Status."
  @type status_result :: :ok | {:error, {:status, byte()} | :timeout | :closed}

  @typedoc "Outcome of a read command."
  @type read_result(value) ::
          {:ok, value} | {:error, {:status, byte()} | :timeout | :closed | :malformed_reply}

  defguardp valid_index?(index) when is_integer(index) and index in 0..0xFFFE

  # ── lifecycle ─────────────────────────────────────────────────────────────

  @doc "Start linked to the caller. See the moduledoc for options and errors."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, opts} = split_opts(opts)
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "Like `start_link/1`, without the link (the owner is still monitored)."
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts) do
    {gen_opts, opts} = split_opts(opts)
    GenServer.start(__MODULE__, opts, gen_opts)
  end

  defp split_opts(opts) do
    opts = Keyword.put_new(opts, :owner, self())

    case Keyword.pop(opts, :name) do
      {nil, opts} -> {[], opts}
      {name, opts} -> {[name: name], opts}
    end
  end

  @doc """
  Close the socket (handing the controller back to the kernel) and stop.
  `:ok` also when the server is already gone.
  """
  @spec close(GenServer.server()) :: :ok
  def close(server) do
    GenServer.stop(server, :normal)
  catch
    :exit, _reason -> :ok
  end

  @doc "The controller index the socket is bound to."
  @spec index(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, :closed}
  def index(server) do
    GenServer.call(server, :index)
  catch
    :exit, _reason -> {:error, :closed}
  end

  @doc """
  The index of the controller with public address `address` (integer
  packed MSB-first, or `"AA:BB:CC:DD:EE:FF"`), from MGMT Read Index List
  and Read Controller Information. Only controllers the kernel currently
  exposes are found — not one bound to a user channel.

  Options: `:timeout` per MGMT command (default `2_000` ms), `:open_control`
  (a `fun() -> {:ok, socket} | {:error, reason}`, default
  `fn -> Bluez.Hci.open(:control) end`).

  Returns `{:ok, index}`, `{:error, :not_found}`, or `{:error, reason}`
  when MGMT can't be asked (opening the socket, a timeout, a failed Read
  Index List).
  """
  @spec find_index(non_neg_integer() | String.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def find_index(address, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @mgmt_timeout)
    open_control = Keyword.get(opts, :open_control, &open_control/0)

    with {:ok, address} <- normalize_address(address) do
      with_control(open_control, fn sock -> find_index(sock, address, timeout) end)
    end
  end

  defp find_index(sock, address, timeout) do
    with {:ok, rp} <- mgmt(sock, Hci.op_read_index_list(), Hci.index_none(), <<>>, timeout),
         {:ok, indexes} <- decode(Hci.decode_index_list(rp)) do
      case Enum.find(indexes, &has_address?(sock, &1, address, timeout)) do
        nil -> {:error, :not_found}
        index -> {:ok, index}
      end
    end
  end

  # A controller that vanished or answers oddly is simply not it.
  defp has_address?(sock, index, address, timeout) do
    case mgmt(sock, Hci.op_read_controller_info(), index, <<>>, timeout) do
      {:ok, rp} -> match?({:ok, %{address: ^address}}, Hci.decode_controller_info(rp))
      {:error, _reason} -> false
    end
  end

  defp normalize_address(address) when is_integer(address) and address in 0..0xFFFFFFFFFFFF,
    do: {:ok, address}

  defp normalize_address(address) when is_binary(address) do
    if Regex.match?(~r/\A[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}\z/, address),
      do: {:ok, Advert.address_to_integer(address)},
      else: {:error, {:invalid_address, address}}
  end

  defp normalize_address(address), do: {:error, {:invalid_address, address}}

  # ── commands ──────────────────────────────────────────────────────────────

  @doc """
  Send one HCI command and wait for its Command Complete/Status. See
  "Commands" in the moduledoc for the results, flow control and timeout.
  `params` is at most 255 bytes.
  """
  @spec command(GenServer.server(), non_neg_integer(), binary(), pos_integer()) :: result()
  def command(server, opcode, params \\ <<>>, timeout \\ @command_timeout)
      when opcode in 0..0xFFFF and is_binary(params) and byte_size(params) <= 255 and
             is_integer(timeout) and timeout > 0 do
    # The deadline is absolute, so time spent in the server's mailbox counts.
    # The server answers by then; the margin only covers a server too busy
    # to (a wedged one surfaces as a timeout, not as "closed").
    deadline = now() + timeout
    GenServer.call(server, {:command, opcode, params, deadline}, timeout + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _reason -> {:error, :closed}
  end

  @doc "HCI Reset (default timeout #{@reset_timeout} ms)."
  @spec reset(GenServer.server(), pos_integer()) :: status_result()
  def reset(server, timeout \\ @reset_timeout),
    do: server |> command(Codec.opcode(:reset), <<>>, timeout) |> status()

  @doc "Read BD_ADDR: the controller's public address, packed MSB-first."
  @spec read_bd_addr(GenServer.server(), pos_integer()) :: read_result(non_neg_integer())
  def read_bd_addr(server, timeout \\ @command_timeout),
    do: read(server, :read_bd_addr, timeout, &Codec.decode_bd_addr/1)

  @doc "Read Local Version Information (`t:Bluez.HciUser.Codec.local_version/0`)."
  @spec read_local_version(GenServer.server(), pos_integer()) ::
          read_result(Codec.local_version())
  def read_local_version(server, timeout \\ @command_timeout),
    do: read(server, :read_local_version, timeout, &Codec.decode_local_version/1)

  @doc """
  LE Read Local Supported Features: the 64-bit feature mask
  (`Bluez.HciUser.Codec.le_features/1`, `Bluez.HciUser.Codec.le_feature?/2`).
  """
  @spec le_read_local_supported_features(GenServer.server(), pos_integer()) ::
          read_result(non_neg_integer())
  def le_read_local_supported_features(server, timeout \\ @command_timeout),
    do: read(server, :le_read_local_supported_features, timeout, &Codec.decode_le_features/1)

  @doc """
  LE Read Number of Supported Advertising Sets. An extended advertising
  command: Reset before using legacy advertising or scanning commands.
  """
  @spec le_read_num_supported_adv_sets(GenServer.server(), pos_integer()) :: read_result(byte())
  def le_read_num_supported_adv_sets(server, timeout \\ @command_timeout),
    do: read(server, :le_read_num_supported_adv_sets, timeout, &Codec.decode_num_adv_sets/1)

  @doc "Set Event Mask (64-bit `mask`, see `Bluez.HciUser.Codec.event_mask/1`)."
  @spec set_event_mask(GenServer.server(), non_neg_integer(), pos_integer()) :: status_result()
  def set_event_mask(server, mask, timeout \\ @command_timeout),
    do: write(server, :set_event_mask, Codec.event_mask(mask), timeout)

  @doc "LE Set Event Mask (64-bit `mask`)."
  @spec le_set_event_mask(GenServer.server(), non_neg_integer(), pos_integer()) :: status_result()
  def le_set_event_mask(server, mask, timeout \\ @command_timeout),
    do: write(server, :le_set_event_mask, Codec.event_mask(mask), timeout)

  @doc """
  LE Set Scan Parameters; `opts` as `Bluez.HciUser.Codec.scan_parameters/1`
  (raises `ArgumentError` on invalid ones, in the caller).
  """
  @spec le_set_scan_parameters(GenServer.server(), keyword(), pos_integer()) :: status_result()
  def le_set_scan_parameters(server, opts, timeout \\ @command_timeout),
    do: write(server, :le_set_scan_parameters, Codec.scan_parameters(opts), timeout)

  @doc "LE Set Scan Enable."
  @spec le_set_scan_enable(GenServer.server(), boolean(), boolean(), pos_integer()) ::
          status_result()
  def le_set_scan_enable(server, enable, filter_duplicates, timeout \\ @command_timeout),
    do: write(server, :le_set_scan_enable, Codec.scan_enable(enable, filter_duplicates), timeout)

  @doc """
  LE Set Advertising Parameters (legacy); `opts` as
  `Bluez.HciUser.Codec.advertising_parameters/1` (raises `ArgumentError`
  on invalid ones, in the caller).
  """
  @spec le_set_advertising_parameters(GenServer.server(), keyword(), pos_integer()) ::
          status_result()
  def le_set_advertising_parameters(server, opts, timeout \\ @command_timeout),
    do: write(server, :le_set_advertising_parameters, Codec.advertising_parameters(opts), timeout)

  @doc "LE Set Advertising Data (legacy): at most 31 AD bytes, sent verbatim."
  @spec le_set_advertising_data(GenServer.server(), binary(), pos_integer()) :: status_result()
  def le_set_advertising_data(server, data, timeout \\ @command_timeout),
    do: write(server, :le_set_advertising_data, Codec.advertising_data(data), timeout)

  @doc "LE Set Advertising Enable (legacy)."
  @spec le_set_advertising_enable(GenServer.server(), boolean(), pos_integer()) :: status_result()
  def le_set_advertising_enable(server, enable, timeout \\ @command_timeout),
    do: write(server, :le_set_advertising_enable, Codec.advertising_enable(enable), timeout)

  defp write(server, name, params, timeout),
    do: server |> command(Codec.opcode(name), params, timeout) |> status()

  defp status({:ok, _return_params}), do: :ok
  defp status({:error, _reason} = error), do: error

  defp read(server, name, timeout, decoder) do
    case command(server, Codec.opcode(name), <<>>, timeout) do
      {:ok, rp} when is_binary(rp) -> decode(decoder.(rp))
      {:ok, :pending} -> {:error, :malformed_reply}
      {:error, _reason} = error -> error
    end
  end

  defp decode({:ok, _value} = ok), do: ok
  defp decode(:error), do: {:error, :malformed_reply}

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    mgmt_timeout = Keyword.get(opts, :mgmt_timeout, @mgmt_timeout)
    # Test seams: fun(index) -> {:ok, socket} | {:error, reason}, and
    # fun() -> {:ok, socket} | {:error, reason} for MGMT.
    open = Keyword.get(opts, :open, &Hci.open(:user, &1))
    open_control = Keyword.get(opts, :open_control, &open_control/0)

    with {:ok, index} <- resolve(opts, open_control, mgmt_timeout),
         :ok <- maybe_power_off(opts, index, open_control, mgmt_timeout),
         {:ok, sock} <- bind(open, index) do
      state = %{
        sock: sock,
        index: index,
        owner: owner,
        owner_mon: Process.monitor(owner),
        ncmd_timeout: Keyword.get(opts, :ncmd_timeout, @ncmd_timeout),
        # Num_HCI_Command_Packets: the controller starts out able to take one.
        credits: 1,
        ncmd_timer: nil,
        # Waiting to be sent, in call order, and the one command sent.
        queue: :queue.new(),
        in_flight: nil,
        closed: nil
      }

      Logger.info("Bluez.HciUser: bound the user channel on hci#{index}")
      {:ok, state, {:continue, :drain}}
    else
      # Exits normally, so a linked caller isn't taken down (OTP 26+).
      {:error, _reason} = error -> error
    end
  end

  defp resolve(opts, open_control, timeout) do
    case {Keyword.get(opts, :index), Keyword.get(opts, :address)} do
      {index, nil} when valid_index?(index) ->
        {:ok, index}

      {nil, address} when address != nil ->
        case find_index(address, open_control: open_control, timeout: timeout) do
          {:ok, index} -> {:ok, index}
          {:error, reason} -> {:error, {:resolve, reason}}
        end

      _other ->
        {:error, {:invalid_option, :index_or_address}}
    end
  end

  defp maybe_power_off(opts, index, open_control, timeout) do
    if Keyword.get(opts, :power_off_first, true) do
      case with_control(open_control, &mgmt(&1, Hci.op_set_powered(), index, <<0>>, timeout)) do
        {:ok, _settings} -> :ok
        {:error, reason} -> {:error, {:power_off, reason}}
      end
    else
      :ok
    end
  end

  defp bind(open, index) do
    case open.(index) do
      {:ok, sock} -> {:ok, sock}
      {:error, reason} -> {:error, {:bind, reason}}
    end
  end

  @impl GenServer
  def handle_continue(:drain, state), do: state |> drain(@drain_batch) |> noreply()

  @impl GenServer
  def handle_call({:command, opcode, params, deadline}, from, state) do
    if now() >= deadline do
      # Expired while waiting in the mailbox: never sent.
      {:reply, {:error, :timeout}, state}
    else
      ref = make_ref()

      entry = %{
        ref: ref,
        opcode: opcode,
        packet: Codec.command_packet(opcode, params),
        from: from,
        deadline: deadline,
        timer: Process.send_after(self(), {:command_timeout, ref}, deadline, abs: true)
      }

      %{state | queue: :queue.in(entry, state.queue)}
      |> dispatch()
      |> noreply()
    end
  end

  def handle_call(:index, _from, state), do: {:reply, {:ok, state.index}, state}

  @impl GenServer
  def handle_info({:"$socket", sock, :select, _handle}, %{sock: sock} = state),
    do: state |> drain(@drain_batch) |> noreply()

  def handle_info({:"$socket", sock, :abort, {_handle, reason}}, %{sock: sock} = state),
    do: state |> close_down({:abort, reason}) |> noreply()

  def handle_info(:drain, state), do: state |> drain(@drain_batch) |> noreply()

  # Unanswered in flight: the controller is faulty, and a late reply could
  # be taken for a later command's. Close rather than guess.
  def handle_info({:command_timeout, ref}, %{in_flight: %{ref: ref}} = state),
    do: state |> fault(:command_timeout) |> noreply()

  def handle_info({:command_timeout, ref}, state), do: state |> drop_queued(ref) |> noreply()

  def handle_info({:ncmd_timeout, timer}, %{ncmd_timer: timer} = state) do
    Logger.warning("Bluez.HciUser: hci#{state.index} granted no command credit; assuming one")
    notify(state, :command_stall)
    %{state | credits: 1, ncmd_timer: nil} |> dispatch() |> noreply()
  end

  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{owner_mon: mon} = state),
    do: {:stop, :normal, state}

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    # Pending callers learn now rather than at their call timeout.
    _ = fail_pending(state)
    # Closing the socket hands the controller back to the kernel.
    :socket.close(state.sock)
    :ok
  end

  defp noreply(%{closed: nil} = state), do: {:noreply, state}
  defp noreply(state), do: {:stop, :normal, state}

  # ── flow control ──────────────────────────────────────────────────────────

  defp dispatch(%{closed: nil, in_flight: nil} = state) when state.credits > 0 do
    case :queue.out(state.queue) do
      {{:value, entry}, queue} -> send_command(%{state | queue: queue}, entry)
      {:empty, _queue} -> state
    end
  end

  defp dispatch(state), do: state

  # Bounded by the command's deadline: a socket that can't take the packet
  # by then is as faulty as a controller that doesn't answer.
  defp send_command(state, entry) do
    case remaining(entry) do
      0 ->
        Process.cancel_timer(entry.timer)
        GenServer.reply(entry.from, {:error, :timeout})
        dispatch(state)

      timeout ->
        case :socket.send(state.sock, entry.packet, [], timeout) do
          :ok ->
            %{state | credits: state.credits - 1, in_flight: entry}

          {:error, :timeout} ->
            fault(%{state | in_flight: entry}, :send_timeout)

          {:error, {:timeout, _unsent}} ->
            fault(%{state | in_flight: entry}, :send_timeout)

          {:error, reason} ->
            close_down(%{state | in_flight: entry}, reason)
        end
    end
  end

  defp remaining(entry), do: max(entry.deadline - now(), 0)

  # The in-flight command failed by timing out: its caller gets
  # {:error, :timeout}, everything else {:error, :closed}.
  defp fault(%{in_flight: entry} = state, reason) do
    Process.cancel_timer(entry.timer)
    GenServer.reply(entry.from, {:error, :timeout})
    close_down(%{state | in_flight: nil}, reason)
  end

  # Num_HCI_Command_Packets from a Command Complete/Status.
  defp credits(state, ncmd) do
    state = %{state | credits: ncmd}

    if ncmd == 0 and state.in_flight == nil,
      do: arm_ncmd_timer(state),
      else: cancel_ncmd_timer(state)
  end

  defp arm_ncmd_timer(%{ncmd_timer: nil} = state) do
    timer = make_ref()
    Process.send_after(self(), {:ncmd_timeout, timer}, state.ncmd_timeout)
    %{state | ncmd_timer: timer}
  end

  defp arm_ncmd_timer(state), do: state

  # A stale timer message is ignored by its ref.
  defp cancel_ncmd_timer(state), do: %{state | ncmd_timer: nil}

  # The reply to the in-flight command, if it is for its opcode.
  defp complete(%{in_flight: %{opcode: opcode} = entry} = state, opcode, reply) do
    Process.cancel_timer(entry.timer)
    GenServer.reply(entry.from, reply)
    %{state | in_flight: nil}
  end

  # Unsolicited (opcode 0x0000): it only grants credits.
  defp complete(state, _opcode, _reply), do: state

  defp drop_queued(state, ref) do
    {timed_out, queue} = state.queue |> :queue.to_list() |> Enum.split_with(&(&1.ref == ref))
    Enum.each(timed_out, &GenServer.reply(&1.from, {:error, :timeout}))
    %{state | queue: :queue.from_list(queue)}
  end

  # ── socket ────────────────────────────────────────────────────────────────

  # Read until the socket would block (re-arming the select), the batch is
  # spent (yield via :drain), or it fails.
  defp drain(%{closed: nil} = state, 0) do
    send(self(), :drain)
    state
  end

  defp drain(%{closed: nil} = state, budget) do
    case :socket.recv(state.sock, 0, [], :nowait) do
      # HCI never sends an empty packet: the socket reached end of file.
      {:ok, <<>>} -> close_down(state, :eof)
      {:ok, packet} -> packet |> Codec.decode_event() |> handle_event(state) |> drain(budget - 1)
      {:select, _info} -> state
      {:error, reason} -> close_down(state, reason)
    end
  end

  defp drain(state, _budget), do: state

  defp handle_event({:command_complete, ncmd, opcode, rp}, state) do
    reply =
      case rp do
        <<0, return_params::binary>> -> {:ok, return_params}
        <<>> -> {:ok, <<>>}
        <<status, _::binary>> -> {:error, {:status, status}}
      end

    state |> complete(opcode, reply) |> credits(ncmd) |> dispatch()
  end

  defp handle_event({:command_status, status, ncmd, opcode}, state) do
    reply = if status == 0, do: {:ok, :pending}, else: {:error, {:status, status}}
    state |> complete(opcode, reply) |> credits(ncmd) |> dispatch()
  end

  defp handle_event({:adv_reports, reports}, state) do
    Enum.each(reports, &notify(state, {:adv_report, &1}))
    state
  end

  defp handle_event({:hardware_error, code}, state) do
    Logger.warning("Bluez.HciUser: hci#{state.index} reported hardware error 0x#{hex(code)}")
    notify(state, {:hardware_error, code})
    state
  end

  defp handle_event({:event, _code, _params} = event, state) do
    notify(state, event)
    state
  end

  defp handle_event(:ignore, state), do: state

  # The socket is gone: fail every command, tell the owner, then stop.
  defp close_down(%{closed: nil} = state, reason) do
    Logger.info("Bluez.HciUser: user channel on hci#{state.index} closed (#{inspect(reason)})")
    state = fail_pending(state)
    notify(state, {:closed, reason})
    %{state | closed: reason}
  end

  defp close_down(state, _reason), do: state

  defp fail_pending(state) do
    entries = List.wrap(state.in_flight) ++ :queue.to_list(state.queue)

    Enum.each(entries, fn entry ->
      Process.cancel_timer(entry.timer)
      GenServer.reply(entry.from, {:error, :closed})
    end)

    %{state | in_flight: nil, queue: :queue.new()}
  end

  defp notify(state, event), do: send(state.owner, {:bluez_hci_user, self(), event})

  defp hex(byte), do: byte |> Integer.to_string(16) |> String.pad_leading(2, "0")

  # ── MGMT (bring-up) ───────────────────────────────────────────────────────

  defp open_control, do: Hci.open(:control)

  defp with_control(open_control, fun) do
    case open_control.() do
      {:ok, sock} ->
        try do
          fun.(sock)
        after
          :socket.close(sock)
        end

      {:error, reason} ->
        {:error, {:control_socket, reason}}
    end
  end

  # One MGMT command, answered by its Command Complete (→ `{:ok, params}`)
  # or a failing Command Status. Events for other controllers/commands on
  # the shared control channel are skipped.
  defp mgmt(sock, opcode, index, params, timeout) do
    case :socket.send(sock, Hci.mgmt_command(opcode, index, params)) do
      :ok -> await_mgmt(sock, opcode, index, deadline(timeout))
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_mgmt(sock, opcode, index, deadline) do
    case :socket.recv(sock, 0, max(deadline - now(), 0)) do
      {:ok, packet} ->
        case Hci.decode_mgmt(packet) do
          {:ok, {:cmd_complete, ^index, ^opcode, :success, params}} ->
            {:ok, params}

          {:ok, {:cmd_complete, ^index, ^opcode, status, _params}} ->
            {:error, status}

          {:ok, {:cmd_status, ^index, ^opcode, status}} when status != :success ->
            {:error, status}

          _other ->
            await_mgmt(sock, opcode, index, deadline)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deadline(timeout), do: now() + timeout
  defp now, do: System.monotonic_time(:millisecond)
end
