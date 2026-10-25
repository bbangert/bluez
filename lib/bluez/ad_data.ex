defmodule Bluez.AdData do
  @moduledoc """
  Encode and decode raw BLE advertising-data (AD) structures — the
  `[len][type][payload]` TLV run that fills an advertising PDU or scan
  response.

  Unlike `Bluez.Advert` (which re-serializes BlueZ's *parsed* device
  properties, lossy by construction), this works on the verbatim bytes:
  element order, duplicates, Flags and unknown/proprietary types all
  survive. It is the shared format of `Bluez.Hci` advertising reports
  (receive) and `Bluez.Mgmt` raw advertising (transmit).

  ## Payload carried in a 16-bit UUID list

  Some proprietary protocols (Tuya "Beacon" lights, among others) carry an
  opaque payload in a Complete/Incomplete List of 16-bit Service UUIDs
  (AD types `0x03`/`0x02`): the list *is* the payload, two bytes per
  "UUID", in order, duplicates included. `uuid16_list/1` builds that
  element from the payload for `Bluez.Mgmt` to send verbatim, and
  `uuid16_list_payload/1` gets the payload back out of a received report.

  Pure and host-testable.
  """

  # AD type codes this module names (Bluetooth Core Spec Supplement, Part A).
  @flags 0x01
  @uuid16_incomplete 0x02
  @uuid16_complete 0x03
  @uuid128_complete 0x07
  @short_name 0x08
  @complete_name 0x09
  @manufacturer_data 0xFF

  # 0000xxxx-0000-1000-8000-00805f9b34fb — BlueZ's bt_string_to_uuid folds
  # this form back to a 16-bit UUID.

  # Legacy advertising PDU / scan response payload limit.
  @legacy_max 31

  @type element :: {type :: 0..255, payload :: binary()}

  @doc "Legacy (non-extended) advertising data / scan response size limit."
  @spec legacy_max_length() :: 31
  def legacy_max_length, do: @legacy_max

  @doc """
  Decode an AD byte run into its elements, in order.

  A zero length byte terminates the run (the spec's "insignificant part":
  some controllers zero-pad to 31 bytes). A length running past the end of
  the buffer is `{:error, :malformed}`.

      iex> Bluez.AdData.decode(<<2, 1, 6, 5, 3, 1, 2, 3, 4>>)
      {:ok, [{1, <<6>>}, {3, <<1, 2, 3, 4>>}]}
  """
  @spec decode(binary()) :: {:ok, [element()]} | {:error, :malformed}
  def decode(data) when is_binary(data), do: decode(data, [])

  defp decode(<<>>, acc), do: {:ok, Enum.reverse(acc)}
  defp decode(<<0, _padding::binary>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode(<<len, type, payload::binary-size(len - 1), tail::binary>>, acc),
    do: decode(tail, [{type, payload} | acc])

  defp decode(_truncated, _acc), do: {:error, :malformed}

  @doc """
  Encode elements into an AD byte run. Raises `ArgumentError` for a type
  outside `0..255` or a payload longer than 254 bytes (one length byte).

      iex> Bluez.AdData.encode([{0x01, <<0x06>>}, {0x03, <<0xAA, 0xBB>>}])
      <<2, 1, 6, 3, 3, 0xAA, 0xBB>>
  """
  @spec encode([element()]) :: binary()
  def encode(elements) when is_list(elements) do
    for {type, payload} <- elements, into: <<>> do
      unless type in 0..255 and is_binary(payload) and byte_size(payload) <= 254 do
        raise ArgumentError, "invalid AD element #{inspect({type, payload})}"
      end

      <<byte_size(payload) + 1, type, payload::binary>>
    end
  end

  @doc """
  First element of `type` in a decoded list, or `nil`.
  """
  @spec find([element()], 0..255) :: binary() | nil
  def find(elements, type) do
    case List.keyfind(elements, type, 0) do
      {^type, payload} -> payload
      nil -> nil
    end
  end

  @doc """
  The payload of the (first) 16-bit Service UUID list — Complete (`0x03`)
  preferred, else Incomplete (`0x02`) — exactly as it appeared on air, or
  `nil` when the advert carries none.

      iex> Bluez.AdData.uuid16_list_payload(<<2, 1, 6, 5, 3, 0x11, 0x22, 0x33, 0x44>>)
      <<0x11, 0x22, 0x33, 0x44>>
  """
  @spec uuid16_list_payload(binary() | [element()]) :: binary() | nil
  def uuid16_list_payload(data) when is_binary(data) do
    case decode(data) do
      {:ok, elements} -> uuid16_list_payload(elements)
      {:error, :malformed} -> nil
    end
  end

  def uuid16_list_payload(elements) when is_list(elements),
    do: find(elements, @uuid16_complete) || find(elements, @uuid16_incomplete)

  @doc """
  Split an even-length payload into the 16-bit UUID values a list AD
  element would carry for it (each pair of bytes little-endian).

      iex> Bluez.AdData.uuid16_values(<<0x11, 0x22, 0x33, 0x44>>)
      [0x2211, 0x4433]
  """
  @spec uuid16_values(binary()) :: [0..0xFFFF]
  def uuid16_values(payload) when is_binary(payload) and rem(byte_size(payload), 2) == 0 do
    for <<value::little-16 <- payload>>, do: value
  end

  @doc """
  A Flags element (`0x01`). `flags` is the raw bitmask — `0x06` is the
  usual "LE General Discoverable, BR/EDR not supported".
  """
  @spec flags(0..255) :: element()
  def flags(bits) when bits in 0..255, do: {@flags, <<bits>>}

  @doc "A Complete List of 16-bit Service UUIDs element carrying `payload` verbatim."
  @spec uuid16_list(binary()) :: element()
  def uuid16_list(payload) when is_binary(payload) and rem(byte_size(payload), 2) == 0,
    do: {@uuid16_complete, payload}

  @doc """
  A Complete List of 128-bit Service UUIDs element. Each 16-byte UUID is
  given in the order it goes on air (little-endian, i.e. the reverse of
  the textual form) — pass raw protocol bytes straight through.
  """
  @spec uuid128_list([<<_::128>>]) :: element()
  def uuid128_list(uuids) when is_list(uuids) do
    {@uuid128_complete, Enum.map_join(uuids, fn <<_::128>> = u -> u end)}
  end

  @doc "A Complete (or, with `shortened: true`, Shortened) Local Name element."
  @spec local_name(String.t(), keyword()) :: element()
  def local_name(name, opts \\ []) when is_binary(name) do
    type = if Keyword.get(opts, :shortened, false), do: @short_name, else: @complete_name
    {type, name}
  end

  @doc "A Manufacturer Specific Data element (company id little-endian, then `data`)."
  @spec manufacturer_data(0..0xFFFF, binary()) :: element()
  def manufacturer_data(company_id, data) when company_id in 0..0xFFFF and is_binary(data),
    do: {@manufacturer_data, <<company_id::little-16, data::binary>>}
end
