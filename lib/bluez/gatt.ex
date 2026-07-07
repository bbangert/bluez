defmodule Bluez.Gatt do
  @moduledoc """
  Active BLE connections + GATT client over BlueZ D-Bus — the engine an
  ESPHome-proxy-style host puts behind its Bluetooth-proxy adapter.

  Owns its own `rebus` connection, separate from `Bluez.Client`
  (the passive scanner): independent match rules, independent failure domain,
  and zero changes to the hardware-verified advert path. Concurrent method
  calls on one rebus connection don't serialize (replies are correlated by
  serial), but every call still blocks its *calling* process — so all BlueZ
  calls here run in `Task`s under `#{inspect(__MODULE__)}.Tasks`, never in
  this GenServer's own loop. `Device1.Connect` alone can take ~25 s.

  ## Event contract

  Results flow asynchronously to the `subscriber` pid captured at
  `connect/3`, through the `on_gatt_event:` fun (`fn subscriber, event`;
  default: `send(subscriber, event)`). Hosts inject a translator to reshape
  events for their own wire protocol. The full event set:

    * `{:gatt_connection, address, {:ok, mtu} | {:error, code}}` — connect
      result, post-remove teardown, or an unexpected disconnect.
    * `{:gatt_service, address, %Bluez.Gatt.Service{}}` — one
      per service, streamed on `get_services/1`.
    * `{:gatt_services_done, address}` — service stream terminator.
    * `{:gatt_read, address, handle, {:ok, binary} | {:error, code}}` —
      characteristic *and* descriptor reads (a failed `get_services/1` on a
      not-ready link also answers here with handle 0, the ESPHome
      convention).
    * `{:gatt_write, address, handle, {:ok, :done} | {:error, code}}` —
      characteristic and descriptor writes.
    * `{:gatt_notify, address, handle, {:ok, :done} | {:error, code}}` —
      Start/StopNotify result.
    * `{:gatt_notify_data, address, handle, binary}` — a notification value.
    * `{:gatt_pair, address, success? :: boolean(), code :: integer()}`
    * `{:gatt_unpair, address, success?, code}`
    * `{:gatt_clear_cache, address, success?, code}`

  Error `code`s follow the ESPHome BLE convention this stack was built
  against: `-1` generic, `-2` not connected.

  ## Options

    * `on_gatt_event:` — see above.
    * `on_connections_changed:` — zero-arity fun invoked whenever a
      connection slot is taken or freed (default: no-op) — e.g. a stats
      ticker.

  ## Connection lifecycle

      connect cast ─→ Device1.Connect (Task) ─→ ServicesResolved? ──true──┐
                                                   │false                 │
                                                   └─ wait for signal ────┤
                                                      (resolve timeout)   ▼
                                       GetManagedObjects ─→ GattTree.build
                                                   │
                            {:gatt_connection, addr, {:ok, mtu}} ──→ host

  The connection reply is deliberately deferred until BlueZ has resolved
  services: every subsequent GATT request is handle-keyed, and the
  handle ↔ object-path map only exists once the GATT objects are visible.
  MTU comes from the experimental `MTU` characteristic property
  (`bluetoothd -E`), falling back to the BLE minimum (23).

  Unexpected disconnects surface as `Device1.PropertiesChanged
  Connected=false`; the subscriber is told via the same connection envelope
  with an error code. Requested disconnects remove state immediately and
  need no follow-up message.

  ## Notifications

  `StartNotify` makes BlueZ emit `PropertiesChanged` with `Value` on the
  characteristic path — the same signal mechanism as adverts. The
  char-path → `{address, handle}` route is registered *before* the
  StartNotify call returns (and rolled back on error) so no early value
  can race past us.

  The host owns cross-client address locking; this
  module trusts that `connect` arrives at most once per address per
  ownership cycle, but stays defensive (a stale entry is torn down and
  replaced).

  ## Pairing and cache clearing (Phase 2)

  `pair/1` calls `Device1.Pair()` — IO is negotiated through
  `Bluez.Agent` (the default NoInputNoOutput agent), and the
  Pair Task brackets the call with `expect_pairing/1`/`pairing_done/1` so
  the agent only authorizes pairings we initiated. `unpair/1` and
  `clear_cache/1` both map to `Adapter1.RemoveDevice` — BlueZ's only
  bond-removal API, and the only D-Bus way to drop a device's cached GATT
  database (they differ only in the reply envelope; the bond, if any,
  goes too — same observable semantics as ESP32's
  `esp_ble_remove_bond_device`). RemoveDevice destroys the device object —
  and the live link with it.

  Hardware-observed ordering hazard: BlueZ disconnects the device (and
  emits `Connected=false`) *while processing* RemoveDevice, before the
  method returns — and a failed `Pair()` can likewise drop the link before
  its error reply lands. Either way the signal path tears the entry down
  first, so pair/remove Task messages carry the subscriber pid themselves:
  the op reply is always delivered, and entry teardown happens via
  whichever of the two paths (signal or result) still finds the entry.

  All three require a live connection entry: replies route to the
  subscriber captured at `connect/3`, so for an unknown address there
  is no one to answer — those requests are logged and dropped (HA only
  issues them on connected devices).
  """

  use GenServer
  require Logger

  alias Bluez.{DBus, DevicePath, GattTree, Variant}
  alias Bluez.Agent, as: PairingAgent

  @adapter_iface "org.bluez.Adapter1"
  @device_iface "org.bluez.Device1"
  @char_iface "org.bluez.GattCharacteristic1"
  @desc_iface "org.bluez.GattDescriptor1"
  @props_iface "org.freedesktop.DBus.Properties"

  @task_sup __MODULE__.Tasks

  # Active-connection slots reported to HA. BlueZ has no hard kernel limit
  # this low, but 3 matches what ESP32 proxies advertise and keeps the
  # single shared radio responsive for passive scanning.
  @max_connections 3

  # Device1.Connect blocks until the link is up or BlueZ gives up (~25 s
  # internally); the caller's patience must outlast it.
  @connect_timeout 32_000
  # ServicesResolved usually follows within a couple of seconds of connect.
  @resolve_timeout 30_000
  # GATT reads/writes block up to the ATT transaction timeout.
  @op_timeout 32_000
  # Device1.Pair blocks through connect (if needed) + SMP pairing; BlueZ's
  # own bonding timeout is shorter, so this is the outer patience bound.
  @pair_timeout 35_000

  @default_mtu 23

  # Max ATT attribute value length (Core spec) — reject larger writes before
  # expanding them into byte lists for marshalling.
  @max_attr_len 512

  # ESPHome-convention BLE error codes (see the moduledoc event contract).
  @err_generic -1
  @err_not_connected -2

  @typedoc "Packed 48-bit MAC, MSB-first."
  @type address :: non_neg_integer()

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Name of the Task.Supervisor all BlueZ calls run under."
  @spec task_supervisor() :: module()
  def task_supervisor, do: @task_sup

  @doc "Total active-connection slots this GATT client offers."
  @spec max_connections() :: pos_integer()
  def max_connections, do: @max_connections

  # ── adapter-facing API (cast-style, results go to the subscriber pid) ────

  @doc """
  Open a BLE connection to `address` and capture `subscriber` as the pid
  all of this connection's events route to (via the `on_gatt_event:` fun).

  Cast-style: returns `:ok` immediately. The outcome arrives as
  `{:gatt_connection, address, {:ok, mtu} | {:error, code}}` — deferred
  until BlueZ has resolved services, so every handle-keyed request below
  is valid the moment the success event lands. `opts` are accepted for
  host-side compatibility and currently unused.

  Refused (with an error event) when `address` is not a 48-bit MAC or all
  `max_connections/0` slots are taken.
  """
  @spec connect(address(), keyword(), pid()) :: :ok
  def connect(address, opts, subscriber),
    do: GenServer.cast(__MODULE__, {:connect, address, opts, subscriber})

  @doc """
  Tear down `address`'s connection. Requested disconnects emit no
  follow-up event (the entry is dropped before BlueZ reports the link
  down); unknown addresses are a no-op.
  """
  @spec disconnect(address()) :: :ok
  def disconnect(address), do: GenServer.cast(__MODULE__, {:disconnect, address})

  @doc """
  Stream the connected device's GATT database to the subscriber: one
  `{:gatt_service, address, %Bluez.Gatt.Service{}}` per service, then
  `{:gatt_services_done, address}`. On a not-ready link the failure is
  reported as `{:gatt_read, address, 0, {:error, -2}}` (the ESPHome
  convention for a failed service listing).
  """
  @spec get_services(address()) :: :ok
  def get_services(address), do: GenServer.cast(__MODULE__, {:get_services, address})

  @doc """
  Read the characteristic at `handle` (a *value* handle, as reported in
  the service stream). Result: `{:gatt_read, address, handle, {:ok,
  binary} | {:error, code}}`. Falls back to a descriptor read when the
  handle names a descriptor.
  """
  @spec read(address(), non_neg_integer()) :: :ok
  def read(address, handle), do: GenServer.cast(__MODULE__, {:read, address, handle})

  @doc """
  Write `data` to the characteristic at `handle`. `response?` selects
  Write-With-Response (`true`) vs Write-Without-Response. Result:
  `{:gatt_write, address, handle, {:ok, :done} | {:error, code}}`.
  Writes larger than the 512-byte ATT attribute limit are refused
  up front.
  """
  @spec write(address(), non_neg_integer(), binary(), boolean()) :: :ok
  def write(address, handle, data, response?),
    do: GenServer.cast(__MODULE__, {:write, address, handle, data, response?})

  @doc """
  Read the descriptor at `handle`. Same result envelope as `read/2`
  (`{:gatt_read, ...}`); falls back to a characteristic read when the
  handle names one.
  """
  @spec read_descriptor(address(), non_neg_integer()) :: :ok
  def read_descriptor(address, handle),
    do: GenServer.cast(__MODULE__, {:read_descriptor, address, handle})

  @doc """
  Write `data` to the descriptor at `handle` (always Write-With-Response).
  Same result envelope as `write/4` (`{:gatt_write, ...}`).
  """
  @spec write_descriptor(address(), non_neg_integer(), binary()) :: :ok
  def write_descriptor(address, handle, data),
    do: GenServer.cast(__MODULE__, {:write_descriptor, address, handle, data})

  @doc """
  Start (`enable?: true`) or stop notifications/indications on the
  characteristic at `handle`. The call result arrives as
  `{:gatt_notify, address, handle, {:ok, :done} | {:error, code}}`;
  subsequent values arrive as `{:gatt_notify_data, address, handle,
  binary}`. The value route is registered before StartNotify returns so
  no early notification can be lost.
  """
  @spec notify(address(), non_neg_integer(), boolean()) :: :ok
  def notify(address, handle, enable?),
    do: GenServer.cast(__MODULE__, {:notify, address, handle, enable?})

  @doc """
  Bond with the connected device (`Device1.Pair()`), with IO negotiated
  through `Bluez.Agent` — only pairings initiated here are authorized.
  Result: `{:gatt_pair, address, success? :: boolean(), code}`. A failed
  pairing can drop the link (hardware-observed), in which case a
  `{:gatt_connection, address, {:error, _}}` teardown event follows.
  """
  @spec pair(address()) :: :ok
  def pair(address), do: GenServer.cast(__MODULE__, {:pair, address})

  @doc """
  Remove the device's bond via `Adapter1.RemoveDevice` — BlueZ's only
  bond-removal API, which also destroys the device object and any live
  link. Result: `{:gatt_unpair, address, success?, code}`, followed by a
  `{:gatt_connection, address, {:error, -2}}` teardown event when a
  connection was up.
  """
  @spec unpair(address()) :: :ok
  def unpair(address), do: GenServer.cast(__MODULE__, {:unpair, address})

  @doc """
  Drop BlueZ's cached GATT database for the device. Same underlying
  operation as `unpair/1` (`RemoveDevice` is the only D-Bus API for it —
  the bond, if any, goes too; same observable semantics as ESP32's
  `esp_ble_remove_bond_device`), differing only in the reply envelope:
  `{:gatt_clear_cache, address, success?, code}`.
  """
  @spec clear_cache(address()) :: :ok
  def clear_cache(address), do: GenServer.cast(__MODULE__, {:clear_cache, address})

  @doc "Free / total connection slots (the host's connections_free callback)."
  @spec connections_free() :: {non_neg_integer(), non_neg_integer()}
  def connections_free, do: GenServer.call(__MODULE__, :connections_free)

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    case Rebus.connect(:system) do
      {:ok, conn} ->
        sig_ref = Rebus.add_signal_handler(conn)
        conn_ref = Process.monitor(conn)

        # rebus installs no bus-side match rules; route org.bluez's Device1
        # (Connected/ServicesResolved) and GattCharacteristic1 (Value)
        # property changes to this connection.
        for iface <- [@device_iface, @char_iface] do
          DBus.add_match(
            conn,
            "type='signal',sender='org.bluez',interface='#{@props_iface}'," <>
              "member='PropertiesChanged',arg0='#{iface}'"
          )
        end

        {:ok,
         %{
           conn: conn,
           conn_ref: conn_ref,
           sig_ref: sig_ref,
           # Event seam (see the moduledoc): every subscriber-bound event
           # goes through this fun so a host can translate the lib-native
           # shapes to its own wire protocol.
           on_gatt_event:
             Keyword.get(opts, :on_gatt_event, fn subscriber, event ->
               send(subscriber, event)
             end),
           # Slot-usage seam: invoked on every entry create/drop.
           on_connections_changed: Keyword.get(opts, :on_connections_changed, fn -> :ok end),
           # address => connection entry (see new_entry/3)
           conns: %{},
           # char object path => {address, reported handle}, for routing
           # notification Values back to the right subscriber.
           notify_paths: %{},
           # Monotonic connection generation. Every Task message carries the
           # generation of the entry that spawned it; results whose
           # generation no longer matches the live entry are stale (the
           # entry was replaced or torn down meanwhile) and are dropped.
           gen_seq: 0
         }}

      {:error, reason} ->
        {:stop, {:dbus_connect_failed, reason}}
    end
  end

  @impl GenServer
  def handle_cast({:connect, address, _opts, subscriber}, state) do
    cond do
      # The wire address is uint64; only 48-bit MACs are representable.
      # Refuse cleanly — a crafted address must not crash this server.
      not DevicePath.valid?(address) ->
        Logger.warning("Bluez.Gatt: connect refused — invalid address #{inspect(address)}")
        emit(state, subscriber, {:gatt_connection, address, {:error, @err_generic}})
        {:noreply, state}

      true ->
        state = teardown_stale_entry(state, address)

        if map_size(state.conns) >= @max_connections do
          Logger.warning("Bluez.Gatt: connect #{fmt(address)} refused — no free slots")
          emit(state, subscriber, {:gatt_connection, address, {:error, @err_generic}})
          {:noreply, state}
        else
          gen = state.gen_seq + 1
          path = DevicePath.from_address(address)
          run_connect(state.conn, address, gen, path)
          notify_connections_changed(state)

          {:noreply,
           %{state | gen_seq: gen}
           |> put_in([:conns, address], new_entry(path, subscriber, gen))}
        end
    end
  end

  def handle_cast({:disconnect, address}, state) do
    case state.conns[address] do
      nil ->
        {:noreply, state}

      entry ->
        # Requested teardown: the host needs no follow-up message. Drop state
        # first so the Connected=false signal doesn't report an unexpected
        # disconnect for an address we no longer track.
        run_disconnect(state.conn, entry.path)
        {:noreply, drop_entry(state, address)}
    end
  end

  def handle_cast({:get_services, address}, state) do
    # On a not-ready link, ESPHome's convention for a get-services failure
    # is a GATT error with handle 0 (what the C++ proxy sends).
    with_ready_entry(state, address, {:gatt_read, address, 0}, fn entry ->
      Enum.each(entry.tree.services, fn service ->
        emit(state, entry.subscriber, {:gatt_service, address, service})
      end)

      emit(state, entry.subscriber, {:gatt_services_done, address})
      {:noreply, state}
    end)
  end

  def handle_cast({:read, address, handle}, state) do
    gatt_op(state, address, {:gatt_read, address, handle}, [:characteristic, :descriptor], fn
      path, kind, gen -> read_value(state.conn, path, kind, gen, {:gatt_read, address, handle})
    end)
  end

  def handle_cast({:read_descriptor, address, handle}, state) do
    gatt_op(state, address, {:gatt_read, address, handle}, [:descriptor, :characteristic], fn
      path, kind, gen -> read_value(state.conn, path, kind, gen, {:gatt_read, address, handle})
    end)
  end

  # Writes larger than an ATT attribute can ever be are refused up front —
  # don't expand multi-megabyte hostile payloads into byte lists just so
  # BlueZ can reject them.
  def handle_cast({:write, address, handle, data, _response?}, state)
      when byte_size(data) > @max_attr_len do
    {:noreply, refuse_oversized_write(state, address, handle)}
  end

  def handle_cast({:write, address, handle, data, response?}, state) do
    gatt_op(state, address, {:gatt_write, address, handle}, [:characteristic], fn path, _k, gen ->
      write_value(
        state.conn,
        path,
        @char_iface,
        data,
        response?,
        gen,
        {:gatt_write, address, handle}
      )
    end)
  end

  def handle_cast({:write_descriptor, address, handle, data}, state)
      when byte_size(data) > @max_attr_len do
    {:noreply, refuse_oversized_write(state, address, handle)}
  end

  def handle_cast({:write_descriptor, address, handle, data}, state) do
    gatt_op(state, address, {:gatt_write, address, handle}, [:descriptor], fn path, _kind, gen ->
      write_value(state.conn, path, @desc_iface, data, true, gen, {:gatt_write, address, handle})
    end)
  end

  def handle_cast({:notify, address, handle, enable?}, state) do
    with_ready_entry(state, address, {:gatt_notify, address, handle}, fn entry ->
      case entry.tree.by_handle[handle] do
        {:characteristic, path} ->
          member = if enable?, do: "StartNotify", else: "StopNotify"

          run_notify(
            state.conn,
            path,
            member,
            entry.gen,
            {:gatt_notify, address, handle, enable?, path}
          )

          # Register the notification route BEFORE StartNotify completes so
          # an immediate first Value can't race past us; rolled back if the
          # call errors (see :op_result below).
          state =
            if enable?,
              do: put_in(state.notify_paths[path], {address, handle}),
              else: update_in(state.notify_paths, &Map.delete(&1, path))

          {:noreply, state}

        _other ->
          emit(state, entry.subscriber, {:gatt_notify, address, handle, {:error, @err_generic}})
          {:noreply, state}
      end
    end)
  end

  # Pairing works on any entry status: Pair() on a half-open link just
  # surfaces BlueZ's own error, and a :ready link is the normal HA flow.
  def handle_cast({:pair, address}, state) do
    case state.conns[address] do
      nil ->
        Logger.debug("Bluez.Gatt: pair for unknown address #{fmt(address)} dropped")
        {:noreply, state}

      entry ->
        run_pair(state.conn, address, entry.path, entry.gen, entry.subscriber)
        {:noreply, state}
    end
  end

  def handle_cast({:unpair, address}, state),
    do: remove_device(state, address, :gatt_unpair)

  def handle_cast({:clear_cache, address}, state),
    do: remove_device(state, address, :gatt_clear_cache)

  @impl GenServer
  def handle_call(:connections_free, _from, state) do
    free = max(@max_connections - map_size(state.conns), 0)
    {:reply, {free, @max_connections}, state}
  end

  # ── async results from BlueZ-call Tasks ──────────────────────────────────

  @impl GenServer
  def handle_info({:connect_step, address, gen, step}, state) do
    case {state.conns[address], step} do
      {%{gen: ^gen, status: :connecting} = entry, :resolved} ->
        run_fetch_tree(state.conn, address, gen)
        {:noreply, put_in(state.conns[address], %{entry | status: :fetching})}

      {%{gen: ^gen, status: :connecting} = entry, :unresolved} ->
        # Connected, but service discovery still running — wait for the
        # ServicesResolved PropertiesChanged signal, bounded by a timer.
        timer = Process.send_after(self(), {:resolve_timeout, address, gen}, @resolve_timeout)

        {:noreply,
         put_in(state.conns[address], %{entry | status: :resolving, resolve_timer: timer})}

      {%{gen: ^gen}, {:failed, reason}} ->
        Logger.warning("Bluez.Gatt: connect #{fmt(address)} failed: #{inspect(reason)}")
        {:noreply, fail_connection(state, address, error_code(reason))}

      # Wrong generation (entry replaced/dropped meanwhile) or an unexpected
      # status for this step — stale Task result, drop it.
      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:tree_result, address, gen, result}, state) do
    case {state.conns[address], result} do
      {%{gen: ^gen, status: :fetching} = entry, {:ok, objects}} ->
        tree = GattTree.build(objects, entry.path)
        entry = %{entry | status: :ready, tree: tree, resolve_timer: nil}

        emit(
          state,
          entry.subscriber,
          {:gatt_connection, address, {:ok, tree.mtu || @default_mtu}}
        )

        {:noreply, put_in(state.conns[address], entry)}

      {%{gen: ^gen}, {:error, reason}} ->
        Logger.warning(
          "Bluez.Gatt: GATT enumeration for #{fmt(address)} failed: #{inspect(reason)}"
        )

        {:noreply, fail_connection(state, address, @err_generic)}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:resolve_timeout, address, gen}, state) do
    case state.conns[address] do
      %{gen: ^gen, status: :resolving} ->
        Logger.warning("Bluez.Gatt: #{fmt(address)} never resolved services")
        {:noreply, fail_connection(state, address, @err_generic)}

      _ ->
        {:noreply, state}
    end
  end

  # Pair/remove replies go to the subscriber captured when the op was
  # dispatched, NOT via an entry lookup: the op itself can drop the link
  # (failed SMP, RemoveDevice's own disconnect), and BlueZ emits that
  # Connected=false BEFORE the method returns — the signal path then tears
  # the entry down first and an entry-keyed reply would be lost (the host
  # would time the request out). Hardware-observed on the H60B0.
  def handle_info({:pair_result, address, _gen, subscriber, result}, state) do
    case result do
      :ok -> emit(state, subscriber, {:gatt_pair, address, true, 0})
      {:error, code} -> emit(state, subscriber, {:gatt_pair, address, false, code})
    end

    {:noreply, state}
  end

  def handle_info({:remove_result, address, gen, tag, subscriber, result}, state) do
    case result do
      :ok ->
        emit(state, subscriber, {tag, address, true, 0})

        # The device object is gone. If the Connected=false signal raced us,
        # the entry (and its teardown envelope) is already handled; otherwise
        # finish the teardown here — op reply first, then the envelope.
        case state.conns[address] do
          %{gen: ^gen} = entry ->
            cancel_resolve_timer(entry)
            emit(state, subscriber, {:gatt_connection, address, {:error, @err_not_connected}})
            {:noreply, drop_entry(state, address)}

          _gone_or_replaced ->
            {:noreply, state}
        end

      {:error, code} ->
        emit(state, subscriber, {tag, address, false, code})
        {:noreply, state}
    end
  end

  def handle_info({:op_result, gen, envelope, result}, state) do
    address = elem(envelope, 1)

    case state.conns[address] do
      %{gen: ^gen} = entry ->
        # A failed StartNotify rolls its optimistic route registration back;
        # a failed StopNotify re-registers nothing (route already removed,
        # stale Values for it are dropped by design).
        state =
          case {envelope, result} do
            {{:gatt_notify, _address, _handle, true, path}, {:error, _}} ->
              update_in(state.notify_paths, &Map.delete(&1, path))

            _ ->
              state
          end

        forward_op_result(state, entry, envelope, result)
        {:noreply, state}

      _stale ->
        {:noreply, state}
    end
  end

  # org.bluez signals (device property changes + notification values).
  def handle_info({ref, %Rebus.Message{type: :signal} = msg}, %{sig_ref: ref} = state) do
    {:noreply, handle_signal(msg, state)}
  end

  # The rebus connection died; stop so the supervisor reconnects us.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_ref: ref} = state) do
    {:stop, {:dbus_connection_down, reason}, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # ── signal handling ──────────────────────────────────────────────────────

  defp handle_signal(
         %Rebus.Message{header_fields: %{member: "PropertiesChanged", path: path}, body: body},
         state
       ) do
    case body do
      [@device_iface, changed, _invalidated] ->
        device_props_changed(state, path, Variant.unwrap_props(changed))

      [@char_iface, changed, _invalidated] ->
        char_props_changed(state, path, Variant.unwrap_props(changed))

      _other ->
        state
    end
  rescue
    e ->
      Logger.warning("Bluez.Gatt: bad PropertiesChanged shape: #{inspect(e)}")
      state
  end

  defp handle_signal(_msg, state), do: state

  defp device_props_changed(state, path, props) do
    case DevicePath.to_address(path) do
      {:ok, address} ->
        entry = state.conns[address]

        cond do
          is_nil(entry) ->
            state

          props["Connected"] == false ->
            # Unexpected drop (requested disconnects clear the entry before
            # BlueZ emits this). Same envelope as a failed connect — the host
            # forwards it as a connected=false response either way.
            Logger.info("Bluez.Gatt: #{fmt(address)} disconnected unexpectedly")
            cancel_resolve_timer(entry)
            emit(state, entry.subscriber, {:gatt_connection, address, {:error, @err_generic}})
            drop_entry(state, address)

          props["ServicesResolved"] == true and entry.status == :resolving ->
            # :fetching makes this a one-shot — a duplicate ServicesResolved
            # signal (or one racing the connect Task's own check) can't
            # spawn a second tree fetch.
            cancel_resolve_timer(entry)
            run_fetch_tree(state.conn, address, entry.gen)
            put_in(state.conns[address], %{entry | status: :fetching, resolve_timer: nil})

          true ->
            state
        end

      :error ->
        state
    end
  end

  defp char_props_changed(state, path, props) do
    with {address, handle} <- state.notify_paths[path],
         %{} = entry <- state.conns[address],
         value when not is_nil(value) <- props["Value"] do
      emit(state, entry.subscriber, {:gatt_notify_data, address, handle, to_bin(value)})
      state
    else
      _ -> state
    end
  end

  # ── connection state helpers ─────────────────────────────────────────────

  # Entry statuses: :connecting → :resolving (waiting for the
  # ServicesResolved signal) → :fetching (GetManagedObjects in flight) →
  # :ready. `gen` stamps every Task message this entry spawns.
  defp new_entry(path, subscriber, gen) do
    %{
      path: path,
      subscriber: subscriber,
      status: :connecting,
      tree: nil,
      resolve_timer: nil,
      gen: gen
    }
  end

  defp forward_op_result(state, entry, envelope, result) do
    case envelope do
      {:gatt_read, address, handle} ->
        emit(state, entry.subscriber, {:gatt_read, address, handle, result})

      {:gatt_write, address, handle} ->
        emit(state, entry.subscriber, {:gatt_write, address, handle, result})

      {:gatt_notify, address, handle, _enable?, _path} ->
        emit(state, entry.subscriber, {:gatt_notify, address, handle, result})

      other ->
        Logger.warning("Bluez.Gatt: unhandled op_result envelope #{inspect(other)}")
    end
  end

  # The link (if known) gets the write error; an unknown address is a stale
  # op and is dropped, same as with_ready_entry/4.
  defp refuse_oversized_write(state, address, handle) do
    case state.conns[address] do
      %{subscriber: subscriber} ->
        Logger.warning("Bluez.Gatt: write to #{fmt(address)} handle #{handle} exceeds ATT limit")
        emit(state, subscriber, {:gatt_write, address, handle, {:error, @err_generic}})

      nil ->
        :ok
    end

    state
  end

  # The host guarantees connect-at-most-once per ownership cycle, but if a
  # stale entry exists anyway (e.g. the host restarted), replace it cleanly.
  defp teardown_stale_entry(state, address) do
    case state.conns[address] do
      nil ->
        state

      entry ->
        Logger.warning("Bluez.Gatt: replacing stale connection state for #{fmt(address)}")
        cancel_resolve_timer(entry)
        run_disconnect(state.conn, entry.path)
        drop_entry(state, address)
    end
  end

  defp fail_connection(state, address, code) do
    case state.conns[address] do
      nil ->
        state

      entry ->
        cancel_resolve_timer(entry)
        emit(state, entry.subscriber, {:gatt_connection, address, {:error, code}})
        # Best-effort cleanup: a half-open link would otherwise hold the slot
        # on the controller until BlueZ notices.
        run_disconnect(state.conn, entry.path)
        drop_entry(state, address)
    end
  end

  defp drop_entry(state, address) do
    {_entry, state} = pop_in(state.conns[address])
    notify_connections_changed(state)

    update_in(state.notify_paths, fn paths ->
      paths |> Enum.reject(fn {_path, {addr, _h}} -> addr == address end) |> Map.new()
    end)
  end

  # Slot usage changed (entry created or dropped) — the injected fun lets
  # the host push an off-tick update (the app wires Bluetooth.Stats, whose
  # cast is fire-and-forget and a no-op when Stats isn't running).
  defp notify_connections_changed(state), do: state.on_connections_changed.()

  # Every subscriber-bound event flows through the injected seam.
  defp emit(state, subscriber, event), do: state.on_gatt_event.(subscriber, event)

  defp cancel_resolve_timer(%{resolve_timer: nil}), do: :ok
  defp cancel_resolve_timer(%{resolve_timer: timer}), do: Process.cancel_timer(timer)

  # Look up a :ready entry; on a known-but-not-ready link, answer with the
  # op's own error envelope (`error_envelope` is the `{tag, address, handle}`
  # prefix the result tuple is built from). An *unknown* address has no
  # subscriber to tell — the host gates ops on ownership, so
  # that's a stale op and gets dropped.
  defp with_ready_entry(state, address, error_envelope, fun) do
    case state.conns[address] do
      %{status: :ready} = entry ->
        fun.(entry)

      %{subscriber: subscriber} ->
        emit(state, subscriber, error_msg(error_envelope, @err_not_connected))
        {:noreply, state}

      nil ->
        Logger.debug("Bluez.Gatt: op for unknown address #{fmt(address)} dropped")
        {:noreply, state}
    end
  end

  # Common shape of read/write ops: resolve handle → path, kind-check, run.
  # The internal envelope doubles as the event-tag prefix (see the moduledoc).
  defp gatt_op(state, address, {_tag, _addr, handle} = envelope, allowed_kinds, run) do
    with_ready_entry(state, address, envelope, fn entry ->
      with {kind, path} <- entry.tree.by_handle[handle],
           true <- kind in allowed_kinds do
        run.(path, kind, entry.gen)
        {:noreply, state}
      else
        _other ->
          emit(state, entry.subscriber, error_msg(envelope, @err_generic))
          {:noreply, state}
      end
    end)
  end

  # unpair and clear_cache are the same BlueZ operation (RemoveDevice);
  # only the reply envelope (`tag`) differs.
  defp remove_device(state, address, tag) do
    case state.conns[address] do
      nil ->
        Logger.debug("Bluez.Gatt: #{tag} for unknown address #{fmt(address)} dropped")
        {:noreply, state}

      entry ->
        run_remove_device(state.conn, address, entry.path, entry.gen, tag, entry.subscriber)
        {:noreply, state}
    end
  end

  defp error_msg({tag, address, handle}, code), do: {tag, address, handle, {:error, code}}

  # ── BlueZ calls (always from Tasks) ──────────────────────────────────────

  defp run_connect(conn, address, gen, path) do
    run_task(fn ->
      with {:ok, _} <- DBus.call(conn, path, @device_iface, "Connect", "", [], @connect_timeout),
           {:ok, resolved?} <- services_resolved?(conn, path) do
        {:connect_step, address, gen, if(resolved?, do: :resolved, else: :unresolved)}
      else
        {:error, reason} -> {:connect_step, address, gen, {:failed, reason}}
      end
    end)
  end

  defp services_resolved?(conn, path) do
    case DBus.call(conn, path, @props_iface, "Get", "ss", [@device_iface, "ServicesResolved"]) do
      {:ok, [{_sig, resolved?}]} -> {:ok, resolved? == true}
      # Can't read the property? Don't fail the connect — wait for the signal.
      {:error, _reason} -> {:ok, false}
    end
  end

  defp run_fetch_tree(conn, address, gen) do
    run_task(fn ->
      {:tree_result, address, gen, DBus.get_managed_objects(conn, @op_timeout)}
    end)
  end

  defp run_disconnect(conn, path) do
    run_task(fn ->
      case DBus.call(conn, path, @device_iface, "Disconnect", "", [], @op_timeout) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.debug("Bluez.Gatt: Disconnect #{path}: #{inspect(reason)}")
      end

      :noreply_to_server
    end)
  end

  defp read_value(conn, path, kind, gen, envelope) do
    iface = if kind == :descriptor, do: @desc_iface, else: @char_iface

    run_task(fn ->
      result =
        case DBus.call(conn, path, iface, "ReadValue", "a{sv}", [[]], @op_timeout) do
          {:ok, [value]} -> {:ok, to_bin(value)}
          {:error, reason} -> {:error, error_code(reason)}
        end

      {:op_result, gen, envelope, result}
    end)
  end

  defp write_value(conn, path, iface, data, response?, gen, envelope) do
    # BlueZ write type: "request" = Write With Response, "command" = Write
    # Without Response. Descriptor writes are always requests.
    type = if response?, do: "request", else: "command"
    body = [:binary.bin_to_list(data), [{"type", {"s", type}}]]

    run_task(fn ->
      result =
        case DBus.call(conn, path, iface, "WriteValue", "aya{sv}", body, @op_timeout) do
          {:ok, _} -> {:ok, :done}
          {:error, reason} -> {:error, error_code(reason)}
        end

      {:op_result, gen, envelope, result}
    end)
  end

  defp run_pair(conn, address, path, gen, subscriber) do
    run_task(fn ->
      # Bracket the (possibly slow) Pair call so the default agent only
      # authorizes this pairing while it is actually in flight. The expect
      # is synchronous (must be registered before Pair triggers bluetoothd's
      # callbacks) and TTL-backed in the Agent, so a Task that dies before
      # pairing_done/1 can't leave the path authorized forever.
      PairingAgent.expect_pairing(path)

      result =
        case DBus.call(conn, path, @device_iface, "Pair", "", [], @pair_timeout) do
          {:ok, _} ->
            :ok

          # Already bonded — the goal state.
          {:error, "org.bluez.Error.AlreadyExists"} ->
            :ok

          {:error, reason} ->
            # Best-effort: don't leave a half-finished SMP exchange dangling.
            DBus.call(conn, path, @device_iface, "CancelPairing", "", [])
            {:error, error_code(reason)}
        end

      PairingAgent.pairing_done(path)
      {:pair_result, address, gen, subscriber, result}
    end)
  end

  defp run_remove_device(conn, address, path, gen, tag, subscriber) do
    adapter = DevicePath.adapter_path()

    run_task(fn ->
      result =
        case DBus.call(conn, adapter, @adapter_iface, "RemoveDevice", "o", [path], @op_timeout) do
          {:ok, _} ->
            :ok

          # Object already gone — bond and GATT cache died with it.
          {:error, "org.bluez.Error.DoesNotExist"} ->
            :ok

          {:error, reason} ->
            {:error, error_code(reason)}
        end

      {:remove_result, address, gen, tag, subscriber, result}
    end)
  end

  defp run_notify(conn, path, member, gen, envelope) do
    run_task(fn ->
      result =
        case DBus.call(conn, path, @char_iface, member, "", [], @op_timeout) do
          {:ok, _} -> {:ok, :done}
          {:error, reason} -> {:error, error_code(reason)}
        end

      {:op_result, gen, envelope, result}
    end)
  end

  # Run a BlueZ call off-loop; the task's return message (unless flagged
  # :noreply_to_server) is delivered to this GenServer's mailbox.
  defp run_task(fun) do
    server = self()

    case Task.Supervisor.start_child(@task_sup, fn ->
           case fun.() do
             :noreply_to_server -> :ok
             msg -> send(server, msg)
           end
         end) do
      {:ok, _pid} ->
        :ok

      other ->
        # Task.Supervisor down/overloaded — the op's reply will never come;
        # at least make the silence diagnosable.
        Logger.warning("Bluez.Gatt: failed to start BlueZ-call task: #{inspect(other)}")
    end
  end

  # ── misc helpers ─────────────────────────────────────────────────────────

  # rebus decodes `ay` to a byte list (or binary, depending on path).
  defp to_bin(value) when is_binary(value), do: value
  defp to_bin(value) when is_list(value), do: :erlang.list_to_binary(value)
  defp to_bin(_other), do: <<>>

  defp error_code("org.bluez.Error.NotConnected"), do: @err_not_connected
  defp error_code(_reason), do: @err_generic

  defp fmt(address) when is_integer(address) do
    address
    |> Integer.to_string(16)
    |> String.pad_leading(12, "0")
  end
end
