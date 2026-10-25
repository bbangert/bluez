defmodule Bluez.Mgmt do
  @moduledoc """
  Raw advertising through the kernel management (MGMT) API, for
  advertisements `LEAdvertisement1` (`Bluez.Advertiser`) cannot express.

  BlueZ's D-Bus advertising API builds the AD bytes itself: it refuses
  Flags, UUID lists, names and service data in its free-form `Data`
  property, moves `LocalName` into the scan response for connectable
  adverts, and adds Flags only when discoverable. Protocols that need a
  specific byte layout in the advertising PDU — e.g. a Local Name *and* a
  128-bit UUID list in one legacy advert, as Tuya Beacon P1 frames and
  virtual-remote frames do — need the AD bytes handed to the kernel
  verbatim. This process does that over an `HCI_CHANNEL_CONTROL` socket
  (`Bluez.Hci.open/2`), using *Add Extended Advertising Parameters* +
  *Add Extended Advertising Data* (kernel ≥ 5.11; legacy PDUs unless a
  secondary-PHY flag is set) so the advertising interval can be set — the
  kernel default of 1.28 s is useless for short bursts.

  Sending requires the controller's transmit lease (`Bluez.Radio`): call
  `advertise/3` and `stop_advertising/3` from the process holding it. The
  lease also names the controller, and ending it — `Bluez.Radio.release/1`
  or the holder exiting — removes every instance sent under it.

  Advertising instances are a per-controller namespace shared with
  `bluetoothd`, which allocates its own from 1 upward. Without
  `instance:`, an advertisement goes to the highest instance number that
  is free or already ours (Read Advertising Features lists the occupied
  ones), so it never takes over `bluetoothd`'s; repeated default sends
  reuse that one instance, each replacing the last. An explicit
  `instance:` is used as given — replacing whatever occupies it. Every
  instance added here is removed again when its `duration_ms:` elapses,
  on `stop_advertising/3`, when its lease ends, and when this process
  stops. A removal the kernel refuses after its lease ended — so no
  holder is left to retry it — is retried here a few times.

  `bluetoothd` doesn't know about instances added here, so a D-Bus
  advertisement could later be given the same number and silently
  overwrite one; `Bluez.Advertiser` checks `held_instances/1` before
  registering and refuses with `{:error, :instance_conflict}` when it
  could (see its moduledoc). Because only the lease holder sends, one
  call at a time, that check is exact.

  ## Software rotation

  Controllers without extended advertising (e.g. the Raspberry Pi's
  onboard BCM43438) have one advertising set; the kernel shares it
  between instances in software, roughly 2 s per instance. Accepting an
  instance there doesn't mean it is on air yet, so with another instance
  active (bluetoothd's, say) a short `duration_ms:` advertisement could be
  removed before it ever transmits. `advertise/3` therefore refuses a
  finite `duration_ms:` with `{:error, :rotation_busy}` when the
  controller lacks hardware offload (`Bluez.Hci.adv_hw_offload?/1`) and any
  other instance is registered. Every request reads the controller's
  advertising features first to decide this.

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

  # Retries of a removal the kernel refused after its lease ended.
  @orphan_retries 3
  @orphan_retry_ms 2_000

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
    * `:instance` — instance number (default: the controller's highest).
    * `:server` — the `Bluez.Mgmt` to use (default `Bluez.Mgmt`).
    * `:flags`, `:min_interval_ms`, `:max_interval_ms`, `:tx_power` — see
      `Bluez.Hci.add_ext_adv_params/2`. `:min_interval_ms`/
      `:max_interval_ms` default to 20/30 ms.

  Returns `{:ok, instance}` once the kernel has accepted the data, or
  `{:error, reason}` — a MGMT status atom (`:busy`, `:invalid_params`,
  `:rejected`, `:not_supported`, …), `:no_free_instance`, `:rotation_busy`
  (see "Software rotation"), `:not_lease_holder`, `:lease_expired`,
  `:too_long`, `{:invalid, message}` for bad options, or `:not_running`.
  """
  @spec advertise(Lease.t(), binary(), keyword()) :: {:ok, byte()} | {:error, term()}
  def advertise(lease, adv_data, opts \\ []) when is_binary(adv_data) do
    # Checked here, in the caller: only the holder sends, and a bad option
    # can never crash the server mid-job.
    with :ok <- Radio.check_holder(lease),
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
  holder). `{:error, :unknown_instance}` when the lease holds no such
  instance.
  """
  @spec stop_advertising(Lease.t(), byte(), GenServer.server()) :: :ok | {:error, term()}
  def stop_advertising(lease, instance, server \\ __MODULE__) when instance in 1..254 do
    with :ok <- Radio.check_holder(lease),
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
  The `{controller_index, instance}` pairs this process holds, including
  one being set up right now. `bluetoothd` doesn't know about them, so
  `Bluez.Advertiser` checks these before registering (see its moduledoc).
  `[]` when not running; `:unknown` when it doesn't answer within
  `timeout` — wedged rather than off, so callers must not assume it holds
  nothing.
  """
  @spec held_instances(GenServer.server(), timeout()) :: [{non_neg_integer(), byte()}] | :unknown
  def held_instances(server \\ __MODULE__, timeout \\ 5_000) do
    GenServer.call(server, :held_instances, timeout)
  catch
    :exit, {:timeout, _call} -> :unknown
    :exit, _reason -> []
  end

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
  # timeout: queued jobs can legitimately take longer than any fixed
  # deadline, and giving up early would leave work running whose outcome
  # (an instance on air) the caller never learns. The server can't stall a
  # caller forever — every MGMT command has a watchdog that restarts it,
  # which exits this call.
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
          # Test seam: the delay between orphan-removal retries.
          retry_ms: Keyword.get(opts, :retry_ms, @orphan_retry_ms),
          # The Radio whose lease ends we receive (see subscribe/1).
          radio: Keyword.get(opts, :radio, Radio),
          radio_pid: nil,
          radio_mon: nil,
          # Ended leases not yet reported drained to the Radio (settle/1).
          draining: MapSet.new(),
          # The in-flight job (one MGMT command at a time) and the queue.
          job: nil,
          queue: :queue.new(),
          # {controller_index, instance} => %{lease_ref, lease_ended,
          #   retries, timer, gen, removing} — instance numbers are
          #   per controller, and one lease may name any controller.
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
      %{^key => %{lease_ref: ^ref, removing: false}} ->
        {:noreply, cleanup(state, key, from)}

      _not_held_under_this_lease ->
        {:reply, {:error, :unknown_instance}, state}
    end
  end

  def handle_call(:held_instances, _from, state),
    do: {:reply, Enum.uniq(in_flight(state) ++ Map.keys(state.instances)), state}

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
      %{^key => %{timer: ^timer}} ->
        {:noreply, cleanup(state, key, nil)}

      _other ->
        {:noreply, state}
    end
  end

  # The lease ended (released, or its holder exited): take everything
  # sent under it off air.
  def handle_info({:radio_lease_ended, ref}, state) do
    state = end_leases(state, &(&1 == ref))
    {:noreply, settle(%{state | draining: MapSet.put(state.draining, ref)})}
  end

  # The Radio went away, and every lease with it. The next send
  # re-subscribes (to its restarted incarnation, when registered by name).
  def handle_info({:DOWN, mon, :process, _pid, _reason}, %{radio_mon: mon} = state) do
    state = %{state | radio_pid: nil, radio_mon: nil, draining: MapSet.new()}
    {:noreply, end_leases(state, fn _ref -> true end)}
  end

  def handle_info({:retry_remove, key, gen}, state) do
    case state.instances do
      %{^key => %{gen: ^gen, removing: false}} -> {:noreply, cleanup(state, key, nil)}
      _other -> {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    # Best effort: don't leave our instances on air after we're gone —
    # including one whose parameters the kernel may already have accepted
    # while its data command is still in flight.
    tracked = Map.keys(state.instances)

    # Bounded sends: we may be stopping *because* the socket is wedged
    # (:mgmt_command_timeout), and an unbounded send would then block until
    # the supervisor kills us. The first send that times out ends the
    # attempt, so the total stays bounded too.
    _ =
      Enum.reduce_while(Enum.uniq(in_flight(state) ++ tracked), :ok, fn {index, instance}, :ok ->
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

  # Report each ended lease drained once nothing sent under it is in
  # flight here — no job of its queued or running, no instance of its
  # still tracked — so the Radio can hand the controller on.
  defp settle(%{draining: draining} = state) do
    done = Enum.reject(draining, &pending?(state, &1))
    Enum.each(done, &Radio.drained(state.radio_pid, &1))
    %{state | draining: MapSet.difference(draining, MapSet.new(done))}
  end

  defp pending?(state, ref) do
    Enum.any?([state.job | :queue.to_list(state.queue)], &lease_job?(&1, ref)) or
      Enum.any?(state.instances, fn {_key, entry} -> entry.lease_ref == ref end)
  end

  defp lease_job?(%{kind: {_step, %Lease{ref: ref}, _arg, _opts}}, ref), do: true
  defp lease_job?(_job, _ref), do: false

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
  # software (see prepared/4).
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
      {{:ok, params}, []} ->
        complete(state, job, params)

      {{:ok, _params}, _more} ->
        send_step(state, %{job | steps: rest})

      {{:error, _status} = error, _rest} ->
        failed(state, job, error)
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
  # end-of-lease cleanup already ran without this instance: take it back
  # off air now instead of reporting success.
  defp complete(state, %{kind: {:advertising, lease, instance, opts}} = job, _params) do
    key = {lease.index, instance}
    state = track(state, lease, key, opts)

    if Radio.valid?(lease) do
      finish(state, job, {:ok, instance})
    else
      if job.from, do: GenServer.reply(job.from, {:error, :lease_expired})
      state = put_in(state.instances[key].lease_ended, true)
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
  # covered by stop_advertising/3, the lease ending and shutdown.
  defp failed(state, %{kind: {:advertising, lease, instance, _opts}, steps: [_data]} = job, error) do
    if job.from, do: GenServer.reply(job.from, error)

    key = {lease.index, instance}
    gen = make_ref()
    entry = %{new_entry(lease, gen) | removing: true}
    state = %{state | instances: Map.put(state.instances, key, entry)}

    enqueue(%{state | job: nil}, remove_job(key, gen, nil))
  end

  # Remove Advertising for an instance the kernel no longer has: it's gone,
  # which is what was asked.
  defp failed(state, %{kind: {:remove, key, gen}} = job, {:error, :invalid_params}),
    do: finish(removed(state, key, gen), job, :ok)

  # Any other removal failure: keep tracking it as live (its duration
  # trigger is spent, but stop_advertising/3, the lease ending and shutdown
  # still cover it; after the lease ended, retry_orphan/2 does).
  defp failed(state, %{kind: {:remove, key, gen}} = job, error) do
    state =
      if current?(state, key, gen) do
        state
        |> update_in([:instances, key], &%{&1 | removing: false})
        |> retry_orphan(key)
      else
        state
      end

    finish(state, job, error)
  end

  defp failed(state, job, error), do: finish(state, job, error)

  defp finish(state, job, reply) do
    if job.from, do: GenServer.reply(job.from, reply)
    %{state | job: nil} |> next() |> settle()
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

    entry = %{new_entry(lease, make_ref()) | timer: timer}
    %{state | instances: Map.put(state.instances, key, entry)}
  end

  defp new_entry(lease, gen) do
    %{
      lease_ref: lease.ref,
      # Its lease is over: nobody is left to retry a failed removal.
      lease_ended: false,
      retries: 0,
      timer: nil,
      gen: gen,
      removing: false
    }
  end

  # Take everything sent under the leases `ended?` matches off air.
  defp end_leases(state, ended?) do
    ended = for {key, %{lease_ref: ref}} <- state.instances, ended?.(ref), do: key

    Enum.reduce(ended, state, fn key, state ->
      state = put_in(state.instances[key].lease_ended, true)

      # One already being removed is retried if that removal fails.
      if state.instances[key].removing,
        do: state,
        else: cleanup(state, key, nil)
    end)
  end

  # A removal refused after its lease ended has no holder left to retry
  # it: retry it here, a few times, before leaving it to shutdown.
  defp retry_orphan(state, {index, instance} = key) do
    case state.instances[key] do
      %{lease_ended: true, retries: n, gen: gen} when n < @orphan_retries ->
        Process.send_after(self(), {:retry_remove, key, gen}, state.retry_ms)
        put_in(state.instances[key].retries, n + 1)

      # Detached from its lease, so the lease counts as drained.
      %{lease_ended: true} ->
        Logger.warning(
          "Bluez.Mgmt: giving up removing hci#{index} instance #{instance} until shutdown"
        )

        put_in(state.instances[key].lease_ref, nil)

      _live_lease ->
        state
    end
  end

  # Removal of exactly this advertisement (stop, expiry, lease end).
  defp cleanup(state, key, from) do
    state = mark_removing(state, key)
    enqueue(state, remove_job(key, state.instances[key].gen, from))
  end

  # Start taking `instance` off air. It stays tracked (flagged `removing`)
  # until the kernel confirms, so a failed removal is still covered by a
  # retry and shutdown; its duration trigger is spent.
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
        state |> untrack({index, instance}) |> settle()

      _other ->
        state
    end
  end
end
