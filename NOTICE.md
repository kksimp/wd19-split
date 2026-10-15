# Notices

## fwupd

The dock and MST hub protocol in `app/Sources/DockCore` (HID-to-I2C bridge
commands, embedded-controller commands, VMM5331 "Panamera" register addresses
and remote-control command flow) follows the `dell-dock` plugin of
[fwupd](https://github.com/fwupd/fwupd):

- `plugins/dell-dock/fu-dell-dock-hid.c` — Copyright 2018 Realtek Semiconductor
  Corporation, Copyright 2018 Dell Inc.
- `plugins/dell-dock/fu-dell-dock-ec.c`, `fu-dell-dock-mst.c` — Copyright Dell Inc.

Those files are licensed `LGPL-2.1-or-later OR MIT`; this project uses them
under the MIT option.

## Trademarks

Dell and WD19 are trademarks of Dell Inc. Synaptics and ViewXpand are
trademarks of Synaptics Incorporated. Apple, Mac and macOS are trademarks of
Apple Inc. They are used here only to describe compatibility.

## Firmware

No Dell, Synaptics or other vendor firmware, firmware dumps or derived
disassembly is included in this repository.
