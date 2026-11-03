defmodule Bluez.HciUser.Codec do
  @moduledoc """
  Pure codecs for the H4 packets `Bluez.HciUser` exchanges with a
  controller over `HCI_CHANNEL_USER`: command framing, the parameter
  encoders of the commands it wraps, their return-parameter decoders, and
  event decoding.

  Multi-byte fields are little-endian, as everywhere in HCI. Addresses are
  integers packed MSB-first (`0xAABBCCDDEEFF`), like `Bluez.Hci`'s. The
  encoders raise `ArgumentError` on out-of-range input instead of letting
  a fixed-width field silently truncate it into another setting.
  """

  import Bitwise

  alias Bluez.Hci

  @h4_command 0x01
  @h4_event 0x04

  @evt_command_complete 0x0E
  @evt_command_status 0x0F
  @evt_hardware_error 0x10
  @evt_le_meta 0x3E
  @le_adv_report 0x02
  @le_ext_adv_report 0x0D

  @opcodes %{
    set_event_mask: 0x0C01,
    reset: 0x0C03,
    read_local_version: 0x1001,
    read_bd_addr: 0x1009,
    le_set_event_mask: 0x2001,
    le_read_local_supported_features: 0x2003,
    le_set_advertising_parameters: 0x2006,
    le_set_advertising_data: 0x2008,
    le_set_advertising_enable: 0x200A,
    le_set_scan_parameters: 0x200B,
    le_set_scan_enable: 0x200C,
    le_read_num_supported_adv_sets: 0x203B
  }

  # Core spec Vol 6 Part B 4.6 (bit => name).
  @le_features [
    encryption: 0,
    conn_param_request: 1,
    extended_reject: 2,
    peripheral_features_exchange: 3,
    ping: 4,
    data_length_extension: 5,
    ll_privacy: 6,
    extended_scanner_filter_policies: 7,
    phy_2m: 8,
    stable_modulation_tx: 9,
    stable_modulation_rx: 10,
    phy_coded: 11,
    extended_advertising: 12,
    periodic_advertising: 13,
    channel_selection_2: 14,
    power_class_1: 15,
    min_used_channels: 16
  ]

  @own_address_types %{public: 0, random: 1, rpa_or_public: 2, rpa_or_random: 3}
  @peer_address_types %{public: 0, random: 1}
  @adv_types %{
    adv_ind: 0x00,
    adv_direct_ind_high: 0x01,
    adv_scan_ind: 0x02,
    adv_nonconn_ind: 0x03,
    adv_direct_ind_low: 0x04
  }
  @scan_types %{passive: 0x00, active: 0x01}

  @typedoc "Name of a command this module encodes (see `opcode/1`)."
  @type command ::
          :set_event_mask
          | :reset
          | :read_local_version
          | :read_bd_addr
          | :le_set_event_mask
          | :le_read_local_supported_features
          | :le_set_advertising_parameters
          | :le_set_advertising_data
          | :le_set_advertising_enable
          | :le_set_scan_parameters
          | :le_set_scan_enable
          | :le_read_num_supported_adv_sets

  @typedoc """
  A decoded HCI event packet (`decode_event/1`).

    * `{:command_complete, ncmd, opcode, return_params}` — the return
      parameters as sent, Status byte first.
    * `{:command_status, status, ncmd, opcode}`.
    * `{:hardware_error, code}`.
    * `{:adv_reports, reports}` — an LE legacy (`0x02`) or extended (`0x0D`)
      advertising report event; `[]` when malformed.
    * `{:event, code, params}` — any other event, LE Meta subevents
      included (subevent code first in `params`).
  """
  @type event ::
          {:command_complete, non_neg_integer(), non_neg_integer(), binary()}
          | {:command_status, byte(), non_neg_integer(), non_neg_integer()}
          | {:hardware_error, byte()}
          | {:adv_reports, [Hci.adv_report()]}
          | {:event, byte(), binary()}

  @typedoc "Read Local Version Information return parameters."
  @type local_version :: %{
          hci_version: byte(),
          hci_revision: non_neg_integer(),
          lmp_version: byte(),
          manufacturer: non_neg_integer(),
          lmp_subversion: non_neg_integer()
        }

  # ── framing ───────────────────────────────────────────────────────────────

  @doc """
  The opcode of a named command.

      iex> Bluez.HciUser.Codec.opcode(:reset)
      0x0C03
  """
  @spec opcode(command()) :: non_neg_integer()
  def opcode(name), do: Map.fetch!(@opcodes, name)

  @doc """
  Frame an H4 command packet: type `0x01`, opcode, parameter length, then
  the parameters.

      iex> Bluez.HciUser.Codec.command_packet(0x200C, <<1, 0>>)
      <<0x01, 0x0C, 0x20, 2, 1, 0>>
  """
  @spec command_packet(non_neg_integer(), binary()) :: binary()
  def command_packet(opcode, params \\ <<>>)
      when opcode in 0..0xFFFF and byte_size(params) <= 255,
      do: <<@h4_command, opcode::little-16, byte_size(params), params::binary>>

  @doc """
  Decode one packet read from a user-channel socket. Returns `:ignore` for
  non-event packets (ACL, SCO, ISO) and for events too short for their
  own header.

      iex> Bluez.HciUser.Codec.decode_event(<<0x04, 0x0E, 4, 1, 0x03, 0x0C, 0>>)
      {:command_complete, 1, 0x0C03, <<0>>}

      iex> Bluez.HciUser.Codec.decode_event(<<0x04, 0x10, 1, 0x42>>)
      {:hardware_error, 0x42}
  """
  @spec decode_event(binary()) :: event() | :ignore
  def decode_event(<<@h4_event, code, len, params::binary-size(len), _::binary>>),
    do: event(code, params)

  def decode_event(_packet), do: :ignore

  defp event(@evt_command_complete, <<ncmd, opcode::little-16, rp::binary>>),
    do: {:command_complete, ncmd, opcode, rp}

  defp event(@evt_command_status, <<status, ncmd, opcode::little-16, _::binary>>),
    do: {:command_status, status, ncmd, opcode}

  defp event(@evt_hardware_error, <<code, _::binary>>), do: {:hardware_error, code}

  defp event(@evt_le_meta, <<sub, _::binary>> = params)
       when sub in [@le_adv_report, @le_ext_adv_report],
       do: {:adv_reports, Hci.decode_le_meta(params)}

  defp event(code, params), do: {:event, code, params}

  # ── parameter encoders ────────────────────────────────────────────────────

  @doc """
  Set Event Mask / LE Set Event Mask parameters: the 64-bit mask,
  little-endian.

      iex> Bluez.HciUser.Codec.event_mask(0x20001FFFFFFFFFFF)
      <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x1F, 0x00, 0x20>>
  """
  @spec event_mask(non_neg_integer()) :: binary()
  def event_mask(mask) when is_integer(mask) and mask in 0..0xFFFFFFFFFFFFFFFF,
    do: <<mask::little-64>>

  def event_mask(mask), do: raise(ArgumentError, "event mask #{inspect(mask)} is not a u64")

  @doc """
  LE Set Scan Parameters parameters. Options:

    * `:type` (required) — `:passive` or `:active`.
    * `:interval_ms`, `:window_ms` (required) — 2.5 ms to 10.24 s in
      0.625 ms steps (rounded), window ≤ interval.
    * `:own_address_type` — `:public` (default), `:random`,
      `:rpa_or_public` or `:rpa_or_random`.
    * `:filter_policy` — raw scanning filter policy, default `0` (accept
      every advertisement not directed at another device).

  ```
  iex> Bluez.HciUser.Codec.scan_parameters(type: :passive, interval_ms: 30, window_ms: 30)
  <<0x00, 0x30, 0x00, 0x30, 0x00, 0x00, 0x00>>
  ```
  """
  @spec scan_parameters(keyword()) :: binary()
  def scan_parameters(opts) do
    type = lookup!(@scan_types, :type, fetch!(opts, :type))
    interval = units!(fetch!(opts, :interval_ms), :interval_ms, 0x0004..0x4000)
    window = units!(fetch!(opts, :window_ms), :window_ms, 0x0004..0x4000)

    if window > interval, do: raise(ArgumentError, "window_ms exceeds interval_ms")

    own =
      lookup!(
        @own_address_types,
        :own_address_type,
        Keyword.get(opts, :own_address_type, :public)
      )

    policy = byte!(Keyword.get(opts, :filter_policy, 0), :filter_policy, 0..3)

    <<type, interval::little-16, window::little-16, own, policy>>
  end

  @doc """
  LE Set Scan Enable parameters.

      iex> Bluez.HciUser.Codec.scan_enable(true, false)
      <<1, 0>>
  """
  @spec scan_enable(boolean(), boolean()) :: binary()
  def scan_enable(enable, filter_duplicates)
      when is_boolean(enable) and is_boolean(filter_duplicates),
      do: <<bool(enable), bool(filter_duplicates)>>

  @doc """
  LE Set Advertising Parameters parameters (legacy advertising). Options:

    * `:type` (required) — `:adv_ind`, `:adv_direct_ind_high`,
      `:adv_scan_ind`, `:adv_nonconn_ind` or `:adv_direct_ind_low`.
    * `:min_interval_ms`, `:max_interval_ms` (required) — 20 ms to
      10.24 s in 0.625 ms steps (rounded), min ≤ max.
    * `:own_address_type` — `:public` (default), `:random`,
      `:rpa_or_public` or `:rpa_or_random`.
    * `:peer_address_type` — `:public` (default) or `:random`; and
      `:peer_address` (default `0`) — only meaningful for directed
      advertising and the RPA own-address types.
    * `:channel_map` — bits 0–2 for channels 37/38/39, default `0x07`
      (all three).
    * `:filter_policy` — raw advertising filter policy, default `0` (scan
      and connect requests from anyone).

  ```
  iex> Bluez.HciUser.Codec.advertising_parameters(
  ...>   type: :adv_ind,
  ...>   min_interval_ms: 20,
  ...>   max_interval_ms: 30
  ...> )
  <<0x20, 0x00, 0x30, 0x00, 0x00, 0x00, 0x00, 0::48, 0x07, 0x00>>
  ```
  """
  @spec advertising_parameters(keyword()) :: binary()
  def advertising_parameters(opts) do
    type = lookup!(@adv_types, :type, fetch!(opts, :type))
    min = units!(fetch!(opts, :min_interval_ms), :min_interval_ms, 0x0020..0x4000)
    max = units!(fetch!(opts, :max_interval_ms), :max_interval_ms, 0x0020..0x4000)

    if min > max, do: raise(ArgumentError, "min_interval_ms exceeds max_interval_ms")

    own =
      lookup!(
        @own_address_types,
        :own_address_type,
        Keyword.get(opts, :own_address_type, :public)
      )

    peer_type =
      lookup!(
        @peer_address_types,
        :peer_address_type,
        Keyword.get(opts, :peer_address_type, :public)
      )

    peer = Keyword.get(opts, :peer_address, 0)

    unless is_integer(peer) and peer in 0..0xFFFFFFFFFFFF,
      do: raise(ArgumentError, "peer_address #{inspect(peer)} is not a 48-bit address")

    channels = byte!(Keyword.get(opts, :channel_map, 0x07), :channel_map, 0x01..0x07)
    policy = byte!(Keyword.get(opts, :filter_policy, 0), :filter_policy, 0..3)

    <<min::little-16, max::little-16, type, own, peer_type, peer::little-48, channels, policy>>
  end

  @doc """
  LE Set Advertising Data parameters: the length, then the AD bytes
  zero-padded to 31. Raises when `data` exceeds 31 bytes.

      iex> Bluez.HciUser.Codec.advertising_data(<<2, 1, 6>>)
      <<3, 2, 1, 6>> <> :binary.copy(<<0>>, 28)
  """
  @spec advertising_data(binary()) :: binary()
  def advertising_data(data) when is_binary(data) and byte_size(data) <= 31,
    do: <<byte_size(data), data::binary, 0::size((31 - byte_size(data)) * 8)>>

  def advertising_data(data) when is_binary(data),
    do: raise(ArgumentError, "advertising data is #{byte_size(data)} bytes (max 31)")

  @doc """
  LE Set Advertising Enable parameters.

      iex> Bluez.HciUser.Codec.advertising_enable(false)
      <<0>>
  """
  @spec advertising_enable(boolean()) :: binary()
  def advertising_enable(enable) when is_boolean(enable), do: <<bool(enable)>>

  defp bool(true), do: 1
  defp bool(false), do: 0

  defp fetch!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "missing required option #{inspect(key)}"
    end
  end

  defp lookup!(map, key, value) do
    case Map.fetch(map, value) do
      {:ok, byte} ->
        byte

      :error ->
        raise ArgumentError,
              "#{key} must be one of #{inspect(Map.keys(map))}, got #{inspect(value)}"
    end
  end

  defp byte!(value, key, range) do
    if is_integer(value) and value in range,
      do: value,
      else: raise(ArgumentError, "#{key} #{inspect(value)} outside #{inspect(range)}")
  end

  # Time in ms → 0.625 ms units, range-checked in units.
  defp units!(ms, key, range) when is_number(ms) do
    units = round(ms / 0.625)

    if units in range,
      do: units,
      else: raise(ArgumentError, "#{key} #{ms} out of range")
  end

  defp units!(ms, key, _range),
    do: raise(ArgumentError, "#{key} must be a number, got #{inspect(ms)}")

  # ── return-parameter decoders (Status byte already stripped) ──────────────

  @doc """
  Read BD_ADDR return parameters → the controller's public address.

      iex> Bluez.HciUser.Codec.decode_bd_addr(<<0x44, 0x3B, 0x1B, 0xB3, 0xFB, 0xB8>>)
      {:ok, 0xB8FBB31B3B44}
  """
  @spec decode_bd_addr(binary()) :: {:ok, non_neg_integer()} | :error
  def decode_bd_addr(<<addr::little-48, _::binary>>), do: {:ok, addr}
  def decode_bd_addr(_rp), do: :error

  @doc """
  Read Local Version Information return parameters.

      iex> Bluez.HciUser.Codec.decode_local_version(<<10, 0x0B, 0x00, 10, 93, 0, 0x22, 0xD9>>)
      {:ok, %{hci_version: 10, hci_revision: 0x0B, lmp_version: 10, manufacturer: 93, lmp_subversion: 0xD922}}
  """
  @spec decode_local_version(binary()) :: {:ok, local_version()} | :error
  def decode_local_version(
        <<hci_version, hci_revision::little-16, lmp_version, manufacturer::little-16,
          lmp_subversion::little-16, _::binary>>
      ) do
    {:ok,
     %{
       hci_version: hci_version,
       hci_revision: hci_revision,
       lmp_version: lmp_version,
       manufacturer: manufacturer,
       lmp_subversion: lmp_subversion
     }}
  end

  def decode_local_version(_rp), do: :error

  @doc """
  LE Read Local Supported Features return parameters → the 64-bit
  feature mask (see `le_features/1`).
  """
  @spec decode_le_features(binary()) :: {:ok, non_neg_integer()} | :error
  def decode_le_features(<<mask::little-64, _::binary>>), do: {:ok, mask}
  def decode_le_features(_rp), do: :error

  @doc "LE Read Number of Supported Advertising Sets return parameters."
  @spec decode_num_adv_sets(binary()) :: {:ok, byte()} | :error
  def decode_num_adv_sets(<<sets, _::binary>>), do: {:ok, sets}
  def decode_num_adv_sets(_rp), do: :error

  @doc """
  Name the LE features set in `mask` (bits 0–16 of the Core spec's LE
  feature table; higher bits are not named).

      iex> Bluez.HciUser.Codec.le_features(0x1121)
      [:encryption, :data_length_extension, :phy_2m, :extended_advertising]
  """
  @spec le_features(non_neg_integer()) :: [atom()]
  def le_features(mask) when is_integer(mask),
    do: for({name, bit} <- @le_features, (mask &&& 1 <<< bit) != 0, do: name)

  @doc """
  Whether `mask` has the named LE feature (one of `le_features/1`'s
  names). Raises `ArgumentError` on an unknown name.

      iex> Bluez.HciUser.Codec.le_feature?(0x1000, :extended_advertising)
      true
  """
  @spec le_feature?(non_neg_integer(), atom()) :: boolean()
  def le_feature?(mask, name) when is_integer(mask) do
    case Keyword.fetch(@le_features, name) do
      {:ok, bit} -> (mask &&& 1 <<< bit) != 0
      :error -> raise ArgumentError, "unknown LE feature #{inspect(name)}"
    end
  end
end
