defmodule BluezTest do
  use ExUnit.Case, async: true

  # Normalize the mixed child shapes (child_spec maps for the daemons,
  # bare modules, {module, opts} tuples) down to a comparable id.
  defp id_of(%{id: id}), do: id
  defp id_of({mod, _opts}), do: mod
  defp id_of(mod) when is_atom(mod), do: mod

  describe "children/1" do
    test "extra_children append after BlueAlsa, in caller order" do
      # Restart-ordering contract under :rest_for_one — extra children
      # (host consumers) restart with the audio path but a fault there
      # never disturbs the scanning/GATT stack. A regression here silently
      # changes crash semantics.
      extra = [
        {Task.Supervisor, name: __MODULE__.ExtraTaskSup},
        __MODULE__.ExtraChild
      ]

      ids = Bluez.children(extra_children: extra) |> Enum.map(&id_of/1)

      assert ids == [
               Bluez.Rebus.SignalHandler,
               DynamicSupervisor,
               :dbus_daemon,
               Bluez.BusReady,
               :bluetoothd,
               Bluez.Client,
               Bluez.Agent,
               Task.Supervisor,
               Bluez.Gatt,
               :bluealsad,
               Bluez.BlueAlsa,
               # extra_children, in caller order
               Task.Supervisor,
               __MODULE__.ExtraChild
             ]
    end

    test "audio: false drops the bluealsad daemon and BlueAlsa client" do
      ids = Bluez.children(audio: false) |> Enum.map(&id_of/1)

      refute :bluealsad in ids
      refute Bluez.BlueAlsa in ids

      # extra_children still land at the end, right after the GATT client.
      assert Bluez.children(audio: false, extra_children: [__MODULE__.ExtraChild])
             |> List.last() == __MODULE__.ExtraChild
    end

    test "opts thread through to the Client/Gatt/BlueAlsa children" do
      fan_out = fn _advert -> :ok end

      children =
        Bluez.children(
          client: [on_advertisement: fan_out],
          gatt: [on_connections_changed: fan_out],
          blue_alsa: [pubsub: __MODULE__.PubSub]
        )

      assert {Bluez.Client, [on_advertisement: ^fan_out]} =
               Enum.find(children, &match?({Bluez.Client, _}, &1))

      assert {Bluez.Gatt, [on_connections_changed: ^fan_out]} =
               Enum.find(children, &match?({Bluez.Gatt, _}, &1))

      assert {Bluez.BlueAlsa, [pubsub: __MODULE__.PubSub]} =
               Enum.find(children, &match?({Bluez.BlueAlsa, _}, &1))
    end

    test "daemon binaries are overridable per opts" do
      children = Bluez.children(dbus_daemon_path: "/opt/dbus", bluetoothd_path: "/opt/btd")

      assert %{id: :dbus_daemon, start: {MuonTrap.Daemon, :start_link, ["/opt/dbus" | _]}} =
               Enum.find(children, &match?(%{id: :dbus_daemon}, &1))

      assert %{id: :bluetoothd, start: {MuonTrap.Daemon, :start_link, ["/opt/btd" | _]}} =
               Enum.find(children, &match?(%{id: :bluetoothd}, &1))
    end

    test "no opts yields the default children with an empty extra slot" do
      ids = Bluez.children([]) |> Enum.map(&id_of/1)

      assert ids == [
               Bluez.Rebus.SignalHandler,
               DynamicSupervisor,
               :dbus_daemon,
               Bluez.BusReady,
               :bluetoothd,
               Bluez.Client,
               Bluez.Agent,
               Task.Supervisor,
               Bluez.Gatt,
               :bluealsad,
               Bluez.BlueAlsa
             ]
    end
  end
end
