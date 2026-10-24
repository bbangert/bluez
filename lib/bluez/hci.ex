defmodule Bluez.Hci do
  @moduledoc """
  Kernel Bluetooth socket plumbing and pure codecs for the two
  `AF_BLUETOOTH`/`BTPROTO_HCI` channels this library talks to directly
  (everything else goes through `bluetoothd` over D-Bus):

    * **`HCI_CHANNEL_RAW`** — read-only sniffing of the controller's LE
      advertising reports, *verbatim* (`Bluez.AdvertReceiver`). BlueZ's
      D-Bus `Device1` properties dedupe and merge AD content across
      adverts, so protocols that carry data in the raw AD (e.g. an ordered
      16-bit UUID list) can only be received here.
    * **`HCI_CHANNEL_CONTROL`** — the kernel management (MGMT) API, for
      advertising instances whose data `LEAdvertisement1` refuses to carry
      (raw Flags, Local Name and 128-bit UUID lists in the advertising PDU
      itself) — `Bluez.Mgmt`.

  Sockets are opened with OTP's `:socket` using integer protocol constants
  and native `sockaddr`s — no NIF or port. Opening needs `CAP_NET_RAW`
  (raw channel) / `CAP_NET_ADMIN` (control channel); Nerves runs as root.

  The decoders are pure and host-testable; `open/2` is the only function
  touching the OS.
  """

  import Bitwise

  @af_bluetooth 31
  @btproto_hci 1
  @sol_hci 0
  @hci_filter 2

  @channel_raw 0
  @channel_control 3
  @dev_none 0xFFFF

  @hci_event_pkt 0x04
  @evt_le_meta 0x3E
  @le_adv_report 0x02
  @le_ext_adv_report 0x0D

  # MGMT events.
  @mgmt_ev_cmd_complete 0x0001
  @mgmt_ev_cmd_status 0x0002
  @mgmt_ev_index_removed 0x0005
  @mgmt_ev_adv_added 0x0023
  @mgmt_ev_adv_removed 0x0024

  # MGMT commands.
  @mgmt_op_read_adv_features 0x003D
  @mgmt_op_remove_advertising 0x003F
  @mgmt_op_add_ext_adv_params 0x0054
  @mgmt_op_add_ext_adv_data 0x0055

  # MGMT Add (Ext) Advertising flag bits (lib/bluetooth/mgmt.h).
  @adv_flags %{
    connectable: 1 <<< 0,
    discoverable: 1 <<< 1,
    limited_discoverable: 1 <<< 2,
    managed_flags: 1 <<< 3,
    tx_power: 1 <<< 4,
    appearance: 1 <<< 5,
    local_name: 1 <<< 6,
    secondary_1m: 1 <<< 7,
    secondary_2m: 1 <<< 8,
    secondary_coded: 1 <<< 9
  }
  @adv_param_duration 1 <<< 12
  @adv_param_timeout 1 <<< 13
  @adv_param_intervals 1 <<< 14
  @adv_param_tx_power 1 <<< 15
  @adv_param_scan_rsp 1 <<< 16

  @mgmt_statuses %{
    0x00 => :success,
    0x01 => :unknown_command,
    0x02 => :not_connected,
    0x03 => :failed,
    0x04 => :connect_failed,
    0x05 => :auth_failed,
    0x06 => :not_paired,
    0x07 => :no_resources,
    0x08 => :timeout,
    0x09 => :already_connected,
    0x0A => :busy,
    0x0B => :rejected,
    0x0C => :not_supported,
    0x0D => :invalid_params,
    0x0E => :disconnected,
    0x0F => :not_powered,
    0x10 => :cancelled,
    0x11 => :invalid_index,
    0x12 => :rfkilled,
    0x13 => :already_paired,
    0x14 => :permission_denied
  }

  @typedoc "Which HCI socket channel to open."
  @type channel :: :raw | :control

  @typedoc """
  One LE advertising report, normalized across the legacy (`0x02`) and
  extended (`0x0D`) LE Meta subevents.

    * `address` — the 48-bit address packed MSB-first (`0xAABBCCDDEEFF`),
      the same packing as `Bluez.Advert`.
    * `address_type` — raw HCI value: `0` public, `1` random, `2`/`3`
      public/random identity (resolved RPA), `0xFF` anonymous.
    * `connectable` / `scannable` / `directed` / `scan_response` — PDU
      properties (derived from the legacy event type, or the extended
      event-type bits).
    * `legacy` — whether the PDU was a legacy one (always `true` for
      `0x02` reports).
    * `data` — the AD bytes exactly as received (see `Bluez.AdData`).
    * `data_status` — `:complete`, `:incomplete` (more fragments follow)
      or `:truncated`; legacy reports are always `:complete`.
    * `tx_power` — dBm, or `nil` when not reported.
  """
  @type adv_report :: %{
          address: non_neg_integer(),
          address_type: byte(),
          rssi: integer(),
          event_type: non_neg_integer(),
          connectable: boolean(),
          scannable: boolean(),
          directed: boolean(),
          scan_response: boolean(),
          legacy: boolean(),
          data: binary(),
          data_status: :complete | :incomplete | :truncated,
          tx_power: integer() | nil
        }

  @typedoc "A decoded MGMT event (`decode_mgmt/1`)."
  @type mgmt_event ::
          {:cmd_complete, index :: non_neg_integer(), opcode :: non_neg_integer(),
           status :: atom(), params :: binary()}
          | {:cmd_status, non_neg_integer(), non_neg_integer(), atom()}
          | {:advertising_added, non_neg_integer(), byte()}
          | {:advertising_removed, non_neg_integer(), byte()}
          | {:index_removed, non_neg_integer()}
          | {:other, code :: non_neg_integer(), non_neg_integer(), binary()}

  # ── sockets ───────────────────────────────────────────────────────────────

  @doc """
  Open and bind an HCI socket.

    * `open(:raw, index)` — `HCI_CHANNEL_RAW` bound to controller `index`
      with a filter passing only LE Meta events (the advertising reports).
    * `open(:control, _)` — `HCI_CHANNEL_CONTROL` (MGMT), bound to no
      controller (commands carry their own index).

  Returns `{:ok, socket}` or `{:error, reason}` (`:eafnosupport` on a
  kernel without Bluetooth, `:eperm`/`:eacces` without the capability).
  """
  @spec open(channel(), non_neg_integer()) :: {:ok, :socket.socket()} | {:error, term()}
  def open(channel, index \\ 0) do
    with {:ok, sock} <- :socket.open(@af_bluetooth, :raw, @btproto_hci) do
      case setup(sock, channel, index) do
        :ok ->
          {:ok, sock}

        {:error, _reason} = error ->
          :socket.close(sock)
          error
      end
    end
  end

  defp setup(sock, :raw, index) do
    with :ok <- :socket.setopt_native(sock, {@sol_hci, @hci_filter}, le_meta_filter()) do
      :socket.bind(sock, sockaddr(index, @channel_raw))
    end
  end

  defp setup(sock, :control, _index),
    do: :socket.bind(sock, sockaddr(@dev_none, @channel_control))

  @doc """
  Native `struct sockaddr_hci` for `:socket.bind/2`: family, then device
  index and channel, both little-endian `u16`.
  """
  @spec sockaddr(non_neg_integer(), non_neg_integer()) :: :socket.sockaddr_native()
  def sockaddr(index, channel),
    do: %{family: @af_bluetooth, addr: <<index::little-16, channel::little-16>>}

  @doc """
  Native `struct hci_ufilter` (16 bytes incl. tail padding) passing only
  HCI event packets with event code LE Meta (`0x3E`).
  """
  @spec le_meta_filter() :: binary()
  def le_meta_filter do
    type_mask = 1 <<< @hci_event_pkt
    event_mask = 1 <<< @evt_le_meta
    lo = event_mask &&& 0xFFFFFFFF
    hi = event_mask >>> 32

    <<type_mask::native-32, lo::native-32, hi::native-32, 0::native-16, 0::16>>
  end

  @doc """
  Controller index from a BlueZ adapter object path.

      iex> Bluez.Hci.adapter_index("/org/bluez/hci1")
      {:ok, 1}
  """
  @spec adapter_index(String.t()) :: {:ok, non_neg_integer()} | :error
  def adapter_index("/org/bluez/hci" <> digits) do
    case Integer.parse(digits) do
      {index, ""} when index >= 0 -> {:ok, index}
      _ -> :error
    end
  end

  def adapter_index(_path), do: :error

  # ── HCI raw channel: LE advertising reports ───────────────────────────────

  @doc """
  Decode one packet read from an `HCI_CHANNEL_RAW` socket (packet-type
  byte first) into its LE advertising reports. Anything else — other
  events, other LE subevents, malformed reports — yields `[]`.
  """
  @spec decode_raw(binary()) :: [adv_report()]
  def decode_raw(<<@hci_event_pkt, @evt_le_meta, len, params::binary-size(len), _::binary>>),
    do: decode_le_meta(params)

  def decode_raw(_other), do: []

  @doc """
  Decode an LE Meta event's parameters (subevent code first). Legacy and
  extended advertising reports are supported; a malformed report drops
  the whole event rather than returning partial garbage.
  """
  @spec decode_le_meta(binary()) :: [adv_report()]
  def decode_le_meta(<<@le_adv_report, count, rest::binary>>),
    do: decode_reports(rest, count, &legacy_report/1)

  def decode_le_meta(<<@le_ext_adv_report, count, rest::binary>>),
    do: decode_reports(rest, count, &ext_report/1)

  def decode_le_meta(_other), do: []

  defp decode_reports(bin, count, fun), do: decode_reports(bin, count, fun, [])

  defp decode_reports(_bin, 0, _fun, acc), do: Enum.reverse(acc)

  defp decode_reports(bin, count, fun, acc) do
    case fun.(bin) do
      {:ok, report, rest} -> decode_reports(rest, count - 1, fun, [report | acc])
      :error -> []
    end
  end

  # Kernel/BlueZ (and every controller in practice) lay reports out one
  # after another, RSSI trailing the data — see hci_ev_le_advertising_info.
  defp legacy_report(
         <<evt, addr_type, addr::binary-size(6), len, data::binary-size(len), rssi::signed,
           rest::binary>>
       ) do
    {connectable, scannable, directed, scan_rsp} = legacy_properties(evt)

    {:ok,
     %{
       address: address(addr),
       address_type: addr_type,
       rssi: rssi,
       event_type: evt,
       connectable: connectable,
       scannable: scannable,
       directed: directed,
       scan_response: scan_rsp,
       legacy: true,
       data: data,
       data_status: :complete,
       tx_power: nil
     }, rest}
  end

  defp legacy_report(_bin), do: :error

  # ADV_IND, ADV_DIRECT_IND, ADV_SCAN_IND, ADV_NONCONN_IND, SCAN_RSP.
  defp legacy_properties(0), do: {true, true, false, false}
  defp legacy_properties(1), do: {true, false, true, false}
  defp legacy_properties(2), do: {false, true, false, false}
  defp legacy_properties(3), do: {false, false, false, false}
  defp legacy_properties(4), do: {false, true, false, true}
  defp legacy_properties(_), do: {false, false, false, false}

  defp ext_report(
         <<evt::little-16, addr_type, addr::binary-size(6), _primary_phy, _secondary_phy, _sid,
           tx_power::signed, rssi::signed, _interval::little-16, _direct_type,
           _direct_addr::binary-size(6), len, data::binary-size(len), rest::binary>>
       ) do
    {:ok,
     %{
       address: address(addr),
       address_type: addr_type,
       rssi: rssi,
       event_type: evt,
       connectable: (evt &&& 0x01) != 0,
       scannable: (evt &&& 0x02) != 0,
       directed: (evt &&& 0x04) != 0,
       scan_response: (evt &&& 0x08) != 0,
       legacy: (evt &&& 0x10) != 0,
       data: data,
       data_status: data_status(evt >>> 5 &&& 0x03),
       # 127 = "not available".
       tx_power: if(tx_power == 127, do: nil, else: tx_power)
     }, rest}
  end

  defp ext_report(_bin), do: :error

  defp data_status(0), do: :complete
  defp data_status(1), do: :incomplete
  defp data_status(_), do: :truncated

  # On-air/HCI addresses are little-endian; pack MSB-first.
  defp address(<<addr::little-48>>), do: addr

  # ── MGMT (control channel) ────────────────────────────────────────────────

  @doc "MGMT index meaning \"no controller\" (`MGMT_INDEX_NONE`)."
  @spec index_none() :: 0xFFFF
  def index_none, do: @dev_none

  @doc """
  Frame a MGMT command: opcode, controller index, parameter length (all
  little-endian `u16`), then the parameters.
  """
  @spec mgmt_command(non_neg_integer(), non_neg_integer(), binary()) :: binary()
  def mgmt_command(opcode, index, params \\ <<>>),
    do: <<opcode::little-16, index::little-16, byte_size(params)::little-16, params::binary>>

  @doc "Opcode of MGMT Read Advertising Features (no parameters)."
  @spec op_read_adv_features() :: non_neg_integer()
  def op_read_adv_features, do: @mgmt_op_read_adv_features

  @doc "Opcode of MGMT Remove Advertising (`<<instance>>`; 0 = all instances)."
  @spec op_remove_advertising() :: non_neg_integer()
  def op_remove_advertising, do: @mgmt_op_remove_advertising

  @doc "Opcode of MGMT Add Extended Advertising Parameters."
  @spec op_add_ext_adv_params() :: non_neg_integer()
  def op_add_ext_adv_params, do: @mgmt_op_add_ext_adv_params

  @doc "Opcode of MGMT Add Extended Advertising Data."
  @spec op_add_ext_adv_data() :: non_neg_integer()
  def op_add_ext_adv_data, do: @mgmt_op_add_ext_adv_data

  @doc "The advertising flag names `adv_flags/1` accepts."
  @spec adv_flag_names() :: [atom()]
  def adv_flag_names, do: Map.keys(@adv_flags)

  @doc """
  Fold flag names into the MGMT advertising flags bitmask. Raises
  `ArgumentError` on an unknown name.

      iex> Bluez.Hci.adv_flags([:connectable, :secondary_1m])
      0x81
  """
  @spec adv_flags([atom()]) :: non_neg_integer()
  def adv_flags(names) when is_list(names) do
    Enum.reduce(names, 0, fn name, acc ->
      case Map.fetch(@adv_flags, name) do
        {:ok, bit} -> acc ||| bit
        :error -> raise ArgumentError, "unknown advertising flag #{inspect(name)}"
      end
    end)
  end

  @doc """
  Parameters of MGMT Add Extended Advertising Parameters (`0x0054`).

  Options (all optional; an omitted one leaves the kernel default):

    * `:flags` — list of `adv_flag_names/0` (default `[]`: non-connectable,
      no kernel-managed Flags/name/appearance/TX power elements).
    * `:min_interval_ms` / `:max_interval_ms` — advertising interval range;
      both or neither (20 ms minimum). The kernel default is 1.28 s, far
      too slow for short bursts.
    * `:tx_power` — requested dBm (`-127..20`).
    * `:duration_s` / `:timeout_s` — the kernel's own whole-second
      rotation duration and lifetime.
    * `:scan_response` — `true` to make the instance scannable.
  """
  @spec add_ext_adv_params(byte(), keyword()) :: binary()
  def add_ext_adv_params(instance, opts \\ []) when instance in 1..254 do
    flags = adv_flags(Keyword.get(opts, :flags, []))

    {duration, flags} = optional_param(opts, :duration_s, 0..0xFFFF, flags, @adv_param_duration)
    {timeout, flags} = optional_param(opts, :timeout_s, 0..0xFFFF, flags, @adv_param_timeout)
    {tx_power, flags} = optional_param(opts, :tx_power, -127..20, flags, @adv_param_tx_power)

    {min_i, max_i, flags} =
      case {opts[:min_interval_ms], opts[:max_interval_ms]} do
        {nil, nil} -> {0, 0, flags}
        {min, max} -> intervals(min, max, flags)
      end

    flags = if opts[:scan_response], do: flags ||| @adv_param_scan_rsp, else: flags

    <<instance, flags::little-32, duration::little-16, timeout::little-16, min_i::little-32,
      max_i::little-32, tx_power::signed>>
  end

  # Range-checked: the fixed-width fields would otherwise silently truncate
  # an out-of-range value into a different setting.
  defp optional_param(opts, key, range, flags, bit) do
    case opts[key] do
      nil ->
        {0, flags}

      value when is_integer(value) ->
        if value in range,
          do: {value, flags ||| bit},
          else: raise(ArgumentError, "#{key} #{value} outside #{inspect(range)}")

      other ->
        raise ArgumentError, "#{key} must be an integer, got #{inspect(other)}"
    end
  end

  # Interval units are 0.625 ms; the HCI range is 0x20..0xFFFFFF.
  defp intervals(min_ms, max_ms, flags)
       when is_number(min_ms) and is_number(max_ms) and min_ms <= max_ms do
    min = round(min_ms / 0.625)
    max = round(max_ms / 0.625)

    unless min >= 0x20 and max <= 0xFFFFFF,
      do: raise(ArgumentError, "advertising interval out of range (20 ms .. 10485 s)")

    {min, max, flags ||| @adv_param_intervals}
  end

  defp intervals(min_ms, max_ms, _flags),
    do: raise(ArgumentError, "invalid interval range #{inspect({min_ms, max_ms})}")

  @doc """
  Parameters of MGMT Add Extended Advertising Data (`0x0055`): the raw AD
  bytes for the advertising PDU and (optionally) the scan response.
  """
  @spec add_ext_adv_data(byte(), binary(), binary()) :: binary()
  def add_ext_adv_data(instance, adv_data, scan_rsp \\ <<>>)
      when instance in 1..254 and byte_size(adv_data) <= 255 and byte_size(scan_rsp) <= 255,
      do:
        <<instance, byte_size(adv_data), byte_size(scan_rsp), adv_data::binary, scan_rsp::binary>>

  @doc """
  Decode one MGMT event read from the control socket. Unrecognized event
  codes are returned as `{:other, code, index, params}`; `:error` only for
  a frame too short for its own header.
  """
  @spec decode_mgmt(binary()) :: {:ok, mgmt_event()} | :error
  def decode_mgmt(
        <<code::little-16, index::little-16, len::little-16, params::binary-size(len)>>
      ),
      do: {:ok, mgmt_event(code, index, params)}

  def decode_mgmt(_bin), do: :error

  defp mgmt_event(@mgmt_ev_cmd_complete, index, <<opcode::little-16, status, rest::binary>>),
    do: {:cmd_complete, index, opcode, mgmt_status(status), rest}

  defp mgmt_event(@mgmt_ev_cmd_status, index, <<opcode::little-16, status, _::binary>>),
    do: {:cmd_status, index, opcode, mgmt_status(status)}

  defp mgmt_event(@mgmt_ev_adv_added, index, <<instance, _::binary>>),
    do: {:advertising_added, index, instance}

  defp mgmt_event(@mgmt_ev_adv_removed, index, <<instance, _::binary>>),
    do: {:advertising_removed, index, instance}

  defp mgmt_event(@mgmt_ev_index_removed, index, _params), do: {:index_removed, index}
  defp mgmt_event(code, index, params), do: {:other, code, index, params}

  @doc """
  Name a MGMT status byte (`:success`, `:busy`, `:invalid_params`, …), or
  `{:unknown_status, byte}`.
  """
  @spec mgmt_status(byte()) :: atom() | {:unknown_status, byte()}
  def mgmt_status(status), do: Map.get(@mgmt_statuses, status, {:unknown_status, status})

  @doc """
  Decode the return parameters of Read Advertising Features.
  """
  @spec decode_adv_features(binary()) ::
          {:ok,
           %{
             supported_flags: non_neg_integer(),
             max_adv_data_len: byte(),
             max_scan_rsp_len: byte(),
             max_instances: byte(),
             instances: [byte()]
           }}
          | :error
  def decode_adv_features(
        <<supported::little-32, max_adv, max_rsp, max_instances, num, instances::binary-size(num),
          _::binary>>
      ) do
    {:ok,
     %{
       supported_flags: supported,
       max_adv_data_len: max_adv,
       max_scan_rsp_len: max_rsp,
       max_instances: max_instances,
       instances: :binary.bin_to_list(instances)
     }}
  end

  def decode_adv_features(_bin), do: :error
end
