defmodule Bluez.GattTree do
  @moduledoc """
  Build a GATT tree from BlueZ's `GetManagedObjects` reply.

  Once a device's `ServicesResolved` flips true, its GATT database appears
  as `org.bluez.GattService1` / `GattCharacteristic1` / `GattDescriptor1`
  objects under the device path. This module turns those (rebus-decoded)
  objects into:

    * `Bluez.Gatt.Service` structs, emitted to the host via
      `{:gatt_service, address, service}` events (the app-side translator
      reshapes them for Home Assistant), and
    * handle ↔ object-path maps for executing handle-keyed GATT requests.

  Pure and host-testable — the D-Bus I/O stays in `Bluez.Gatt`.

  ## Handle convention (bleak-compatible)

  BlueZ encodes the ATT handle of each attribute in the object path's hex
  suffix (`service000a/char000b/desc000d`). For characteristics that is the
  *declaration* handle; clients address the *value* attribute, which always
  sits at declaration + 1. We report `path_handle + 1` for characteristics
  (exactly what bleak — HA's own BlueZ backend — does), and the path handle
  as-is for services and descriptors. HA echoes our reported handles back
  in GATT requests, and `by_handle` is keyed by the same reported handles,
  so the mapping is self-consistent — and consistent with HA's cached GATT
  databases from bleak/ESP32 proxies, which also carry value handles.

  ## Hierarchy

  Children are attached via their parent object-path properties
  (`Characteristic.Service`, `Descriptor.Characteristic`) rather than path
  string prefixes. Objects with malformed paths (no parseable handle) or
  dangling parent references are dropped.
  """

  alias Bluez.Gatt.{Characteristic, Descriptor, Service}
  alias Bluez.Variant

  @service_iface "org.bluez.GattService1"
  @char_iface "org.bluez.GattCharacteristic1"
  @desc_iface "org.bluez.GattDescriptor1"

  # The Bluetooth SIG base UUID: short UUIDs are 0000XXXX-0000-1000-8000-00805f9b34fb.
  @sig_base_suffix "-0000-1000-8000-00805f9b34fb"

  # org.bluez.GattCharacteristic1 `Flags` → GATT characteristic-properties
  # bitmask (Core spec 3.3.1.1, the encoding ESPHome/HA expects). Flags
  # without a bit in the byte (reliable-write, encrypt-read, …) are dropped.
  @property_bits %{
    "broadcast" => 0x01,
    "read" => 0x02,
    "write-without-response" => 0x04,
    "write" => 0x08,
    "notify" => 0x10,
    "indicate" => 0x20,
    "authenticated-signed-writes" => 0x40,
    "extended-properties" => 0x80
  }

  @type kind :: :characteristic | :descriptor
  @type t :: %__MODULE__{
          services: [Service.t()],
          by_handle: %{non_neg_integer() => {kind(), String.t()}},
          handle_by_char_path: %{String.t() => non_neg_integer()},
          mtu: non_neg_integer() | nil
        }

  defstruct services: [], by_handle: %{}, handle_by_char_path: %{}, mtu: nil

  @doc """
  Build the GATT tree for `device_path` from a `GetManagedObjects` object
  list (rebus-decoded: `[{path, [{iface, props_list}]}]`).

  `mtu` is the ATT MTU reported by any of the device's characteristics
  (`bluetoothd -E` exposes the experimental `MTU` property), or `nil` when
  none carries one.
  """
  @spec build([{String.t(), list()}], String.t()) :: t()
  def build(objects, device_path) when is_list(objects) and is_binary(device_path) do
    prefix = device_path <> "/"

    grouped =
      for {path, ifaces} <- objects,
          is_binary(path) and String.starts_with?(path, prefix),
          {iface, props_list} <- ifaces,
          iface in [@service_iface, @char_iface, @desc_iface],
          # Non-matching generator pattern (:error) skips the object.
          {:ok, handle} <- [path_handle(path)],
          reduce: %{services: [], chars: [], descs: []} do
        acc ->
          props = Variant.unwrap_props(props_list)

          case iface do
            @service_iface -> %{acc | services: [{path, handle, props} | acc.services]}
            @char_iface -> %{acc | chars: [{path, handle, props} | acc.chars]}
            @desc_iface -> %{acc | descs: [{path, handle, props} | acc.descs]}
          end
      end

    # The reduce prepends, so restore true bus order: Map.new keeps the last
    # element it sees, and "last object in bus order wins" (for duplicate
    # handles BlueZ shouldn't emit) only holds on the un-reversed lists.
    grouped =
      Map.new(grouped, fn {kind, entries} -> {kind, Enum.reverse(entries)} end)

    descs_by_char =
      Enum.group_by(grouped.descs, fn {_p, _h, props} -> props["Characteristic"] end)

    chars_by_service = Enum.group_by(grouped.chars, fn {_p, _h, props} -> props["Service"] end)

    services =
      grouped.services
      |> Enum.sort_by(fn {_path, handle, _props} -> handle end)
      |> Enum.map(fn {path, handle, props} ->
        %Service{
          uuid: to_uuid(props["UUID"]),
          handle: handle,
          characteristics: build_characteristics(chars_by_service[path] || [], descs_by_char)
        }
      end)

    %__MODULE__{
      services: services,
      by_handle: build_by_handle(grouped),
      handle_by_char_path: Map.new(grouped.chars, fn {path, h, _} -> {path, value_handle(h)} end),
      mtu: first_mtu(grouped.chars)
    }
  end

  @doc """
  Map a BlueZ `Flags` string list to the GATT properties bitmask.

      iex> Bluez.GattTree.properties_mask(["read", "notify"]) == 0x12
      true
  """
  @spec properties_mask([String.t()] | term()) :: non_neg_integer()
  def properties_mask(flags) when is_list(flags) do
    Enum.reduce(flags, 0, fn flag, mask -> Bitwise.bor(mask, Map.get(@property_bits, flag, 0)) end)
  end

  def properties_mask(_other), do: 0

  @doc """
  Convert a BlueZ UUID string to the `t:Bluez.Gatt.Service.uuid/0`
  shape: a 16-bit integer when it's a SIG base UUID (smaller on the wire,
  matches what ESP32 proxies send), else the full 16-byte binary. Invalid
  strings map to the all-zero UUID rather than crashing the tree build.
  """
  @spec to_uuid(String.t() | term()) :: Service.uuid()
  def to_uuid(uuid) when is_binary(uuid) do
    normalized = String.downcase(uuid)

    with <<"0000", short::binary-size(4), @sig_base_suffix>> <- normalized,
         {value, ""} <- Integer.parse(short, 16) do
      value
    else
      _ -> to_uuid_binary(normalized)
    end
  end

  def to_uuid(_other), do: <<0::128>>

  defp to_uuid_binary(uuid) do
    case uuid |> String.replace("-", "") |> Base.decode16(case: :mixed) do
      {:ok, <<bin::binary-size(16)>>} -> bin
      _ -> <<0::128>>
    end
  end

  # ── internals ────────────────────────────────────────────────────────────

  defp build_characteristics(chars, descs_by_char) do
    chars
    |> Enum.sort_by(fn {_path, handle, _props} -> handle end)
    |> Enum.map(fn {path, handle, props} ->
      %Characteristic{
        uuid: to_uuid(props["UUID"]),
        handle: value_handle(handle),
        properties: properties_mask(props["Flags"]),
        descriptors: build_descriptors(descs_by_char[path] || [])
      }
    end)
  end

  defp build_descriptors(descs) do
    descs
    |> Enum.sort_by(fn {_path, handle, _props} -> handle end)
    |> Enum.map(fn {_path, handle, props} ->
      %Descriptor{uuid: to_uuid(props["UUID"]), handle: handle}
    end)
  end

  defp build_by_handle(grouped) do
    chars =
      Map.new(grouped.chars, fn {path, h, _} -> {value_handle(h), {:characteristic, path}} end)

    Enum.reduce(grouped.descs, chars, fn {path, h, _}, acc ->
      Map.put(acc, h, {:descriptor, path})
    end)
  end

  # Characteristic object paths carry the declaration handle; the value
  # attribute (what reads/writes/notifies address) is always at +1.
  defp value_handle(decl_handle), do: decl_handle + 1

  # ".../service000a" → 0x000A; the hex suffix after the trailing alpha tag.
  defp path_handle(path) do
    base = path |> String.split("/") |> List.last()

    case Regex.run(~r/^(?:service|char|desc)([0-9a-fA-F]+)$/, base) do
      [_, hex] ->
        case Integer.parse(hex, 16) do
          {handle, ""} -> {:ok, handle}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp first_mtu(chars) do
    Enum.find_value(chars, fn {_path, _h, props} ->
      case props["MTU"] do
        mtu when is_integer(mtu) and mtu > 0 -> mtu
        _ -> nil
      end
    end)
  end
end
