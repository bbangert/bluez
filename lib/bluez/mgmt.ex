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

  Advertising instances are a per-controller namespace shared with
  `bluetoothd`, which allocates its own from 1 upward. Without
  `instance:`, an advertisement goes to the highest instance number that
  is free or already ours (`read_advertising_features/0` lists the
  occupied ones), so it never takes over `bluetoothd`'s; repeated default
  sends reuse that one instance, each replacing the last. An explicit
  `instance:` is used as given — replacing whatever occupies it. Every
  instance added here is removed again when its `duration_ms:` elapses,
  when its owner process exits, on `stop_advertising/1`, and when this
  process stops.

  `bluetoothd` doesn't know about instances added here, so a D-Bus
  advertisement could later be given the same number and silently
  overwrite one. `Bluez.Advertiser` guards against that by consulting
  `held_instances/1` and refusing with `{:error, :instance_conflict}`
  while bluetoothd's next pick could collide; on a one-instance
  controller the two paths take turns. That check is a snapshot, not a
  reservation, so don't advertise through both on the same controller
  concurrently — drive them from one process.

  Without the `adapter_index:` start option, requests are refused with
  `{:error, :no_adapter_index}` until `Bluez.Client` has resolved the
  adapter, so nothing is ever left on the `hci0` fallback.

  ## Software rotation

  Controllers without extended advertising (e.g. the Raspberry Pi's
  onboard BCM43438) have one advertising set; the kernel shares it
  between instances in software, roughly 2 s per instance. Accepting an
  instance there doesn't mean it is on air yet, so with another instance
  active (bluetoothd's, say) a short `duration_ms:` advertisement could be
  removed before it ever transmits. `advertise/2` therefore refuses a
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
  """

  use GenServer
  require Logger

  alias Bluez.{AdData, DevicePath, Hci}

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
  Add (or replace) an advertising instance carrying `adv_data` verbatim.

  Options:

    * `:scan_response` — raw scan-response AD bytes (default none).
    * `:duration_ms` — remove the instance after this many ms (default:
      advertise until stopped).
    * `:instance` — instance number (default: the controller's highest).
    * `:owner` — pid whose exit removes the instance (default: the
      caller). Pass `nil` to tie it to this process only.
    * `:server` — the `Bluez.Mgmt` to use (default `Bluez.Mgmt`).
    * `:flags`, `:min_interval_ms`, `:max_interval_ms`, `:tx_power` — see
      `Bluez.Hci.add_ext_adv_params/2`. `:min_interval_ms`/
      `:max_interval_ms` default to 20/30 ms.

  Returns `{:ok, instance}` once the kernel has accepted the data, or
  `{:error, reason}` — a MGMT status atom (`:busy`, `:invalid_params`,
  `:rejected`, `:not_supported`, …), `:no_free_instance`, `:rotation_busy`
  (see "Software rotation"), `:too_long`, `{:invalid, message}` for bad
  options, or `:not_running`.
  """
  @spec advertise(binary(), keyword()) :: {:ok, byte()} | {:error, term()}
  def advertise(adv_data, opts \\ []) when is_binary(adv_data) do
    opts = Keyword.put_new(opts, :owner, self())

    # Validate here, in the caller, so a bad option can never crash the
    # server mid-job.
    with :ok <- validate(adv_data, opts) do
      server_call(Keyword.get(opts, :server, __MODULE__), {:advertise, adv_data, opts})
    end
  end

  defp validate(adv_data, opts) do
    scan_rsp = Keyword.get(opts, :scan_response, <<>>)

    cond do
      not is_binary(scan_rsp) -> invalid("scan_response")
      byte_size(adv_data) > 255 or byte_size(scan_rsp) > 255 -> {:error, :too_long}
      not valid_opt?(opts, :instance, &(&1 in 1..254)) -> invalid("instance")
      not valid_opt?(opts, :duration_ms, &(is_integer(&1) and &1 > 0)) -> invalid("duration_ms")
      not valid_opt?(opts, :owner, &is_pid/1) -> invalid("owner")
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

  @doc "Remove an instance added by `advertise/2`."
  @spec stop_advertising(byte(), GenServer.server()) :: :ok | {:error, term()}
  def stop_advertising(instance, server \\ __MODULE__) when instance in 1..254,
    do: server_call(server, {:stop_advertising, instance})

  @doc """
  The controller's advertising capabilities (*Read Advertising
  Features*): supported flags, maximum data lengths, instance count and
  the instances currently registered (by anyone).
  """
  @spec read_advertising_features(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def read_advertising_features(server \\ __MODULE__),
    do: server_call(server, :read_advertising_features)

  @doc """
  The `{controller_index, instance}` pairs this process holds, including
  one being set up right now. `bluetoothd` doesn't know about them, so
  `Bluez.Advertiser` checks these before registering (see its moduledoc).
  `[]` when not running.
  """
  @spec held_instances(GenServer.server()) :: [{non_neg_integer(), byte()}]
  def held_instances(server \\ __MODULE__) do
    GenServer.call(server, :held_instances)
  catch
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
          adapter_index: Keyword.get(opts, :adapter_index),
          command_timeout: Keyword.get(opts, :command_timeout, @command_timeout),
          # The in-flight job (one MGMT command at a time) and the queue.
          job: nil,
          queue: :queue.new(),
          # instance => %{index, owner_ref, timer}
          instances: %{}
        }

        {:ok, arm(state)}

      {:error, reason} ->
        # No Bluetooth / no permission: not something a restart fixes.
        Logger.warning("Bluez.Mgmt: cannot open the MGMT socket (#{inspect(reason)})")
        :ignore
    end
  end

  @impl GenServer
  def handle_call({:advertise, adv_data, opts}, from, state) do
    case index(state) do
      {:ok, index} ->
        job = %{
          from: from,
          kind: {:advertise, index, adv_data, opts},
          steps: []
        }

        {:noreply, enqueue(state, job)}

      :error ->
        {:reply, {:error, :no_adapter_index}, state}
    end
  end

  def handle_call({:stop_advertising, instance}, from, state) do
    case Map.fetch(state.instances, instance) do
      # :current — an explicit stop removes whatever occupies the instance
      # when it runs, including a replacement that lands meanwhile.
      {:ok, entry} ->
        state = mark_removing(state, instance)
        {:noreply, enqueue(state, remove_job(entry.index, instance, :current, from))}

      :error ->
        {:reply, {:error, :unknown_instance}, state}
    end
  end

  def handle_call(:held_instances, _from, state) do
    tracked = for {instance, entry} <- state.instances, do: {entry.index, instance}

    in_flight =
      case state.job do
        %{kind: {:advertising, index, instance, _opts}} -> [{index, instance}]
        _other -> []
      end

    {:reply, Enum.uniq(in_flight ++ tracked), state}
  end

  def handle_call(:read_advertising_features, from, state) do
    case index(state) do
      {:ok, index} ->
        job = %{
          from: from,
          kind: :features,
          steps: [{Hci.op_read_adv_features(), index, <<>>}]
        }

        {:noreply, enqueue(state, job)}

      :error ->
        {:reply, {:error, :no_adapter_index}, state}
    end
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

  def handle_info({:expire, instance, timer}, state) do
    case state.instances do
      %{^instance => %{timer: ^timer}} ->
        {:noreply, cleanup(state, instance, nil)}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    owned = for {instance, %{owner_ref: ^ref}} <- state.instances, do: instance
    {:noreply, Enum.reduce(owned, state, &cleanup(&2, &1, nil))}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    # Best effort: don't leave our instances on air after we're gone —
    # including one whose parameters the kernel may already have accepted
    # while its data command is still in flight.
    tracked = for {instance, entry} <- state.instances, do: {entry.index, instance}

    in_flight =
      case state.job do
        %{kind: {:advertising, index, instance, _opts}} -> [{index, instance}]
        _other -> []
      end

    # Bounded sends: we may be stopping *because* the socket is wedged
    # (:mgmt_command_timeout), and an unbounded send would then block until
    # the supervisor kills us. The first send that times out ends the
    # attempt, so the total stays bounded too.
    _ =
      Enum.reduce_while(Enum.uniq(in_flight ++ tracked), :ok, fn {index, instance}, :ok ->
        command = Hci.mgmt_command(Hci.op_remove_advertising(), index, <<instance>>)

        case :socket.send(state.sock, command, [], @terminate_send_timeout) do
          {:error, :timeout} -> {:halt, :timeout}
          _sent_or_failed -> {:cont, :ok}
        end
      end)

    :socket.close(state.sock)
  end

  # ── job queue ─────────────────────────────────────────────────────────────

  # `gen` ties an automatic removal (expiry, owner exit) to the
  # advertisement it was queued for: if the instance has been re-advertised
  # by the time it runs, the removal is stale and skipped (see start_job/2).
  # An explicit stop passes `:current` instead.
  defp remove_job(index, instance, gen, from) do
    %{
      from: from,
      kind: {:remove, instance, gen},
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
  defp start_job(state, %{kind: {:advertise, index, adv_data, opts}} = job) do
    steps = [{Hci.op_read_adv_features(), index, <<>>}]
    send_step(state, %{job | steps: steps, kind: {:prepare, index, adv_data, opts}})
  end

  defp start_job(state, %{kind: {:remove, instance, :current}} = job) do
    case state.instances[instance] do
      %{index: index, gen: gen} ->
        state = mark_removing(state, instance)
        steps = [{Hci.op_remove_advertising(), index, <<instance>>}]
        send_step(state, %{job | kind: {:remove, instance, gen}, steps: steps})

      nil ->
        finish(state, job, :ok)
    end
  end

  defp start_job(state, %{kind: {:remove, instance, gen}} = job) do
    if current?(state, instance, gen),
      do: send_step(state, job),
      else: finish(state, job, :ok)
  end

  defp start_job(state, job), do: send_step(state, job)

  # Options were validated by advertise/2 in the caller, so building the
  # parameters here cannot raise.
  defp start_advertise(state, job, index, instance, adv_data, opts) do
    steps = [
      {Hci.op_add_ext_adv_params(), index, Hci.add_ext_adv_params(instance, params_opts(opts))},
      {Hci.op_add_ext_adv_data(), index,
       Hci.add_ext_adv_data(instance, adv_data, Keyword.get(opts, :scan_response, <<>>))}
    ]

    send_step(state, %{job | steps: steps, kind: {:advertising, index, instance, opts}})
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

  defp complete(state, %{kind: {:prepare, index, adv_data, opts}} = job, params) do
    case Hci.decode_adv_features(params) do
      {:ok, features} -> prepared(state, job, {index, adv_data, opts}, features)
      :error -> finish(state, job, {:error, :malformed_reply})
    end
  end

  defp complete(state, %{kind: {:advertising, index, instance, opts}} = job, _params) do
    state = track(state, index, instance, opts)
    finish(state, job, {:ok, instance})
  end

  defp complete(state, %{kind: :features} = job, params) do
    result =
      case Hci.decode_adv_features(params) do
        {:ok, features} -> {:ok, features}
        :error -> {:error, :malformed_reply}
      end

    finish(state, job, result)
  end

  defp complete(state, %{kind: {:remove, instance, gen}} = job, _params),
    do: finish(removed(state, instance, gen), job, :ok)

  # Parameters accepted but data refused leaves a half-made instance:
  # report the failure, then remove it as the very next job — ahead of
  # anything queued, which may be a new advertisement on the same instance.
  defp failed(state, %{kind: {:advertising, index, instance, _opts}, steps: [_data]} = job, error) do
    if job.from, do: GenServer.reply(job.from, error)

    # Track it (as being removed, replacing any older entry — the accepted
    # parameters already overwrote that advertisement) so a failed rollback
    # is still covered by stop_advertising/1 and shutdown.
    state = untrack(state, instance)
    gen = make_ref()
    entry = %{index: index, owner_ref: nil, timer: nil, gen: gen, removing: true}
    state = put_in(state.instances[instance], entry)

    rollback = remove_job(index, instance, gen, nil)
    next(%{state | job: nil, queue: :queue.in_r(rollback, state.queue)})
  end

  # Remove Advertising for an instance the kernel no longer has: it's gone,
  # which is what was asked.
  defp failed(state, %{kind: {:remove, instance, gen}} = job, {:error, :invalid_params}),
    do: finish(removed(state, instance, gen), job, :ok)

  # Any other removal failure: keep tracking it (owner/duration cleanup is
  # spent, but stop_advertising/1 and shutdown still cover it).
  defp failed(state, %{kind: {:remove, instance, gen}} = job, error) do
    state =
      if current?(state, instance, gen),
        do: update_in(state.instances[instance], &%{&1 | removing: false}),
        else: state

    finish(state, job, error)
  end

  defp failed(state, job, error), do: finish(state, job, error)

  defp finish(state, job, reply) do
    if job.from, do: GenServer.reply(job.from, reply)
    next(%{state | job: nil})
  end

  # ── instance tracking ─────────────────────────────────────────────────────

  defp track(state, index, instance, opts) do
    # Replacing an instance we already track: drop the old bookkeeping.
    state = untrack(state, instance)

    owner_ref =
      case opts[:owner] do
        pid when is_pid(pid) -> Process.monitor(pid)
        nil -> nil
      end

    timer =
      case opts[:duration_ms] do
        ms when is_integer(ms) and ms > 0 ->
          timer = make_ref()
          Process.send_after(self(), {:expire, instance, timer}, ms)
          timer

        nil ->
          nil
      end

    entry = %{index: index, owner_ref: owner_ref, timer: timer, gen: make_ref(), removing: false}
    %{state | instances: Map.put(state.instances, instance, entry)}
  end

  # Automatic removal (expiry, owner exit) of exactly this advertisement.
  defp cleanup(state, instance, from) do
    state = mark_removing(state, instance)
    entry = state.instances[instance]
    enqueue(state, remove_job(entry.index, instance, entry.gen, from))
  end

  # Start taking `instance` off air. It stays tracked (flagged `removing`)
  # until the kernel confirms, so a failed removal is still covered by
  # stop_advertising/1 and shutdown; owner and duration triggers are spent.
  defp mark_removing(state, instance) do
    entry = Map.fetch!(state.instances, instance)
    if entry.owner_ref, do: Process.demonitor(entry.owner_ref, [:flush])
    put_in(state.instances[instance], %{entry | owner_ref: nil, timer: nil, removing: true})
  end

  # With the controller's features in hand: settle the instance, and refuse
  # a finite advertisement the kernel would only rotate in. Without hardware
  # offload, instances share the air in ~2 s software slots, so with another
  # instance active a short `duration_ms:` can be removed before it ever
  # transmits — while add/data report success.
  defp prepared(state, job, {index, adv_data, opts}, features) do
    instance = opts[:instance] || pick_instance(state, index, features)

    cond do
      instance == nil ->
        finish(state, job, {:error, :no_free_instance})

      opts[:duration_ms] != nil and not Hci.adv_hw_offload?(features.supported_flags) and
          Enum.any?(features.instances, &(&1 != instance)) ->
        finish(state, job, {:error, :rotation_busy})

      true ->
        start_advertise(state, job, index, instance, adv_data, opts)
    end
  end

  # Highest instance that is free on the controller or already ours there
  # (re-advertising replaces our own); never one someone else holds.
  defp pick_instance(state, index, %{max_instances: max, instances: in_use}) when max > 0 do
    Enum.find(max..1//-1, fn instance ->
      match?(%{index: ^index}, state.instances[instance]) or instance not in in_use
    end)
  end

  defp pick_instance(_state, _index, _features), do: nil

  defp current?(state, instance, gen), do: match?(%{gen: ^gen}, state.instances[instance])

  defp removed(state, instance, gen),
    do: if(current?(state, instance, gen), do: untrack(state, instance), else: state)

  defp untrack(state, instance) do
    case Map.pop(state.instances, instance) do
      {nil, _instances} ->
        state

      {entry, instances} ->
        if entry.owner_ref, do: Process.demonitor(entry.owner_ref, [:flush])
        %{state | instances: instances}
    end
  end

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
      # every controller's events, so match the index too.
      {:ok, {:advertising_removed, index, instance}} ->
        case state.instances[instance] do
          %{index: ^index} -> untrack(state, instance)
          _other -> state
        end

      _other ->
        state
    end
  end

  defp index(%{adapter_index: index}) when is_integer(index), do: {:ok, index}

  defp index(_state) do
    with {:ok, path} <- DevicePath.resolved_adapter_path(), do: Hci.adapter_index(path)
  end
end
