defmodule Bluez.AdvertTest do
  use ExUnit.Case, async: true

  alias Bluez.Advert

  describe "address_to_integer/1" do
    test "parses a colon MAC into the MSB-first integer HA expects" do
      assert Advert.address_to_integer("AA:BB:CC:DD:EE:FF") == 0xAABBCCDDEEFF
      assert Advert.address_to_integer("00:00:00:00:00:01") == 1
    end
  end

  describe "reconstruct/1 — address handling" do
    test "skips when there is no address" do
      assert Advert.reconstruct(%{"RSSI" => -50}) == :skip
    end

    test "skips a non-map argument" do
      assert Advert.reconstruct(nil) == :skip
    end

    test "skips a malformed (non-MAC) Address instead of raising" do
      assert Advert.reconstruct(%{"Address" => "not-a-mac"}) == :skip
      assert Advert.reconstruct(%{"Address" => "AA:BB:CC"}) == :skip
      assert Advert.reconstruct(%{"Address" => "GG:HH:II:JJ:KK:LL"}) == :skip
    end

    test "carries rssi and address type through" do
      assert {:ok, %{rss: -50, address_type: 1}} =
               Advert.reconstruct(%{
                 "Address" => "11:22:33:44:55:66",
                 "RSSI" => -50,
                 "AddressType" => "random"
               })

      assert {:ok, %{address_type: 0}} =
               Advert.reconstruct(%{"Address" => "11:22:33:44:55:66", "AddressType" => "public"})
    end

    test "defaults RSSI to 0 when absent" do
      assert {:ok, %{rss: 0}} = Advert.reconstruct(%{"Address" => "11:22:33:44:55:66"})
    end
  end

  describe "reconstruct/1 — AD reconstruction" do
    test "manufacturer-data element (type 0xFF, little-endian company id)" do
      {:ok, %{raw_data: raw}} =
        Advert.reconstruct(%{
          "Address" => "11:22:33:44:55:66",
          "ManufacturerData" => %{0x004C => <<0x02, 0x15, 0xAA>>}
        })

      # <<len, 0xFF, company_id::little-16, data>>; len = 1+2+3 = 6
      assert raw == <<6, 0xFF, 0x4C, 0x00, 0x02, 0x15, 0xAA>>
    end

    test "multiple manufacturer IDs each produce a 0xFF element" do
      {:ok, %{raw_data: raw}} =
        Advert.reconstruct(%{
          "Address" => "11:22:33:44:55:66",
          "ManufacturerData" => %{0x004C => <<0xAA>>, 0x0006 => <<0xBB>>}
        })

      # Order is map-iteration order; assert both elements are present.
      # :binary.match (not =~) because AD bytes are arbitrary, not UTF-8 text.
      assert :binary.match(raw, <<4, 0xFF, 0x4C, 0x00, 0xAA>>) != :nomatch
      assert :binary.match(raw, <<4, 0xFF, 0x06, 0x00, 0xBB>>) != :nomatch
      assert byte_size(raw) == 10
    end

    test "drops a manufacturer element whose data would exceed 254 bytes" do
      # company(2) + 253 bytes = 255 > 254 -> dropped (length byte can't hold it)
      big = :binary.copy(<<0>>, 253)

      {:ok, %{raw_data: raw}} =
        Advert.reconstruct(%{
          "Address" => "11:22:33:44:55:66",
          "ManufacturerData" => %{0x004C => big}
        })

      assert raw == <<>>
    end

    test "16-bit service-data element (type 0x16, e.g. BTHome 0xFCD2)" do
      {:ok, %{raw_data: raw}} =
        Advert.reconstruct(%{
          "Address" => "11:22:33:44:55:66",
          "ServiceData" => %{"0000fcd2-0000-1000-8000-00805f9b34fb" => <<0x40, 0x01, 0x64>>}
        })

      assert raw == <<6, 0x16, 0xD2, 0xFC, 0x40, 0x01, 0x64>>
    end

    test "128-bit service-data element (type 0x21, little-endian UUID)" do
      uuid = "12345678-1234-5678-1234-567812345678"

      {:ok, %{raw_data: raw}} =
        Advert.reconstruct(%{
          "Address" => "11:22:33:44:55:66",
          "ServiceData" => %{uuid => <<0xAB>>}
        })

      # 16 UUID bytes (reversed to LE) + 1 data byte; len = 1 + 16 + 1 = 18
      le_uuid =
        <<0x78, 0x56, 0x34, 0x12, 0x78, 0x56, 0x34, 0x12, 0x78, 0x56, 0x34, 0x12, 0x78, 0x56,
          0x34, 0x12>>

      assert raw == <<18, 0x21>> <> le_uuid <> <<0xAB>>
    end

    test "16-bit ServiceUUIDs become a 0x03 element; 128-bit are excluded" do
      {:ok, %{raw_data: raw}} =
        Advert.reconstruct(%{
          "Address" => "11:22:33:44:55:66",
          "ServiceUUIDs" => [
            "0000fcd2-0000-1000-8000-00805f9b34fb",
            "0000180f-0000-1000-8000-00805f9b34fb",
            "12345678-1234-5678-1234-567812345678"
          ]
        })

      # <<len, 0x03, 0xD2 0xFC, 0x0F 0x18>> — two 16-bit UUIDs LE, 128-bit dropped
      assert raw == <<5, 0x03, 0xD2, 0xFC, 0x0F, 0x18>>
    end

    test "complete local name (0x09) and tx power (0x0A)" do
      {:ok, %{raw_data: raw}} =
        Advert.reconstruct(%{
          "Address" => "11:22:33:44:55:66",
          "Name" => "Govee",
          "TxPower" => -4
        })

      assert :binary.match(raw, <<6, 0x09, "Govee">>) != :nomatch
      assert :binary.match(raw, <<2, 0x0A, 0xFC>>) != :nomatch
    end

    test "empty name produces no 0x09 element" do
      {:ok, %{raw_data: raw}} =
        Advert.reconstruct(%{"Address" => "11:22:33:44:55:66", "Name" => ""})

      assert :binary.match(raw, <<0x09>>) == :nomatch
      assert raw == <<>>
    end

    test "tx power at signed-byte boundaries" do
      {:ok, %{raw_data: hi}} =
        Advert.reconstruct(%{"Address" => "11:22:33:44:55:66", "TxPower" => 127})

      {:ok, %{raw_data: lo}} =
        Advert.reconstruct(%{"Address" => "11:22:33:44:55:66", "TxPower" => -128})

      assert hi == <<2, 0x0A, 127>>
      assert lo == <<2, 0x0A, 0x80>>
    end
  end
end
