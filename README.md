# Kodoku (`sfai05/Aidoku` Fork)

**Kodoku** (`io.github.sfai05.Kodoku`) is a personal fork of [Aidoku](https://github.com/Aidoku/Aidoku) designed for **free Apple ID / SideStore sideloading** and **self-hostable cross-device sync via PocketBase**, while keeping upstream merges minimal and cleanly isolated.

## Differences vs. Upstream Aidoku

| Area | Upstream Aidoku | Kodoku (`sfai05/Aidoku`) |
|---|---|---|
| **Signing & Entitlements** | Uses CloudKit, Push Notifications (`aps-environment`), and custom fonts entitlement | Removes paid-developer-only entitlements (`aps-environment`, iCloud/CloudKit/Ubiquity, `user-fonts`, `remote-notification`) so it builds and runs cleanly with a free Apple ID (Personal Team); keeps local notifications and `BGProcessingTask` / `fetch` |
| **Cross-Device Sync** | `NSPersistentCloudKitContainer` (iCloud / CloudKit) | **PocketBase Sync Engine** (`SyncStorageProvider` + `SyncEnvelope` gzip snapshots with `revision` optimistic locking, SHA-256 verification, tombstones, and non-destructive background smart merge) |
| **Sync Triggers & Battery** | Black-box iOS CloudKit & APNs scheduling | 60s default change debounce (configurable 5–120s), automatic foreground pull, lock-screen / background `UIBackgroundTask` flush, and disk flush on termination |
| **Sync UI & Recovery** | Single iCloud Sync toggle | Dedicated **Settings → PocketBase Sync** dashboard (Green/Yellow/Red indicator, counts, setup wizard using transient Superuser credentials or manual `docs/sync/pb_schema.json` import, Keychain-only `users` auth, Sync Logs viewer, Force Sync/Push/Pull, historical snapshot rollback, cleanup, and cursor reset) |
| **Upstream Isolation** | Core codebase + `Localizable.strings` | New sync engine & UI live in `Aidoku/Core/Sync/` and `Aidoku/Features/Settings/Sync/` with separate `ForkLocalizable.strings` (`en` / `zh-Hant`), `ForkSync.` defaults keys, and zero edits to `Aidoku.xcdatamodeld` or `project.pbxproj` |

### Installing Kodoku (SideStore / AltStore)

1. Open **SideStore** (recommended) or **AltStore**, navigate to **Sources**, and add:
   ```
   https://raw.githubusercontent.com/sfai05/Aidoku/altstore/apps.json
   ```
2. Install **Kodoku** (or upgrade in-place when new builds publish), or download the latest unsigned `.ipa` from [GitHub Releases](https://github.com/sfai05/Aidoku/releases).
3. To enable cross-device sync, open **Settings → PocketBase Sync**, create the collection with the **One-Time Setup Wizard** (or import `docs/sync/pb_schema.json` in PocketBase Admin UI `/_/`), and sign in with a regular PocketBase **`users`** collection account on each device.

> Note: Sync transfers your library, manga edits, reading history, chapters, categories, tracking links, reading sessions, updates, vocabulary, custom source configs, and source list URLs. Safe app settings are **off by default** (and sensitive keys matching `login`/`password`/`token`/`auth`/`cookie` are stripped even when enabled). External `.aix` sources and offline downloads are installed per device.

---

## Upstream Aidoku README

# Aidoku

A free and open source manga reading application for iOS, iPadOS, and macOS.

<p>
	<img src="https://raw.githubusercontent.com/Aidoku/Website/refs/heads/main/static/images/library-noframe.png" width="25%" alt="Library">
	<img src="https://raw.githubusercontent.com/Aidoku/Website/refs/heads/main/static/images/source-noframe.png" width="25%" alt="Source">
	<img src="https://raw.githubusercontent.com/Aidoku/Website/refs/heads/main/static/images/reader-noframe.png" width="25%" alt="Reader">
</p>

## Features

- No ads
- Local file reading (CBZ)
- Built-in reading service providers (Komga, Kavita, Suwayomi)
- WASM external source system
- Downloads
- Tracker integration (AniList, MyAnimeList, etc.)
- OCR dictionary lookup

## Installation

For detailed installation instructions, check out [the website](https://aidoku.app).

### TestFlight

To join the TestFlight, you will need to join the [Aidoku Discord](https://discord.gg/kh2PYT8V8d).

### AltStore

We have an AltStore repo that contains the latest releases ipa. You can copy the [direct source URL](https://raw.githubusercontent.com/Aidoku/Aidoku/altstore/apps.json) and paste it into AltStore. Note that AltStore PAL is not supported.

### Manual Installation

The latest ipa file will always be available from the [releases page](https://github.com/Aidoku/Aidoku/releases). Nightly ipas are also built on each commit, but it's not recommended to use these since they may have in-progress changes that could cause issues when updating later.

## Contributing

Aidoku is still in a beta phase, and there are a lot of planned features and fixes. If you're interested in contributing, I'd first recommend checking with me on [Discord](https://discord.gg/kh2PYT8V8d) in the app development channel.

This repo (excluding translations) is licensed under [GPLv3](https://github.com/Aidoku/Aidoku/blob/main/LICENSE), but contributors must also sign the project [CLA](https://gist.github.com/Skittyblock/893952ff23f0df0e5cd02abbaddc2be9). Essentially, this just gives me (Skittyblock) the ability to distribute Aidoku via TestFlight/the App Store, but others must obtain an exception from me in order to do the same. Otherwise, GPLv3 applies and this code can be used freely as long as the modified source code is made available.

### Translations

Interested in translating Aidoku? We use [Weblate](https://hosted.weblate.org/engage/aidoku/) to crowdsource translations, so anyone can create an account and contribute!

Translations are licensed separately from the app code, under [Apache 2.0](https://spdx.org/licenses/Apache-2.0.html).
