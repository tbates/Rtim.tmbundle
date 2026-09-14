#!/usr/bin/env python3
"""Report (and optionally strip) mainMenu UUIDs with no matching bundle item.

Orphan menu entries draw nothing, so they silently glue neighbouring
dividers together and shift every drop slot below them. Empty categories
are reported but never touched.

Usage:
  unused_uuids.py --json BUNDLE_PATH    machine-readable report on stdout
  unused_uuids.py --report BUNDLE_PATH  human-readable report on stdout
  unused_uuids.py --strip BUNDLE_PATH   delete orphan refs from items
                                        arrays (backup first), JSON result

Exit status is 0 unless something failed outright; findings travel in
the output, not the exit code.
"""
import json
import os
import plistlib
import re
import shutil
import sys
import tempfile
import time

UUID_RE = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"
    r"[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
SEP = "------------------------------------"
MENU_ELIGIBLE_PREFIXES = ("Commands/", "Snippets/", "Macros/")


def is_uuid(value):
    return isinstance(value, str) and bool(UUID_RE.match(value))


def item_files(bundle):
    """Map every item uuid in the bundle to its file, relative to root."""
    found = {}
    for dirpath, _dirnames, filenames in os.walk(bundle):
        for name in filenames:
            path = os.path.join(dirpath, name)
            try:
                with open(path, "rb") as handle:
                    data = plistlib.load(handle)
            except Exception:
                continue
            if not isinstance(data, dict):
                continue
            uuid = data.get("uuid")
            if is_uuid(uuid):
                found[uuid] = os.path.relpath(path, bundle)
    return found


def menu_tables(info):
    """Yield (menu_label, submenu_key_or_None, items_list) for top + submenus."""
    main = info.get("mainMenu", {}) or {}
    yield ("<top level>", None, main.get("items", []) or [])
    for key, sub in (main.get("submenus", {}) or {}).items():
        yield (sub.get("name", key), key, sub.get("items", []) or [])


def analyze(bundle):
    with open(os.path.join(bundle, "info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    main = info.get("mainMenu", {}) or {}
    subrecs = main.get("submenus", {}) or {}
    have = item_files(bundle)

    orphans = {}   # uuid -> set of menu labels
    invalid = []   # (menu label, index, value)
    tables = list(menu_tables(info))
    for label, _key, items in tables:
        for index, entry in enumerate(items):
            if entry == SEP:
                continue
            if not is_uuid(entry):
                invalid.append(
                    {"menu": label, "index": index, "value": entry}
                )
                continue
            if entry in subrecs or entry in have:
                continue
            orphans.setdefault(entry, set()).add(label)

    placed = set()
    for _label, _key, items in tables:
        placed.update(u for u in items if is_uuid(u))
    empty, gutted, dead = [], [], []
    for key, sub in subrecs.items():
        items = sub.get("items", []) or []
        name = sub.get("name", key)
        if not items:
            empty.append({"uuid": key, "name": name})
            continue
        if key not in placed:
            dead.append({"uuid": key, "name": name})
        refs = [u for u in items if is_uuid(u) and u != SEP]
        if refs and not any(u in subrecs or u in have for u in refs):
            gutted.append(
                {"uuid": key, "name": name, "entries": len(items)}
            )

    return {
        "bundle": info.get("name", os.path.basename(bundle)),
        "orphans": [
            {"uuid": uuid, "menus": sorted(menus)}
            for uuid, menus in sorted(orphans.items())
        ],
        "empty_categories": empty,
        "gutted_categories": gutted,
        "dead_categories": dead,
        "invalid_entries": invalid,
    }


def human_report(report):
    lines = []
    orphans = report["orphans"]
    lines.append(
        "%s: %d orphan UUID%s, %d empty categor%s"
        % (
            report["bundle"],
            len(orphans),
            "" if len(orphans) == 1 else "s",
            len(report["empty_categories"]),
            "y" if len(report["empty_categories"]) == 1 else "ies",
        )
    )
    if orphans:
        lines.append("ORPHANS (in a menu, matching no item):")
        shown = orphans[:12]
        for entry in shown:
            lines.append(
                "  %s in %s" % (entry["uuid"][:8], ", ".join(entry["menus"]))
            )
        if len(orphans) > len(shown):
            lines.append("  …and %d more" % (len(orphans) - len(shown)))
    for entry in report["gutted_categories"]:
        lines.append(
            "GUTTED (nothing in it resolves): %s — left alone"
            % entry["name"]
        )
    for entry in report["dead_categories"]:
        lines.append(
            "UNPLACED (never listed, cannot open): %s — left alone"
            % entry["name"]
        )
    for entry in report["invalid_entries"]:
        lines.append(
            "INVALID entry in %s slot %d (%r) — left alone"
            % (entry["menu"], entry["index"], entry["value"])
        )
    if not orphans:
        lines.append("Clean — nothing to strip.")
    return "\n".join(lines) + "\n"


def strip_orphans(bundle):
    report = analyze(bundle)
    doomed = {entry["uuid"] for entry in report["orphans"]}
    if not doomed:
        return {"stripped": 0, "backup": None}
    plist_path = os.path.join(bundle, "info.plist")
    with open(plist_path, "rb") as handle:
        raw = handle.read()
    # Safety copy goes to the OS temp dir, never into the bundle: bak files
    # beside info.plist end up committed as noise, and a missing cleanup
    # once took info.plist itself with it.
    backup = os.path.join(
        tempfile.gettempdir(),
        "%s.orphan-bak-%s" % (
            os.path.basename(bundle), time.strftime("%Y%m%d-%H%M%S")
        ),
    )
    shutil.copyfile(plist_path, backup)
    fmt = (
        plistlib.FMT_BINARY
        if raw.startswith(b"bplist") else plistlib.FMT_XML
    )
    info = plistlib.loads(raw)
    main = info.get("mainMenu", {}) or {}

    def clean(items):
        kept = [u for u in items if u not in doomed]
        return kept, len(items) - len(kept)

    removed = 0
    top = main.get("items", []) or []
    main["items"], n = clean(top)
    removed += n
    for sub in (main.get("submenus", {}) or {}).values():
        items = sub.get("items", []) or []
        sub["items"], n = clean(items)
        removed += n
    with open(plist_path, "wb") as handle:
        plistlib.dump(info, handle, fmt=fmt, sort_keys=False)
    return {"stripped": removed, "backup": backup}


def main(argv):
    if len(argv) != 3 or argv[1] not in ("--json", "--report", "--strip"):
        sys.stderr.write("usage: unused_uuids.py [--json|--report|--strip] BUNDLE\n")
        return 1
    mode, bundle = argv[1], argv[2]
    try:
        if mode == "--json":
            sys.stdout.write(json.dumps(analyze(bundle), indent=1) + "\n")
        elif mode == "--report":
            sys.stdout.write(human_report(analyze(bundle)))
        else:
            sys.stdout.write(json.dumps(strip_orphans(bundle)) + "\n")
    except Exception as exc:
        sys.stderr.write("unused_uuids: %s\n" % exc)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
