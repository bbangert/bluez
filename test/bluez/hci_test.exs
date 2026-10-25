defmodule Bluez.HciTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Bluez.Hci

  doctest Bluez.Hci

  # Address AA:BB:CC:DD:EE:FF as it travels over HCI (little-endian).
  @addr_le <<0xFF, 0xEE, 0xDD, 0xCC, 0xBB, 0xAA>>
  @adv_data <<2, 1, 6, 5, 3, 0x11, 0x22, 0x33, 0x44>>

  defp legacy_report(evt, addr_type, data, rssi),
    do: <<evt, addr_type, @addr_le::binary, byte_size(data), data::binary, rssi::signed>>

  defp le_meta(params), do: <<0x04, 0x3E, byte_size(params), params::binary>>

  describe "decode_raw/1 — legacy reports (0x02)" do
    test "decodes an ADV_NONCONN_IND verbatim" do
      packet = le_meta(<<0x02, 1>> <> legacy_report(3, 1, @adv_data, -60))

      assert [report] = Hci.decode_raw(packet)

      assert report == %{
               address: 0xAABBCCDDEEFF,
               address_type: 1,
               rssi: -60,
               event_type: 3,
               connectable: false,
               scannable: false,
               directed: false,
               scan_response: false,
               legacy: true,
               data: @adv_data,
               data_status: :complete,
               tx_power: nil
             }
    end

    test "decodes several reports in one event, in order" do
      params =
        <<0x02, 2>> <>
          legacy_report(0, 0, @adv_data, -40) <> legacy_report(4, 0, <<2, 9, ?x>>, -41)

      assert [%{connectable: true, rssi: -40}, %{scan_response: true, data: <<2, 9, ?x>>}] =
               Hci.decode_raw(le_meta(params))
    end

    test "drops a truncated event rather than returning partial reports" do
      params = <<0x02, 2>> <> legacy_report(0, 0, @adv_data, -40) <> <<0, 0>>
      assert Hci.decode_raw(le_meta(params)) == []
    end
  end

  describe "decode_raw/1 — extended reports (0x0D)" do
    defp ext_report(evt, data, opts \\ []) do
      tx = Keyword.get(opts, :tx_power, 127)

      <<evt::little-16, 1, @addr_le::binary, 1, 0, 0xFF, tx::signed, -70::signed, 0::16, 0, 0::48,
        byte_size(data), data::binary>>
    end

    test "decodes a legacy PDU seen through extended scanning" do
      # ADV_NONCONN_IND via ext scanning: legacy bit only.
      packet = le_meta(<<0x0D, 1>> <> ext_report(0x10, @adv_data))

      assert [
               %{
                 address: 0xAABBCCDDEEFF,
                 address_type: 1,
                 rssi: -70,
                 legacy: true,
                 connectable: false,
                 data: @adv_data,
                 data_status: :complete,
                 tx_power: nil
               }
             ] = Hci.decode_raw(packet)
    end

    test "reports data status and TX power" do
      packet = le_meta(<<0x0D, 1>> <> ext_report(0x01 ||| 1 <<< 5, <<1, 2>>, tx_power: -4))

      assert [%{connectable: true, legacy: false, data_status: :incomplete, tx_power: -4}] =
               Hci.decode_raw(packet)
    end
  end

  test "decode_raw/1 ignores everything that isn't an advertising report" do
    # Command Complete, an LE Connection Complete subevent, garbage.
    assert Hci.decode_raw(<<0x04, 0x0E, 4, 1, 0x03, 0x0C, 0>>) == []
    assert Hci.decode_raw(le_meta(<<0x01, 0::8*18>>)) == []
    assert Hci.decode_raw(<<0x02, 1, 2, 3>>) == []
    assert Hci.decode_raw(<<>>) == []
  end

  test "le_meta_filter/0 is a 16-byte hci_ufilter passing only LE Meta events" do
    filter = Hci.le_meta_filter()
    assert byte_size(filter) == 16

    <<type_mask::native-32, lo::native-32, hi::native-32, _opcode::native-16, _pad::16>> =
      filter

    assert type_mask == 1 <<< 0x04
    # Event 0x3E = word 1, bit 30.
    assert lo == 0
    assert hi == 1 <<< 30
  end

  test "sockaddr/2 packs dev and channel as host-endian unsigned shorts" do
    # struct sockaddr_hci's fields are native `unsigned short`, unlike the
    # little-endian fields inside HCI/MGMT packets.
    assert Hci.sockaddr(1, 3) == %{family: 31, addr: <<1::native-16, 3::native-16>>}
  end

  test "adv_hw_offload?/1 reads MGMT_ADV_FLAG_HW_OFFLOAD (bit 11)" do
    assert Hci.adv_hw_offload?(0x0800)
    assert Hci.adv_hw_offload?(0xFFFF)
    refute Hci.adv_hw_offload?(0x07FF)
  end

  test "adapter_index/1 rejects non-adapter paths" do
    assert Hci.adapter_index("/org/bluez/hci0") == {:ok, 0}
    assert Hci.adapter_index("/org/bluez/hci0/dev_AA") == :error
    assert Hci.adapter_index("/org/other") == :error
  end

  describe "MGMT" do
    test "mgmt_command/3 frames opcode, index and length" do
      assert Hci.mgmt_command(0x003F, 0, <<5>>) == <<0x3F, 0, 0, 0, 1, 0, 5>>
    end

    test "add_ext_adv_params/2 sets only the parameters given" do
      assert <<7, flags::little-32, 0::16, 0::16, 0::32, 0::32, 0>> = Hci.add_ext_adv_params(7)
      assert flags == 0

      params =
        Hci.add_ext_adv_params(7,
          flags: [:connectable],
          min_interval_ms: 20,
          max_interval_ms: 30,
          tx_power: -2,
          duration_s: 2,
          scan_response: true
        )

      assert <<7, flags::little-32, 2::little-16, 0::16, 32::little-32, 48::little-32,
               -2::signed>> = params

      # connectable | PARAM_DURATION | PARAM_INTERVALS | PARAM_TX_POWER | PARAM_SCAN_RSP
      assert flags == (1 ||| 1 <<< 12 ||| 1 <<< 14 ||| 1 <<< 15 ||| 1 <<< 16)
    end

    test "add_ext_adv_params/2 refuses out-of-range intervals and unknown flags" do
      assert_raise ArgumentError, fn ->
        Hci.add_ext_adv_params(1, min_interval_ms: 10, max_interval_ms: 30)
      end

      assert_raise ArgumentError, fn ->
        Hci.add_ext_adv_params(1, min_interval_ms: 40, max_interval_ms: 30)
      end

      assert_raise ArgumentError, fn -> Hci.add_ext_adv_params(1, flags: [:bogus]) end
    end

    test "add_ext_adv_params/2 refuses values its fixed-width fields would truncate" do
      for opts <- [
            [tx_power: 256],
            [tx_power: 21],
            [tx_power: -128],
            [duration_s: 65_536],
            [timeout_s: -1],
            [tx_power: :loud]
          ] do
        assert_raise ArgumentError, fn -> Hci.add_ext_adv_params(1, opts) end
      end

      assert <<1, _::binary>> = Hci.add_ext_adv_params(1, tx_power: 20, duration_s: 65_535)
    end

    test "add_ext_adv_data/3 carries adv data then scan response" do
      assert Hci.add_ext_adv_data(3, <<1, 2>>, <<9>>) == <<3, 2, 1, 1, 2, 9>>
    end

    test "decode_mgmt/1" do
      assert Hci.decode_mgmt(<<1, 0, 0, 0, 4, 0, 0x55, 0, 0, 3>>) ==
               {:ok, {:cmd_complete, 0, 0x55, :success, <<3>>}}

      assert Hci.decode_mgmt(<<2, 0, 1, 0, 3, 0, 0x54, 0, 0x0A>>) ==
               {:ok, {:cmd_status, 1, 0x54, :busy}}

      assert Hci.decode_mgmt(<<0x24, 0, 0, 0, 1, 0, 5>>) ==
               {:ok, {:advertising_removed, 0, 5}}

      assert Hci.decode_mgmt(<<0x12, 0, 0, 0, 1, 0, 5>>) == {:ok, {:other, 0x12, 0, <<5>>}}
      assert Hci.decode_mgmt(<<1, 0, 0>>) == :error
    end

    test "decode_adv_features/1" do
      assert Hci.decode_adv_features(<<0x7F::little-32, 31, 31, 5, 2, 1, 2>>) ==
               {:ok,
                %{
                  supported_flags: 0x7F,
                  max_adv_data_len: 31,
                  max_scan_rsp_len: 31,
                  max_instances: 5,
                  instances: [1, 2]
                }}
    end
  end
end
