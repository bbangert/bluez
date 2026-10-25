# Host integration

Everything the library needs from your application flows through
`Bluez.start_link/1` opts — injected funs, a PubSub, and child specs.
This guide is the integration cookbook: the option surface, the GATT
event contract your translator must cover, and the runtime patterns
(radio switching, scan suspension) a full-featured host ends up using.

The running example is an ESPHome-style Bluetooth proxy (the application
this library was extracted from), but nothing here is specific to it.

## Wiring it up

Build the child spec in one place so every app-side callback is visible
together:

```elixir
defmodule MyApp.Bluetooth do
  def bluez_spec do
    {Bluez,
     client: [
       # Called once per emitted advertisement (see "Advertisements").
       on_advertisement: &MyApp.Scanner.on_advertisement/1,
       # Optional: {:bluetooth_adapters_changed} broadcasts on adapter
       # claim/hotplug. nil (default) = no broadcasts.
       pubsub: MyApp.PubSub
     ],
     gatt: [
       # Called for every GATT event (see "The GATT event contract").
       on_gatt_event: &MyApp.BLEProxy.gatt_event/2,
       # Called whenever a connection slot is taken or freed.
       on_connections_changed: &MyApp.Stats.connections_changed/0
     ],
     audio: true,
     blue_alsa: [pubsub: MyApp.PubSub],
     desired_adapter: nil,
     extra_children: [
       # Your own BlueZ consumers. They restart with the audio path and
       # can rely on everything above them being up.
       MyApp.HeadphoneManager
     ]}
  end
end
```

Start it under your supervision tree (directly, or under a
`DynamicSupervisor` if you stop/start it at runtime — see "Switching
radios").

## Raw advertising and verbatim reports

Opt in with `advertiser:`, `mgmt:` and/or `advert_receiver:` (each `true`
or a keyword list):

```elixir
{Bluez,
 client: [on_advertisement: &MyApp.Scanner.on_advertisement/1],
 advertiser: true,
 mgmt: true,
 advert_receiver: [on_report: &MyApp.Beacons.on_report/1]}
```

Either advertiser starts `Bluez.Radio`. Sending needs the controller's
transmit lease: acquire it in the process that will send (typically the
GenServer driving your protocol) and keep it for as long as that process
transmits. Only the holder may send; releasing the lease, or the holder
exiting, takes everything it sent off air. A send returning
`{:error, :lease_expired}` means the lease is gone (e.g. `Bluez.Radio`
restarted): acquire again.

```elixir
{:ok, lease} = Bluez.Radio.acquire()
```

`acquire/1` returns `{:error, :no_adapter_index}` until `Bluez.Client`
has resolved the adapter, and `{:error, {:held_by, pid}}` while another
process holds it.

Send a payload as an ordered 16-bit UUID list for 300 ms:

```elixir
uuids = Bluez.AdData.uuid16_strings(payload)
spec = %{type: :broadcast, service_uuids: uuids}
{:ok, _id} = Bluez.Advertiser.advertise(lease, spec, duration_ms: 300)
```

Send an exact legacy advertising PDU (here Flags + Local Name + one
128-bit UUID) at a 20–30 ms interval:

```elixir
alias Bluez.AdData

data = Bluez.Mgmt.legacy_adv_data([AdData.local_name(name), AdData.uuid128_list([block])])
{:ok, _instance} = Bluez.Mgmt.advertise(lease, data, duration_ms: 300)
```

Receive reports with the AD bytes as they were on air:

```elixir
def on_report(%{address: addr, rssi: rssi, data: data}) do
  case Bluez.AdData.uuid16_list_payload(data) do
    nil -> :ok
    payload -> MyApp.Beacons.handle(addr, rssi, payload)
  end
end
```

`on_report:` runs in the receiver's process for every report the
controller produces (far more than the deduplicated `on_advertisement:`
stream), so filter cheaply and hand real work off. Reports only flow
while `Bluez.Client` is scanning; prefer `:active` mode when every
packet matters, since controllers that offload advertisement-monitor
filtering can drop adverts in `:passive` mode.

## Advertisements

`on_advertisement:` receives one map per emitted advert:

```elixir
%{
  address: 0xAABBCCDDEEFF,   # 48-bit MAC, MSB-first integer
  rss: 0xC4,                 # raw unsigned RSSI byte (two's complement)
  address_type: 0 | 1,       # public | random
  raw_data: <<...>>          # reconstructed AD byte structure
}
```

The fun runs **in the Client's GenServer loop** — treat it like a
`handle_info` body. Fan out with non-blocking sends (a `Registry.dispatch/3`
over subscriber pids works well); never make blocking calls from it.

Emission is already gated (first sighting / payload change / RSSI
heartbeat — see `Bluez.DeviceCache`; configurable via `Bluez.Client`'s
`rssi_heartbeat_ms:` option with default 10 s), so forward every invocation.

Scanner mode is runtime-switchable with `Bluez.Client.set_mode/1`
(`:passive`/`:active`), persists across Client crashes, and can be
suspended/resumed wholesale (`suspend_scan/0` / `resume_scan/0`) when
your app needs the radio for something else — suspension preserves the
configured mode.

## The GATT event contract

`Bluez.Gatt`'s API is cast-style: requests return `:ok` immediately and
results are delivered to the `subscriber` pid captured at
`Bluez.Gatt.connect/3`, through your `on_gatt_event:` fun
(`fn subscriber, event`; default `send(subscriber, event)`).

The complete event set — your translator should cover every tag and
crash on anything else (an unknown tag is a library contract violation;
don't silently drop it):

| Event | When |
|-------|------|
| `{:gatt_connection, address, {:ok, mtu}}` | Connect succeeded and services are resolved; handle-keyed requests are valid from here |
| `{:gatt_connection, address, {:error, code}}` | Connect failed, the device dropped the link, or post-`unpair`/`clear_cache` teardown |
| `{:gatt_service, address, %Bluez.Gatt.Service{}}` | One per service, after `get_services/1` |
| `{:gatt_services_done, address}` | Service stream terminator |
| `{:gatt_read, address, handle, {:ok, binary} \| {:error, code}}` | Characteristic/descriptor read result (also carries a failed `get_services/1` as handle 0) |
| `{:gatt_write, address, handle, {:ok, :done} \| {:error, code}}` | Characteristic/descriptor write result |
| `{:gatt_notify, address, handle, {:ok, :done} \| {:error, code}}` | Start/StopNotify call result |
| `{:gatt_notify_data, address, handle, binary}` | A notification/indication value |
| `{:gatt_pair, address, success?, code}` | `pair/1` result |
| `{:gatt_unpair, address, success?, code}` | `unpair/1` result |
| `{:gatt_clear_cache, address, success?, code}` | `clear_cache/1` result |

Error `code`s follow the ESPHome BLE convention: `-1` generic, `-2` not
connected.

The fun runs in the Gatt server's loop; keep it to a translate-and-send.
A minimal pass-through host needs no translator at all (the default
sends the events verbatim). A host with its own wire shapes translates
exhaustively:

```elixir
defmodule MyApp.BLEProxy do
  def gatt_event(subscriber, event) do
    send(subscriber, translate(event))
    :ok
  end

  # One clause per tag — exhaustive, deliberately no catch-all.
  defp translate({:gatt_connection, addr, result}),
    do: {:my_ble_connection, addr, result}

  defp translate({:gatt_service, addr, service}),
    do: {:my_ble_service, addr, reshape_service(service)}

  # ... one clause for each remaining tag ...
end
```

`%Bluez.Gatt.Service{}` carries `uuid`, `handle`, and nested
`%Bluez.Gatt.Characteristic{}` (with a Core-spec `properties` bitmask
and `%Bluez.Gatt.Descriptor{}` children). UUIDs are 16-bit integers for
Bluetooth-SIG base UUIDs, else 16-byte binaries.

### Ownership expectations

The library trusts the host to gate GATT requests on connection
ownership: `connect/3` at most once per address per ownership cycle, and
requests only for addresses the caller owns. Requests for unknown
addresses are logged and dropped (there is no subscriber to answer);
stale entries are torn down defensively.

## Audio PCMs

With `audio: true`, `Bluez.BlueAlsa.pcms/0` lists the ready-to-open A2DP
playback PCMs:

```elixir
[%{mac: "AA:BB:CC:DD:EE:FF",
   pcm_path: "/org/bluealsa/hci0/dev_.../a2dpsrc/sink",
   alsa_string: "bluealsa:DEV=AA:BB:CC:DD:EE:FF,PROFILE=a2dp",
   alias: "WH-1000XM4"}]
```

Re-enumerate when `{:bluealsa_pcms_changed}` arrives on the `blue_alsa:
[pubsub: ...]` topic (`Bluez.BlueAlsa.pcms_topic/0`) — that broadcast is
the authoritative trigger: a headset can (re)connect via bluetoothd
auto-reconnect without any action of yours, and even an explicit
`Device1.Connect` returns before the PCM exists.

Note this is the *control plane* only: your audio pipeline opens the
`alsa_string` itself. Pairing/connecting headsets is also yours —
typically a consumer in `extra_children:` driving `Device1` calls over
its own bus connection.

## Switching radios

To let users re-point the stack at a different controller at runtime,
run `{Bluez, opts}` under a `DynamicSupervisor` and own the cycle in a
manager process:

1. publish the new MAC: `:persistent_term.put(Bluez.DevicePath.desired_adapter_key(), mac)`
2. terminate the `Bluez` child, wait ~1.5 s (the old `bluetoothd`
   releases its L2CAP listening sockets a beat after exiting —
   hardware-found; an immediate restart fails adapter registration with
   "Address already in use")
3. start it again — `Bluez.Client` resolves the new MAC during setup

Active connections drop by design; the scanner re-engages the configured
mode on the new radio. For a fixed single-radio device, skip all of this
and pass `desired_adapter:` (or nothing — auto).

## Status surfaces

For dashboards, the synchronous reads compose into a status page:

- `Bluez.Client.adapters_info/0` — live `Adapter1` identity for every
  adapter the daemon exposes
- `Bluez.Client.devices_seen/1` — distinct advertisers in a window
- `Bluez.Client.configured_mode/0` — the persisted scan mode
- `Bluez.Gatt.connections_free/0` — `{free, total}` connection slots
- `Bluez.BlueAlsa.pcms/0` — connected audio sinks

All are safe to call while the stack is down **if** you wrap them in
`catch :exit` (they exit when the process isn't running — see the
idiom note in the `Bluez` moduledoc).
