"""Unit tests for update_sidestore_source.py and the fork apps.json template."""

from __future__ import annotations

import hashlib
import json
import os
import plistlib
import tempfile
import unittest
import zipfile

import update_sidestore_source as updater


REPO_ROOT = os.path.abspath(
    os.path.join(os.path.dirname(__file__), "..", "..", "..", "..")
)
TEMPLATE_PATH = os.path.join(
    REPO_ROOT, ".github", "workflows", "supporting", "fork", "apps.json"
)


def create_synthetic_ipa(
    directory: str,
    bundle_id: str = "io.github.sfai05.Dokuha",
    version: str = "0.9",
    build_version: str = "101",
    min_os: str = "15.0",
    display_name: str = "Dokuha",
    include_plist: bool = True,
) -> str:
    """Create a minimal .ipa zip archive for testing."""
    ipa_path = os.path.join(directory, "Dokuha-test.ipa")
    plist_data = {}
    if version is not None:
        plist_data["CFBundleShortVersionString"] = version
    if build_version is not None:
        plist_data["CFBundleVersion"] = build_version
    if bundle_id is not None:
        plist_data["CFBundleIdentifier"] = bundle_id
    if min_os is not None:
        plist_data["MinimumOSVersion"] = min_os
    if display_name is not None:
        plist_data["CFBundleDisplayName"] = display_name

    with zipfile.ZipFile(ipa_path, "w") as zf:
        if include_plist:
            zf.writestr(
                "Payload/Aidoku.app/Info.plist",
                plistlib.dumps(plist_data),
            )
        else:
            zf.writestr("Payload/Aidoku.app/PkgInfo", b"APPL????")
    return ipa_path


class TestUpdateSideStoreSource(unittest.TestCase):
    """Tests for SideStore/AltStore source metadata generation."""

    def test_template_apps_json_contract(self) -> None:
        with open(TEMPLATE_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)

        self.assertEqual(data["name"], "Dokuha")
        self.assertEqual(data["identifier"], "io.github.sfai05.dokuha.source")
        self.assertEqual(
            data["sourceURL"],
            "https://raw.githubusercontent.com/sfai05/Aidoku/altstore/apps.json",
        )
        self.assertEqual(data["featuredApps"], ["io.github.sfai05.Dokuha"])
        app = data["apps"][0]
        self.assertEqual(app["name"], "Dokuha")
        self.assertEqual(app["bundleIdentifier"], "io.github.sfai05.Dokuha")
        self.assertEqual(app["tintColor"], "1F6BFF")
        self.assertEqual(app["appPermissions"]["entitlements"], [])
        self.assertIn("NSFaceIDUsageDescription", app["appPermissions"]["privacy"])
        self.assertIn("NSPhotoLibraryUsageDescription", app["appPermissions"]["privacy"])
        self.assertIn("NSLocalNetworkUsageDescription", app["appPermissions"]["privacy"])
        self.assertNotIn("Official", data["description"])

    def test_read_ipa_metadata_valid(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            ipa_path = create_synthetic_ipa(tmpdir)
            meta = updater.read_ipa_metadata(ipa_path)
            self.assertEqual(
                meta,
                {
                    "version": "0.9",
                    "buildVersion": "101",
                    "bundleIdentifier": "io.github.sfai05.Dokuha",
                    "minOSVersion": "15.0",
                    "displayName": "Dokuha",
                },
            )

    def test_read_ipa_metadata_missing_plist(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            ipa_path = create_synthetic_ipa(tmpdir, include_plist=False)
            with self.assertRaises(FileNotFoundError):
                updater.read_ipa_metadata(ipa_path)

    def test_read_ipa_metadata_missing_required_fields(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            ipa_path = create_synthetic_ipa(tmpdir, build_version="")
            with self.assertRaises(ValueError):
                updater.read_ipa_metadata(ipa_path)

    def test_markdown_to_plain_text_and_images(self) -> None:
        raw = (
            "## What's New\n"
            "![Build Status](https://img.shields.io/badge/build-passing-blue)\n"
            "- Added **blue** icon (`#1F6BFF`)\n"
            "- See [Release](https://github.com/sfai05/Aidoku)\n"
        )
        plain = updater.markdown_to_plain_text(raw)
        self.assertEqual(
            plain,
            "What's New\n"
            "Build Status\n"
            "• Added blue icon (\"#1F6BFF\")\n"
            "• See Release (https://github.com/sfai05/Aidoku)",
        )
        self.assertNotIn("!", plain)

    def test_merge_history_dedup_clobbered_url_and_date_sort(self) -> None:
        with open(TEMPLATE_PATH, "r", encoding="utf-8") as f:
            template = json.load(f)

        v1 = {
            "version": "0.9",
            "buildVersion": "101",
            "date": "2026-11-27T12:00:00Z",
            "localizedDescription": "Initial release",
            "downloadURL": "https://example.com/Dokuha-v0.9-dokuha.101.ipa",
            "size": 12345,
            "minOSVersion": "15.0",
        }
        first = updater.merge_source_json(
            template, None, v1, "io.github.sfai05.Dokuha"
        )
        self.assertEqual(len(first["apps"][0]["versions"]), 1)

        # Simulate newer release and older backfilled release -> sorted descending by date
        v2 = {
            "version": "0.9",
            "buildVersion": "102",
            "date": "2026-11-28T09:00:00Z",
            "localizedDescription": "Updated release",
            "downloadURL": "https://example.com/Dokuha-v0.9-dokuha.102.ipa",
            "size": 23456,
            "minOSVersion": "15.0",
        }
        second = updater.merge_source_json(
            template, first, v2, "io.github.sfai05.Dokuha"
        )
        self.assertEqual(
            [v["buildVersion"] for v in second["apps"][0]["versions"]],
            ["102", "101"],
        )

        # Re-running same tag (clobbered downloadURL with newer buildVersion 103)
        # must replace stale build 102 entry sharing that downloadURL.
        v2_clobbered = {
            "version": "0.9",
            "buildVersion": "103",
            "date": "2026-11-29T10:00:00Z",
            "localizedDescription": "Re-built release",
            "downloadURL": "https://example.com/Dokuha-v0.9-dokuha.102.ipa",
            "size": 24000,
            "minOSVersion": "15.0",
        }
        third = updater.merge_source_json(
            template, second, v2_clobbered, "io.github.sfai05.Dokuha"
        )
        self.assertEqual(
            [v["buildVersion"] for v in third["apps"][0]["versions"]],
            ["103", "101"],
        )

        # Adding an older-dated entry still keeps chronological descending order
        older = {
            "version": "0.9",
            "buildVersion": "100",
            "date": "2026-11-26T08:00:00Z",
            "localizedDescription": "Older release",
            "downloadURL": "https://example.com/Dokuha-v0.9-dokuha.100.ipa",
            "size": 11111,
            "minOSVersion": "15.0",
        }
        fourth = updater.merge_source_json(
            template, third, older, "io.github.sfai05.Dokuha"
        )
        self.assertEqual(
            [v["buildVersion"] for v in fourth["apps"][0]["versions"]],
            ["103", "101", "100"],
        )

    def test_merge_ignores_legacy_bundle_id_versions(self) -> None:
        with open(TEMPLATE_PATH, "r", encoding="utf-8") as f:
            template = json.load(f)

        legacy_existing = {
            "name": "Kodoku",
            "identifier": "io.github.sfai05.kodoku.source",
            "apps": [
                {
                    "name": "Kodoku",
                    "bundleIdentifier": "io.github.sfai05.Kodoku",
                    "versions": [
                        {
                            "version": "0.9",
                            "buildVersion": "106",
                            "date": "2026-11-27T23:27:17Z",
                            "localizedDescription": "Legacy release",
                            "downloadURL": "https://example.com/Kodoku-v0.9-kodoku.106.ipa",
                            "size": 15339235,
                            "minOSVersion": "15.0",
                        }
                    ],
                }
            ],
        }
        new_entry = {
            "version": "0.9",
            "buildVersion": "107",
            "date": "2026-11-28T01:00:00Z",
            "localizedDescription": "Dokuha release",
            "downloadURL": "https://example.com/Dokuha-v0.9-dokuha.107.ipa",
            "size": 15400000,
            "minOSVersion": "15.0",
        }
        merged = updater.merge_source_json(
            template, legacy_existing, new_entry, "io.github.sfai05.Dokuha"
        )
        self.assertEqual(merged["identifier"], "io.github.sfai05.dokuha.source")
        self.assertEqual(merged["featuredApps"], ["io.github.sfai05.Dokuha"])
        self.assertEqual(merged["apps"][0]["bundleIdentifier"], "io.github.sfai05.Dokuha")
        self.assertEqual(merged["apps"][0]["versions"], [new_entry])

    def test_merge_bundle_id_mismatch_raises(self) -> None:
        with open(TEMPLATE_PATH, "r", encoding="utf-8") as f:
            template = json.load(f)

        entry = {
            "version": "0.9",
            "buildVersion": "101",
            "date": "2026-11-27T12:00:00Z",
            "localizedDescription": "Test",
            "downloadURL": "https://example.com/test.ipa",
            "size": 100,
            "minOSVersion": "15.0",
        }
        with self.assertRaises(ValueError):
            updater.merge_source_json(template, None, entry, "app.aidoku.Aidoku")

    def test_cli_end_to_end_with_notes_file_and_sha256(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            ipa_path = create_synthetic_ipa(tmpdir, build_version="105")
            notes_path = os.path.join(tmpdir, "notes.md")
            out_path = os.path.join(tmpdir, "out", "apps.json")
            with open(notes_path, "w", encoding="utf-8") as f:
                f.write("### Highlights\n- Works with **SideStore**\n")

            with open(ipa_path, "rb") as f:
                expected_sha256 = hashlib.sha256(f.read()).hexdigest()

            exit_code = updater.main(
                [
                    "--template",
                    TEMPLATE_PATH,
                    "--ipa",
                    ipa_path,
                    "--download-url",
                    "https://github.com/sfai05/Aidoku/releases/download/v0.9-dokuha.105/Dokuha-v0.9-dokuha.105.ipa",
                    "--date",
                    "2026-11-27T12:00:00Z",
                    "--notes-file",
                    notes_path,
                    "--output",
                    out_path,
                ]
            )
            self.assertEqual(exit_code, 0)
            with open(out_path, "r", encoding="utf-8") as f:
                result = json.load(f)

            versions = result["apps"][0]["versions"]
            self.assertEqual(len(versions), 1)
            self.assertEqual(versions[0]["buildVersion"], "105")
            self.assertEqual(
                versions[0]["localizedDescription"],
                "Highlights\n• Works with SideStore",
            )
            self.assertEqual(versions[0]["size"], os.path.getsize(ipa_path))
            self.assertEqual(versions[0]["sha256"], expected_sha256)
            self.assertEqual(len(versions[0]["sha256"]), 64)


if __name__ == "__main__":
    unittest.main()
