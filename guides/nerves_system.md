# Nerves system requirements

The official Nerves systems ship **neither BlueZ nor dbus**, so this
library needs a customized system. This guide lists exactly what that
system must add — every item below was hardware-found bringing the stack
up on Raspberry Pis (a known-good reference implementation for eight
targets lives at
[`bbangert/nerves_systems_universal_proxy`](https://github.com/bbangert/nerves_systems_universal_proxy)).

## Buildroot packages (`nerves_defconfig`)

```text
BR2_PACKAGE_DBUS=y
BR2_PACKAGE_BLUEZ5_UTILS=y
```

`BLUEZ5_UTILS` installs `bluetoothd` at
`/usr/libexec/bluetooth/bluetoothd` — the library's default
`bluetoothd_path:`. BlueZ must be ≥ 5.66 for the
`AdvertisementMonitorManager1` passive-scanning API (the library always
starts the daemon with `-E`).

For `audio: true`, additionally:

```text
BR2_PACKAGE_BLUEZ_ALSA=y
```

bluez-alsa's PCM is a **userspace ALSA plugin** — no kernel audio config
is needed (unlike, say, `snd-usb-audio`). Buildroot ships bluez-alsa 4.x,
whose daemon is named `bluealsad`; the library probes both the v4 and v3
binary names. The stock package builds SBC only — fine for A2DP; codec
extras (AAC etc.) have licensing implications and are your call.

### Radio firmware blobs

- **Raspberry Pi onboard radios**: `BR2_PACKAGE_RPI_DISTRO_BLUEZ_FIRMWARE=y`
  (a `nerves_system_br` package) installs the Pi `.hcd` set with the
  per-board symlinks (e.g.
  `BCM4345C0.raspberrypi,3-model-b-plus.hcd → BCM4345C0.hcd`), so the
  kernel's `btbcm` picks the right patchram file from the device tree
  compatible string. (Trivia that bites raw-HCI stacks: LMP subversion
  `0x6119` is BCM4345**C0** — Pi 3 B+/3 A+ — while `0x6606` is C5, Pi
  400/CM4. The kernel path gets this right by itself.)
- **Realtek USB dongles** (RTL8761B/BU — most cheap "BT 5.0" dongles):
  `BR2_PACKAGE_LINUX_FIRMWARE=y` + `BR2_PACKAGE_LINUX_FIRMWARE_RTL_87XX_BT=y`
  for the `rtl_bt/` blobs.

## Kernel fragment

For a UART-attached radio (Pi onboard chips) the kernel must auto-attach
`hci0` via serdev:

```text
CONFIG_BT=y
CONFIG_BT_BREDR=y
CONFIG_BT_LE=y
CONFIG_BT_HCIUART=y
CONFIG_BT_HCIUART_SERDEV=y
CONFIG_BT_HCIUART_BCM=y
# THE GOTCHA — see below:
CONFIG_SERIAL_DEV_BUS=y
CONFIG_SERIAL_DEV_CTRL_TTYPORT=y
```

**The gotcha**: `CONFIG_BT_HCIUART_SERDEV` only *depends on*
`SERIAL_DEV_BUS` — it does **not** `select` it. If `SERIAL_DEV_BUS` is in
neither your fragment nor the base defconfig, `make olddefconfig`
**silently drops `BT_HCIUART_SERDEV` back to `n`**: the firmware boots,
`bluetoothd` runs, the `.hcd` files are present, the device tree is
correct — and `/sys/class/bluetooth/` stays empty with zero BT lines in
dmesg. When writing kernel fragments, list every `depends on`
prerequisite explicitly; `olddefconfig` only auto-resolves `select`ed
symbols.

For USB dongles (also the only path on boards without an onboard radio):

```text
CONFIG_BT_HCIBTUSB=y
CONFIG_BT_HCIBTUSB_BCM=y
CONFIG_BT_HCIBTUSB_RTL=y
CONFIG_BT_HCIBTUSB_MTK=y
```

`btusb` probes on USB enumeration — no attach step, independent of the
serdev path above. With both configured, onboard and USB radios coexist
and `desired_adapter:` picks which one this library drives.

## Device tree (Raspberry Pi)

The Pi systems must keep the Bluetooth child node under the mini-UART
(the `miniuart-bt` arrangement the upstream Nerves Pi systems already
use — BT on `/dev/ttyS0`, leaving the PL011 for the console). The serdev
kernel path binds that node and auto-attaches the chip; nothing in
userspace touches the UART.

Known boot-timing caveat on the Pi 3 B+: the serdev probe can race
rootfs availability, so the onboard radio occasionally enumerates
seconds late. See the adapter-selection notes in the
[architecture guide](architecture.md) for how that interacts with
`desired_adapter:`.

## App-side rootfs overlay

These live in the *application's* `rootfs_overlay` (not the system),
since they're policy, not plumbing:

- **`/var/lib/bluetooth → /data/bluetooth` symlink.** `bluetoothd`
  persists adapter identity and link keys under `/var/lib/bluetooth`,
  which is read-only squashfs on Nerves. `Bluez.prepare_runtime/0`
  creates `/data/bluetooth` (mode `0700`) at start; the symlink makes
  the daemon land there.

  ```text
  rootfs_overlay/var/lib/bluetooth -> /data/bluetooth
  ```

- **`/etc/bluetooth/main.conf`** (optional but recommended for passive
  scanning): BlueZ's default AdvMonitor scan duty cycle is aggressive
  (~50%), and every received advert becomes a `PropertiesChanged` signal
  your BEAM must D-Bus-decode — at ~50% duty this can dominate CPU on a
  small device. A ~10% duty cycle cuts the advert rate ~5× with no
  practical loss for sensor scanning:

  ```ini
  [LE]
  ScanIntervalAdvMonitor=480   # 300 ms
  ScanWindowAdvMonitor=48      # 30 ms
  ```

  (bluetoothd 5.79 logs a cosmetic "Unknown key" warning for these — a
  key-validation whitelist typo upstream; the values are applied, and
  the warning disappears on later BlueZ versions.)

## What the library handles itself

No system/overlay work is needed for: `/run/dbus` + the bus socket +
machine-id (created/cleaned by `Bluez.prepare_runtime/0`), daemon
supervision (`MuonTrap`, no init scripts — do **not** enable the
buildroot dbus/bluetoothd init scripts), or agent/monitor registration.

## Checklist

A new target is ready when, on hardware:

1. `ls /sys/class/bluetooth` shows `hci0` shortly after boot (serdev or
   btusb did its job).
2. `Bluez` starts and `Bluez.Client.adapters_info/0` lists the adapter
   with its MAC.
3. Passive scanning delivers adverts to your `on_advertisement:` fun.
4. With `audio: true`: `bluealsad` stays up (check the logs) and
   `Bluez.BlueAlsa.pcms/0` answers `[]` (not an exit) with no headset
   connected.
