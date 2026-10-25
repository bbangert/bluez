defmodule Bluez.AdDataTest do
  use ExUnit.Case, async: true

  alias Bluez.AdData

  doctest Bluez.AdData

  describe "decode/1" do
    test "keeps element order and duplicates" do
      data = <<2, 1, 6, 3, 3, 0xAA, 0xBB, 3, 3, 0xAA, 0xBB, 2, 0x99, 0>>

      assert AdData.decode(data) ==
               {:ok, [{1, <<6>>}, {3, <<0xAA, 0xBB>>}, {3, <<0xAA, 0xBB>>}, {0x99, <<0>>}]}
    end

    test "stops at zero padding" do
      assert AdData.decode(<<2, 1, 6, 0, 0, 0, 0>>) == {:ok, [{1, <<6>>}]}
    end

    test "rejects a length running past the buffer" do
      assert AdData.decode(<<5, 3, 1, 2>>) == {:error, :malformed}
      assert AdData.decode(<<2>>) == {:error, :malformed}
    end

    test "round-trips through encode/1" do
      elements = [AdData.flags(0x06), AdData.local_name("abc"), {0xFF, <<0xD0, 0x07, 1>>}]
      assert elements |> AdData.encode() |> AdData.decode() == {:ok, elements}
    end
  end

  describe "encode/1" do
    test "rejects oversized payloads and bad types" do
      assert_raise ArgumentError, fn -> AdData.encode([{1, :binary.copy(<<0>>, 255)}]) end
      assert_raise ArgumentError, fn -> AdData.encode([{256, <<>>}]) end
    end
  end

  describe "16-bit UUID list payloads" do
    # A 26-byte opaque payload, as protocols like Tuya Beacon P2 carry it:
    # 13 "UUIDs", repeated values allowed, order significant.
    @payload <<0x12, 0x34, 0x12, 0x34>> <> :binary.copy(<<0xFE, 0x01>>, 11)

    test "uuid16_strings/1 encodes so that BlueZ's little-endian serialization is verbatim" do
      strings = AdData.uuid16_strings(@payload)
      assert length(strings) == 13
      assert Enum.at(strings, 0) == Enum.at(strings, 1)

      # What bluetoothd does with each base-UUID string: fold to 16 bits,
      # write little-endian, in list order.
      on_air =
        for "0000" <> <<hex::binary-size(4)>> <> "-0000-1000-8000-00805f9b34fb" <- strings,
            into: <<>>,
            do: <<String.to_integer(hex, 16)::little-16>>

      assert on_air == @payload
    end

    test "uuid16_list_payload/1 extracts the list from a received advert" do
      data = AdData.encode([AdData.flags(0x06), AdData.uuid16_list(@payload)])
      assert AdData.uuid16_list_payload(data) == @payload
    end

    test "uuid16_list_payload/1 falls back to the incomplete list, nil when absent" do
      assert AdData.uuid16_list_payload(<<3, 2, 1, 2>>) == <<1, 2>>
      assert AdData.uuid16_list_payload(<<2, 1, 6>>) == nil
      assert AdData.uuid16_list_payload(<<9, 9>>) == nil
    end
  end

  test "element builders" do
    assert AdData.manufacturer_data(0x07D0, <<1, 2>>) == {0xFF, <<0xD0, 0x07, 1, 2>>}
    assert AdData.local_name("ab", shortened: true) == {0x08, "ab"}
    assert AdData.uuid128_list([<<1::128>>, <<2::128>>]) == {0x07, <<1::128, 2::128>>}
  end
end
