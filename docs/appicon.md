# The app icon (`Assets.car`) — how it's built

> Dev notes. The user-facing instructions live in the [README](../README.md).

The icon is shipped as a real compiled `Assets.car`, built by **our pure-Python
CoreUI compiler** — a standalone sibling project,
[`coreui-car`](../../coreui-car) (`~/Projects/coreui-car`; a from-scratch
implementation of Apple's BOM/CoreUI catalog format based on the research at
https://dbg.re/posts/car-file-format/ and cross-validated against real
Xcode-built catalogs shipped inside the iOS SDK; the Rust crate
`skytoup/car-parser` was used as an independent verifier). This repo only
keeps the project-specific generator `tools/car/make_icon_car.py`, which
imports the library from the sibling directory.

The catalog mirrors the AppIcon facet of a real Xcode iOS app catalog exactly:

- one `MultisizeImage` holder rendition (`AppIcon`, Part 218, `SISM` payload),
- plus the light and dark 1024×1024 content renditions (Part 220) with
  gzip-compressed BGRA bitmaps (MLEC v3/v1, `KCBC` chunks of 341 pixel rows
  + a 1-row tail), wired through `CFBundleIcons` → `CFBundlePrimaryIcon` →
  `CFBundleIconName: AppIcon` like actool would.

Two device-verified gotchas are encoded by the generator:

1. the facet/rendition **Identifier must be < 0x8000** — larger values read
   negative as signed `int16` and springboard silently falls back to a
   placeholder;
2. only chunked **MLEC v1/v3** payloads render — bare v0 payloads are ignored
   by on-device CoreUI.

Practical notes:

- Regenerate the catalog after changing the artwork:
  `python3 tools/car/make_icon_car.py` (renders via `tools/preview_icon.py`,
  compiles via the sibling `coreui-car` project, writes `Assets.car`).
  PNG previews land in `IconPreview/`.
- Verify a `.car` independently: the Rust crate's `car-cli info Assets.car`.
- Library docs, tests (round-trips of real Apple catalogs) and the generic
  `build_car.py` CLI live in the `coreui-car` project.
- Fallback: `AppIcon.png` (flat icon via `iconPath`) stays in the bundle —
  iOS 26 automatically applies its Liquid Glass bezel to legacy icons if the
  catalog lookup ever fails.
- `AppIcon.icon/` remains the hand-authored Liquid Glass source
  (glass/specular/blur layers) for a future Xcode/Icon Composer build.
