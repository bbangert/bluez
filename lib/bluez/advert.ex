defmodule Bluez.Advert do
  @moduledoc """
  Reconstructs a BLE advertisement (the verbatim-ish AD byte structure plus
  the fields an ESPHome-style scanner host needs) from BlueZ's *parsed* device
  properties.

  D-Bus / `org.bluez` does NOT expose the raw over-the-air AD bytes, only
  parsed properties (`ManufacturerData`, `ServiceData`, `ServiceUUIDs`,
  `Name`, `TxPower`, `RSSI`, `Address`). We re-serialize those back into AD
  elements. This is **lossy** — it drops AD element order, the Flags (0x01)
  element, unknown/proprietary AD types, and the adv/scan-response split —
  but it is faithful for the manufacturer- and service-data elements that
  Home Assistant's sensor decoders use (BTHome `0xFCD2`, Govee, Xiaomi).

  This is how HA's own Linux/BlueZ adapters reconstruct adverts
  (`bluetooth-data-tools`).

  ## Inputs

  `reconstruct/1` takes a *props map* keyed by BlueZ property name with
  values already unwrapped from their D-Bus variants by
  `Bluez.Client`:

      %{
        "Address" => "AA:BB:CC:DD:EE:FF",
        "AddressType" => "public" | "random",
        "RSSI" => -60,                       # int16, may be absent
        "ManufacturerData" => %{0x004C => <<...>>},   # company_id => bytes
        "ServiceData" => %{"0000fcd2-..." => <<...>>},# uuid string => bytes
        "ServiceUUIDs" => ["0000fcd2-0000-1000-8000-00805f9b34fb", ...],
        "Name" => "Govee_...",
        "TxPower" => -4
      }

  ## Output

  `{:ok, advert}` where `advert` is the map shape
  `Bluez.Client`'s `on_advertisement:` fun consumes, or `:skip` when there
  is no `Address` (can't address the advert) — RSSI/data may legitimately be
  absent on a given update.
  """

  # Base UUID suffix for 16-bit/32-bit Bluetooth SIG short UUIDs:
  # 0000xxxx-0000-1000-8000-00805f9b34fb
  @base_uuid_suffix "-0000-1000-8000-00805f9b34fb"

  @type advert :: %{
          address: non_neg_integer(),
          rss: integer(),
          address_type: 0 | 1,
          raw_data: binary()
        }

  @doc """
  Build the `on_advertisement/1` map from unwrapped BlueZ props, or `:skip`.
  """
  @spec reconstruct(map()) :: {:ok, advert()} | :skip
  def reconstruct(props) when is_map(props) do
    # Require a syntactically valid MAC before parsing — a non-MAC Address
    # string would otherwise make address_to_integer/1 raise, and reconstruct
    # is called from paths without a rescue (e.g. seed_existing).
    with addr when is_binary(addr) <- props["Address"],
         true <- valid_mac?(addr) do
      {:ok,
       %{
         address: address_to_integer(addr),
         rss: Map.get(props, "RSSI", 0),
         address_type: address_type(Map.get(props, "AddressType")),
         raw_data: build_ad(props)
       }}
    else
      _ -> :skip
    end
  end

  def reconstruct(_), do: :skip

  defp valid_mac?(mac) do
    case String.split(mac, ":") do
      parts when length(parts) == 6 -> Enum.all?(parts, &hex_byte?/1)
      _ -> false
    end
  end

  defp hex_byte?(s), do: byte_size(s) in 1..2 and match?({_, ""}, Integer.parse(s, 16))

  @doc """
  Parse `"AA:BB:CC:DD:EE:FF"` into the MSB-first integer Home Assistant
  expects (`0xAABBCCDDEEFF`). Matches what blue_heron forwarded (validated on
  rpi3 against HA — no byte swap).
  """
  @spec address_to_integer(String.t()) :: non_neg_integer()
  def address_to_integer(mac) do
    mac
    |> String.split(":")
    |> Enum.reduce(0, fn hex, acc -> acc * 256 + String.to_integer(hex, 16) end)
  end

  defp address_type("random"), do: 1
  defp address_type(_), do: 0

  # Re-serialize the parsed props into AD elements. Order is our own (BlueZ
  # lost the original); HA decoders key off AD type, not order.
  defp build_ad(props) do
    [
      ad_service_uuids(Map.get(props, "ServiceUUIDs")),
      ad_local_name(Map.get(props, "Name")),
      ad_tx_power(Map.get(props, "TxPower")),
      ad_service_data(Map.get(props, "ServiceData")),
      ad_manufacturer_data(Map.get(props, "ManufacturerData"))
    ]
    |> IO.iodata_to_binary()
  end

  # 0xFF Manufacturer Specific Data: <<company_id::little-16, bytes>>, one AD
  # element per company id.
  defp ad_manufacturer_data(map) when is_map(map) do
    for {company_id, bytes} <- map, is_integer(company_id), is_binary(bytes) do
      ad_element(0xFF, <<company_id::little-16, bytes::binary>>)
    end
  end

  defp ad_manufacturer_data(_), do: []

  # Service Data: 16-bit short UUID -> 0x16 <<uuid::little-16, bytes>>;
  # 128-bit -> 0x21 <<uuid::binary-16 (little-endian), bytes>>.
  defp ad_service_data(map) when is_map(map) do
    for {uuid, bytes} <- map, is_binary(uuid), is_binary(bytes) do
      case short_uuid16(uuid) do
        {:ok, u16} -> ad_element(0x16, <<u16::little-16, bytes::binary>>)
        :error -> ad_element(0x21, uuid128_le(uuid) <> bytes)
      end
    end
  end

  defp ad_service_data(_), do: []

  # 0x03 Complete List of 16-bit Service Class UUIDs (only the 16-bit ones).
  defp ad_service_uuids(list) when is_list(list) do
    u16s =
      for uuid <- list, {:ok, u16} <- [short_uuid16(uuid)] do
        <<u16::little-16>>
      end

    case u16s do
      [] -> []
      bins -> ad_element(0x03, IO.iodata_to_binary(bins))
    end
  end

  defp ad_service_uuids(_), do: []

  # 0x09 Complete Local Name.
  defp ad_local_name(name) when is_binary(name) and name != "", do: ad_element(0x09, name)
  defp ad_local_name(_), do: []

  # 0x0A TX Power Level (signed byte).
  defp ad_tx_power(power) when is_integer(power), do: ad_element(0x0A, <<power::signed-8>>)
  defp ad_tx_power(_), do: []

  # One AD structure: <<length, type, data...>> where length counts type+data.
  # The length is a single byte, so data must be <= 254; a larger field (e.g. a
  # device advertising an oversized ServiceData/ManufacturerData blob) is
  # dropped rather than emitted with a wrapped/overflowed length byte.
  defp ad_element(type, data)
       when is_integer(type) and is_binary(data) and byte_size(data) <= 254 do
    <<byte_size(data) + 1, type, data::binary>>
  end

  defp ad_element(_type, _data), do: <<>>

  # "0000fcd2-0000-1000-8000-00805f9b34fb" -> {:ok, 0xFCD2} for SIG base UUIDs
  # whose high 16 bits of the first group are zero (true 16-bit UUIDs).
  defp short_uuid16(uuid) when is_binary(uuid) do
    down = String.downcase(uuid)

    with true <- String.ends_with?(down, @base_uuid_suffix),
         <<first8::binary-8, "-", _::binary>> <- down,
         {value, ""} <- Integer.parse(first8, 16),
         true <- value <= 0xFFFF do
      {:ok, value}
    else
      _ -> :error
    end
  end

  # 128-bit UUID string -> 16 raw bytes, little-endian (AD wire order).
  defp uuid128_le(uuid) do
    uuid
    |> String.replace("-", "")
    |> Base.decode16!(case: :mixed)
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> :erlang.list_to_binary()
  end
end
