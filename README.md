# Dokuha (`sfai05/Aidoku` Fork)

**Dokuha** (`io.github.sfai05.Dokuha`) is a personal fork of [Aidoku](https://github.com/Aidoku/Aidoku) designed for **free Apple ID / SideStore sideloading** and **self-hostable cross-device sync via PocketBase**, while keeping upstream merges minimal and cleanly isolated.

## Differences vs. Upstream Aidoku

| Area | Upstream Aidoku | Dokuha (`sfai05/Aidoku`) |
|---|---|---|
| **Signing & Entitlements** | Uses CloudKit, Push Notifications (`aps-environment`), and custom fonts entitlement | Removes paid-developer-only entitlements (`aps-environment`, iCloud/CloudKit/Ubiquity, `user-fonts`, `remote-notification`) so it builds and runs cleanly with a free Apple ID (Personal Team); keeps local notifications and `BGProcessingTask` / `fetch` |
| **Cross-Device Sync** | `NSPersistentCloudKitContainer` (iCloud / CloudKit) | **PocketBase Sync Engine** (`SyncStorageProvider` + `SyncEnvelope` gzip snapshots with `revision` optimistic locking, SHA-256 verification, tombstones, and non-destructive background smart merge) |
| **Sync Triggers & Battery** | Black-box iOS CloudKit & APNs scheduling | 60s default change debounce (configurable 5–120s), automatic foreground pull, lock-screen / background `UIBackgroundTask` flush, and disk flush on termination |
| **Sync UI & Recovery** | Single iCloud Sync toggle | Dedicated **Settings → PocketBase Sync** dashboard (Green/Yellow/Red indicator, counts, setup wizard using transient Superuser credentials or manual `docs/sync/pb_schema.json` import, Keychain-only `users` auth, Sync Logs viewer, Force Sync/Push/Pull, historical snapshot rollback, cleanup, and cursor reset) |
| **Metadata Editing & MangaBaka Pull** | Basic cover customization & source refresh locks | In-app **Edit Metadata** editor (`...` menu for bookmarked & local manga covering Cover, Title, Authors, Artists, Status, Content Rating, Description, Tags + per-field source reset) and **MangaBaka Pull** diff sheet (tracked-gated, multi-language title & description picking from MangaBaka + MangaDex/Bangumi including auto Traditional Chinese conversion, original-language author/artist names via AniList, browsable all-covers volume gallery picker via MangaBaka `/images`, Content Rating mapping, local-only `Title Language Priority`, and PocketBase per-field `EditedKeys` sync preservation) |
| **MangaBaka Tracking & Auth** | OAuth only (frequent session drops, `Int`-only progress decoding, silent `PATCH`/404 failures) | Supports long-lived **Personal Access Token (`mb-...` via `x-api-key`)** stored in iOS Keychain and verified via `/v1/my/profile` (non-destructive switching preserves tracked manga links), hardened OAuth refresh (RFC 3986 form encoding, concurrent refresh coalescing, token preservation on transient errors), decimal chapter/volume/rating decoding, remote 404 fallback + `POST` auto-create, `en_US_POSIX` `YYYY-MM-DD` date handling, and fixed `finish_date` encoding |
| **Library Filter & Sort** | Buried in `...` submenus; menu checkmarks fail to update live on tap | Dedicated top-bar Filter & Sort button opening a grouped-card SwiftUI sheet with live matching title count, single-row horizontal Sort bar, tri-state Filter pills (include / exclude / clear), direct Content Rating pills, expandable Sources / Categories cards, tuned initial detent height, a non-overlapping removable active filter chips strip with dynamic horizontal scroll edge fade stacked below the category bar, and a quick `Clear Filters` empty-state action |
| **Library Category Bar** | Single dropdown menu (`All v`) requiring two taps to switch categories + redundant search bar | One-tap edge-to-edge horizontal scrollable capsule pill bar with dynamic scroll edge fade, lock indicators, distinct Filter Group pill styling, auto-scroll to active selection, and strengthened cover title contrast scrim (redundant in-library search bar removed in favor of the tab-bar Search tab) |
| **Upstream Isolation** | Core codebase + `Localizable.strings` | New fork code lives cleanly in `Aidoku/Core/Sync/`, `Aidoku/Features/Settings/Sync/`, `Aidoku/Core/Metadata/`, `Aidoku/Features/Manga/Metadata/`, `Aidoku/Features/Library/Fork/`, `Aidoku/Core/Tracking/Fork/`, and `Aidoku/Features/Settings/Tracking/` with separate `ForkLocalizable.strings` (`en` / `zh-Hant`), `ForkSync.`/`Fork.` defaults keys, isolated fork CI workflows (`fork-release.yml`, Ubuntu-based `fork-lint.yml`), and zero edits to `Aidoku.xcdatamodeld` or `project.pbxproj` |

### Installing Dokuha (SideStore / AltStore)

1. Open **SideStore** (recommended) or **AltStore**, navigate to **Sources**, and add:
   ```
   https://raw.githubusercontent.com/sfai05/Aidoku/altstore/apps.json
   ```
2. Install **Dokuha** (or upgrade in-place when new builds publish), or download the latest unsigned `.ipa` from [GitHub Releases](https://github.com/sfai05/Aidoku/releases).
3. To enable cross-device sync, open **Settings → PocketBase Sync**, create the collection with the **One-Time Setup Wizard** (or import `docs/sync/pb_schema.json` in PocketBase Admin UI `/_/`), and sign in with a regular PocketBase **`users`** collection account on each device.

> Note: Sync transfers your library, manga edits, reading history, chapters, categories, tracking links, reading sessions, updates, vocabulary, custom source configs, and source list URLs. Safe app settings are **off by default** (and sensitive keys matching `login`/`password`/`token`/`auth`/`cookie` are stripped even when enabled). External `.aix` sources and offline downloads are installed per device.
>
> Note: User-initiated **Pull from MangaBaka** actions query public, unauthenticated third-party endpoints (AniList, MangaDex, and Bangumi) using the tracked series ID or title solely to enrich original-language staff names and localized synopses. No user credentials or personal data are sent.

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
