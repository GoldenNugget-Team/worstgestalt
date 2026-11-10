# WorstGestalt

Edit hidden device features on your iPhone with a tap. WorstGestalt is an
on-device editor for **MobileGestalt** — the system database Apple uses to
decide which hardware/software features your phone "has". By changing a value
in that database you can enable things Apple left turned off: the Dynamic
Island on devices without it, Always-On Display, Boot Chime on non-X devices,
Apple Pencil support, app-intents teapot CPU mode, and more.

Works on **iOS 26.0 – 26.7.2 and 27.x** (minimum deployment target:
iOS 26.0). Built without a Mac, via
**[xtool](https://github.com/xtool-org/xtool)**.

> ⚠️ **This is not a jailbreak.** The app uses the `containermanagerd` API and
> sandbox extensions to access a system cache — no exploits are persisted
> after you close the app and no modifications survive a restore.
>
> **But MobileGestalt is powerful:** wrong values can break system functions
> up to the point of requiring a reflash. Use it only on your own device and
> always keep a fresh backup (the app creates one automatically before every
> write — keep the "restore backup" button as a safety net).

## Features

- **Gestalt** — load the cache, search across all ~940 known keys
  (human-readable names from the Apple Wiki), edit values of any type
  (string / int / float / bool / data / json), delete and add keys.
- **Presets** — one-tap toggles for proven configurations: Dynamic Island
  (subtype), device name (App Store badge), Always-On Display (+ vibrancy),
  UIParallax, Liquid Glass low-perf, boot chime, 80 % charge limit,
  Tap to Wake, Camera Control, Apple Pencil, Collision SOS, Stage Manager,
  iPad apps, Apple Internal install, Internal Storage, SRD,
  Siri AI (US/LL) — with device spoofing when your model doesn't support it.
- **Backups** — automatic backup before every write, restore from the app,
  import from the Files app, export via ShareLink.
- **Log** — all bridge output, line by line, so you know exactly what happened.

## Install

### What you need

- iPhone or iPad on iOS 26.0 – 26.7.2 or 27.x.
- Developer Mode enabled (Settings → Privacy & Security → Developer Mode).
- Any sideload tool that can install an unsign-then-resign IPA.

### Option A — prebuilt IPA (recommended)

Grab the newest **`WorstGestalt-distr.ipa`** from the
[Releases page](https://github.com/GoldenNugget-Team/worstgestalt/releases)
and side-load it:

| Tool | Verdict |
|---|---|
| **AltStore / SideStore** | ✅ recommended — they register/fit the App Group to your team automatically |
| **GoldenNugget-mobile** | ✅ recommended — same |
| [worstload](https://github.com/GoldenNugget-Team) | ✅ mini-CLI sideloader (private — ask in the Discord) — registers the requested App Group verbatim; use this with a paid Apple ID if your usual tool can't register groups |
| Feather | ❌ — does not register App Groups on the portal → the class-7 escape won't work |
| Other paid-cert installers | ❌ — a paid certificate **without a registered App Group** is not enough; use worstload |

> The **App Group** (`group.com.awesomenull.worstgestalt`) is what powers
> Backend A. If you install with a tool that doesn't register groups, the app
> still works on iOS 26.x via Backend B (no App Group needed) — the main
> scenarios are covered there too.

### Option B — build from source

Build and install straight from Linux or macOS without Xcode via
[xtool](https://github.com/xtool-org/xtool):

```bash
# 1. One-time quick setup: app id, Apple ID login, install the SDK
xtool setup

# 2. Build  (and 3. install on a connected iPhone)
xtool dev build --run
# or an ipa to re-sign and sideload yourself:
xtool dev build --ipa
```

`xtool.yml` can point at your own bundle ID — see
[Changing the app ID / App Group](#changing-the-app-id--app-group).

### If you're a developer working from WSL

Building from Windows Subsystem for Linux needs a small usbmuxd proxy tweak —
the full walkthrough is in
[docs/wsl-usbmuxd.md](docs/wsl-usbmuxd.md).

## How it works

1. **Backend A — worse_query** (Taj C, forcequitOS, GPL-3.0): the app creates
   a symlink `App Group/Library/Caches` → target path, sends
   `containermanagerd` a class 7 (App Group) `container_query`, and the
   kernel issues a sandbox token already tied to the target vnode.
2. **Backend B — bad_query** (same author): a class 13
   (`systemgroup.com.apple.mobilegestaltcache`) `container_query` + path
   traversal via `part_domain` — works on iOS 26.x and needs no App Group.
3. With the token the app reads the plist, edits `CacheExtra`, serializes and
   writes **in place** (`open(O_WRONLY)` + `ftruncate` + `write` + `fsync`) —
   a rename would create a new inode and the sandbox token bound to the old
   vnode would break. After writing, the plist is re-read and verified.
4. Before every write — an automatic backup of the raw bytes into
   `Documents/Backups/`.

## Troubleshooting

**The icon in the list says the escape test failed / wrong backend?**
The app tells you which backend is available when it loads. Backend A needs
the App Group registered properly — reinstall with AltStore / SideStore /
GoldenNugget-mobile / worstload, or use Backend B on iOS 26.x.

**Something broke after restoring a value.**
Open the app → Backups → restore the most recent backup (or import an
external backup from the Files app). If the springboard has already
misbehaved, reboot: MobileGestalt values only get written when the phone
re-reads the plist on boot, so a good backup restore before a reboot is
almost always enough. Keep iTunes/Finder (or idevicebackup) backups too —
a reflash is the last resort for a reason.

**My changes don't show up.**
MobileGestalt changes are picked up at boot (or when the reading app
re-checks). Apply the preset, then respring/reboot as the preset instructs.

## Changing the app ID / App Group

| What | Where |
|---|---|
| bundle ID | `xtool.yml` → `bundleID` |
| App Group | `Sources/WorseGestalt/Config.swift` + `entitlements.plist` |

Backend B (bad_query) does **not** require an App Group — if you are on a
free account and the build/signing fails on the App Group, you can drop
`entitlementsPath` from `xtool.yml` and set `appGroup = ""` in
`Config.swift`: only the bad_query path remains (iOS 26.x / 27.x main
scenarios covered). The App Group is only needed for backend A
(worse_query).

## Repository tour

| Path | What's inside |
|---|---|
| `Sources/WorseGestalt/` | the app (SwiftUI + BQCore bridge engine) |
| `Sources/CQueryBridges/` | the Objective-C escapes, incl. `worse_query.m` |
| `tools/car/` | project-specific icon-catalog generator (info: [docs/appicon.md](docs/appicon.md)) |
| `docs/` | developer notes on the `.car` format, WSL build loop, icon |
| `Assets.car`, `AppIcon.png`, `AppIcon.icon/` | the icon (compiled, fallback, Liquid Glass source) |

## Sources

- https://github.com/forcequitOS/worse_query and
  https://github.com/forcequitOS/bad_query — ObjC/C escapes
  (GPL-3.0, © Taj C / forcequit)
- https://theapplewiki.com/wiki/List_of_MobileGestalt_keys — key reference
  (CC BY-SA) → `tools/gen_keymap.py`
- Preset pool (CL keys) — Nugget / GestaltEdit / Apple Wiki community
- https://github.com/xtool-org/xtool — building and installing without Xcode

## Licenses

**GPL-3.0-or-later** — see [`LICENSE`](LICENSE). The escape code is GPL-3.0
(© Taj C / forcequitOS; ported from worse_query). The KAMUI engine ported to
Swift lives in `Sources/WorseGestalt/BQCore.swift` (MIT, © 2026 KAMUI
contributors — `KamuiEngine-LICENSE`). The NeoSpring respring is by
@neonmodder123 & @skadz108 (`rooootdev/neospring`, via GoldenNugget-mobile).
The key reference is CC BY-SA 4.0 (Apple Wiki).

**Author:** awesomenull · engine: KAMUI · NeoSpring respring: @neonmodder123
& @skadz108 · escapes: Taj C, forcequitOS.
