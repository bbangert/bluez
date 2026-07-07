# Bluez

BlueZ-over-D-Bus client library for Elixir: BLE scanning (passive *and*
active), active GATT connections, pairing, and bluez-alsa A2DP audio — the
pieces an [ESPHome-style Bluetooth
proxy](https://esphome.io/components/bluetooth_proxy.html) or any
BLE-consuming Elixir application needs on embedded Linux.

Built for [Nerves](https://nerves-project.org/) devices (read-only rootfs,
[`MuonTrap`](https://hex.pm/packages/muontrap)-supervised daemons) but has no
Nerves dependency: it runs on any Linux host where your application may own
the system D-Bus instance.

## Status

Early extraction from
[`universal_proxy`](https://github.com/bbangert/universal_proxy), where this
code shipped and was hardware-validated as an ESPHome Bluetooth proxy on
Raspberry Pis (passive/active scanning into Home Assistant, GATT
connect/read/write/notify/pair against real peripherals, BT-headphone
audio). Still being iterated on; not a final API.

## Documentation

Start here once you're ready to go beyond the quickstart below:

- [Architecture guide](guides/architecture.md) — the supervision tree and
  its restart semantics, the two rebus connections, scan-mode transitions,
  advert reconstruction, the GATT connection lifecycle, adapter selection,
  and the benign failure loops.
- [Host integration guide](guides/host_integration.md) — the integration
  cookbook: every `Bluez.start_link/1` option, the full GATT event
  contract with a translator example, audio PCM discovery, and the
  runtime radio-switching pattern.

The core modules carry the reference detail:

- `Bluez` — the supervisor and every start option
- `Bluez.Client` — scanning, mode switching, adapter enumeration
- `Bluez.Gatt` — the GATT request API and event contract
- `Bluez.Agent` — pairing authorization
- `Bluez.BlueAlsa` — A2DP playback PCM discovery

## Features

- **One supervisor** that brings up `dbus-daemon`, `bluetoothd -E`, and
  (optionally) `bluealsad`, with crash-isolation and restart ordering
  (`:rest_for_one`) already worked out — an audio fault never restarts
  scanning, a bus restart rebuilds everything above it.
- **Passive and active BLE scanning**, runtime-switchable. Passive mode
  uses BlueZ's `AdvertisementMonitor1` (no scan requests — peripherals
  don't burn battery answering); active mode collects SCAN_RSP data.
- **Advertisement reconstruction** — BlueZ only exposes parsed properties;
  they're re-serialized into AD byte structures, emit-gated (first
  sighting / payload change / RSSI heartbeat) and LRU-capped, then fanned
  out through your `on_advertisement:` fun.
- **Handle-keyed GATT client** — connect / service discovery / read /
  write / notify / pair / unpair / clear-cache, with a documented,
  host-agnostic event contract delivered through your `on_gatt_event:`
  fun. Generation-stamped so late replies can't corrupt replaced
  connections.
- **Pairing agent** that authorizes exactly the pairings your code
  initiated.
- **bluez-alsa integration** (optional) — enumerates ready-to-open A2DP
  playback PCMs and signals your app when the set changes.
- **No host coupling** — configuration flows exclusively through
  `start_link/1` opts (funs, a PubSub, child specs); no
  `Application.get_env`, no callbacks into named host modules.

## Installation (git, for now)

Not yet on hex — the D-Bus layer uses a vendored
[rebus](https://github.com/ausimian/rebus) fork
([bbangert/rebus @ `dbus-service`](https://github.com/bbangert/rebus/tree/dbus-service))
that adds the service-side API (exported objects, replies, signals) this
library needs for passive scanning. It's pinned as a git submodule, so
clone with:

```sh
git clone --recurse-submodules https://github.com/bbangert/bluez.git
# or, after a plain clone:
git submodule update --init
```

Then take it as a path or git dependency. Hex publication follows once the
rebus fork is reconciled upstream.

## Usage

```elixir
children = [
  {Bluez,
   client: [on_advertisement: &MyApp.Scanner.on_advertisement/1],
   gatt: [on_gatt_event: &MyApp.BLEProxy.gatt_event/2],
   desired_adapter: nil,     # nil = auto (lowest-index adapter)
   audio: true}              # bluealsad + Bluez.BlueAlsa
]
```

Adverts then arrive at your scanner fun as maps
(`%{address:, rss:, address_type:, raw_data:}`), and GATT requests are
cast-style with results delivered as events:

```elixir
Bluez.Gatt.connect(0xAABBCCDDEEFF, [], self())
receive do
  {:gatt_connection, addr, {:ok, mtu}} -> Bluez.Gatt.get_services(addr)
  {:gatt_connection, _addr, {:error, code}} -> {:error, code}
end
```

See the [host integration guide](guides/host_integration.md) for the full
option surface and event contract.

## Runtime requirements

- BlueZ ≥ 5.66, started by this supervisor with `-E` (experimental — needed
  for passive scanning and the GATT `MTU` property).
- dbus (this supervisor owns the *system* bus — don't run it next to a
  distro dbus/bluetoothd).
- Optional: bluez-alsa v4 for `audio: true`.
- Writable `/run/dbus` and `/data/bluetooth`; on a read-only rootfs point
  `/var/lib/bluetooth` at `/data/bluetooth` with an overlay symlink.

## License

Apache-2.0 — see the LICENSE file in the repository.
