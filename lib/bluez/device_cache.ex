defmodule Bluez.DeviceCache do
  @moduledoc """
  Pure per-device advertisement cache with emit-gating and a bounded size.
  No I/O — `Bluez.Client` owns the side effects (it emits the
  adverts this module returns).

  Each device path maps to `%{props, last_raw, last_emit, last_seen}`. On
  `upsert/4` the new props are merged, the advert is reconstructed
  (`Bluez.Advert`), and an advert is returned to emit only when:

    * it's the first sighting, or
    * the reconstructed AD payload changed (sensor data update), or
    * the heartbeat interval has elapsed (keeps RSSI/last-seen fresh in HA
      without forwarding every PDU).

  The heartbeat is configurable per cache instance (`new/1`'s
  `heartbeat_ms:` opt) because it's the only refresh some devices ever get:
  a static-payload beacon (fixed iBeacon UUID/major/minor) changes no AD
  bytes ever, so without the heartbeat its RSSI/last-seen would freeze at
  first sight for as long as it keeps advertising.

  The map is capped at `@max_devices` (LRU by `last_seen`) so a device spraying
  randomized MACs — each a new BlueZ object path — can't grow it without bound
  (BlueZ's `InterfacesRemoved` is the only other prune and is outside our
  control).
  """

  alias Bluez.Advert

  @max_devices 512
  @default_rssi_heartbeat_ms 10_000

  @type t :: %__MODULE__{
          devices: %{optional(String.t()) => map()},
          heartbeat_ms: pos_integer()
        }
  defstruct devices: %{}, heartbeat_ms: @default_rssi_heartbeat_ms

  @doc "The default heartbeat interval (ms) used when `new/1` is called without `heartbeat_ms:`."
  @spec default_heartbeat_ms() :: pos_integer()
  def default_heartbeat_ms, do: @default_rssi_heartbeat_ms

  @doc """
  An empty cache. `heartbeat_ms:` (default `#{@default_rssi_heartbeat_ms}`)
  sets how long an unchanged advert is suppressed before `upsert/4`
  re-emits it anyway — see the moduledoc. Raises `ArgumentError` unless
  it's a positive integer.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    heartbeat_ms = Keyword.get(opts, :heartbeat_ms, @default_rssi_heartbeat_ms)

    unless is_integer(heartbeat_ms) and heartbeat_ms > 0 do
      raise ArgumentError,
            "heartbeat_ms must be a positive integer, got: #{inspect(heartbeat_ms)}"
    end

    %__MODULE__{heartbeat_ms: heartbeat_ms}
  end

  @doc "Number of device entries currently cached."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{devices: devices}), do: map_size(devices)

  @doc """
  Merge `new_props` for `path` at monotonic `now_ms`. Returns
  `{cache, adverts}` where `adverts` is `[]` or a single reconstructed advert
  the caller should emit.
  """
  @spec upsert(t(), String.t(), map(), integer()) ::
          {t(), [Bluez.Advert.advert()]}
  def upsert(%__MODULE__{} = cache, path, new_props, now_ms) do
    entry = Map.get(cache.devices, path, %{props: %{}, last_raw: nil, last_emit: nil})
    merged = Map.merge(entry.props, new_props)

    {adverts, last_raw, last_emit} =
      case Advert.reconstruct(merged) do
        {:ok, advert} ->
          if emit?(advert.raw_data, entry.last_raw, entry.last_emit, now_ms, cache.heartbeat_ms) do
            {[advert], advert.raw_data, now_ms}
          else
            {[], entry.last_raw, entry.last_emit}
          end

        :skip ->
          {[], entry.last_raw, entry.last_emit}
      end

    new_entry = %{props: merged, last_raw: last_raw, last_emit: last_emit, last_seen: now_ms}
    devices = cap(Map.put(cache.devices, path, new_entry))
    {%{cache | devices: devices}, adverts}
  end

  @doc "Drop `path`'s entry (BlueZ emitted `InterfacesRemoved` for it)."
  @spec remove(t(), String.t()) :: t()
  def remove(%__MODULE__{} = cache, path), do: %{cache | devices: Map.delete(cache.devices, path)}

  @doc """
  Distinct devices seen within the last `window_ms` of monotonic `now_ms` —
  the web tab's "devices (15 min)" stat. A plain scan bounded by the LRU
  cap, so it's cheap enough to run per stats tick.

  Note the cap also bounds the answer: with > `#{@max_devices}` active
  devices the count saturates at the cap (eviction forgets the oldest).
  """
  @spec seen_within(t(), integer(), pos_integer()) :: non_neg_integer()
  def seen_within(%__MODULE__{devices: devices}, now_ms, window_ms) do
    Enum.count(devices, fn {_path, entry} -> now_ms - entry.last_seen <= window_ms end)
  end

  @doc """
  Emit decision (pure). Emit on first sight (`last_raw == nil`), on a payload
  change, or once the heartbeat interval has elapsed.
  """
  @spec emit?(binary(), binary() | nil, integer() | nil, integer(), integer()) :: boolean()
  def emit?(_raw, nil, _last_emit, _now, _heartbeat_ms), do: true
  def emit?(raw, last_raw, _last_emit, _now, _heartbeat_ms) when raw != last_raw, do: true
  # No prior emit time — treat as never emitted (also keeps the function total:
  # avoids `now - nil` when called with last_raw present but last_emit nil).
  def emit?(_raw, _last_raw, nil, _now, _heartbeat_ms), do: true
  def emit?(_raw, _last_raw, last_emit, now, heartbeat_ms), do: now - last_emit >= heartbeat_ms

  # Evict the least-recently-seen entries until at or below the cap. The
  # just-upserted entry has the newest last_seen, so it's never the victim.
  defp cap(devices) when map_size(devices) <= @max_devices, do: devices

  defp cap(devices) do
    {oldest, _} = Enum.min_by(devices, fn {_path, e} -> e.last_seen end)
    cap(Map.delete(devices, oldest))
  end
end
