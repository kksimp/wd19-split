# WD19 VMM5331 — Phase 1 findings (2026-10-15)

Dock: WD19, MST fw 05.06.03 (bank 0). Source image: a full flash dump of the
author's dock (not published; verified against hub checksums).

## Image layout (per 128 KiB bank)

| Flash offset | Contents | Runtime RAM |
|---|---|---|
| 0x0000–0x00FF | fallback EDID ("SYN" 1024x768) | 0x1600 page (EDID presented upstream) |
| 0x0100–0x01FF | config block, byte 0x1FF = checksum | **0x1700–0x17FF** |
| 0x0400–0x040F | segment header | — |
| 0x0410–~0x17FFF | MCS-251 **source-mode** code | **FD:0000–FE:7BEF** |
| 0x1FFF0 / 0x1FFFF | bank tag / bank checksum | — |
| 0x40000–0x7FFFF | encrypted ESM (not touched) | — |

Ghidra: `80251:BE:24:default`, context `srcMode=1`, raw load at 0xFD0000 of
file[0x410:0x18000]. Scripts in `ghidra/scripts/`, output in `ghidra/out/`.
Hardware registers are reached through a window at direct addresses
0x40–0x48 (0x45–0x47 = address, 0x48 = command, 0x40–0x43 = data).

## Upstream EDID builder: FUN_RAM_fd1130

Called from fd1ab8, fd58ca, fd79fe (likely hot-plug/link handlers).

- `mode = cfg[0x140] & 0x0F` (RAM 0x1740). **Dell ships 0x03.**
- Finds the first connected downstream port (port map nibbles from
  cfg[0x141], default 0xA4), copies that monitor's EDID into 0x1600.
- `ports = RAM[0x1821] & 0x0F` (live value 2).
- mode 4: leave EDID alone.
- **mode 3: stop — pass the first monitor's EDID through unchanged (what
  we see today: macOS shows "HP E233", hub mirrors).**
- mode 0/1: overwrite vendor/product with Synaptics' (from RAM 0x395), then
  continue into the aggregate path.
- mode 2 (and 0/1) with ports > 1: aggregate path —
  `total_width = port_width * ports`; if `< 4096` use the real timing,
  otherwise fall back to 1920x1080 tiles (2160/1440-line panels) or
  1280x1024 tiles. Then rewrite header and checksums (0x167F, 0x16FF).

cfg[0x106] (RAM 0x1706) is a feature-flag byte used in ~10 functions:
bit0 (most used, per-port logic; firmware sets it itself at runtime in
fe0b98), bit3, bit5, bit6 (+ cfg[0x115]==2, the pair Dell enabled in
newer builds), bit7 (+ cfg[0x130] bit0). Current value 0x44.

## Live verification (read-only RC READ_MEMORY)

| RAM | Read | Meaning |
|---|---|---|
| 0x1700 | `20 00 83 83 00 00 44 00 …` | config copy ✓ |
| 0x1740 | `03` | mode 3 (pass-through) ✓ |
| 0x1600 | `00ffffffffffff00 220e5f34 01010101` | HP E233 EDID, matches macOS ✓ |
| 0x1821 | `0x52` → 2 | two monitors ✓ |
| 0x182E | `00` | port 0 selected ✓ |
| 0x1823 | `0780 0780` | per-port widths 1920, 1920 |

## Open question

Whether choosing the aggregate mode also programs the video path to send
the left/right halves to each output (vs. only changing the EDID). The
register programming lives behind the 0x31xxxx window (fe109a and
friends); a live test is cheaper than decoding it statically.

## Proposed next step (needs explicit OK — it is a write, RAM only)

1. Add an allowlisted `mst-poke` to dockctl (RC WRITE_MEMORY, only 0x1740).
2. Write 0x1740 = 0x02 (RAM only; dock power-cycle restores 0x03).
3. Replug one monitor's cable to re-run the EDID builder.
4. Observe: macOS resolution (expect 3840x1080), what each monitor shows,
   and re-read 0x1600.

## Live test result (2026-10-15)

RAM 0x1740 := 2 (RAM only), one monitor replugged at the dock:
- Hub rebuilt the upstream EDID: descriptor slot 4 (0x166C) became a
  3840x1080@60 DTD (278.10 MHz, 4120x1125 total, image size field 255x255 mm).
  First (preferred) DTD stays the HP's 1920x1080; basic size stays 51x29 cm.
- macOS offered it only as HiDPI: `3840x1080 (UI 1920x540)`.
- Driving 3840x1080 for 30 s: **the dock split the picture — left half on one
  HP, right half on the other.** Link stayed 2-lane HBR3.
- Remaining issue: macOS only offers the scaled (2x) variant, so the desktop
  looks zoomed. Need a 1x 3840x1080 mode.
