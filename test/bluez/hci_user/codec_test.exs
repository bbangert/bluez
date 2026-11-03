defmodule Bluez.HciUser.CodecTest do
  use ExUnit.Case, async: true

  alias Bluez.HciUser.Codec

  doctest Bluez.HciUser.Codec

  describe "decode_event/1" do
    test "Command Status" do
      assert Codec.decode_event(<<0x04, 0x0F, 4, 0x0C, 1, 0x0D, 0x20>>) ==
               {:command_status, 0x0C, 1, 0x200D}
    end

    test "LE advertising reports go through Bluez.Hci's decoder" do
      params = <<0x02, 1, 3, 0, 1, 2, 3, 4, 5, 6, 0, -40::signed>>

      assert {:adv_reports, [%{address: 0x060504030201, rssi: -40}]} =
               Codec.decode_event(<<0x04, 0x3E, byte_size(params), params::binary>>)
    end

    test "a malformed report event yields no reports" do
      assert Codec.decode_event(<<0x04, 0x3E, 3, 0x02, 1, 3>>) == {:adv_reports, []}
    end

    test "data packets and truncated events are ignored" do
      assert Codec.decode_event(<<0x02, 0x40, 0x00, 1, 0, 0xAA>>) == :ignore
      assert Codec.decode_event(<<0x04, 0x0E, 9, 1>>) == :ignore
    end
  end

  describe "encoders" do
    test "advertising parameters carry every explicit option" do
      params =
        Codec.advertising_parameters(
          type: :adv_nonconn_ind,
          min_interval_ms: 100,
          max_interval_ms: 150,
          own_address_type: :random,
          peer_address_type: :random,
          peer_address: 0xAABBCCDDEEFF,
          channel_map: 0x01,
          filter_policy: 3
        )

      assert params ==
               <<160::little-16, 240::little-16, 0x03, 1, 1, 0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA,
                 0x01, 3>>
    end

    test "out-of-range or missing options raise" do
      for opts <- [
            [type: :adv_ind, min_interval_ms: 10, max_interval_ms: 30],
            [type: :adv_ind, min_interval_ms: 40, max_interval_ms: 30],
            [type: :bogus, min_interval_ms: 20, max_interval_ms: 30],
            [type: :adv_ind, min_interval_ms: 20, max_interval_ms: 30, channel_map: 0],
            [type: :adv_ind, min_interval_ms: 20, max_interval_ms: 30, peer_address: -1],
            [min_interval_ms: 20, max_interval_ms: 30]
          ] do
        assert_raise ArgumentError, fn -> Codec.advertising_parameters(opts) end
      end

      assert_raise ArgumentError, fn ->
        Codec.scan_parameters(type: :active, interval_ms: 20_000, window_ms: 30)
      end

      assert_raise ArgumentError, fn -> Codec.event_mask(Bitwise.bsl(1, 64)) end
    end

    test "active scanning with a random own address" do
      assert Codec.scan_parameters(
               type: :active,
               interval_ms: 100,
               window_ms: 50,
               own_address_type: :random,
               filter_policy: 1
             ) == <<1, 160::little-16, 80::little-16, 1, 1>>
    end
  end

  test "le_feature?/2 refuses unknown names" do
    assert_raise ArgumentError, fn -> Codec.le_feature?(0, :warp_drive) end
  end
end
