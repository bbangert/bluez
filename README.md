# Bluez

BlueZ-over-D-Bus client for Elixir: BLE scanning (passive *and* active),
active GATT connections, pairing, and bluez-alsa A2DP audio — the pieces an
[ESPHome-style Bluetooth proxy](https://esphome.io/components/bluetooth_proxy.html)
or any BLE-consuming Elixir application needs on embedded Linux.

Built for [Nerves](https://nerves-project.org/) devices (read-only rootfs,
[`MuonTrap`](https://hex.pm/packages/muontrap)-supervised daemons) but has no
Nerves dependency: it runs on any Linux host where your application may own
the system D-Bus instance. Extracted from a hardware-validated ESPHome
Bluetooth proxy running on Raspberry Pis.

## What you get

- **One supervisor** (`Bluez`) that brings up `dbus-daemon`, `bluetoothd -E`,
  and (optionally) `bluealsad`, plus the Elixir clients on top —
  crash-isolation and restart ordering (`:rest_for_one`) already worked out.
- **`Bluez.Client`** — BLE scanning in BlueZ's passive
  (`AdvertisementMonitor1`, no scan requests) or active (`StartDiscovery`)
  mode, runtime-switchable; advertisements are reconstructed into AD byte
  structures and fanned out through your `on_advertisement:` fun.
- **`Bluez.Gatt`** — handle-keyed GATT client (connect / services / read /
  write / notify / pair / unpair / clear-cache) with a documented,
  host-agnostic event contract delivered through your `on_gatt_event:` fun.
- **`Bluez.Agent`** — default NoInputNoOutput pairing agent that only
  authorizes pairings your code initiated.
- **`Bluez.BlueAlsa`** — discovers ready-to-open A2DP playback PCMs
  (bluez-alsa v4 `ObjectManager` API) for BT-headphone/speaker audio.

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

See the `Bluez` moduledoc for every option (daemon binary paths, PubSub
wiring, `extra_children:` ordering guarantees) and the `Bluez.Gatt`
moduledoc for the full GATT event contract.

## Runtime requirements

- BlueZ ≥ 5.66, started by this supervisor with `-E` (experimental — needed
  for passive scanning and the GATT `MTU` property).
- dbus (this supervisor owns the *system* bus — don't run it next to a
  distro dbus/bluetoothd).
- Optional: bluez-alsa v4 for `audio: true`.
- Writable `/run/dbus` and `/data/bluetooth`; on a read-only rootfs point
  `/var/lib/bluetooth` at `/data/bluetooth` with an overlay symlink.

## Installation (git, for now)

Not yet on hex — the D-Bus layer uses a vendored
[rebus](https://github.com/ausimian/rebus) fork
([bbangert/rebus @ `dbus-service`](https://github.com/bbangert/rebus/tree/dbus-service))
that adds the service-side API (exported objects, replies, signals) this
library needs. It's pinned as a git submodule, so clone with:

```sh
git clone --recurse-submodules https://github.com/bbangert/bluez.git
# or, after a plain clone:
git submodule update --init
```

Then take it as a path or git dependency. Hex publication follows once the
rebus fork is reconciled upstream.

## License

Apache-2.0 — see [LICENSE](LICENSE).
