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
  `bluetoothd`, which allocates its own from 1 upward. Instances added
  here default to the controller's *highest* instance number
  (`read_advertising_features/0`) to stay clear of it; pass `instance:`
  to manage several. Every instance added here is removed again when its
  `duration_ms:` elapses, when its owner process exits, on
  `stop_advertising/1`, and when this process stops.

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

  @call_timeout 10_000
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
  `:rejected`, `:not_supported`, …), `:too_long`, `{:invalid, message}`
  for bad options, or `:not_running`.
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

  # `catch :exit` idiom (see `Bluez`): not running / wedged → error tuple.
  defp server_call(server, request) do
    GenServer.call(server, request, @call_timeout)
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
      {:ok, _entry} ->
        {:noreply, cleanup(state, instance, from)}

      :error ->
        {:reply, {:error, :unknown_instance}, state}
    end
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

    Enum.each(Enum.uniq(in_flight ++ tracked), fn {index, instance} ->
      :socket.send(state.sock, Hci.mgmt_command(Hci.op_remove_advertising(), index, <<instance>>))
    end)

    :socket.close(state.sock)
  end

  # ── job queue ─────────────────────────────────────────────────────────────

  # `gen` ties a removal to the advertisement it was queued for: if the
  # instance has been re-advertised by the time it runs, the removal is
  # stale and skipped (see start_job/2). `:rollback` removes unconditionally.
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

  # Advertise needs the default instance first, which may need a Read
  # Advertising Features round-trip; resolve the steps lazily.
  defp start_job(state, %{kind: {:advertise, index, adv_data, opts}} = job) do
    case opts[:instance] do
      nil ->
        steps = [{Hci.op_read_adv_features(), index, <<>>}]
        send_step(state, %{job | steps: steps, kind: {:pick_instance, index, adv_data, opts}})

      instance ->
        start_advertise(state, job, index, instance, adv_data, opts)
    end
  end

  defp start_job(state, %{kind: {:remove, instance, gen}} = job) do
    if gen == :rollback or current?(state, instance, gen),
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

      {:error, reason} ->
        finish(state, job, {:error, reason})
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

  defp complete(state, %{kind: {:pick_instance, index, adv_data, opts}} = job, params) do
    case Hci.decode_adv_features(params) do
      {:ok, %{max_instances: max}} when max > 0 ->
        start_advertise(state, job, index, max, adv_data, opts)

      _other ->
        finish(state, job, {:error, :no_advertising_instances})
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
    rollback = remove_job(index, instance, :rollback, nil)
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

  # Start taking `instance` off air. It stays tracked (flagged `removing`)
  # until the kernel confirms, so a failed removal is still covered by
  # stop_advertising/1 and shutdown; owner and duration triggers are spent.
  defp cleanup(state, instance, from) do
    entry = Map.fetch!(state.instances, instance)
    if entry.owner_ref, do: Process.demonitor(entry.owner_ref, [:flush])
    entry = %{entry | owner_ref: nil, timer: nil, removing: true}
    state = put_in(state.instances[instance], entry)
    enqueue(state, remove_job(entry.index, instance, entry.gen, from))
  end

  defp current?(state, instance, gen), do: match?(%{gen: ^gen}, state.instances[instance])

  defp removed(state, instance, :rollback), do: untrack(state, instance)

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
  defp index(_state), do: Hci.adapter_index(DevicePath.adapter_path())
end
