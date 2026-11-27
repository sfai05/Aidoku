"""Unit tests for update_sidestore_source.py and the fork apps.json template."""

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
    bundle_id: str = "io.github.sfai05.Kodoku",
    version: str = "0.9",
    build_version: str = "101",
    min_os: str = "15.0",
    display_name: str = "Kodoku",
    include_plist: bool = True,
) -> str:
    """Create a minimal .ipa zip archive for testing."""
    ipa_path = os.path.join(directory, "Kodoku-test.ipa")
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

        self.assertEqual(data["name"], "Kodoku")
        self.assertEqual(
            data["sourceURL"],
            "https://raw.githubusercontent.com/sfai05/Aidoku/altstore/apps.json",
        )
        self.assertEqual(data["featuredApps"], ["io.github.sfai05.Kodoku"])
        app = data["apps"][0]
        self.assertEqual(app["name"], "Kodoku")
        self.assertEqual(app["bundleIdentifier"], "io.github.sfai05.Kodoku")
        self.assertEqual(app["tintColor"], "1F6BFF")
        self.assertEqual(app["appPermissions"]["entitlements"], [])
        self.assertIn("NSFaceIDUsageDescription", app["appPermissions"]["privacy"])
        self.assertIn("NSPhotoLibraryUsageDescription", app["appPermissions"]["privacy"])
        self.assertIn("NSLocalNetworkUsageDescription", app["appPermissions"]["privacy"])

    def test_read_ipa_metadata_valid(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            ipa_path = create_synthetic_ipa(tmpdir)
            meta = updater.read_ipa_metadata(ipa_path)
            self.assertEqual(
                meta,
                {
                    "version": "0.9",
                    "buildVersion": "101",
                    "bundleIdentifier": "io.github.sfai05.Kodoku",
                    "minOSVersion": "15.0",
                    "displayName": "Kodoku",
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

    def test_markdown_to_plain_text(self) -> None:
        raw = "## What's New\n- Added **blue** icon (`#1F6BFF`)\n- See [Release](https://github.com/sfai05/Aidoku)\n"
        plain = updater.markdown_to_plain_text(raw)
        self.assertEqual(
            plain,
            "What's New\n• Added blue icon (\"#1F6BFF\")\n• See Release (https://github.com/sfai05/Aidoku)",
        )

    def test_merge_initial_history_and_idempotent_dedup(self) -> None:
        with open(TEMPLATE_PATH, "r", encoding="utf-8") as f:
            template = json.load(f)

        v1 = {
            "version": "0.9",
            "buildVersion": "101",
            "date": "2026-11-27T12:00:00Z",
            "localizedDescription": "Initial release",
            "downloadURL": "https://example.com/Kodoku-101.ipa",
            "size": 12345,
            "minOSVersion": "15.0",
        }
        first = updater.merge_source_json(
            template, None, v1, "io.github.sfai05.Kodoku"
        )
        self.assertEqual(len(first["apps"][0]["versions"]), 1)
        self.assertEqual(first["apps"][0]["versions"][0]["buildVersion"], "101")

        # Simulate older history plus re-running v2
        v2 = {
            "version": "0.9",
            "buildVersion": "102",
            "date": "2026-11-28T09:00:00Z",
            "localizedDescription": "Updated release",
            "downloadURL": "https://example.com/Kodoku-102.ipa",
            "size": 23456,
            "minOSVersion": "15.0",
        }
        second = updater.merge_source_json(
            template, first, v2, "io.github.sfai05.Kodoku"
        )
        self.assertEqual(
            [v["buildVersion"] for v in second["apps"][0]["versions"]],
            ["102", "101"],
        )

        # Idempotent replacement when (version, buildVersion) already exists
        v2_rebuilt = dict(v2, localizedDescription="Edited release notes")
        third = updater.merge_source_json(
            template, second, v2_rebuilt, "io.github.sfai05.Kodoku"
        )
        self.assertEqual(
            [v["buildVersion"] for v in third["apps"][0]["versions"]],
            ["102", "101"],
        )
        self.assertEqual(
            third["apps"][0]["versions"][0]["localizedDescription"],
            "Edited release notes",
        )

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

    def test_cli_end_to_end_with_notes_file(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            ipa_path = create_synthetic_ipa(tmpdir, build_version="105")
            notes_path = os.path.join(tmpdir, "notes.md")
            out_path = os.path.join(tmpdir, "out", "apps.json")
            with open(notes_path, "w", encoding="utf-8") as f:
                f.write("### Highlights\n- Works with **SideStore**\n")

            exit_code = updater.main(
                [
                    "--template",
                    TEMPLATE_PATH,
                    "--ipa",
                    ipa_path,
                    "--download-url",
                    "https://github.com/sfai05/Aidoku/releases/download/v0.9-kodoku.105/Kodoku-v0.9-kodoku.105.ipa",
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


if __name__ == "__main__":
    unittest.main()
