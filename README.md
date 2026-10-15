# WD19 Split

**Two external monitors on a Mac that only supports one, through a Dell WD19 dock.**

Base Apple silicon chips (M1, M2, …) have a single display engine for external
screens, and macOS doesn't do DisplayPort MST. A Dell WD19 on those Macs just
mirrors the same picture to every monitor. WD19 Split fixes that without
drivers, kernel extensions or firmware changes:

- the Mac sends **one wide picture** (e.g. 3840×1080), which it can do;
- the dock's own Synaptics VMM5331 hub **splits it** across its two outputs,
  using a display mode the hub already supports (ViewXpand) but that Dell
  ships switched off;
- optionally, the app presents the two halves to macOS as **two separate
  displays**, each with its own Dock, menu bar, full-screen space and window
  snapping.

It is a small menu bar app plus a command-line tool, written in Swift and C.

## Layouts

| Layout | What macOS sees | Notes |
|---|---|---|
| **Mirror** | one monitor, copied to both screens | Dell's default |
| **Ultrawide** | one 3840×1080 display spanning both screens | zero added latency; works with protected video |
| **Two displays** | two separate 1920×1080 displays | one frame of latency; **Swap sides** toggle; protected video shows black (by design) |

Every layout change shows a **Keep / Revert** prompt that reverts on its own
after 15 seconds, like System Settings does for resolution changes.

## Requirements

- A Mac on macOS 14 or later (developed on an M2 MacBook Pro, macOS 27).
- A Dell **WD19** (Salomon family) whose MST hub runs firmware **05.06.03**.
  The app checks the dock type, the hub firmware version and the hub's memory
  layout, and refuses anything it hasn't been verified against.
- Two monitors on the dock. Identical panels work best: the hub combines them
  side by side, and the combined width must stay under 4096 pixels.
- Xcode command-line tools (Swift 6) to build.

Other WD19 hub firmware versions, the WD22 and the newer WD25 family use
different hub chips or layouts and are not supported.

## Build and run

```bash
git clone https://github.com/kksimp/wd19-split.git
cd wd19-split
scripts/install_hooks.sh     # optional: secret-scan hooks for contributors
app/build_app.sh             # -> app/dist/WD19 Split.app and app/dist/dockctl
open "app/dist/WD19 Split.app"
```

`build_app.sh` signs with your first "Apple Development" identity if you have
one (so macOS privacy permissions survive rebuilds), otherwise ad-hoc. Set
`SIGN_ID` to choose another.

## Using it

1. Open **WD19 Split**. Its window (and the menu bar icon, if macOS shows it)
   lists the dock, hub firmware and connected monitors.
2. Pick **Ultrawide** or **Two displays**.
3. The first time after the dock powers up, the window may ask you to **unplug
   one monitor at the dock and plug it back in**. The hub only rebuilds the
   display description it gives the Mac when a monitor is plugged in.
4. **Two displays** asks once for **Screen Recording** permission (System
   Settings → Privacy & Security → Screen & System Audio Recording). That is
   how it draws the two virtual displays onto the real signal.
5. **Restore Dell defaults** puts the dock back to mirroring.

Settings: open at login, re-apply your layout whenever the dock connects, and
HiDPI for the ultrawide layout.

## What it changes — and what it never does

- **Changes:** one byte in the hub's RAM (upstream display mode at `0x1740`:
  `3` = Dell's mirror, `2` = split) and your Mac's display configuration.
  Unplugging the dock's power restores Dell's defaults completely.
- **Never:** writes the dock's firmware or flash, touches the hub's encrypted
  security / HDCP region, or disables or works around HDCP or any other
  content protection.
- Every hub write in the code goes through a single allowlisted function
  (`dc_mst_set_edid_mode` in `app/Sources/DockCore`).
- The two-display layout uses macOS's standard ScreenCaptureKit, which leaves
  protected content black. Use Ultrawide for streaming video.
- If the app quits or crashes, macOS removes its virtual displays by itself
  and the screens fall back to the ultrawide desktop.

## How it works

```
Mac (one external display engine)
  └─ USB-C, DisplayPort alt mode, single stream ──► WD19 dock
                                                     └─ Synaptics VMM5331 MST hub
                                                          ├─ left half  ──► monitor 1
                                                          └─ right half ──► monitor 2
```

- **Talking to the dock.** The dock exposes a vendor HID device
  (`413c:b06e`, the RTS5487 hub's HID-to-I2C bridge). Through it the app
  reaches the dock's embedded controller and the MST hub, using the protocol
  documented by [fwupd](https://github.com/fwupd/fwupd)'s `dell-dock` plugin.
  This is ordinary userspace IOKit HID: no driver, no SIP changes.
- **The switch.** The hub copies its config block to RAM at boot. Its EDID
  builder reads the low nibble of `0x1740`: mode 3 passes the first monitor's
  EDID through (mirror), mode 2 builds a combined timing of
  `monitor width × number of monitors` and splits the video accordingly.
- **The Mac side.** macOS hides the unscaled 3840×1080 mode from its public
  API; the app selects it through the same window-server mode table System
  Settings uses. For two displays it creates two `CGVirtualDisplay`s, captures
  them with ScreenCaptureKit, draws them side by side on a borderless overlay
  covering the real display, keeps the pointer on the virtual panels, and
  parks the real display where it doesn't steal the Dock or menu bar.

The full reverse-engineering notes (flash layout, MCS-251 source-mode
disassembly, the EDID builder, live verification) are in
[`research/PHASE1_FINDINGS.md`](research/PHASE1_FINDINGS.md). Firmware images,
dumps and disassembly output are deliberately **not** in this repository; the
Ghidra scripts and tools to reproduce them from Dell's public firmware are.

## Command-line tool

```bash
app/dist/dockctl info              # dock model, versions
app/dist/dockctl mst-status        # hub bootloader status, active bank
app/dist/dockctl mst-mem 0x1740 4  # read hub RAM
app/dist/dockctl mst-poke 0x1740 2 # the one write: 2 = split, 3 = Dell default
```

## Troubleshooting

- **Log:** `~/Library/Logs/WD19Split.log` records every step of a layout change.
- **Self-test:** `open -n "app/dist/WD19 Split.app" --args --selftest-two 15`
  turns the two-display layout on for 15 s without prompts, checks frames,
  pointer guard and Dock placement, writes pictures next to the log, then
  undoes everything.
- **No menu bar icon:** macOS hides menu bar items when the bar is full or the
  app isn't allowed there; opening the app again always shows its window.
- **Clicking the desktop hides all windows:** that's macOS's "Click wallpaper
  to reveal desktop" (System Settings → Desktop & Dock → set it to
  "Only in Stage Manager").
- **Don't run Dell's dock firmware updater** if you want to keep using this:
  a new hub firmware version is refused until it has been verified.

## Project layout

```
app/Sources/DockCore       C library: HID bridge, dock EC and MST hub access
app/Sources/dockctl        command-line tool
app/Sources/WD19Split      SwiftUI app: hub control, display modes, two-display layout
app/Sources/VirtualDisplay declarations for CoreGraphics' virtual display classes
research/                  findings, Ghidra scripts, firmware-package extractor
scripts/                   secret scan and git hooks
```

## Credits and disclaimer

The dock and hub protocol follows fwupd's `dell-dock` plugin (see
[NOTICE.md](NOTICE.md)). This is an independent interoperability project, not
affiliated with or endorsed by Dell, Synaptics or Apple. Use at your own risk;
it only changes volatile settings, and a dock power cycle undoes them.

Licensed under the [MIT License](LICENSE).
