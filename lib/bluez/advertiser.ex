defmodule Bluez.Advertiser do
  @moduledoc """
  LE advertising through BlueZ's `org.bluez.LEAdvertisingManager1`: each
  advertisement is an `org.bluez.LEAdvertisement1` object this process
  exports on the bus, registered with `bluetoothd`, and unregistered again
  after `duration_ms:`, on `stop/3`, or when its transmit lease ends.

  Sending requires the controller's transmit lease (`Bluez.Radio`): call
  `advertise/3` and `stop/3` from the process holding it. The lease names
  the controller (`/org/bluez/hciN`), and ending it — `Bluez.Radio.release/1`
  or the holder exiting — unregisters everything sent under it.

  BlueZ builds the AD bytes from the object's properties. It keeps
  `ServiceUUIDs` in the given order *with duplicates*, so protocols that
  carry a payload in a 16-bit UUID list can be sent here — see
  `Bluez.AdData.uuid16_strings/1`:

      {:ok, lease} = Bluez.Radio.acquire()
      payload = <<...26 bytes...>>

      Bluez.Advertiser.advertise(
        lease,
        %{type: :broadcast, service_uuids: Bluez.AdData.uuid16_strings(payload)},
        duration_ms: 300
      )

  What BlueZ will *not* do: put Flags, names, UUID lists or service data
  in the free-form `data:` map (it rejects those AD types), put
  `local_name:` in the advertising PDU of a connectable advert (it goes to
  the scan response), or add Flags unless `discoverable: true`. For a
  verbatim byte layout use `Bluez.Mgmt` instead.

  Like `Bluez.Client` and `Bluez.Agent`, this is a D-Bus client *and*
  service on its own `rebus` connection; registration runs in a Task
  because `bluetoothd` calls `Properties.GetAll` back on us before
  `RegisterAdvertisement` returns.

  ## Sharing the controller with `Bluez.Mgmt`

  Advertising instances are per controller, and `bluetoothd` allocates
  them from its own bookkeeping, which doesn't include instances
  `Bluez.Mgmt` adds directly through the kernel. It always takes the
  lowest number it considers free, so with *n* of our advertisements on a
  controller its next pick is at most *n + 1*. `advertise/3` therefore
  refuses with `{:error, :instance_conflict}` while `Bluez.Mgmt` holds an
  instance in that range — rather than let BlueZ silently overwrite the
  raw advertisement (and `Bluez.Mgmt`'s later cleanup then remove this
  one). `Bluez.Mgmt` defaults to the controller's highest free instance,
  so on controllers with several instances both can run side by side; on
  a one-instance controller they take turns.

  The check is exact because of the lease: only the holder sends on the
  controller, and each send returns only once BlueZ (or the kernel) has
  the instance — so no other send can slip in between check and use. A
  `Bluez.Mgmt` that doesn't answer counts as a conflict.

  An unregistration BlueZ refuses after its lease ended — so no holder is
  left to retry it — is retried here a few times.

  ## Start options

    * `radio:` — the `Bluez.Radio` whose leases to accept (default
      `Bluez.Radio`); leases from any other are refused.
    * `name:` — registered name (default `Bluez.Advertiser`).

  ## Advertisement spec

  A map; every key is optional except `:type`:

    * `type:` — `:broadcast` (non-connectable) or `:peripheral`.
    * `service_uuids:`, `solicit_uuids:` — lists of UUID strings (16-bit
      as the full base-UUID form or 4 hex digits).
    * `manufacturer_data:` — `%{company_id => binary}`.
    * `service_data:` — `%{uuid_string => binary}`.
    * `data:` — `%{ad_type => binary}` for AD types BlueZ allows raw.
    * `local_name:`, `appearance:`, `discoverable:`, `includes:` (e.g.
      `["tx-power"]`), `min_interval_ms:`, `max_interval_ms:`, `tx_power:`.
  """

  use GenServer
  require Logger

  alias Bluez.{DBus, Radio}
  alias Bluez.Radio.Lease
  alias Bluez.Rebus.Message

  @adv_mgr_iface "org.bluez.LEAdvertisingManager1"
  @adv_iface "org.bluez.LEAdvertisement1"
  @props_iface "org.freedesktop.DBus.Properties"
  @introspect_iface "org.freedesktop.DBus.Introspectable"

  @path_prefix "/org/exbluez/advertiser/adv"
  @call_timeout 10_000

  # Retries of an unregistration BlueZ refused after its lease ended.
  @orphan_retries 3
  @orphan_retry_ms 2_000

  @type spec :: %{
          required(:type) => :broadcast | :peripheral,
          optional(:service_uuids) => [String.t()],
          optional(:solicit_uuids) => [String.t()],
          optional(:manufacturer_data) => %{optional(0..0xFFFF) => binary()},
          optional(:service_data) => %{optional(String.t()) => binary()},
          optional(:data) => %{optional(0..255) => binary()},
          optional(:local_name) => String.t(),
          optional(:appearance) => 0..0xFFFF,
          optional(:discoverable) => boolean(),
          optional(:includes) => [String.t()],
          optional(:min_interval_ms) => pos_integer(),
          optional(:max_interval_ms) => pos_integer(),
          optional(:tx_power) => integer()
        }

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register an advertisement on the controller `lease` covers (call it
  from the lease holder). Returns `{:ok, id}` once `bluetoothd` has
  accepted it (it is on air from then), or `{:error, reason}` — a BlueZ
  error name (`"org.bluez.Error.NotPermitted"` when out of instances or
  the data is too long, `"org.bluez.Error.InvalidArguments"`, …),
  `:not_lease_holder`, `:lease_expired`, or `:not_running`.

  Options:

    * `:duration_ms` — unregister after this many ms (default: until
      `stop/3` or the lease ends). Millisecond-precise, unlike BlueZ's
      whole-second `Timeout`.
    * `:server` — the Advertiser to use (default `Bluez.Advertiser`).
    * `:mgmt` — the `Bluez.Mgmt` whose instances to respect (default
      `Bluez.Mgmt`; no effect when it isn't running).

  A spec without a valid `:type` (or with an invalid field) returns
  `{:error, {:invalid_spec, message}}`; bad options return
  `{:error, {:invalid, option}}`.

  Returns `{:error, :instance_conflict}` instead of registering when
  `bluetoothd` could hand this advertisement an instance `Bluez.Mgmt`
  holds on the same controller (see "Sharing the controller with
  `Bluez.Mgmt`" above).
  """
  @spec advertise(Lease.t(), spec(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def advertise(lease, spec, opts \\ [])

  def advertise(lease, %{type: type} = spec, opts) when type in [:broadcast, :peripheral] do
    server = Keyword.get(opts, :server, __MODULE__)

    # Checked here, in the caller: only the holder sends, and a bad option
    # must not crash the shared server and lose every other advertisement.
    with :ok <- Radio.check_holder(lease),
         :ok <- validate_opts(opts),
         {:ok, props} <- properties(spec) do
      held = Bluez.Mgmt.held_instances(Keyword.get(opts, :mgmt, Bluez.Mgmt))
      server_call(server, {:advertise, lease, props, opts, held})
    end
  end

  def advertise(_lease, spec, _opts),
    do: {:error, {:invalid_spec, "type must be :broadcast or :peripheral, got: #{inspect(spec)}"}}

  defp validate_opts(opts) do
    if valid_duration?(opts[:duration_ms]), do: :ok, else: {:error, {:invalid, "duration_ms"}}
  end

  defp valid_duration?(nil), do: true
  defp valid_duration?(ms), do: is_integer(ms) and ms > 0

  @doc """
  Unregister an advertisement `advertise/3` registered under `lease`
  (call it from the holder). Returns `:ok` once BlueZ has confirmed the
  unregistration, so a following `advertise/3` can reuse the freed slot
  (`:ok` also when already gone). If BlueZ refuses or the call times out,
  returns `{:error, reason}` and the advertisement stays tracked, so
  `stop/3` can be retried. `{:error, :unknown_advertisement}` for one
  registered under another lease.
  """
  @spec stop(Lease.t(), pos_integer(), GenServer.server()) :: :ok | {:error, term()}
  def stop(lease, id, server \\ __MODULE__) do
    with :ok <- Radio.check_holder(lease) do
      case server_call(server, {:stop, lease, id}) do
        {:error, :not_running} -> :ok
        other -> other
      end
    end
  end

  @doc """
  Build the `LEAdvertisement1` property list (`a{sv}` as rebus encodes
  it) for a spec. Pure — exposed for tests.
  """
  @spec properties(spec()) :: {:ok, [{String.t(), {String.t(), term()}}]} | {:error, term()}
  def properties(spec) do
    props =
      Enum.flat_map(spec, fn {key, value} -> property(key, value) end)

    {:ok, props}
  rescue
    e in [ArgumentError, FunctionClauseError] -> {:error, {:invalid_spec, Exception.message(e)}}
  end

  defp property(:type, :broadcast), do: [{"Type", {"s", "broadcast"}}]
  defp property(:type, :peripheral), do: [{"Type", {"s", "peripheral"}}]
  defp property(:service_uuids, uuids), do: [{"ServiceUUIDs", {"as", strings!(uuids)}}]
  defp property(:solicit_uuids, uuids), do: [{"SolicitUUIDs", {"as", strings!(uuids)}}]

  # Every key is checked (never filtered out): a bad entry must fail the
  # spec, not register an advertisement silently missing that payload.
  defp property(:manufacturer_data, map) when is_map(map),
    do: [{"ManufacturerData", {"a{qv}", byte_entries(map, &(&1 in 0..0xFFFF))}}]

  defp property(:service_data, map) when is_map(map),
    do: [{"ServiceData", {"a{sv}", byte_entries(map, &is_binary/1)}}]

  defp property(:data, map) when is_map(map),
    do: [{"Data", {"a{yv}", byte_entries(map, &(&1 in 0..255))}}]

  defp property(:local_name, name) when is_binary(name), do: [{"LocalName", {"s", name}}]

  defp property(:appearance, value) when value in 0..0xFFFF,
    do: [{"Appearance", {"q", value}}]

  defp property(:discoverable, value) when is_boolean(value),
    do: [{"Discoverable", {"b", value}}]

  defp property(:includes, list), do: [{"Includes", {"as", strings!(list)}}]

  # D-Bus `u`: anything wider would be truncated into a different interval.
  defp property(:min_interval_ms, ms) when ms in 1..0xFFFFFFFF,
    do: [{"MinInterval", {"u", ms}}]

  defp property(:max_interval_ms, ms) when ms in 1..0xFFFFFFFF,
    do: [{"MaxInterval", {"u", ms}}]

  defp property(:tx_power, dbm) when dbm in -127..20, do: [{"TxPower", {"n", dbm}}]

  defp property(key, value),
    do: raise(ArgumentError, "invalid advertisement field #{inspect({key, value})}")

  defp strings!(list) when is_list(list) do
    if Enum.all?(list, &is_binary/1),
      do: list,
      else: raise(ArgumentError, "expected a list of strings, got #{inspect(list)}")
  end

  defp bytes!(bin) when is_binary(bin), do: :binary.bin_to_list(bin)

  defp byte_entries(map, valid_key?) do
    for {key, bytes} <- map do
      unless valid_key?.(key), do: raise(ArgumentError, "invalid key #{inspect(key)}")
      {key, {"ay", bytes!(bytes)}}
    end
  end

  # `catch :exit` idiom (see `Bluez`).
  defp server_call(server, request) do
    GenServer.call(server, request, @call_timeout)
  catch
    :exit, _reason -> {:error, :not_running}
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    connect = Keyword.get(opts, :connect_fun, fn -> Bluez.Rebus.connect(:system) end)

    case connect.() do
      {:ok, conn} ->
        Bluez.Rebus.set_method_handler(conn, self())

        state = %{
          conn: conn,
          conn_ref: Process.monitor(conn),
          # Test seam: the delay between orphan-unregistration retries.
          retry_ms: Keyword.get(opts, :retry_ms, @orphan_retry_ms),
          # The Radio whose lease ends we receive (see subscribe/1).
          radio: Keyword.get(opts, :radio, Radio),
          radio_pid: nil,
          radio_mon: nil,
          # Ended leases not yet reported drained to the Radio (settle/1).
          draining: MapSet.new(),
          next_id: 1,
          # id => %{props, adapter, index, lease_ref, lease_ended, retries,
          #         timer, cancelled, waiters,
          #         status: :registering | :active | :unregistering}
          ads: %{}
        }

        {:ok, subscribe(state)}

      {:error, reason} ->
        {:stop, {:dbus_connect_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:advertise, lease, props, opts, mgmt_held}, from, state) do
    state = subscribe(state)

    cond do
      not lease_valid?(state, lease) ->
        {:reply, {:error, :lease_expired}, state}

      mgmt_conflict?(state, lease.index, mgmt_held) ->
        {:reply, {:error, :instance_conflict}, state}

      true ->
        start_registration(state, lease, props, opts, from)
    end
  end

  # Replies once BlueZ has confirmed the unregistration (or refused it);
  # a stop arriving mid-unregistration (or mid-registration, after the
  # lease ended under it) waits too.
  def handle_call({:stop, %Lease{ref: ref}, id}, from, state) do
    case Map.fetch(state.ads, id) do
      {:ok, %{lease_ref: other}} when other != ref ->
        {:reply, {:error, :unknown_advertisement}, state}

      {:ok, %{status: :active}} ->
        {:noreply, begin_unregister(state, id, [from])}

      {:ok, %{status: :unregistering} = entry} ->
        {:noreply, put_in(state.ads[id], %{entry | waiters: [from | entry.waiters]})}

      {:ok, %{status: :registering}} ->
        {:noreply, cancel_registration(state, id, [from])}

      :error ->
        {:reply, :ok, state}
    end
  end

  # bluetoothd allocates the lowest instance its own bookkeeping shows as
  # free — it doesn't know Bluez.Mgmt's — so with `count` of our
  # advertisements on this controller its next pick is at most count + 1.
  # Any Mgmt instance in that range could be silently taken over. A Mgmt
  # that didn't answer may hold any of them.
  defp mgmt_conflict?(_state, _index, :unknown), do: true

  defp mgmt_conflict?(state, index, mgmt_held) do
    count = Enum.count(state.ads, fn {_id, entry} -> entry.index == index end)

    Enum.any?(mgmt_held, fn {held_index, instance} ->
      held_index == index and instance <= count + 1
    end)
  end

  defp start_registration(state, lease, props, opts, from) do
    id = state.next_id
    path = path(id)
    conn = state.conn
    me = self()
    adapter = "/org/bluez/hci" <> Integer.to_string(lease.index)

    entry = %{
      props: props,
      adapter: adapter,
      index: lease.index,
      lease_ref: lease.ref,
      # Its lease is over: nobody is left to retry a failed unregister.
      lease_ended: false,
      retries: 0,
      timer: nil,
      status: :registering,
      # Stopped while registering: unregister as soon as BlueZ answers.
      cancelled: false,
      # stop/3 callers waiting for the unregistration to be confirmed.
      waiters: []
    }

    # RegisterAdvertisement re-enters us (GetAll), so it can't run here.
    {:ok, _pid} =
      Task.start(fn ->
        result =
          DBus.call(conn, adapter, @adv_mgr_iface, "RegisterAdvertisement", "oa{sv}", [
            path,
            []
          ])

        send(me, {:registered, id, from, opts[:duration_ms], result})
      end)

    {:noreply, %{state | next_id: id + 1, ads: Map.put(state.ads, id, entry)}}
  end

  @impl GenServer
  def handle_info({:registered, id, from, duration_ms, result}, state) do
    case {result, Map.fetch(state.ads, id)} do
      {{:ok, _}, {:ok, %{cancelled: false} = entry}} ->
        timer =
          if is_integer(duration_ms) and duration_ms > 0,
            do: Process.send_after(self(), {:expire, id}, duration_ms)

        GenServer.reply(from, {:ok, id})
        entry = %{entry | status: :active, timer: timer}
        {:noreply, %{state | ads: Map.put(state.ads, id, entry)}}

      # Stopped (lease end, Release) while registering: take it
      # straight back off air, answering the waiting stop callers when done.
      {{:ok, _}, {:ok, entry}} ->
        GenServer.reply(from, {:error, if(entry.lease_ended, do: :lease_expired, else: :stopped)})
        {:noreply, begin_unregister(state, id, entry.waiters)}

      # Our call timed out (or the connection hiccuped): BlueZ may still
      # accept the registration later, so unregister rather than leave an
      # untracked advertisement running — tracked until that is confirmed.
      {{:error, {:exit, _}} = error, {:ok, entry}} ->
        GenServer.reply(from, error)
        {:noreply, begin_unregister(state, id, entry.waiters)}

      {{:error, reason}, {:ok, entry}} ->
        GenServer.reply(from, {:error, reason})
        Enum.each(entry.waiters, &GenServer.reply(&1, :ok))
        {:noreply, drop(state, id)}

      {_result, :error} ->
        GenServer.reply(from, {:error, :stopped})
        {:noreply, state}
    end
  end

  def handle_info({:unregistered, id, result}, state) do
    case {result, Map.fetch(state.ads, id)} do
      {_result, :error} ->
        {:noreply, state}

      # Gone either way: BlueZ removed it, or never had it.
      {{:ok, _}, {:ok, entry}} ->
        {:noreply, unregistered(state, id, entry)}

      {{:error, "org.bluez.Error.DoesNotExist"}, {:ok, entry}} ->
        {:noreply, unregistered(state, id, entry)}

      # Refused or timed out: it may still be on air, so keep tracking it
      # (stop/3 can retry — or, after its lease ended, retry_orphan/2; its
      # duration trigger is spent).
      {{:error, reason}, {:ok, entry}} ->
        Logger.warning("Bluez.Advertiser: unregistering #{path(id)} failed: #{inspect(reason)}")
        Enum.each(entry.waiters, &GenServer.reply(&1, {:error, reason}))
        state = put_in(state.ads[id], %{entry | status: :active, waiters: []})
        {:noreply, retry_orphan(state, id)}
    end
  end

  def handle_info({:expire, id}, state), do: {:noreply, unregister(state, id)}

  def handle_info({:dbus_call, %Message{} = msg}, state),
    do: {:noreply, dispatch_method_call(msg, state)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_ref: ref} = state),
    do: {:stop, {:dbus_connection_down, reason}, state}

  # The lease ended (released, or its holder exited): unregister
  # everything sent under it.
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

  def handle_info({:retry_unregister, id}, state) do
    case state.ads do
      %{^id => %{status: :active}} -> {:noreply, begin_unregister(state, id, [])}
      _other -> {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

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

  # Report each ended lease drained once none of its advertisements is
  # tracked here any more (registering, unregistering, or awaiting a
  # retry), so the Radio can hand the controller on.
  defp settle(%{draining: draining} = state) do
    done =
      Enum.reject(draining, fn ref ->
        Enum.any?(state.ads, fn {_id, entry} -> entry.lease_ref == ref end)
      end)

    Enum.each(done, &Radio.drained(state.radio_pid, &1))
    %{state | draining: MapSet.difference(draining, MapSet.new(done))}
  end

  # Unregister everything sent under the leases `ended?` matches.
  defp end_leases(state, ended?) do
    ids = for {id, %{lease_ref: ref}} <- state.ads, ended?.(ref), do: id

    Enum.reduce(ids, state, fn id, state ->
      state = put_in(state.ads[id].lease_ended, true)
      unregister(state, id)
    end)
  end

  # An unregister refused after its lease ended has no holder left to
  # retry it: retry it here, a few times, before leaving it to BlueZ
  # (which drops it when this process's bus connection closes).
  defp retry_orphan(state, id) do
    case state.ads[id] do
      %{lease_ended: true, retries: n} when n < @orphan_retries ->
        Process.send_after(self(), {:retry_unregister, id}, state.retry_ms)
        put_in(state.ads[id].retries, n + 1)

      # Detached from its lease, so the lease counts as drained.
      %{lease_ended: true} ->
        Logger.warning("Bluez.Advertiser: giving up unregistering #{path(id)}")
        settle(put_in(state.ads[id].lease_ref, nil))

      _live_lease ->
        state
    end
  end

  defp unregistered(state, id, entry) do
    Enum.each(entry.waiters, &GenServer.reply(&1, :ok))
    drop(state, id)
  end

  # Lease end / expiry: start taking it off air, whatever stage it's at.
  defp unregister(state, id) do
    case Map.fetch(state.ads, id) do
      {:ok, %{status: :active}} -> begin_unregister(state, id, [])
      {:ok, %{status: :registering}} -> cancel_registration(state, id, [])
      _unregistering_or_gone -> state
    end
  end

  defp cancel_registration(state, id, waiters) do
    entry = spend_triggers(Map.fetch!(state.ads, id))
    put_in(state.ads[id], %{entry | cancelled: true, waiters: waiters ++ entry.waiters})
  end

  # The entry stays (status :unregistering) until the Task's result
  # arrives, so a failure leaves it tracked and retryable.
  defp begin_unregister(state, id, waiters) do
    entry = spend_triggers(Map.fetch!(state.ads, id))
    conn = state.conn
    adapter = entry.adapter
    me = self()

    {:ok, _pid} =
      Task.start(fn ->
        result =
          DBus.call(conn, adapter, @adv_mgr_iface, "UnregisterAdvertisement", "o", [path(id)])

        send(me, {:unregistered, id, result})
      end)

    entry = %{entry | status: :unregistering, waiters: waiters ++ entry.waiters}
    put_in(state.ads[id], entry)
  end

  # The duration trigger fires at most once per advertisement.
  defp spend_triggers(entry) do
    if entry.timer, do: Process.cancel_timer(entry.timer)
    %{entry | timer: nil}
  end

  defp drop(state, id) do
    case Map.pop(state.ads, id) do
      {nil, _ads} ->
        state

      {entry, ads} ->
        if entry.timer, do: Process.cancel_timer(entry.timer)
        settle(%{state | ads: ads})
    end
  end

  # ── inbound method-call dispatch ──────────────────────────────────────────

  defp dispatch_method_call(%Message{header_fields: hf} = msg, state) do
    conn = state.conn

    entry =
      case id_from_path(hf[:path]) do
        {:ok, id} -> Map.get(state.ads, id)
        :error -> nil
      end

    case {hf[:interface], hf[:member], entry} do
      {@props_iface, "GetAll", %{props: props}} ->
        Bluez.Rebus.reply(conn, msg, [props], "a{sv}")
        state

      {@props_iface, "Get", %{props: props}} ->
        reply_property(conn, msg, props, Enum.at(msg.body, 1))
        state

      # bluetoothd dropped it (adapter powered off, daemon exiting). Mid-
      # registration, keep the entry (cancelled) so a RegisterAdvertisement
      # that still succeeds gets unregistered instead of left untracked.
      {@adv_iface, "Release", %{status: :registering}} ->
        Bluez.Rebus.reply(conn, msg)
        {:ok, id} = id_from_path(hf[:path])
        cancel_registration(state, id, [])

      {@adv_iface, "Release", %{} = entry} ->
        Bluez.Rebus.reply(conn, msg)
        {:ok, id} = id_from_path(hf[:path])
        Enum.each(entry.waiters, &GenServer.reply(&1, :ok))
        drop(state, id)

      {@introspect_iface, "Introspect", _entry} ->
        Bluez.Rebus.reply(conn, msg, [introspect_xml(entry)], "s")
        state

      {iface, member, _entry} ->
        Bluez.Rebus.reply_error(
          conn,
          msg,
          "org.freedesktop.DBus.Error.UnknownMethod",
          "#{iface}.#{member}"
        )

        state
    end
  rescue
    e ->
      Logger.warning("Bluez.Advertiser: inbound call handling raised #{inspect(e)}")

      Bluez.Rebus.reply_error(
        state.conn,
        msg,
        "org.freedesktop.DBus.Error.Failed",
        Exception.message(e)
      )

      state
  end

  defp reply_property(conn, msg, props, name) do
    case List.keyfind(props, name, 0) do
      {_name, variant} ->
        Bluez.Rebus.reply(conn, msg, [variant], "v")

      nil ->
        Bluez.Rebus.reply_error(conn, msg, "org.freedesktop.DBus.Error.UnknownProperty", name)
    end
  end

  defp introspect_xml(entry) do
    interfaces = if entry, do: ~s(<interface name="#{@adv_iface}"/>), else: ""

    ~s(<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">\n<node>#{interfaces}</node>)
  end

  defp path(id), do: @path_prefix <> Integer.to_string(id)

  defp id_from_path(@path_prefix <> digits) do
    case Integer.parse(digits) do
      {id, ""} -> {:ok, id}
      _ -> :error
    end
  end

  defp id_from_path(_path), do: :error
end
