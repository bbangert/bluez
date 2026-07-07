# Changelog

## v0.1.0 (unreleased)

Initial extraction from
[`universal_proxy`](https://github.com/bbangert/universal_proxy), where this
stack shipped as a hardware-validated ESPHome Bluetooth proxy on Raspberry
Pis.

- `Bluez` supervisor: dbus-daemon → bluetoothd → scanning/GATT/pairing
  clients → optional bluez-alsa pair → host `extra_children:`, under
  `:rest_for_one` with an explicit restart budget.
- `Bluez.Client`: passive (`AdvertisementMonitor1`) and active
  (`StartDiscovery`) scanning with serialized, watchdogged mode
  transitions; advert reconstruction + emit-gating; adapter enumeration.
- `Bluez.Gatt`: handle-keyed GATT client (connect/services/read/write/
  notify/pair/unpair/clear-cache) with a host-agnostic, documented event
  contract (`on_gatt_event:`).
- `Bluez.Agent`: NoInputNoOutput pairing agent scoped to stack-initiated
  pairings.
- `Bluez.BlueAlsa`: A2DP playback PCM discovery (bluez-alsa v4
  ObjectManager API) with change broadcasts.
- Host seams throughout: `on_advertisement:`, `on_gatt_event:`,
  `on_connections_changed:`, `pubsub:`, `desired_adapter:`, `audio:`,
  daemon binary paths, `extra_children:`.
- D-Bus layer on a vendored [rebus](https://github.com/ausimian/rebus)
  fork (service-side API), pinned as a git submodule.
