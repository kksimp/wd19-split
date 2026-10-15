# WD19 Split — app

See the [top-level README](../README.md) for what this does, requirements and
safety boundaries.

- `build_app.sh` builds `dist/WD19 Split.app` and `dist/dockctl` (release),
  signing with your first Apple Development identity or `SIGN_ID`.
- `Sources/DockCore` — C library: HID bridge, dock EC and MST hub access.
  The only hub write is `dc_mst_set_edid_mode` (hub RAM `0x1740`).
- `Sources/dockctl` — command-line tool on top of DockCore.
- `Sources/WD19Split` — SwiftUI app (hub controller, display modes,
  two-display layout, self-test via `--selftest-two N`).
- `Sources/VirtualDisplay` — declarations for CoreGraphics' virtual displays.
