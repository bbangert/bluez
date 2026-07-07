defmodule Bluez.Variant do
  @moduledoc """
  Unwraps `org.bluez` D-Bus property maps (as decoded by `rebus`) into plain
  Elixir maps for `Bluez.Advert`.

  rebus decodes an `a{sv}` dict to a list of `{key, {signature, value}}` and a
  variant to `{signature, value}`. This module strips those wrappers, with two
  special cases that are themselves nested dicts of byte arrays:

    * `ManufacturerData` (`a{qv}`): `[{company_id, {"ay", bytes}}]` → `%{company_id => binary}`
    * `ServiceData` (`a{sv}`): `[{uuid, {"ay", bytes}}]` → `%{uuid => binary}`

  Pure and host-testable — this is the main parse seam between raw D-Bus wire
  data and advert reconstruction.
  """

  @doc "Unwrap a decoded `a{sv}` property list into a `%{name => value}` map."
  @spec unwrap_props([{String.t(), term()}]) :: %{optional(String.t()) => term()}
  def unwrap_props(props_list) when is_list(props_list) do
    Map.new(props_list, fn {key, variant} -> {key, unwrap(key, variant)} end)
  end

  # ManufacturerData (a{qv}): dict of company-id → variant(ay).
  defp unwrap("ManufacturerData", {_sig, entries}) when is_list(entries) do
    Map.new(entries, fn {id, {_s, bytes}} -> {id, to_binary(bytes)} end)
  end

  # ServiceData (a{sv}): dict of uuid → variant(ay).
  defp unwrap("ServiceData", {_sig, entries}) when is_list(entries) do
    Map.new(entries, fn {uuid, {_s, bytes}} -> {uuid, to_binary(bytes)} end)
  end

  # Any other variant: drop the signature, keep the value.
  defp unwrap(_key, {_sig, value}), do: value
  defp unwrap(_key, value), do: value

  defp to_binary(bytes) when is_list(bytes), do: :erlang.list_to_binary(bytes)
  defp to_binary(bytes) when is_binary(bytes), do: bytes
end
