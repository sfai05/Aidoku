# AGENTS.md — Fork Engineering & Upstream Sync Guide

## Project Context

This repository (`sfai05/Aidoku`) is a personal fork of [`Aidoku/Aidoku`](https://github.com/Aidoku/Aidoku).
The primary goals of this fork are:
1. **Free Apple ID & Sideload First**: Compile and run cleanly with a free Apple ID (Personal Team) and distribute wireless updates/re-signing via **SideStore** (while remaining compatible with **AltStore**).
2. **Reliable Self-Hostable & Cloud Sync**: Replace iCloud/CloudKit sync with a transparent, debuggable sync engine backed first by **PocketBase** (supporting both self-hosted instances and PocketBaseCloud / third-party hosts).
3. **Long-Term Upstream Maintainability**: Keep all fork changes modular, minimally invasive, and easy to merge/rebase as upstream `Aidoku/Aidoku` evolves.

---

## Communication & Language Rules

- **Interactive Session Chat**: Always communicate with the user in **Traditional Chinese (繁體中文)** unless explicitly asked otherwise.
- **Repository & GitHub Artifacts**: Write **all** GitHub Issues, PR titles/descriptions, PR review comments, commit messages, code comments, and documentation in **English**.

---

## Git, Branching & Review Workflow

- **Remotes**:
  - `origin`: `https://github.com/sfai05/Aidoku.git` (your fork)
  - `upstream`: `https://github.com/Aidoku/Aidoku.git` (push **disabled**; fetch/merge only)
  - **NEVER** push commits, file issues, or open pull requests against `Aidoku/Aidoku`. Always verify targets point to `sfai05/Aidoku`.
- **Branching**:
  - **Never** commit feature, fix, or configuration work directly to `main`.
  - Always branch off `main` using descriptive names: `feat/<topic>`, `fix/<topic>`, `chore/<topic>`, `docs/<topic>`.
- **Commit Messages**:
  - Use concise Conventional Commits in English (e.g., `feat:`, `fix:`, `refactor:`, `chore:`, `docs:`, `test:`).
- **Independent Review Gate (Required Before Merge)**:
  - Before merging any PR into `main`, run an **independent cross-provider review agent** (e.g., Claude reviewing Gemini-authored changes, or vice versa).
  - Address valid review findings, verify build/tests/SwiftLint as applicable, and only merge after the independent review is complete.
- **Issue Tracking**:
  - Link PRs to their corresponding `sfai05/Aidoku` GitHub issue(s).
  - When closing an issue or merging a PR that closes it, post a concise English closing summary comment covering the merged PR/commit, verification results, and any follow-ups.

---

## Upstream Sync Guidelines (Low-Touch Forking)

Follow these rules in every task to keep merging `upstream/main` straightforward:

1. **Module Isolation (Leverage Xcode Synchronized Groups)**
   - Place new fork code in dedicated directories (e.g., `Aidoku/Core/Sync/`, `Aidoku/Features/Settings/Sync/`, `AidokuTests/Sync/`).
   - Both `Aidoku` and `AidokuTests` use Xcode 16 `PBXFileSystemSynchronizedRootGroup` in `Aidoku.xcodeproj/project.pbxproj`, meaning new Swift/test files in these folders are picked up automatically. Avoid unnecessary edits to `project.pbxproj`.

2. **Minimal Upstream Hooks**
   - Keep modifications to upstream files (`AppDelegate.swift`, `Settings.swift`, `SettingsView.swift`, `CoreDataManager.swift`, `LibraryViewController.swift`, etc.) as thin as possible — ideally 1–5 line delegation hooks wrapped or labeled with `// MARK: - Fork: <brief reason>`.
   - Prefer gating or routing around upstream behavior (e.g., iCloud sync hooks) instead of deleting large blocks of upstream code.

3. **Never Modify Upstream Core Data Schema**
   - Do **NOT** edit `Aidoku/Core/Database/Aidoku.xcdatamodeld` or add custom Core Data model versions, as upstream actively bumps schema versions (currently `0.9.xcdatamodel`).
   - Store fork-specific state (`revision`, deletion tombstones, sync logs, secret-category flags, etc.) outside Core Data in dedicated JSON files under `FileManager.default.applicationSupportDirectory`, scoped `UserDefaults` keys, or Keychain.

4. **Separate Localization Tables**
   - Upstream uses Weblate to continuously update `Aidoku/App/Resources/Localization/*.lproj/Localizable.strings`.
   - Do **not** scatter fork strings across upstream `Localizable.strings` files. Store fork UI strings in a separate `.strings` table (e.g., `ForkLocalizable.strings`) accessed via a dedicated localization helper.

5. **Separate CI Workflows & Minimal Config Diffs**
   - Add fork-specific CI workflows (e.g., `.github/workflows/fork-release.yml`) instead of rewriting upstream workflows (`nightly.yml`, `update_altstore_source.yml`). Note that upstream's `nightly.yml` targets a custom `xcode-27` runner; fork workflows must target standard GitHub-hosted macOS runners.
   - Keep `Aidoku/Aidoku.xcconfig`, `Aidoku/Aidoku.entitlements`, and `Aidoku/Info.plist` diffs minimal and clearly commented.

6. **Code Style (`.swiftlint.yml`)**
   - Follow `.swiftlint.yml` strictly:
     - 4 spaces for indentation (never tabs; enforced by `spaces_not_tabs`).
     - Leading space after `//` in comments (enforced by `comment_whitespace`).
     - No trailing `.0` on float literals (enforced by `point_zero`, e.g., `16`, not `16.0`).
     - Line length <= 150 warning / 200 error; adhere to all opt-in rules (`implicit_return`, `first_where`, `empty_count`, `sorted_first_last`, etc.).

7. **Security & Secrets**
   - Store all sync auth tokens, passwords, and session secrets exclusively in **iOS Keychain**.
   - Never store sensitive credentials in `UserDefaults`, as `BackupManager` exports `UserDefaults` keys matching allowed prefixes (e.g., `General`, `Token`, `Tracker`).
   - Any PocketBase Superuser/Admin credentials used in the **One-Time Setup Wizard** must remain strictly transient in memory for schema creation and be discarded immediately afterward — never persisted to Keychain, `UserDefaults`, or logs.

---

## Agreed Architecture Decisions

- **Free Apple ID / Sideloading**:
  - Remove paid-only entitlements (`aps-environment`, iCloud/CloudKit/Ubiquity containers) from `Aidoku.entitlements` and `remote-notification` from `Info.plist` `UIBackgroundModes`.
  - Keep local notifications (`NotificationManager` / `UNUserNotificationCenter`) and `BGProcessingTask` (`processing`, `fetch`) intact; they do not require APNs.
  - Publish unsigned `.ipa` builds + SideStore/AltStore-compatible `apps.json` from `sfai05/Aidoku`.
- **Cross-Device Sync (iPhone + iPad)**:
  - **Storage Abstraction**: Define a thin `SyncStorageProvider` protocol (`healthCheck`, `fetchLatestMetadata`, `downloadSnapshot`, `uploadSnapshot`, `listSnapshots`, `deleteSnapshot`) so PocketBase ships first while allowing future providers (e.g., WebDAV) without rewriting merge logic.
  - **Snapshot + Smart Merge**: Wrap Aidoku's existing `Backup` codable model inside a `SyncEnvelope` (`revision` optimistic lock, `deviceId`, `updatedAt`, lightweight deletion `tombstones`).
  - **Non-Destructive Merger**: Regular sync runs a quiet background smart merge (newest `dateRead` wins for history, union + tombstone reconciliation for library/categories/tracks/`EditedKeys`). Never invoke destructive `BackupManager.doRestore` (which wipes Core Data stores and presents blocking alerts) during automatic sync; reserve full overwrite strictly for explicit user-triggered **Force Push / Force Pull** recovery actions.
  - **PocketBase Auth & Schema**: Authenticate daily sync via PocketBase's standard `users` collection (`auth-with-password` + `auth-refresh`) with owner-scoped API rules (`@request.auth.id != "" && owner = @request.auth.id`). Support both an in-app **One-Time Setup Wizard** (programmatic collection creation using transient Superuser credentials) and **Manual `pb_schema.json` Import** (for least-privilege or shared servers).

---

## Tracked Roadmap (`sfai05/Aidoku` Issues)

### Must Have
- **#1** — Audit and remove paid Apple Developer entitlements for free Apple ID builds
- **#2** — Add SideStore and AltStore distribution workflow (CI IPA build + Source JSON)
- **#3** — Implement PocketBase sync core (Snapshot + Smart Merge engine & storage abstraction)
- **#4** — Add Sync Status Dashboard, sync logs, and experimental recovery tools

### Future
- **#5** — Better manga management: Tracker metadata sync (MangaBaka) and manual metadata editing
- **#6** — Secret categories locked with Face ID
- **#7** — Home screen Widgets (sideload & free Apple ID compatible)
- **#8** — Better notifications when new chapters are dropped
