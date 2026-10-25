defmodule Bluez.Mgmt do
  @moduledoc """
  Raw LE advertising through the kernel management (MGMT) API: the AD
  bytes you build go on air verbatim, on any controller the kernel drives.

  BlueZ's D-Bus advertising API (`LEAdvertisement1`) builds the AD bytes
  itself and can't express every layout: it refuses Flags, UUID lists,
  names and service data in its free-form `Data`, and moves `LocalName`
  into the scan response of connectable adverts. Protocols that carry
  their payload in the advertising PDU itself — a Local Name *and* a
  128-bit UUID list in one legacy advert, or an opaque payload as an
  ordered 16-bit UUID list with repeated values — need the bytes handed to
  the kernel as they are. This process does that over an
  `HCI_CHANNEL_CONTROL` socket (`Bluez.Hci.open/2`), using *Add Extended
  Advertising Parameters* + *Add Extended Advertising Data* (legacy PDUs
  unless a secondary-PHY flag is set) so the interval can be set — the
  kernel default of 1.28 s misses short bursts.

  Requires Linux 5.17 or later. The commands exist since 5.11, but before
  5.17 the kernel refuses an advertising command as busy while another
  one (from any socket, `bluetoothd`'s included) is still pending, rather
  than queueing it; this module's cleanup relies on the queueing.

  ## Leases

  Sending needs the controller's lease, acquired with `mode: :mgmt`
  (`Bluez.Radio`): call `advertise/3` and `stop_advertising/3` from the
  lease holder. The lease names the controller, and ending it —
  `Bluez.Radio.release/1`, the holder exiting, or the Radio stopping —
  removes every instance sent under it.

  ## Instances

  Advertising instances are numbered per controller. Without `instance:`,
  an advertisement goes to the highest instance that is free on the
  controller or already ours (Read Advertising Features lists the occupied
  ones), so it never takes over one `bluetoothd` holds; repeated default
  sends reuse that instance, each replacing the last. An explicit
  `instance:` is used as given, replacing whatever occupies it. A
  controller with several hardware advertising sets (most USB dongles and
  recent SoC radios) keeps several instances on air at once.

  Every instance added here is removed again when its `duration_ms:`
  elapses, on `stop_advertising/3`, when its lease ends, and when this
  process stops (crashes included: `terminate/2` removes them). A removal
  the kernel refuses leaves the instance tracked, so stopping it again or
  shutdown still covers it. Only an untrappable kill skips that cleanup;
  the kernel then keeps the instances until they are removed or the
  controller is reset.

  ## Software rotation

  Controllers without extended advertising (e.g. the Raspberry Pi's
  onboard BCM43438) have one advertising set, which the kernel shares
  between instances in software, roughly 2 s per instance. Accepting an
  instance there doesn't mean it is on air yet, so with another instance
  registered a short `duration_ms:` advertisement could be removed before
  it ever transmits. `advertise/3` therefore refuses a finite
  `duration_ms:` with `{:error, :rotation_busy}` when the controller lacks
  hardware offload (`Bluez.Hci.adv_hw_offload?/1`) and any other instance
  is registered. Every send reads the controller's advertising features
  first to decide this.

  ## Address

  The kernel picks the advertising address: a **connectable** instance
  (`flags: [:connectable]`) uses the controller's identity address
  (public, or the static random address if one is configured), stable
  across sends; a **non-connectable** one uses a fresh non-resolvable
  private address each time it is added. Choose accordingly when the
  receiver keys on the sender address.

  `bluetoothd` must not have the legacy "Advertising" setting enabled
  (`btmgmt advertising on`) — the kernel rejects instances while it is.

  ## Start options

    * `radio:` — the `Bluez.Radio` whose leases to accept (default
      `Bluez.Radio`); leases from any other are refused.
    * `name:` — registered name (default `Bluez.Mgmt`).
  """

  use GenServer
  require Logger

  alias Bluez.{AdData, Hci, Radio}
  alias Bluez.Radio.Lease

  # Per-send patience in terminate/2 (see there).
  @terminate_send_timeout 100

  # Per-command patience for the kernel's reply; MGMT always answers, so
  # hitting this means the socket is wedged — restart with a fresh one.
  @command_timeout 5_000

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Add (or replace) an advertising instance carrying `adv_data` verbatim,
  on the controller `lease` covers. Call it from the lease holder.

  Options:

    * `:scan_response` — raw scan-response AD bytes (default none).
    * `:duration_ms` — remove the instance after this many ms (default:
      advertise until stopped).
    * `:instance` — instance number (default: see "Instances").
    * `:server` — the `Bluez.Mgmt` to use (default `Bluez.Mgmt`).
    * `:flags`, `:min_interval_ms`, `:max_interval_ms`, `:tx_power` — see
      `Bluez.Hci.add_ext_adv_params/2`. `:min_interval_ms`/
      `:max_interval_ms` default to 20/30 ms.

  Returns `{:ok, instance}` once the kernel has accepted the data, or
  `{:error, reason}` — a MGMT status atom (`:busy`, `:invalid_params`,
  `:rejected`, `:not_supported`, …), `:no_free_instance`, `:rotation_busy`
  (see "Software rotation"), `:not_lease_holder`, `{:mode, mode}` for a
  lease of another mode, `:lease_expired`, `:too_long`,
  `{:invalid, message}` for bad options, or `:not_running`.
  """
  @spec advertise(Lease.t(), binary(), keyword()) :: {:ok, byte()} | {:error, term()}
  def advertise(lease, adv_data, opts \\ []) when is_binary(adv_data) do
    # Checked here, in the caller: only the holder sends, and a bad option
    # can never crash the server mid-job.
    with :ok <- Radio.check_holder(lease, :mgmt),
         :ok <- validate(adv_data, opts) do
      server_call(Keyword.get(opts, :server, __MODULE__), {:advertise, lease, adv_data, opts})
    end
  end

  defp validate(adv_data, opts) do
    scan_rsp = Keyword.get(opts, :scan_response, <<>>)

    cond do
      not is_binary(scan_rsp) -> invalid("scan_response")
      byte_size(adv_data) > 255 or byte_size(scan_rsp) > 255 -> {:error, :too_long}
      not valid_opt?(opts, :instance, &(&1 in 1..254)) -> invalid("instance")
      not valid_opt?(opts, :duration_ms, &(is_integer(&1) and &1 > 0)) -> invalid("duration_ms")
      true -> validate_params(opts)
    end
  end

  defp valid_opt?(opts, key, fun) do
    case Keyword.get(opts, key) do
      nil -> true
      value -> fun.(value)
    end
  end

  defp invalid(what), do: {:error, {:invalid, what}}

  defp validate_params(opts) do
    _ = Hci.add_ext_adv_params(1, params_opts(opts))
    :ok
  rescue
    e in [ArgumentError, FunctionClauseError, CaseClauseError] ->
      {:error, {:invalid, Exception.message(e)}}
  end

  defp params_opts(opts) do
    opts
    |> Keyword.take([:flags, :min_interval_ms, :max_interval_ms, :tx_power])
    |> Keyword.put_new(:min_interval_ms, 20)
    |> Keyword.put_new(:max_interval_ms, 30)
    |> Keyword.put(:scan_response, Keyword.get(opts, :scan_response, <<>>) != <<>>)
  end

  @doc """
  Remove an instance `advertise/3` added under `lease` (call it from the
  holder). Returns once the kernel has confirmed. `{:error,
  :unknown_instance}` when the lease holds no such instance.
  """
  @spec stop_advertising(Lease.t(), byte(), GenServer.server()) :: :ok | {:error, term()}
  def stop_advertising(lease, instance, server \\ __MODULE__) when instance in 1..254 do
    with :ok <- Radio.check_holder(lease, :mgmt),
         do: server_call(server, {:stop_advertising, lease, instance})
  end

  @doc """
  Controller `index`'s advertising capabilities (*Read Advertising
  Features*): supported flags, maximum data lengths, instance count and
  the instances currently registered (by anyone). Read-only, so no lease
  is needed.
  """
  @spec read_advertising_features(non_neg_integer(), GenServer.server()) ::
          {:ok, map()} | {:error, term()}
  def read_advertising_features(index, server \\ __MODULE__) when is_integer(index),
    do: server_call(server, {:read_advertising_features, index})

  @doc """
  Convenience for the common legacy layout: a Flags element (default
  `0x06`) followed by `elements`, encoded with `Bluez.AdData.encode/1`.
  Raises `ArgumentError` when the result exceeds 31 bytes.
  """
  @spec legacy_adv_data([AdData.element()], keyword()) :: binary()
  def legacy_adv_data(elements, opts \\ []) do
    flags = Keyword.get(opts, :flags, 0x06)
    data = AdData.encode([AdData.flags(flags) | elements])

    if byte_size(data) > AdData.legacy_max_length(),
      do: raise(ArgumentError, "advertising data is #{byte_size(data)} bytes (max 31)")

    data
  end

  # `catch :exit` idiom (see `Bluez`): not running → error tuple. No call
  # timeout: a request still queued when the caller gave up would run
  # anyway, and its outcome (an instance on air) would go unreported. The
  # server can't stall a caller forever — every MGMT command has a
  # watchdog that restarts it, which exits this call.
  defp server_call(server, request) do
    GenServer.call(server, request, :infinity)
  catch
    :exit, _reason -> {:error, :not_running}
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    # Test seam: fun() -> {:ok, socket} | {:error, reason}.
    open = Keyword.get(opts, :open, fn -> Hci.open(:control) end)

    case open.() do
      {:ok, sock} ->
        state = %{
          sock: sock,
          command_timeout: Keyword.get(opts, :command_timeout, @command_timeout),
          # The Radio whose lease ends we receive (see subscribe/1).
          radio: Keyword.get(opts, :radio, Radio),
          radio_pid: nil,
          radio_mon: nil,
          # The in-flight job (one MGMT command at a time) and the queue.
          job: nil,
          queue: :queue.new(),
          # {controller_index, instance} => %{lease_ref, timer, gen, removing}
          instances: %{}
        }

        {:ok, state |> subscribe() |> arm()}

      {:error, reason} ->
        # No Bluetooth / no permission: not something a restart fixes.
        Logger.warning("Bluez.Mgmt: cannot open the MGMT socket (#{inspect(reason)})")
        :ignore
    end
  end

  @impl GenServer
  def handle_call({:advertise, lease, adv_data, opts}, from, state) do
    state = subscribe(state)

    if lease_valid?(state, lease) do
      job = %{from: from, kind: {:advertise, lease, adv_data, opts}, steps: []}
      {:noreply, enqueue(state, job)}
    else
      {:reply, {:error, :lease_expired}, state}
    end
  end

  def handle_call({:stop_advertising, %Lease{index: index, ref: ref}, instance}, from, state) do
    key = {index, instance}

    case state.instances do
      # Also while a removal (an expiry's, say) is pending: this one queues
      # behind it, and is skipped as stale if that one succeeds.
      %{^key => %{lease_ref: ^ref}} ->
        {:noreply, cleanup(state, key, from)}

      _not_held_under_this_lease ->
        {:reply, {:error, :unknown_instance}, state}
    end
  end

  def handle_call({:read_advertising_features, index}, from, state) do
    job = %{from: from, kind: :features, steps: [{Hci.op_read_adv_features(), index, <<>>}]}
    {:noreply, enqueue(state, job)}
  end

  @impl GenServer
  def handle_info({:"$socket", sock, :select, _handle}, %{sock: sock} = state),
    do: {:noreply, arm(state)}

  # The pending select was aborted (socket closed under us): nothing would
  # re-arm it, so restart with a fresh socket rather than go deaf.
  def handle_info({:"$socket", sock, :abort, {_handle, reason}}, %{sock: sock} = state) do
    Logger.error("Bluez.Mgmt: MGMT socket aborted (#{inspect(reason)}); restarting")
    {:stop, {:mgmt_socket_abort, reason}, state}
  end

  def handle_info({:command_timeout, ref}, %{job: %{ref: ref}} = state) do
    Logger.error("Bluez.Mgmt: MGMT command timed out; restarting with a fresh socket")
    {:stop, :mgmt_command_timeout, state}
  end

  def handle_info({:expire, key, timer}, state) do
    case state.instances do
      %{^key => %{timer: ^timer}} -> {:noreply, cleanup(state, key, nil)}
      _other -> {:noreply, state}
    end
  end

  # The lease ended (released, or its holder exited): take everything
  # sent under it off air.
  def handle_info({:radio_lease_ended, ref}, state),
    do: {:noreply, end_leases(state, &(&1 == ref))}

  # The Radio went away, and every lease with it. The next send
  # re-subscribes (to its restarted incarnation, when registered by name).
  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{radio_mon: mon} = state) do
    state = %{state | radio_pid: nil, radio_mon: nil}
    {:noreply, end_leases(state, fn _ref -> true end)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    # Best effort: don't leave our instances on air after we're gone —
    # including one whose parameters the kernel may already have accepted
    # while its data command is still in flight.
    #
    # Bounded sends: we may be stopping *because* the socket is wedged
    # (:mgmt_command_timeout), and an unbounded send would then block until
    # the supervisor kills us. The first send that times out ends the
    # attempt, so the total stays bounded too.
    keys = Enum.uniq(in_flight(state) ++ Map.keys(state.instances))

    _ =
      Enum.reduce_while(keys, :ok, fn {index, instance}, :ok ->
        command = Hci.mgmt_command(Hci.op_remove_advertising(), index, <<instance>>)

        case :socket.send(state.sock, command, [], @terminate_send_timeout) do
          {:error, :timeout} -> {:halt, :timeout}
          _sent_or_failed -> {:cont, :ok}
        end
      end)

    :socket.close(state.sock)
  end

  # Lease ends come from the Radio we subscribed to (and monitor); a lease
  # from any other would end without telling us, so it is refused. Retried
  # on each send while no Radio was reachable.
  defp subscribe(%{radio_pid: nil} = state) do
    case Radio.subscribe(state.radio) do
      {:ok, pid} -> %{state | radio_pid: pid, radio_mon: Process.monitor(pid)}
      {:error, :not_running} -> state
    end
  end

  defp subscribe(state), do: state

  defp lease_valid?(%{radio_pid: pid}, %Lease{radio: pid} = lease) when is_pid(pid),
    do: Radio.valid?(lease)

  defp lease_valid?(_state, _lease), do: false

  # ── job queue ─────────────────────────────────────────────────────────────

  # `gen` ties a removal to the advertisement it was queued for: if the
  # instance has been re-advertised by the time it runs (an expiry racing
  # the holder's replacement), the removal is stale and skipped (see
  # start_job/2).
  defp remove_job({index, instance} = key, gen, from) do
    %{
      from: from,
      kind: {:remove, key, gen},
      steps: [{Hci.op_remove_advertising(), index, <<instance>>}]
    }
  end

  defp enqueue(state, job), do: next(%{state | queue: :queue.in(job, state.queue)})

  defp next(%{job: nil} = state) do
    case :queue.out(state.queue) do
      {{:value, job}, queue} -> start_job(%{state | queue: queue}, job)
      {:empty, _queue} -> state
    end
  end

  defp next(state), do: state

  # Every advertise starts with Read Advertising Features: it picks the
  # default instance and tells whether the controller rotates instances in
  # software (see prepared/4). A send queued behind its lease's end is
  # refused rather than put on air.
  defp start_job(state, %{kind: {:advertise, lease, adv_data, opts}} = job) do
    if Radio.valid?(lease) do
      steps = [{Hci.op_read_adv_features(), lease.index, <<>>}]
      send_step(state, %{job | steps: steps, kind: {:prepare, lease, adv_data, opts}})
    else
      finish(state, job, {:error, :lease_expired})
    end
  end

  defp start_job(state, %{kind: {:remove, key, gen}} = job) do
    if current?(state, key, gen),
      do: send_step(state, job),
      else: finish(state, job, :ok)
  end

  defp start_job(state, job), do: send_step(state, job)

  # Options were validated by advertise/3 in the caller, so building the
  # parameters here cannot raise.
  defp start_advertise(state, job, lease, instance, adv_data, opts) do
    index = lease.index

    steps = [
      {Hci.op_add_ext_adv_params(), index, Hci.add_ext_adv_params(instance, params_opts(opts))},
      {Hci.op_add_ext_adv_data(), index,
       Hci.add_ext_adv_data(instance, adv_data, Keyword.get(opts, :scan_response, <<>>))}
    ]

    send_step(state, %{job | steps: steps, kind: {:advertising, lease, instance, opts}})
  end

  defp send_step(state, %{steps: [{opcode, index, params} | _rest]} = job) do
    case :socket.send(state.sock, Hci.mgmt_command(opcode, index, params)) do
      :ok ->
        ref = make_ref()
        Process.send_after(self(), {:command_timeout, ref}, state.command_timeout)
        %{state | job: Map.put(job, :ref, ref)}

      # Through failed/3, so a data command that can't be sent still gets
      # its half-made instance rolled back.
      {:error, reason} ->
        failed(state, job, {:error, reason})
    end
  end

  # A reply for the in-flight step. Success advances the job; the first
  # failure ends it.
  defp step_done(%{job: %{steps: [{opcode, _i, _p} | rest]} = job} = state, opcode, result) do
    state = %{state | job: nil}

    case {result, rest} do
      {{:ok, params}, []} -> complete(state, job, params)
      {{:ok, _params}, _more} -> send_step(state, %{job | steps: rest})
      {{:error, _status} = error, _rest} -> failed(state, job, error)
    end
  end

  defp step_done(state, _opcode, _result), do: state

  defp complete(state, %{kind: {:prepare, lease, adv_data, opts}} = job, params) do
    case Hci.decode_adv_features(params) do
      {:ok, features} -> prepared(state, job, {lease, adv_data, opts}, features)
      :error -> finish(state, job, {:error, :malformed_reply})
    end
  end

  # On air. If the lease ended while the commands were in flight, its
  # end-of-lease cleanup ran without this instance: take it back off air
  # now instead of reporting success.
  defp complete(state, %{kind: {:advertising, lease, instance, opts}} = job, _params) do
    key = {lease.index, instance}
    state = track(state, lease, key, opts)

    if Radio.valid?(lease) do
      finish(state, job, {:ok, instance})
    else
      if job.from, do: GenServer.reply(job.from, {:error, :lease_expired})
      cleanup(%{state | job: nil}, key, nil)
    end
  end

  defp complete(state, %{kind: :features} = job, params) do
    result =
      case Hci.decode_adv_features(params) do
        {:ok, features} -> {:ok, features}
        :error -> {:error, :malformed_reply}
      end

    finish(state, job, result)
  end

  defp complete(state, %{kind: {:remove, key, gen}} = job, _params),
    do: finish(removed(state, key, gen), job, :ok)

  # Parameters accepted but data refused leaves a half-made instance:
  # report the failure and remove it. It is tracked under the lease (as
  # being removed, replacing any older entry — the accepted parameters
  # already overwrote that advertisement) so a failed rollback is still
  # covered by stop_advertising/3 and shutdown.
  defp failed(state, %{kind: {:advertising, lease, instance, _opts}, steps: [_data]} = job, error) do
    if job.from, do: GenServer.reply(job.from, error)

    key = {lease.index, instance}
    gen = make_ref()
    entry = %{lease_ref: lease.ref, timer: nil, gen: gen, removing: true}
    state = %{state | instances: Map.put(state.instances, key, entry)}

    enqueue(%{state | job: nil}, remove_job(key, gen, nil))
  end

  # Remove Advertising for an instance (or controller) the kernel no
  # longer has: it's gone, which is what was asked.
  defp failed(state, %{kind: {:remove, key, gen}} = job, {:error, status})
       when status in [:invalid_params, :invalid_index],
       do: finish(removed(state, key, gen), job, :ok)

  # Any other removal failure: keep tracking it as live (its duration
  # trigger is spent, but stop_advertising/3 and shutdown still cover it).
  defp failed(state, %{kind: {:remove, key, gen}} = job, error) do
    state =
      if current?(state, key, gen),
        do: update_in(state.instances[key], &%{&1 | removing: false}),
        else: state

    finish(state, job, error)
  end

  defp failed(state, job, error), do: finish(state, job, error)

  defp finish(state, job, reply) do
    if job.from, do: GenServer.reply(job.from, reply)
    next(%{state | job: nil})
  end

  # The instance whose parameters the kernel may already have accepted
  # while its data command is still in flight.
  defp in_flight(state) do
    case state.job do
      %{kind: {:advertising, lease, instance, _opts}} -> [{lease.index, instance}]
      _other -> []
    end
  end

  # ── instance tracking ─────────────────────────────────────────────────────

  # Replacing an instance we already track drops the old bookkeeping.
  defp track(state, lease, key, opts) do
    timer =
      case opts[:duration_ms] do
        ms when is_integer(ms) and ms > 0 ->
          timer = make_ref()
          Process.send_after(self(), {:expire, key, timer}, ms)
          timer

        nil ->
          nil
      end

    entry = %{lease_ref: lease.ref, timer: timer, gen: make_ref(), removing: false}
    %{state | instances: Map.put(state.instances, key, entry)}
  end

  # Take everything sent under the leases `ended?` matches off air (those
  # not already being removed).
  defp end_leases(state, ended?) do
    ended =
      for {key, %{lease_ref: ref, removing: false}} <- state.instances, ended?.(ref), do: key

    Enum.reduce(ended, state, &cleanup(&2, &1, nil))
  end

  # Removal of exactly this advertisement (stop, expiry, lease end).
  defp cleanup(state, key, from) do
    state = mark_removing(state, key)
    enqueue(state, remove_job(key, state.instances[key].gen, from))
  end

  # Start taking `key` off air. It stays tracked (flagged `removing`) until
  # the kernel confirms, so a failed removal is still covered by a retry
  # and shutdown; its duration trigger is spent.
  defp mark_removing(state, key) do
    entry = Map.fetch!(state.instances, key)
    put_in(state.instances[key], %{entry | timer: nil, removing: true})
  end

  # With the controller's features in hand: settle the instance, and refuse
  # a finite advertisement the kernel would only rotate in. Without hardware
  # offload, instances share the air in ~2 s software slots, so with another
  # instance active a short `duration_ms:` can be removed before it ever
  # transmits — while add/data report success.
  defp prepared(state, job, {lease, adv_data, opts}, features) do
    instance = opts[:instance] || pick_instance(state, lease.index, features)

    cond do
      instance == nil ->
        finish(state, job, {:error, :no_free_instance})

      opts[:duration_ms] != nil and not Hci.adv_hw_offload?(features.supported_flags) and
          Enum.any?(features.instances, &(&1 != instance)) ->
        finish(state, job, {:error, :rotation_busy})

      true ->
        start_advertise(state, job, lease, instance, adv_data, opts)
    end
  end

  # Highest instance that is free on the controller or already ours there
  # (re-advertising replaces our own); never one someone else holds.
  defp pick_instance(state, index, %{max_instances: max, instances: in_use}) when max > 0 do
    Enum.find(max..1//-1, fn instance ->
      Map.has_key?(state.instances, {index, instance}) or instance not in in_use
    end)
  end

  defp pick_instance(_state, _index, _features), do: nil

  defp current?(state, key, gen), do: match?(%{gen: ^gen}, state.instances[key])

  defp removed(state, key, gen),
    do: if(current?(state, key, gen), do: untrack(state, key), else: state)

  defp untrack(state, key), do: %{state | instances: Map.delete(state.instances, key)}

  # ── socket ────────────────────────────────────────────────────────────────

  defp arm(state) do
    case :socket.recv(state.sock, 0, [], :nowait) do
      {:ok, packet} -> packet |> handle_packet(state) |> arm()
      {:select, _info} -> state
      {:error, reason} -> exit({:mgmt_socket_error, reason})
    end
  end

  defp handle_packet(packet, state) do
    case Hci.decode_mgmt(packet) do
      {:ok, {:cmd_complete, _index, opcode, :success, params}} ->
        step_done(state, opcode, {:ok, params})

      {:ok, {:cmd_complete, _index, opcode, status, _params}} ->
        step_done(state, opcode, {:error, status})

      # Command Status is only sent for failures (or pending async work,
      # which Command Complete then finishes).
      {:ok, {:cmd_status, _index, opcode, status}} when status != :success ->
        step_done(state, opcode, {:error, status})

      # Someone else (bluetoothd restarting, an expiring kernel timeout)
      # removed one of our instances: stop tracking it. The socket sees
      # every controller's events; the key holds the index.
      {:ok, {:advertising_removed, index, instance}} ->
        untrack(state, {index, instance})

      # The controller went away (a USB dongle unplugged), its instances
      # with it. Forget them, so a controller later given the same index
      # isn't mistaken for holding ours.
      {:ok, {:index_removed, index}} ->
        %{state | instances: Map.reject(state.instances, &match?({{^index, _}, _}, &1))}

      _other ->
        state
    end
  end
end
