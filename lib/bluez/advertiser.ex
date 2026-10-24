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

  alias Bluez.{DBus, DevicePath}
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
  """
  @spec advertise(spec(), keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def advertise(%{type: type} = spec, opts \\ []) when type in [:broadcast, :peripheral] do
    opts = Keyword.put_new(opts, :owner, self())
    server = Keyword.get(opts, :server, __MODULE__)

    with {:ok, props} <- properties(spec) do
      server_call(server, {:advertise, props, opts})
    end
  end

  @doc "Unregister an advertisement early. `:ok` also when already gone."
  @spec stop(pos_integer(), GenServer.server()) :: :ok
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

  defp property(:manufacturer_data, map) when is_map(map) do
    entries = for {id, bytes} <- map, id in 0..0xFFFF, do: {id, {"ay", bytes!(bytes)}}
    [{"ManufacturerData", {"a{qv}", entries}}]
  end

  defp property(:service_data, map) when is_map(map) do
    entries = for {uuid, bytes} <- map, is_binary(uuid), do: {uuid, {"ay", bytes!(bytes)}}
    [{"ServiceData", {"a{sv}", entries}}]
  end

  defp property(:data, map) when is_map(map) do
    entries = for {type, bytes} <- map, type in 0..255, do: {type, {"ay", bytes!(bytes)}}
    [{"Data", {"a{yv}", entries}}]
  end

  defp property(:local_name, name) when is_binary(name), do: [{"LocalName", {"s", name}}]

  defp property(:appearance, value) when value in 0..0xFFFF,
    do: [{"Appearance", {"q", value}}]

  defp property(:discoverable, value) when is_boolean(value),
    do: [{"Discoverable", {"b", value}}]

  defp property(:includes, list), do: [{"Includes", {"as", strings!(list)}}]

  defp property(:min_interval_ms, ms) when is_integer(ms) and ms > 0,
    do: [{"MinInterval", {"u", ms}}]

  defp property(:max_interval_ms, ms) when is_integer(ms) and ms > 0,
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
          next_id: 1,
          # id => %{props, owner_ref, timer, status: :registering | :active}
          ads: %{}
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, {:dbus_connect_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:advertise, props, opts}, from, state) do
    id = state.next_id
    path = path(id)
    conn = state.conn
    me = self()

    owner_ref =
      case opts[:owner] do
        pid when is_pid(pid) -> Process.monitor(pid)
        nil -> nil
      end

    entry = %{props: props, owner_ref: owner_ref, timer: nil, status: :registering}

    # RegisterAdvertisement re-enters us (GetAll), so it can't run here.
    {:ok, _pid} =
      Task.start(fn ->
        result =
          DBus.call(conn, adapter_path(), @adv_mgr_iface, "RegisterAdvertisement", "oa{sv}", [
            path,
            []
          ])

        send(me, {:registered, id, from, opts[:duration_ms], result})
      end)

    {:noreply, %{state | next_id: id + 1, ads: Map.put(state.ads, id, entry)}}
  end

  def handle_call({:stop, id}, _from, state), do: {:reply, :ok, unregister(state, id)}

  @impl GenServer
  def handle_info({:registered, id, from, duration_ms, result}, state) do
    case {result, Map.fetch(state.ads, id)} do
      {{:ok, _}, {:ok, entry}} ->
        timer =
          if is_integer(duration_ms) and duration_ms > 0,
            do: Process.send_after(self(), {:expire, id}, duration_ms)

        GenServer.reply(from, {:ok, id})
        entry = %{entry | status: :active, timer: timer}
        {:noreply, %{state | ads: Map.put(state.ads, id, entry)}}

      {{:ok, _}, :error} ->
        # Stopped (owner died) while registering: take it back off air.
        GenServer.reply(from, {:error, :stopped})
        unregister_async(state.conn, id)
        {:noreply, state}

      # Our call timed out (or the connection hiccuped): BlueZ may still
      # accept the registration later, so take it back off air rather than
      # leave an untracked advertisement running.
      {{:error, {:exit, _}} = error, _} ->
        GenServer.reply(from, error)
        unregister_async(state.conn, id)
        {:noreply, drop(state, id)}

      {{:error, reason}, _} ->
        GenServer.reply(from, {:error, reason})
        {:noreply, drop(state, id)}
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

  # Active: unregister on the bus. Still registering: just forget it — the
  # :registered handler unregisters once BlueZ has answered.
  defp unregister(state, id) do
    case Map.fetch(state.ads, id) do
      {:ok, %{status: :active}} ->
        unregister_async(state.conn, id)
        drop(state, id)

      {:ok, %{status: :registering}} ->
        drop(state, id)

      :error ->
        state
    end
  end

  defp unregister_async(conn, id) do
    {:ok, _pid} =
      Task.start(fn ->
        DBus.call(conn, adapter_path(), @adv_mgr_iface, "UnregisterAdvertisement", "o", [path(id)])
      end)

    :ok
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

      # bluetoothd dropped it (adapter powered off, daemon exiting).
      {@adv_iface, "Release", %{} = _entry} ->
        Bluez.Rebus.reply(conn, msg)
        {:ok, id} = id_from_path(hf[:path])
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

  defp adapter_path, do: DevicePath.adapter_path()
end
