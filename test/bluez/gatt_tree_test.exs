defmodule Bluez.GattTreeTest do
  use ExUnit.Case, async: true

  alias Bluez.Gatt.{Characteristic, Descriptor, Service}
  alias Bluez.GattTree

  doctest GattTree

  @dev "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
  @other_dev "/org/bluez/hci0/dev_11_22_33_44_55_66"

  @battery_service "0000180f-0000-1000-8000-00805f9b34fb"
  @battery_level "00002a19-0000-1000-8000-00805f9b34fb"
  @cccd "00002902-0000-1000-8000-00805f9b34fb"
  @nordic_uart "6e400001-b5a3-f393-e0a9-e50e24dcca9e"

  # GetManagedObjects entries the way rebus decodes them: {path, [{iface,
  # [{prop, {signature, value}}]}]}. Mirrors a real BlueZ tree for a device
  # with a battery service (notify-able level + CCCD) and a vendor service.
  defp objects do
    svc = @dev <> "/service000a"
    chr = svc <> "/char000b"
    desc = chr <> "/desc000d"
    vendor_svc = @dev <> "/service0010"
    vendor_chr = vendor_svc <> "/char0011"

    [
      {"/org/bluez/hci0", [{"org.bluez.Adapter1", [{"Powered", {"b", true}}]}]},
      {@dev, [{"org.bluez.Device1", [{"Connected", {"b", true}}]}]},
      {svc,
       [
         {"org.bluez.GattService1",
          [
            {"UUID", {"s", @battery_service}},
            {"Primary", {"b", true}},
            {"Device", {"o", @dev}}
          ]}
       ]},
      {chr,
       [
         {"org.bluez.GattCharacteristic1",
          [
            {"UUID", {"s", @battery_level}},
            {"Service", {"o", svc}},
            {"Flags", {"as", ["read", "notify"]}},
            {"MTU", {"q", 247}}
          ]}
       ]},
      {desc,
       [
         {"org.bluez.GattDescriptor1", [{"UUID", {"s", @cccd}}, {"Characteristic", {"o", chr}}]}
       ]},
      {vendor_svc,
       [
         {"org.bluez.GattService1",
          [
            {"UUID", {"s", @nordic_uart}},
            {"Primary", {"b", true}},
            {"Device", {"o", @dev}}
          ]}
       ]},
      {vendor_chr,
       [
         {"org.bluez.GattCharacteristic1",
          [
            {"UUID", {"s", String.upcase(@nordic_uart)}},
            {"Service", {"o", vendor_svc}},
            {"Flags", {"as", ["write", "write-without-response"]}}
          ]}
       ]},
      # Another device's GATT objects must not leak into this tree.
      {@other_dev <> "/service0001",
       [
         {"org.bluez.GattService1",
          [{"UUID", {"s", @battery_service}}, {"Device", {"o", @other_dev}}]}
       ]},
      # Malformed path (no parseable handle) is dropped, not a crash.
      {@dev <> "/serviceXYZ", [{"org.bluez.GattService1", [{"UUID", {"s", @battery_service}}]}]}
    ]
  end

  describe "build/2" do
    test "builds neutral Service structs sorted by handle" do
      tree = GattTree.build(objects(), @dev)

      assert [
               %Service{uuid: 0x180F, handle: 0x0A, characteristics: [battery_char]},
               %Service{uuid: vendor_uuid, handle: 0x10, characteristics: [vendor_char]}
             ] = tree.services

      # Characteristics report the VALUE handle (declaration + 1, bleak
      # convention); descriptors report their own handle.
      assert %Characteristic{
               uuid: 0x2A19,
               handle: 0x0C,
               properties: 0x12,
               descriptors: [%Descriptor{uuid: 0x2902, handle: 0x0D}]
             } = battery_char

      # Non-SIG UUIDs come through as the full 16-byte binary, case-folded.
      assert vendor_uuid ==
               @nordic_uart |> String.replace("-", "") |> Base.decode16!(case: :lower)

      assert %Characteristic{handle: 0x12, properties: 0x0C, descriptors: []} = vendor_char
    end

    test "maps reported handles back to object paths and kinds" do
      tree = GattTree.build(objects(), @dev)

      assert tree.by_handle[0x0C] == {:characteristic, @dev <> "/service000a/char000b"}
      assert tree.by_handle[0x12] == {:characteristic, @dev <> "/service0010/char0011"}

      assert tree.by_handle[0x0D] ==
               {:descriptor, @dev <> "/service000a/char000b/desc000d"}

      refute Map.has_key?(tree.by_handle, 0x0B)
    end

    test "maps characteristic paths to reported handles (for notifications)" do
      tree = GattTree.build(objects(), @dev)

      assert tree.handle_by_char_path[@dev <> "/service000a/char000b"] == 0x0C
      assert tree.handle_by_char_path[@dev <> "/service0010/char0011"] == 0x12
    end

    test "surfaces the experimental MTU property when present" do
      assert GattTree.build(objects(), @dev).mtu == 247
    end

    test "mtu is nil when no characteristic reports one" do
      assert GattTree.build(objects(), @other_dev).mtu == nil
    end

    test "excludes other devices' objects and tolerates malformed paths" do
      tree = GattTree.build(objects(), @other_dev)

      assert [%Service{handle: 0x01, characteristics: []}] = tree.services
    end

    test "empty object list yields an empty tree" do
      tree = GattTree.build([], @dev)

      assert tree.services == []
      assert tree.by_handle == %{}
      assert tree.handle_by_char_path == %{}
      assert tree.mtu == nil
    end

    test "a characteristic whose Service parent belongs to another device is orphaned" do
      # Path under @dev, but parent ref points into @other_dev's tree: it
      # must not show up in either device's service list.
      orphan =
        {@dev <> "/service000a/char00f0",
         [
           {"org.bluez.GattCharacteristic1",
            [
              {"UUID", {"s", @battery_level}},
              {"Service", {"o", @other_dev <> "/service0001"}},
              {"Flags", {"as", ["read"]}}
            ]}
         ]}

      tree = GattTree.build(objects() ++ [orphan], @dev)

      char_uuids =
        for svc <- tree.services, chr <- svc.characteristics, do: chr.handle

      refute 0xF1 in char_uuids
      # The orphan is still addressable by handle (BlueZ would serve it),
      # so the op maps keep it.
      assert tree.by_handle[0xF1] == {:characteristic, @dev <> "/service000a/char00f0"}
    end

    test "duplicate handles: last object in bus order wins in the op maps" do
      dup =
        {@dev <> "/service0010/char000b",
         [
           {"org.bluez.GattCharacteristic1",
            [
              {"UUID", {"s", @battery_level}},
              {"Service", {"o", @dev <> "/service0010"}},
              {"Flags", {"as", ["read"]}}
            ]}
         ]}

      tree = GattTree.build(objects() ++ [dup], @dev)

      # Both chars claim declaration handle 0x0B → value handle 0x0C. The
      # LAST object in bus order wins in the op maps (BlueZ shouldn't emit
      # duplicates; this documents the deterministic tie-break).
      assert tree.by_handle[0x0C] == {:characteristic, @dev <> "/service0010/char000b"}
    end
  end

  describe "properties_mask/1" do
    test "maps all spec'd flags to their bits" do
      assert GattTree.properties_mask(["broadcast"]) == 0x01
      assert GattTree.properties_mask(["read"]) == 0x02
      assert GattTree.properties_mask(["write-without-response"]) == 0x04
      assert GattTree.properties_mask(["write"]) == 0x08
      assert GattTree.properties_mask(["notify"]) == 0x10
      assert GattTree.properties_mask(["indicate"]) == 0x20
      assert GattTree.properties_mask(["authenticated-signed-writes"]) == 0x40
      assert GattTree.properties_mask(["extended-properties"]) == 0x80
    end

    test "ignores flags without a properties bit" do
      assert GattTree.properties_mask(["reliable-write", "encrypt-read", "read"]) == 0x02
    end

    test "non-list input maps to 0" do
      assert GattTree.properties_mask(nil) == 0
      assert GattTree.properties_mask("read") == 0
    end
  end

  describe "to_uuid/1" do
    test "SIG base UUIDs collapse to the 16-bit short form" do
      assert GattTree.to_uuid(@battery_service) == 0x180F
      assert GattTree.to_uuid(String.upcase(@cccd)) == 0x2902
    end

    test "vendor UUIDs become 16-byte binaries" do
      assert GattTree.to_uuid(@nordic_uart) ==
               <<0x6E400001B5A3F393E0A9E50E24DCCA9E::128>>
    end

    test "garbage maps to the all-zero UUID instead of raising" do
      assert GattTree.to_uuid("not-a-uuid") == <<0::128>>
      assert GattTree.to_uuid(nil) == <<0::128>>
      assert GattTree.to_uuid(42) == <<0::128>>
    end
  end
end
