"""Generate or update the SideStore/AltStore source JSON for Kodoku releases."""

from __future__ import annotations

import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
import os
import plistlib
import re
import zipfile


DEFAULT_MIN_OS_VERSION = "15.0"


def compute_sha256(file_path: str) -> str:
    """Compute lowercase hexadecimal SHA-256 digest for a file."""
    digest = hashlib.sha256()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_ipa_metadata(ipa_path: str) -> dict:
    """Extract bundle metadata from Payload/<App>.app/Info.plist inside an IPA."""
    with zipfile.ZipFile(ipa_path, "r") as ipa:
        info_plist_path = next(
            (
                name
                for name in ipa.namelist()
                if name.startswith("Payload/")
                and name.count("/") == 2
                and name.endswith(".app/Info.plist")
            ),
            None,
        )
        if not info_plist_path:
            raise FileNotFoundError(f"Info.plist not found inside IPA: {ipa_path}")

        plist = plistlib.loads(ipa.read(info_plist_path))

    version = str(plist.get("CFBundleShortVersionString") or "").strip()
    build_version = str(plist.get("CFBundleVersion") or "").strip()
    bundle_id = str(plist.get("CFBundleIdentifier") or "").strip()
    min_os_version = str(plist.get("MinimumOSVersion") or DEFAULT_MIN_OS_VERSION).strip()
    display_name = str(
        plist.get("CFBundleDisplayName") or plist.get("CFBundleName") or ""
    ).strip()

    if not version or not build_version or not bundle_id:
        raise ValueError(
            "IPA Info.plist must define CFBundleShortVersionString, "
            "CFBundleVersion, and CFBundleIdentifier"
        )

    return {
        "version": version,
        "buildVersion": build_version,
        "bundleIdentifier": bundle_id,
        "minOSVersion": min_os_version,
        "displayName": display_name,
    }


def markdown_to_plain_text(text: str) -> str:
    """Convert GitHub Release Markdown into plain text suitable for SideStore/AltStore."""
    if not text:
        return ""

    text = text.replace("\r\n", "\n")
    text = re.sub(r"!\[([^\]]*)\]\([^)]+\)", r"\1", text)
    text = re.sub(r"\[([^\]]+)\]\(<?([^)>\s]+)>?\)", r"\1 (\2)", text)
    text = re.sub(r"<(https?://[^>\s]+)>", r"\1", text)
    text = re.sub(r"<[^<>]+?>", "", text)
    text = re.sub(r"^\s{0,3}#{1,6}\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"^(\s*)[-*+]\s+", r"\1• ", text, flags=re.MULTILINE)
    text = re.sub(r"(\*\*|__)(.+?)\1", r"\2", text)
    text = re.sub(r"(?<!\w)[*_](\S(?:.*?\S)?)[*_](?!\w)", r"\1", text)
    text = re.sub(r"~~(.+?)~~", r"\1", text)
    text = text.replace("`", '"')
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def normalize_iso_date(date_str: str) -> str:
    """Validate and normalize a release timestamp string."""
    cleaned = date_str.strip()
    if not cleaned:
        raise ValueError("Release date must not be empty")

    if re.fullmatch(r"\d{4}-\d{2}-\d{2}", cleaned):
        datetime.strptime(cleaned, "%Y-%m-%d")
        return cleaned

    parsed = datetime.fromisoformat(cleaned.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    else:
        parsed = parsed.astimezone(timezone.utc)
    return parsed.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_sort_timestamp(date_str: str) -> datetime:
    """Parse an ISO date or timestamp into UTC datetime for descending sorting."""
    cleaned = (date_str or "").strip()
    if not cleaned:
        return datetime.min.replace(tzinfo=timezone.utc)
    try:
        parsed = datetime.fromisoformat(cleaned.replace("Z", "+00:00"))
    except ValueError:
        return datetime.min.replace(tzinfo=timezone.utc)
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def build_version_entry(
    metadata: dict,
    download_url: str,
    size: int,
    date_str: str,
    notes: str = "",
    sha256: str | None = None,
) -> dict:
    """Build an AltStore/SideStore v2 version entry dictionary."""
    plain_notes = markdown_to_plain_text(notes)
    if not plain_notes:
        plain_notes = f"Kodoku {metadata['version']} (build {metadata['buildVersion']})"

    entry = {
        "version": metadata["version"],
        "buildVersion": metadata["buildVersion"],
        "date": normalize_iso_date(date_str),
        "localizedDescription": plain_notes,
        "downloadURL": download_url,
        "size": int(size),
        "minOSVersion": metadata["minOSVersion"],
    }
    if sha256:
        entry["sha256"] = sha256
    return entry


def merge_source_json(
    template_data: dict,
    existing_data: dict | None,
    version_entry: dict,
    expected_bundle_id: str,
) -> dict:
    """Merge a new version entry onto the template metadata and any prior versions."""
    merged = copy.deepcopy(template_data)
    apps = merged.get("apps")
    if not isinstance(apps, list) or not apps:
        raise ValueError("Template apps.json must contain a non-empty 'apps' list")

    app = apps[0]
    template_bundle_id = app.get("bundleIdentifier")
    if expected_bundle_id != template_bundle_id:
        raise ValueError(
            f"Bundle identifier mismatch: expected {template_bundle_id}, "
            f"got {expected_bundle_id}"
        )

    merged["featuredApps"] = [template_bundle_id]

    prior_versions = []
    if existing_data and isinstance(existing_data.get("apps"), list):
        matching_app = next(
            (
                item
                for item in existing_data["apps"]
                if item.get("bundleIdentifier") == template_bundle_id
            ),
            None,
        )
        if matching_app and isinstance(matching_app.get("versions"), list):
            prior_versions = list(matching_app["versions"])

        if isinstance(existing_data.get("news"), list) and existing_data["news"]:
            merged["news"] = list(existing_data["news"])

    filtered_versions = [
        item
        for item in prior_versions
        if (item.get("version"), item.get("buildVersion"))
        != (version_entry["version"], version_entry["buildVersion"])
        and item.get("downloadURL") != version_entry["downloadURL"]
    ]
    tagged_versions = [(0, version_entry)] + [
        (index + 1, item) for index, item in enumerate(filtered_versions)
    ]
    tagged_versions.sort(
        key=lambda pair: (
            parse_sort_timestamp(str(pair[1].get("date") or "")),
            -pair[0],
        ),
        reverse=True,
    )
    app["versions"] = [item for _, item in tagged_versions]
    return merged


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(
        description="Update Kodoku SideStore/AltStore source JSON from a built IPA."
    )
    parser.add_argument("--template", required=True, help="Path to template apps.json")
    parser.add_argument(
        "--existing",
        default="",
        help="Optional path to existing apps.json from the altstore branch",
    )
    parser.add_argument("--ipa", required=True, help="Path to the built .ipa archive")
    parser.add_argument("--download-url", required=True, help="IPA release asset URL")
    parser.add_argument(
        "--size",
        type=int,
        default=None,
        help="IPA byte size (defaults to local file size)",
    )
    parser.add_argument("--date", required=True, help="ISO 8601 release timestamp")
    parser.add_argument("--notes", default="", help="Release notes Markdown string")
    parser.add_argument(
        "--notes-file",
        default="",
        help="Optional file containing release notes Markdown (overrides --notes)",
    )
    parser.add_argument("--output", required=True, help="Output apps.json path")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint."""
    args = parse_args(argv)

    with open(args.template, "r", encoding="utf-8") as f:
        template_data = json.load(f)

    existing_data = None
    if args.existing and os.path.isfile(args.existing) and os.path.getsize(args.existing) > 0:
        with open(args.existing, "r", encoding="utf-8") as f:
            existing_data = json.load(f)

    notes = args.notes
    if args.notes_file and os.path.isfile(args.notes_file):
        with open(args.notes_file, "r", encoding="utf-8") as f:
            notes = f.read()

    metadata = read_ipa_metadata(args.ipa)
    ipa_size = args.size if args.size is not None else os.path.getsize(args.ipa)
    ipa_sha256 = compute_sha256(args.ipa)
    version_entry = build_version_entry(
        metadata=metadata,
        download_url=args.download_url,
        size=ipa_size,
        date_str=args.date,
        notes=notes,
        sha256=ipa_sha256,
    )
    updated = merge_source_json(
        template_data=template_data,
        existing_data=existing_data,
        version_entry=version_entry,
        expected_bundle_id=metadata["bundleIdentifier"],
    )

    output_dir = os.path.dirname(os.path.abspath(args.output))
    if output_dir:
        os.makedirs(output_dir, exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(updated, f, indent=2, ensure_ascii=False)
        f.write("\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
