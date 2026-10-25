defmodule Bluez.Advertiser do
  @moduledoc """
  LE advertising through BlueZ's `org.bluez.LEAdvertisingManager1`: each
  advertisement is an `org.bluez.LEAdvertisement1` object this process
  exports on the bus, registered with `bluetoothd`, and unregistered again
  after `duration_ms:`, on `stop/1`, or when its owner process exits.

  BlueZ builds the AD bytes from the object's properties. It keeps
  `ServiceUUIDs` in the given order *with duplicates*, so protocols that
  carry a payload in a 16-bit UUID list can be sent here — see
  `Bluez.AdData.uuid16_strings/1`:

      payload = <<...26 bytes...>>
      Bluez.Advertiser.advertise(
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
  controller its next pick is at most *n + 1*. `advertise/2` therefore
  refuses with `{:error, :instance_conflict}` while `Bluez.Mgmt` holds an
  instance in that range — rather than let BlueZ silently overwrite the
  raw advertisement (and `Bluez.Mgmt`'s later cleanup then remove this
  one). `Bluez.Mgmt` defaults to the controller's highest free instance,
  so on controllers with several instances both can run side by side; on
  a one-instance controller they take turns.

  The check is a snapshot, not a reservation: it can't see an
  `Bluez.Mgmt.advertise/2` that starts after it, and `Bluez.Mgmt` can't
  see a registration still in flight here. **Don't send through both on
  the same controller concurrently** — issue them from one process (one
  after the other), as a single protocol driver naturally does.

  ## Start options

    * `adapter_path:` — the adapter object path to advertise on (default:
      the one `Bluez.Client` resolves; until it has, `advertise/2` returns
      `{:error, :no_adapter}`). Each advertisement is unregistered from
      the adapter it was registered on.
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

  alias Bluez.{DBus, DevicePath, Hci}
  alias Bluez.Rebus.Message

  @adv_mgr_iface "org.bluez.LEAdvertisingManager1"
  @adv_iface "org.bluez.LEAdvertisement1"
  @props_iface "org.freedesktop.DBus.Properties"
  @introspect_iface "org.freedesktop.DBus.Introspectable"

  @path_prefix "/org/exbluez/advertiser/adv"
  @call_timeout 10_000

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
  Register an advertisement. Returns `{:ok, id}` once `bluetoothd` has
  accepted it (it is on air from then), or `{:error, reason}` — a BlueZ
  error name (`"org.bluez.Error.NotPermitted"` when out of instances or
  the data is too long, `"org.bluez.Error.InvalidArguments"`, …) or
  `:not_running`.

  Options:

    * `:duration_ms` — unregister after this many ms (default: until
      `stop/1`). Millisecond-precise, unlike BlueZ's whole-second
      `Timeout`.
    * `:owner` — pid whose exit unregisters it (default: the caller;
      `nil` = none).
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

  Until `Bluez.Client` has resolved the adapter (and without the
  `adapter_path:` start option) this returns `{:error, :no_adapter}`
  rather than registering on the `hci0` fallback.
  """
  @spec advertise(spec(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def advertise(spec, opts \\ [])

  def advertise(%{type: type} = spec, opts) when type in [:broadcast, :peripheral] do
    opts = Keyword.put_new(opts, :owner, self())
    server = Keyword.get(opts, :server, __MODULE__)

    # Validated here, in the caller: a bad option must not crash the
    # shared server and lose every other advertisement's state.
    with :ok <- validate_opts(opts),
         {:ok, props} <- properties(spec) do
      held = Bluez.Mgmt.held_instances(Keyword.get(opts, :mgmt, Bluez.Mgmt))
      server_call(server, {:advertise, props, opts, held})
    end
  end

  def advertise(spec, _opts),
    do: {:error, {:invalid_spec, "type must be :broadcast or :peripheral, got: #{inspect(spec)}"}}

  defp validate_opts(opts) do
    cond do
      not (is_nil(opts[:owner]) or is_pid(opts[:owner])) -> {:error, {:invalid, "owner"}}
      not valid_duration?(opts[:duration_ms]) -> {:error, {:invalid, "duration_ms"}}
      true -> :ok
    end
  end

  defp valid_duration?(nil), do: true
  defp valid_duration?(ms), do: is_integer(ms) and ms > 0

  @doc """
  Unregister an advertisement early. Returns `:ok` once BlueZ has
  confirmed the unregistration, so a following `advertise/2` can reuse
  the freed slot (`:ok` also when already gone). If BlueZ refuses or the
  call times out, returns `{:error, reason}` and the advertisement stays
  tracked, so `stop/2` can be retried.
  """
  @spec stop(pos_integer(), GenServer.server()) :: :ok | {:error, term()}
  def stop(id, server \\ __MODULE__) do
    case server_call(server, {:stop, id}) do
      {:error, :not_running} -> :ok
      other -> other
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
    adapter_path = Keyword.get(opts, :adapter_path)

    case connect.() do
      {:ok, conn} ->
        Bluez.Rebus.set_method_handler(conn, self())

        state = %{
          conn: conn,
          conn_ref: Process.monitor(conn),
          # Explicit adapter, else the one Bluez.Client resolves.
          adapter_path: adapter_path,
          next_id: 1,
          # id => %{props, adapter, owner_ref, timer, cancelled, waiters,
          #         status: :registering | :active | :unregistering}
          ads: %{}
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:dbus_connect_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:advertise, props, opts, mgmt_held}, from, state) do
    with {:ok, adapter} <- adapter_path(state),
         :ok <- check_mgmt_conflict(state, adapter, mgmt_held) do
      start_registration(state, adapter, props, opts, from)
    else
      :error -> {:reply, {:error, :no_adapter}, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  # Replies once BlueZ has confirmed the unregistration (or refused it);
  # a stop arriving mid-registration or mid-unregistration waits too.
  def handle_call({:stop, id}, from, state) do
    case Map.fetch(state.ads, id) do
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
  # Any Mgmt instance in that range could be silently taken over.
  defp check_mgmt_conflict(state, adapter, mgmt_held) do
    case Hci.adapter_index(adapter) do
      {:ok, index} ->
        count = Enum.count(state.ads, fn {_id, entry} -> entry.adapter == adapter end)
        reachable = fn {held_index, instance} -> held_index == index and instance <= count + 1 end

        if Enum.any?(mgmt_held, reachable), do: {:error, :instance_conflict}, else: :ok

      # Not an hciN path (only from an explicit adapter_path:): no index
      # to compare, nothing Mgmt could hold there.
      :error ->
        :ok
    end
  end

  # Every later cleanup goes to the adapter captured here, never a re-read.
  defp start_registration(state, adapter, props, opts, from) do
    id = state.next_id
    path = path(id)
    conn = state.conn
    me = self()

    owner_ref =
      case opts[:owner] do
        pid when is_pid(pid) -> Process.monitor(pid)
        nil -> nil
      end

    entry = %{
      props: props,
      adapter: adapter,
      owner_ref: owner_ref,
      timer: nil,
      status: :registering,
      # Stopped while registering: unregister as soon as BlueZ answers.
      cancelled: false,
      # stop/2 callers waiting for the unregistration to be confirmed.
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

      # Stopped (stop/2, owner exit, expiry) while registering: take it
      # straight back off air, answering the waiting stop callers when done.
      {{:ok, _}, {:ok, entry}} ->
        GenServer.reply(from, {:error, :stopped})
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
      # (stop/2 can retry; its owner and duration triggers are spent).
      {{:error, reason}, {:ok, entry}} ->
        Logger.warning("Bluez.Advertiser: unregistering #{path(id)} failed: #{inspect(reason)}")
        Enum.each(entry.waiters, &GenServer.reply(&1, {:error, reason}))
        {:noreply, put_in(state.ads[id], %{entry | status: :active, waiters: []})}
    end
  end

  def handle_info({:expire, id}, state), do: {:noreply, unregister(state, id)}

  def handle_info({:dbus_call, %Message{} = msg}, state),
    do: {:noreply, dispatch_method_call(msg, state)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{conn_ref: ref} = state),
    do: {:stop, {:dbus_connection_down, reason}, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    ids = for {id, %{owner_ref: ^ref}} <- state.ads, do: id
    {:noreply, Enum.reduce(ids, state, &unregister(&2, &1))}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp unregistered(state, id, entry) do
    Enum.each(entry.waiters, &GenServer.reply(&1, :ok))
    drop(state, id)
  end

  # Owner exit / expiry: start taking it off air, whatever stage it's at.
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

  # Owner and duration triggers fire at most once per advertisement.
  defp spend_triggers(entry) do
    if entry.owner_ref, do: Process.demonitor(entry.owner_ref, [:flush])
    if entry.timer, do: Process.cancel_timer(entry.timer)
    %{entry | owner_ref: nil, timer: nil}
  end

  defp drop(state, id) do
    case Map.pop(state.ads, id) do
      {nil, _ads} ->
        state

      {entry, ads} ->
        if entry.owner_ref, do: Process.demonitor(entry.owner_ref, [:flush])
        if entry.timer, do: Process.cancel_timer(entry.timer)
        %{state | ads: ads}
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

  defp adapter_path(%{adapter_path: path}) when is_binary(path), do: {:ok, path}
  defp adapter_path(_state), do: DevicePath.resolved_adapter_path()
end
