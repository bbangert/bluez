defmodule Bluez.Client do
  @moduledoc """
  Persistent `rebus` D-Bus client + service to `org.bluez`, driving BLE
  scanning and turning device signals into advertisements, fanned out
  through the `on_advertisement:` fun.

  Supports both scanner modes Home Assistant can request (`set_mode/1`,
  called via `BluetoothScanner.set_scanner_mode/1`):

    * `:passive` (default) — a BlueZ `AdvertisementMonitor`. We never send
      scan requests, so scannable peripherals don't burn battery answering
      us. Requires *exporting* a D-Bus object BlueZ calls back into, so this
      process is both a client and a service (via the forked rebus's
      `set_method_handler/2`).
    * `:active` — `Adapter1.StartDiscovery` with an LE filter. BlueZ sends
      scan requests, so SCAN_RSP data (e.g. device names) is collected —
      parity with ESP32 proxies' active mode.

  Device data arrives the same way in both modes
  (`InterfacesAdded`/`PropertiesChanged` on `Device1` objects), so the
  advert pipeline downstream is mode-agnostic.

  Flow:

    1. `Rebus.connect(:system)`, `set_method_handler(self())`, monitor the
       connection, and install bus match rules for org.bluez device signals.
    2. Power the adapter on, then engage `configured_mode/0`: either
       `AdvertisementMonitorManager1.RegisterMonitor` our root object (BlueZ
       enumerates the monitor via `ObjectManager.GetManagedObjects` and calls
       `Activate`/`DeviceFound` on it; the monitor's `or_patterns` (FLAGS
       \\x02/\\x06/\\x1a) match effectively all advertisers — the habluetooth
       "match all" recipe), or `SetDiscoveryFilter` + `StartDiscovery`.
    3. Matched devices surface as `InterfacesAdded`/`PropertiesChanged` signals;
       props are unwrapped (`Bluez.Variant`) and fed to
       `Bluez.DeviceCache`, which reconstructs + emit-gates and
       returns the adverts to fan out via `BluetoothScanner.on_advertisement/1`.

  Mode transitions:

    * Run in a Task — BlueZ calls `GetManagedObjects` back on us before
      `RegisterMonitor` returns, so the GenServer must stay free to answer —
      and are serialized: at most one in flight, identified by a generation
      ref so a stale Task result can't corrupt state. A `set_mode/1` arriving
      mid-transition parks in a one-slot pending queue keyed by target mode:
      callers asking for the same target coalesce (all get `:ok` when it
      lands); a different target displaces them with `{:error, :superseded}`
      (latest target wins).
    * Transitions engage the new mode BEFORE disengaging the old one
      (monitor and discovery can legally coexist in BlueZ): a failed engage
      leaves the previous mode still scanning rather than going dark.
      Disengage is best-effort, and self-healing lives in engage's
      idempotency: whatever drifted, re-engaging treats
      `AlreadyExists`/`InProgress` as success, so the next transition always
      converges on the target mode.
    * The configured mode persists in `:persistent_term` across Client
      restarts: a bluetoothd/connection crash re-engages what HA chose
      rather than silently reverting to passive.

  Resilience:

    * The rebus connection is monitored; if it dies (e.g. a malformed bus
      frame `:stop`s it) the Client stops and the supervisor restarts it,
      re-establishing the connection.
    * Setup retries via `send_after` (not `Process.sleep`) so the GenServer
      stays responsive while waiting for `bluetoothd` to claim org.bluez.
  """

  use GenServer
  require Logger

  alias Bluez.{DBus, DeviceCache, DevicePath, Variant}

  @adapter_iface "org.bluez.Adapter1"
  @device_iface "org.bluez.Device1"
  @advmon_mgr_iface "org.bluez.AdvertisementMonitorManager1"
  @advmon_iface "org.bluez.AdvertisementMonitor1"
  @props_iface "org.freedesktop.DBus.Properties"
  @om_iface "org.freedesktop.DBus.ObjectManager"
  @introspect_iface "org.freedesktop.DBus.Introspectable"
  @bluez "org.bluez"

  # Our exported ObjectManager root + the single monitor object beneath it.
  @root_path "/org/exbluez/advmon"
  @monitor_path "/org/exbluez/advmon/monitor0"

  # bluetoothd may not have claimed org.bluez/hci0 the instant we start.
  @setup_retries 20
  @setup_retry_ms 500

  # Timeout for the (Task-issued) RegisterMonitor call to BlueZ.
  @register_timeout_ms 10_000

  # set_mode/1 callers wait for the whole transition — and a caller parked
  # behind an in-flight transition waits for that one too. Budget two
  # back-to-back worst cases (each: engage RegisterMonitor 10 s + best-effort
  # disengage 5 s) plus margin; normal transitions complete in milliseconds.
  @set_mode_timeout_ms 32_000

  # Watchdog for a mode-transition Task that neither completes nor dies —
  # e.g. a D-Bus call wedged past its own timeouts. Must exceed the 32 s
  # set_mode budget so it only fires when the transition machinery itself
  # is stuck; then we stop and let the supervisor rebuild us with fresh
  # D-Bus state (a wedged connection is suspect — don't patch state).
  @transition_watchdog_ms 45_000

  # :persistent_term key for the HA-configured scanner mode. Survives Client
  # restarts (within a boot) so re-init re-engages what HA chose.
  @mode_key {__MODULE__, :configured_mode}

  # PubSub topic carrying `{:bluetooth_adapters_changed}` whenever the set
  # of org.bluez adapters changes (claim at setup, hotplug add/remove).
  # a host radio monitor subscribes and re-enumerates. Broadcast on
  # the Phoenix.PubSub passed as the `pubsub:` opt (no-op when absent), so
  # the Bluez layer carries no upward dependency.
  @adapters_topic "bluetooth:adapters"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Switch the scanner between `:passive` (AdvertisementMonitor) and `:active`
  (StartDiscovery) at runtime. Returns once the BlueZ transition completes.

  A caller whose transition is already in flight always gets that
  transition's own result. Only callers parked *behind* an in-flight
  transition can get `{:error, :superseded}` — when a newer `set_mode/1`
  asking for a different mode displaces them (same-mode callers coalesce
  and succeed together).

  Callers must `catch :exit` for the not-running/timeout cases (see the
  moduledoc idiom note in `Bluez`).
  """
  @spec set_mode(:passive | :active) :: :ok | {:error, term()}
  def set_mode(mode) when mode in [:passive, :active] do
    GenServer.call(__MODULE__, {:set_mode, mode}, @set_mode_timeout_ms)
  end

  @doc """
  Suspend scanning entirely (disengage the monitor/discovery), preserving the
  HA-configured mode so `resume_scan/0` restores it. Used by Improv Wi-Fi
  provisioning: it only runs on a no-connectivity boot, when there is no HA
  client to consume proxied advertisements anyway — so scanning is pointless
  (and may degrade the active BLE peripheral connection on a single radio).

  Fire-and-forget cast (the transition runs off-loop); safe to call when the
  Client isn't running (no-op).
  """
  @spec suspend_scan() :: :ok
  def suspend_scan, do: GenServer.cast(__MODULE__, :suspend_scan)

  @doc "Re-engage the HA-configured scanner mode after `suspend_scan/0`."
  @spec resume_scan() :: :ok
  def resume_scan, do: GenServer.cast(__MODULE__, :resume_scan)

  @doc """
  The HA-configured scanner mode (`:passive` default). Pure
  `:persistent_term` read — safe on any target, with or without the Client
  running (host tests, early boot).
  """
  @spec configured_mode() :: :passive | :active
  def configured_mode, do: :persistent_term.get(@mode_key, :passive)

  @doc "PubSub topic carrying `{:bluetooth_adapters_changed}` on adapter add/remove."
  @spec adapters_topic() :: String.t()
  def adapters_topic, do: @adapters_topic

  @doc """
  `org.bluez.Adapter1` properties for every adapter object the daemon
  exposes: `[%{path:, address:, name:, powered:}]` — e.g. for a host's
  radio list. Returns `[]` when this Client isn't running (BT subtree
  down, host tests) or the daemon can't answer.
  """
  @spec adapters_info() :: [
          %{
            path: String.t(),
            address: String.t() | nil,
            name: String.t() | nil,
            powered: boolean()
          }
        ]
  def adapters_info do
    GenServer.call(__MODULE__, :adapters_info)
  catch
    :exit, _ -> []
  end

  @doc """
  Distinct devices the advert cache has seen in the last `window_ms`
  (`Bluez.DeviceCache.seen_within/3`). `0` when this Client
  isn't running — e.g. for a host's stats ticker.
  """
  @spec devices_seen(pos_integer()) :: non_neg_integer()
  def devices_seen(window_ms) when is_integer(window_ms) and window_ms > 0 do
    GenServer.call(__MODULE__, {:devices_seen, window_ms})
  catch
    :exit, _ -> 0
  end

  @impl GenServer
  def init(opts) do
    # `connect_fun` / `apply_mode_fun` / `watchdog_ms` / `setup` are
    # test-only injection seams (host has no system D-Bus). Production
    # callers pass `on_advertisement:` (per-advert fan-out fun) and
    # `pubsub:` (adapter-change broadcasts).
    connect_fun = Keyword.get(opts, :connect_fun, fn -> Rebus.connect(:system) end)

    case connect_fun.() do
      {:ok, conn} ->
        ref = Rebus.add_signal_handler(conn)
        # Receive inbound method calls (BlueZ → our monitor object) too.
        Rebus.set_method_handler(conn, self())
        # Restart (and reconnect) if the connection dies.
        conn_ref = Process.monitor(conn)

        # rebus installs no bus-side match rules, so org.bluez's device signals
        # wouldn't reach us; ask the daemon to route them.
        if Keyword.get(opts, :setup, true), do: add_signal_matches(conn)

        state = %{
          conn: conn,
          conn_ref: conn_ref,
          sig_ref: ref,
          cache: DeviceCache.new(),
          # mode = last successfully applied mode; engaged = what BlueZ is
          # actually doing for us right now (:none until setup engages).
          mode: nil,
          engaged: :none,
          # transition = nil (idle) or the in-flight Task's bookkeeping:
          # %{ref: generation ref, task_ref: monitor, watchdog: timer,
          #   target:, froms:}. pending = one-slot queue parked behind
          # it: {target, [from]} — same-target callers coalesce, a new
          # target displaces them.
          transition: nil,
          pending: nil,
          # Advert fan-out seam: called once per reconstructed advert map.
          on_advertisement: Keyword.get(opts, :on_advertisement, fn _advert -> :ok end),
          # Phoenix.PubSub instance for adapter-change broadcasts; nil = no-op.
          pubsub: Keyword.get(opts, :pubsub),
          apply_mode_fun: Keyword.get(opts, :apply_mode_fun),
          watchdog_ms: Keyword.get(opts, :watchdog_ms, @transition_watchdog_ms),
          # Set of org.bluez adapter object paths ("/org/bluez/hciN"),
          # seeded at setup and maintained from InterfacesAdded/Removed.
          # `adapters_info/0` does a cheap per-path GetAll over this set
          # instead of a whole-tree GetManagedObjects.
          adapters: MapSet.new()
        }

        if Keyword.get(opts, :setup, true) do
          {:ok, state, {:continue, {:setup, @setup_retries}}}
        else
          {:ok, state}
        end

      {:error, reason} ->
        {:stop, {:dbus_connect_failed, reason}}
    end
  end

  @impl GenServer
  def handle_continue({:setup, retries}, state), do: attempt_setup(state, retries)

  @impl GenServer
  def handle_call(:adapters_info, _from, state) do
    {:reply, adapter_props_for(state.conn, state.adapters), state}
  end

  def handle_call({:devices_seen, window_ms}, _from, state) do
    now = System.monotonic_time(:millisecond)
    {:reply, DeviceCache.seen_within(state.cache, now, window_ms), state}
  end

  def handle_call({:set_mode, target}, from, state) do
    {:noreply, transition_to(target, [from], state)}
  end

  @impl GenServer
  # Improv provisioning suspends scanning while armed (see suspend_scan/0). `:off`
  # disengages without overwriting the persisted HA mode, so resume restores it.
  def handle_cast(:suspend_scan, state) do
    {:noreply, transition_to(:off, [], state)}
  end

  def handle_cast(:resume_scan, state) do
    {:noreply, transition_to(configured_mode(), [], state)}
  end

  # Shared by set_mode (call, froms = [from]) and suspend/resume (cast, froms = []).
  defp transition_to(target, froms, state) do
    cond do
      # A transition is running: park behind it. Same-target callers pile
      # into one pending slot and all succeed together; a different target
      # displaces them (latest target wins).
      state.transition != nil ->
        merge_pending(state, target, froms)

      # Already there (and actually engaged — a failed initial setup leaves
      # engaged: :none, which falls through and retries). `:off` is "there"
      # when nothing is engaged.
      state.mode == target and engaged_ok?(target, state.engaged) ->
        Enum.each(froms, &GenServer.reply(&1, :ok))
        state

      true ->
        start_transition(state, target, froms)
    end
  end

  defp engaged_ok?(:off, engaged), do: engaged == :none
  defp engaged_ok?(_mode, engaged), do: engaged != :none

  defp merge_pending(state, target, froms) do
    pending =
      case state.pending do
        {^target, existing} ->
          {target, froms ++ existing}

        {_other_target, existing} ->
          Enum.each(existing, &GenServer.reply(&1, {:error, :superseded}))
          {target, froms}

        nil ->
          {target, froms}
      end

    %{state | pending: pending}
  end

  @impl GenServer
  # Connection died (e.g. malformed frame stopped it). Stop so the supervisor
  # restarts us and we reconnect; rebus connections are :temporary and don't
  # restart themselves.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_ref: ref} = state) do
    {:stop, {:dbus_connection_down, reason}, state}
  end

  # Non-blocking setup retry (adapter not yet present).
  def handle_info({:setup_retry, retries}, state), do: attempt_setup(state, retries)

  # org.bluez device signals arrive as {handler_ref, %Message{type: :signal}}.
  def handle_info({ref, %Rebus.Message{type: :signal} = msg}, %{sig_ref: ref} = state) do
    {:noreply, handle_signal(msg, state)}
  end

  # Inbound method calls from BlueZ into our exported monitor/ObjectManager.
  def handle_info({:dbus_call, %Rebus.Message{} = msg}, state) do
    dispatch_method_call(msg, state)
    {:noreply, state}
  end

  # The transition Task died without sending its completion message
  # (brutal kill, or a bug in the task body's own error handling). Clear
  # `transition` so the state machine can't wedge, fail the callers, and
  # serve whatever parked behind it.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{transition: %{task_ref: ref}} = state) do
    %{watchdog: watchdog, target: target, froms: froms} = state.transition
    Process.cancel_timer(watchdog)

    Logger.error(
      "Bluez.Client: mode transition to #{inspect(target)} task died " <>
        "without completing: #{inspect(reason)}"
    )

    Enum.each(froms, &GenServer.reply(&1, {:error, :transition_task_died}))
    {:noreply, run_pending(%{state | transition: nil})}
  end

  # The transition neither completed nor died within the watchdog budget —
  # a D-Bus call is stuck past its own timeouts, so the connection state
  # is suspect. Stop and let the supervisor rebuild us fresh rather than
  # patching state around a wedged connection.
  def handle_info({:transition_watchdog, ref}, %{transition: %{ref: ref}} = state) do
    %{target: target, froms: froms, task_pid: task_pid, task_ref: task_ref} = state.transition

    Logger.error(
      "Bluez.Client: scanner mode transition to #{inspect(target)} stuck " <>
        "beyond #{state.watchdog_ms} ms — stopping for a fresh D-Bus connection"
    )

    # Reap the wedged Task — it's unsupervised, and the blocked D-Bus
    # call it sits in is exactly the "stuck indefinitely" case this
    # watchdog exists for; nothing else would ever kill it.
    Process.demonitor(task_ref, [:flush])
    Process.exit(task_pid, :kill)

    # Fail the current callers AND anyone parked behind them — a plain
    # {:error, _} tuple beats riding the raw process exit (mirrors the
    # task-died path, which serves pending via run_pending).
    Enum.each(froms, &GenServer.reply(&1, {:error, :transition_stuck}))

    case state.pending do
      {_target, pending_froms} ->
        Enum.each(pending_froms, &GenServer.reply(&1, {:error, :transition_stuck}))

      nil ->
        :ok
    end

    {:stop, {:transition_stuck, target}, %{state | pending: nil}}
  end

  # Current transition finished — commit the outcome, answer the callers,
  # then run whatever parked behind it.
  def handle_info(
        {:mode_transition, ref, target, froms, result},
        %{transition: %{ref: ref}} = state
      ) do
    %{task_ref: task_ref, watchdog: watchdog} = state.transition
    Process.demonitor(task_ref, [:flush])
    Process.cancel_timer(watchdog)
    state = %{state | transition: nil}

    state =
      case result do
        {:ok, engaged} ->
          # `:off` (suspend) must NOT overwrite the HA-configured mode — resume
          # reads it back from here.
          if target != :off, do: :persistent_term.put(@mode_key, target)
          Enum.each(froms, &GenServer.reply(&1, :ok))
          Logger.info("Bluez.Client: scanner mode #{target} engaged (#{engaged})")
          %{state | mode: target, engaged: engaged}

        {:error, reason, engaged} ->
          Enum.each(froms, &GenServer.reply(&1, {:error, reason}))
          Logger.error("Bluez.Client: scanner mode #{target} failed: #{inspect(reason)}")
          %{state | engaged: engaged}
      end

    {:noreply, run_pending(state)}
  end

  # Stale transition result (generation ref mismatch — superseded while its
  # Task ran). Never commit it; just make sure its callers aren't left hanging.
  def handle_info({:mode_transition, _ref, _target, froms, _result}, state) do
    Enum.each(froms, &GenServer.reply(&1, {:error, :superseded}))
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── setup ────────────────────────────────────────────────────────────────

  defp attempt_setup(state, retries) do
    case discover_adapters(state.conn) do
      [] when retries > 0 ->
        Process.send_after(self(), {:setup_retry, retries - 1}, @setup_retry_ms)
        {:noreply, state}

      [] ->
        # No controllers at all — don't log adapter_path()/the resolved
        # path here: it's a persistent_term that defaults to hci0 (or a
        # previously-selected radio) and would misrepresent the failure.
        # Report the absence + the desired radio for context.
        Logger.error(
          "Bluez.Client: no Bluetooth adapter appeared on org.bluez " <>
            "(desired: #{DevicePath.desired_adapter() || "auto"})"
        )

        {:stop, :no_adapter, state}

      adapters ->
        claim_adapter(adapters)
        state = %{state | adapters: MapSet.new(adapters, & &1.path)}
        power_on(state.conn)
        state = seed_existing(state)
        # Tell RadioMonitor the adapter set is live (its identity is now
        # readable). This is the boot/claim edge of the event stream that
        # replaced its poll; hotplug edges come from InterfacesAdded/Removed.
        broadcast_adapters_changed(state)

        # An early set_mode/1 may already have a transition in flight (its
        # D-Bus calls work as soon as the adapter answers) — don't race it;
        # it engages the caller's mode and run_pending takes over from there.
        state =
          if state.transition == nil,
            do: start_transition(state, configured_mode(), []),
            else: state

        {:noreply, state}
    end
  end

  # ── scanner mode transitions ─────────────────────────────────────────────

  # Kick a Task that moves BlueZ from `state.engaged` to `target`, replying
  # to every caller in `froms` ([] for setup-initiated engages). Runs off
  # the GenServer loop because RegisterMonitor re-enters us (BlueZ calls
  # GetManagedObjects back before it returns). The generation ref ties the
  # Task's result to this transition; handle_info ignores stale ones.
  defp start_transition(state, target, froms) do
    me = self()
    conn = state.conn
    engaged = state.engaged
    ref = make_ref()
    apply_mode_fun = state.apply_mode_fun || (&apply_mode/3)

    {:ok, task_pid} =
      Task.start(fn ->
        # The completion message must ALWAYS arrive — a Task that dies without
        # sending it leaves `transition` stuck non-nil and every future
        # set_mode/1 parking until timeout. apply_mode/3 shouldn't raise
        # (DBus.call normalizes errors), but don't bet the state machine on it.
        result =
          try do
            apply_mode_fun.(conn, engaged, target)
          rescue
            e -> {:error, e, engaged}
          catch
            kind, reason -> {:error, {kind, reason}, engaged}
          end

        send(me, {:mode_transition, ref, target, froms, result})
      end)

    # Belt (monitor) and braces (watchdog) for the guarantee above: the
    # monitor catches a task killed before it can send; the watchdog
    # catches a task alive but stuck in a wedged D-Bus call.
    task_ref = Process.monitor(task_pid)
    watchdog = Process.send_after(me, {:transition_watchdog, ref}, state.watchdog_ms)

    transition = %{
      ref: ref,
      task_pid: task_pid,
      task_ref: task_ref,
      watchdog: watchdog,
      target: target,
      froms: froms
    }

    %{state | transition: transition}
  end

  # After a transition: serve the parked set_mode callers, if any.
  defp run_pending(%{pending: nil} = state), do: state

  defp run_pending(%{pending: {target, froms}} = state) do
    state = %{state | pending: nil}

    if state.mode == target and engaged_ok?(target, state.engaged) do
      Enum.each(froms, &GenServer.reply(&1, :ok))
      state
    else
      start_transition(state, target, froms)
    end
  end

  # Runs in the Task. Engage-first: monitor + discovery can legally coexist
  # in BlueZ, so bring the new mode up before tearing the old one down. A
  # failed engage then leaves the previous mode still scanning — engaged
  # unchanged, so the eventual teardown still targets the right strategy —
  # instead of going dark. Disengage stays best-effort (engage idempotency
  # below self-heals any drift on the next transition).
  # Returns {:ok, engaged} | {:error, reason, engaged}.
  defp apply_mode(conn, engaged, target) do
    case engage(conn, target) do
      :ok ->
        new_engaged = engaged_for(target)
        if engaged != new_engaged, do: disengage(conn, engaged)
        {:ok, new_engaged}

      {:error, reason} ->
        {:error, reason, engaged}
    end
  end

  defp engaged_for(:passive), do: :monitor
  defp engaged_for(:active), do: :discovery
  defp engaged_for(:off), do: :none

  defp disengage(_conn, :none), do: :ok

  defp disengage(conn, :monitor) do
    case call(conn, adapter_path(), @advmon_mgr_iface, "UnregisterMonitor", "o", [@root_path]) do
      {:ok, _} -> :ok
      # Wasn't registered (engage failed earlier) — already disengaged.
      {:error, "org.bluez.Error.DoesNotExist"} -> :ok
      {:error, reason} -> Logger.warning("Bluez.Client: UnregisterMonitor: #{inspect(reason)}")
    end
  end

  defp disengage(conn, :discovery) do
    case call(conn, adapter_path(), @adapter_iface, "StopDiscovery", "", []) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.warning("Bluez.Client: StopDiscovery: #{inspect(reason)}")
    end
  end

  # Suspend: nothing to engage; apply_mode then disengages whatever was running.
  defp engage(_conn, :off), do: :ok

  defp engage(conn, :passive) do
    case register_monitor(conn) do
      :ok -> :ok
      # Already registered (a drifted earlier state) — goal reached.
      {:error, "org.bluez.Error.AlreadyExists"} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp engage(conn, :active) do
    # DuplicateData=false lets BlueZ coalesce identical re-broadcasts and only
    # signal when a device's advertising data actually changes (plus periodic
    # RSSI) — DeviceCache still emit-gates downstream.
    filter = [{"Transport", {"s", "le"}}, {"DuplicateData", {"b", false}}]

    with {:ok, _} <-
           call(conn, adapter_path(), @adapter_iface, "SetDiscoveryFilter", "a{sv}", [filter]),
         {:ok, _} <- start_discovery(conn) do
      :ok
    end
  end

  defp start_discovery(conn) do
    case call(conn, adapter_path(), @adapter_iface, "StartDiscovery", "", []) do
      # Already discovering (a drifted earlier state) — goal reached.
      {:error, "org.bluez.Error.InProgress"} -> {:ok, []}
      other -> other
    end
  end

  defp register_monitor(conn) do
    msg =
      Rebus.Message.new!(:method_call,
        destination: @bluez,
        path: adapter_path(),
        interface: @advmon_mgr_iface,
        member: "RegisterMonitor",
        signature: "o",
        body: [@root_path]
      )

    case GenServer.call(conn, {:send, msg}, @register_timeout_ms) do
      %Rebus.Message{type: :method_return} -> :ok
      %Rebus.Message{type: :error, header_fields: hf} -> {:error, hf[:error_name]}
    end
  rescue
    e -> {:error, e}
  catch
    # GenServer.call timeout / dead connection raise an exit, not an exception.
    :exit, reason -> {:error, {:exit, reason}}
  end

  # ── inbound method-call dispatch (we are the service BlueZ calls) ────────

  defp dispatch_method_call(%Rebus.Message{header_fields: hf} = msg, state) do
    conn = state.conn

    case {hf[:interface], hf[:member]} do
      {@om_iface, "GetManagedObjects"} ->
        Rebus.reply(conn, msg, [managed_objects()], "a{oa{sa{sv}}}")

      {@props_iface, "GetAll"} ->
        Rebus.reply(conn, msg, [monitor_props()], "a{sv}")

      {@props_iface, "Get"} ->
        prop = msg.body |> Enum.at(1)

        case List.keyfind(monitor_props(), prop, 0) do
          {_p, variant} -> Rebus.reply(conn, msg, [variant], "v")
          nil -> Rebus.reply_error(conn, msg, "org.freedesktop.DBus.Error.UnknownProperty", prop)
        end

      {@advmon_iface, "Activate"} ->
        Logger.info("Bluez.Client: AdvertisementMonitor activated (passive scanning)")
        Rebus.reply(conn, msg)

      {@advmon_iface, member} when member in ["Release", "DeviceFound", "DeviceLost"] ->
        # We learn device data from InterfacesAdded/PropertiesChanged, so these
        # are just acknowledged.
        Rebus.reply(conn, msg)

      {@introspect_iface, "Introspect"} ->
        Rebus.reply(conn, msg, [introspect_xml(hf[:path])], "s")

      {iface, member} ->
        Rebus.reply_error(
          conn,
          msg,
          "org.freedesktop.DBus.Error.UnknownMethod",
          "#{iface}.#{member}"
        )
    end
  rescue
    e ->
      Logger.warning("Bluez.Client: inbound call handling raised #{inspect(e)}")
      # Always answer a reply-expecting call so BlueZ doesn't block until its
      # timeout; reply_error/4 no-ops for NO_REPLY_EXPECTED notifications.
      Rebus.reply_error(
        state.conn,
        msg,
        "org.freedesktop.DBus.Error.Failed",
        Exception.message(e)
      )
  end

  # The single advertisement monitor we expose. `or_patterns` matching the
  # common Flags values is BlueZ's documented "match all devices" workaround
  # (passive scanning requires ≥1 pattern); RSSISamplingPeriod=0 reports every
  # received advert (forwarding is throttled downstream by DeviceCache).
  defp monitor_props do
    [
      {"Type", {"s", "or_patterns"}},
      {"RSSISamplingPeriod", {"q", 0}},
      {"Patterns", {"a(yyay)", [[0, 0x01, [0x02]], [0, 0x01, [0x06]], [0, 0x01, [0x1A]]]}}
    ]
  end

  defp managed_objects do
    [{@monitor_path, [{@advmon_iface, monitor_props()}]}]
  end

  defp introspect_xml(path) do
    interfaces =
      cond do
        path == @root_path -> ~s(<interface name="#{@om_iface}"/>)
        path == @monitor_path -> ~s(<interface name="#{@advmon_iface}"/>)
        true -> ""
      end

    ~s(<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">\n<node>#{interfaces}</node>)
  end

  # ── org.bluez device signal handling (advert source) ────────────────────

  defp handle_signal(
         %Rebus.Message{header_fields: %{member: "InterfacesAdded"}, body: body},
         state
       ) do
    [path, interfaces] = body

    cond do
      # A new adapter object (e.g. a USB dongle hot-plugged) — track it and
      # tell RadioMonitor. This is the hotplug edge that replaced its poll.
      # Update the set BEFORE broadcasting: RadioMonitor's adapters_info/0 is
      # a GenServer.call back into us, so it can't run until this handler
      # returns anyway, but committing first keeps the ordering obvious.
      List.keyfind(interfaces, @adapter_iface, 0) != nil ->
        if MapSet.member?(state.adapters, path) do
          state
        else
          state = %{state | adapters: MapSet.put(state.adapters, path)}
          broadcast_adapters_changed(state)
          state
        end

      String.starts_with?(path, adapter_path() <> "/dev_") ->
        case List.keyfind(interfaces, @device_iface, 0) do
          {_iface, props_list} -> ingest(state, path, Variant.unwrap_props(props_list))
          nil -> state
        end

      true ->
        state
    end
  rescue
    e ->
      Logger.warning("Bluez.Client: bad InterfacesAdded shape: #{inspect(e)}")
      state
  end

  defp handle_signal(
         %Rebus.Message{header_fields: %{member: "PropertiesChanged", path: path}, body: body},
         state
       ) do
    [iface, changed, _invalidated] = body

    if iface == @device_iface and String.starts_with?(path, adapter_path() <> "/dev_") do
      ingest(state, path, Variant.unwrap_props(changed))
    else
      state
    end
  rescue
    e ->
      Logger.warning("Bluez.Client: bad PropertiesChanged shape: #{inspect(e)}")
      state
  end

  defp handle_signal(
         %Rebus.Message{header_fields: %{member: "InterfacesRemoved"}, body: body},
         state
       ) do
    case body do
      [path, ifaces] when is_list(ifaces) ->
        cond do
          # An adapter went away (dongle unplugged) — untrack + notify
          # (set committed before the broadcast, as in InterfacesAdded).
          @adapter_iface in ifaces and MapSet.member?(state.adapters, path) ->
            state = %{state | adapters: MapSet.delete(state.adapters, path)}
            broadcast_adapters_changed(state)
            state

          String.starts_with?(path, adapter_path() <> "/dev_") ->
            %{state | cache: DeviceCache.remove(state.cache, path)}

          true ->
            state
        end

      [path | _] ->
        if String.starts_with?(path, adapter_path() <> "/dev_"),
          do: %{state | cache: DeviceCache.remove(state.cache, path)},
          else: state

      _ ->
        state
    end
  end

  defp handle_signal(_msg, state), do: state

  # Merge props into the cache and emit whatever adverts it returns.
  defp ingest(state, path, props) do
    {cache, adverts} =
      DeviceCache.upsert(state.cache, path, props, System.monotonic_time(:millisecond))

    Enum.each(adverts, &emit(state, &1))
    %{state | cache: cache}
  end

  # Fan each advert out through the injected seam. The map is
  # rebuilt to exactly these four keys so the fun's contract is stable
  # regardless of what the cache carries internally.
  defp emit(state, %{address: address, rss: rss, address_type: address_type, raw_data: raw_data}) do
    state.on_advertisement.(%{
      address: address,
      rss: rss,
      address_type: address_type,
      raw_data: raw_data
    })
  end

  # ── outbound org.bluez calls + helpers ──────────────────────────────────

  defp add_signal_matches(conn) do
    # Scope to org.bluez so we only receive the daemon's signals, not
    # ObjectManager/PropertiesChanged from unrelated bus peers.
    rules = [
      "type='signal',sender='#{@bluez}',interface='org.freedesktop.DBus.ObjectManager'",
      "type='signal',sender='#{@bluez}',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged',arg0='#{@device_iface}'"
    ]

    Enum.each(rules, &DBus.add_match(conn, &1))
  end

  # Resolve which of the discovered adapters this subtree drives and publish
  # its object path. The kernel exposes no BT MAC in sysfs, so the
  # user-selected MAC (DevicePath.desired_adapter/0, written by
  # Bluetooth.Manager before the subtree started) can only be matched here,
  # against bluetoothd's Adapter1 objects: the desired MAC's adapter if
  # present, else the lowest-index one (auto/onboard).
  defp claim_adapter(adapters) do
    desired = DevicePath.desired_adapter()

    chosen =
      Enum.find(adapters, fn %{address: address} -> address == desired end) ||
        fallback_adapter(adapters, desired)

    :persistent_term.put(DevicePath.adapter_path_key(), chosen.path)
    Logger.info("Bluez.Client: driving #{chosen.path} (#{chosen.address})")
  end

  defp fallback_adapter(adapters, desired) do
    if desired != nil do
      Logger.warning("Bluez.Client: selected radio #{desired} not present, using first adapter")
    end

    Enum.min_by(adapters, &path_index(&1.path))
  end

  defp path_index(path) do
    case path |> Path.basename() |> String.replace_prefix("hci", "") |> Integer.parse() do
      {n, ""} -> n
      _ -> 999_999
    end
  end

  # All org.bluez Adapter1 objects, discovered from the full object tree.
  # GetManagedObjects is expensive (whole tree, scales with discovered BLE
  # devices) — called only at setup (including each retry while waiting for
  # an adapter to appear), never on the steady-state path. The steady
  # `adapters_info/0` reads `adapter_props_for/2` (per-path GetAll) instead.
  defp discover_adapters(conn) do
    case get_managed_objects(conn) do
      {:ok, objects} ->
        for {path, ifaces} <- objects,
            {_iface, props} <- [List.keyfind(ifaces, @adapter_iface, 0)] do
          unwrapped = Variant.unwrap_props(props)

          %{
            path: path,
            address: unwrapped["Address"],
            name: unwrapped["Name"],
            powered: unwrapped["Powered"] == true
          }
        end

      {:error, _} ->
        []
    end
  end

  # Cheap identity read for the tracked adapter paths: one small
  # `Properties.GetAll(Adapter1)` per adapter (1-2 objects) rather than the
  # whole org.bluez tree. Dropped silently if an adapter vanished between
  # the signal and this call.
  defp adapter_props_for(conn, paths) do
    for path <- paths, {:ok, [props]} <- [adapter_get_all(conn, path)] do
      unwrapped = Variant.unwrap_props(props)

      %{
        path: path,
        address: unwrapped["Address"],
        name: unwrapped["Name"],
        powered: unwrapped["Powered"] == true
      }
    end
  end

  defp adapter_get_all(conn, path) do
    call(conn, path, @props_iface, "GetAll", "s", [@adapter_iface])
  end

  defp broadcast_adapters_changed(%{pubsub: nil}), do: :ok

  defp broadcast_adapters_changed(%{pubsub: pubsub}) do
    Phoenix.PubSub.broadcast(pubsub, @adapters_topic, {:bluetooth_adapters_changed})
  end

  # Power the claimed adapter on — required to scan through it. Other
  # adapters' power state is deliberately NOT managed: from the Elixir
  # side all that matters is which adapter we utilize over rebus, not the
  # device-wide Bluetooth on/off state.
  defp power_on(conn) do
    call(conn, adapter_path(), @props_iface, "Set", "ssv", [
      @adapter_iface,
      "Powered",
      {"b", true}
    ])
  end

  # The adapter object path the whole subtree drives — published by the
  # host before this subtree (re)starts (or via desired_adapter:) and
  # published via :persistent_term, so it's stable for this process's
  # lifetime. Read per use (a persistent_term read is ~free) rather than
  # cached in state.
  defp adapter_path, do: DevicePath.adapter_path()

  defp seed_existing(state) do
    case get_managed_objects(state.conn) do
      {:ok, objects} ->
        Enum.reduce(objects, state, fn
          {path, ifaces}, acc ->
            case List.keyfind(ifaces, @device_iface, 0) do
              {_i, props} -> ingest(acc, path, Variant.unwrap_props(props))
              nil -> acc
            end

          _, acc ->
            acc
        end)

      _ ->
        state
    end
  end

  defp get_managed_objects(conn), do: DBus.get_managed_objects(conn)

  # Outbound method call → {:ok, body} | {:error, reason}. Extracted to
  # Bluez.DBus so the GATT client shares it.
  defp call(conn, path, interface, member, signature, body) do
    DBus.call(conn, path, interface, member, signature, body)
  end
end
