defmodule Bluez.VariantTest do
  use ExUnit.Case, async: true

  alias Bluez.Variant

  describe "unwrap_props/1" do
    test "strips the variant signature from plain props" do
      props = [{"RSSI", {"n", -60}}, {"AddressType", {"s", "public"}}, {"TxPower", {"n", -4}}]

      assert Variant.unwrap_props(props) == %{
               "RSSI" => -60,
               "AddressType" => "public",
               "TxPower" => -4
             }
    end

    test "ManufacturerData (a{qv}) becomes %{company_id => binary}" do
      props = [{"ManufacturerData", {"a{qv}", [{0x004C, {"ay", [0x02, 0x15, 0xAA]}}]}}]

      assert Variant.unwrap_props(props) == %{
               "ManufacturerData" => %{0x004C => <<0x02, 0x15, 0xAA>>}
             }
    end

    test "ServiceData (a{sv}) becomes %{uuid => binary}" do
      props = [
        {"ServiceData",
         {"a{sv}", [{"0000fcd2-0000-1000-8000-00805f9b34fb", {"ay", [0x40, 0x01]}}]}}
      ]

      assert Variant.unwrap_props(props) == %{
               "ServiceData" => %{"0000fcd2-0000-1000-8000-00805f9b34fb" => <<0x40, 0x01>>}
             }
    end

    test "accepts already-binary byte arrays" do
      props = [{"ManufacturerData", {"a{qv}", [{0x06, {"ay", <<0xBB>>}}]}}]
      assert Variant.unwrap_props(props) == %{"ManufacturerData" => %{0x06 => <<0xBB>>}}
    end

    test "list values that are not the special dicts pass through unwrapped" do
      props = [{"ServiceUUIDs", {"as", ["0000180f-0000-1000-8000-00805f9b34fb"]}}]

      assert Variant.unwrap_props(props) == %{
               "ServiceUUIDs" => ["0000180f-0000-1000-8000-00805f9b34fb"]
             }
    end
  end
end
