#!/usr/bin/env python3
"""Regenerate the ISM control-mapping table in docs/LLD-RHEL-IRAP.md.

Inputs
  docs/data/ism-controls.json   verbatim ISM control dataset (see ism-controls.meta.json)
  docs/data/ism-mapping.yml     hand-authored mapping: control id -> status/reference/note

Output
  docs/LLD-RHEL-IRAP.md         everything between the BEGIN/END ISM TABLE markers

Usage
  python3 scripts/ism_map.py            # rewrite the table in place
  python3 scripts/ism_map.py --check    # exit 1 if the LLD is out of date
  python3 scripts/ism_map.py --stats    # print the status breakdown only

Standard library only — no PyYAML, no network access.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONTROLS = os.path.join(REPO, "docs", "data", "ism-controls.json")
MAPPING = os.path.join(REPO, "docs", "data", "ism-mapping.yml")
LLD = os.path.join(REPO, "docs", "LLD-RHEL-IRAP.md")

BEGIN = "<!-- BEGIN ISM TABLE -->"
END = "<!-- END ISM TABLE -->"

# Several dataset values carry the *next* control appended after a stray table
# separator, e.g.  "...text. | | [ism-0430](/control/ism-0430) | Access to ..."
# Split those back out so each control id resolves to its own statement.
EMBEDDED = re.compile(r"\|\s*\|\s*\[(ism-[0-9a-z\-]+)\]\(/control/\1\)\s*\|")

STATUS = {
    "implemented": "\u2705 Implemented",
    "partial": "\U0001f7e1 Partial",
    "customer": "\U0001f4cb Customer",
    "not-addressed": "\u274c Not addressed",
}

MAX_STATEMENT = 300


# --------------------------------------------------------------------------
# dataset
# --------------------------------------------------------------------------
def clean(text: str) -> str:
    """Strip the dataset's embedded HTML down to a single-line statement."""
    text = re.sub(r"</li>\s*<li>", "; ", text)
    text = re.sub(r"</?li>", "", text)
    text = re.sub(r"<[^>]+>", " ", text)
    text = html.unescape(text)
    text = re.sub(r"\s+", " ", text).strip()
    return text.rstrip(";").strip()


def load_controls(path: str = CONTROLS) -> dict:
    with open(path, encoding="utf-8") as handle:
        raw = json.load(handle)
    out = {}
    for key, value in raw.items():
        parts = EMBEDDED.split(value)
        out[key] = clean(parts[0])
        index = 1
        while index < len(parts):
            out[parts[index]] = clean(parts[index + 1])
            index += 2
    return out


# --------------------------------------------------------------------------
# minimal YAML reader (nested mappings of scalars — nothing else is used)
# --------------------------------------------------------------------------
def _scalar(token: str) -> str:
    token = token.strip()
    if len(token) >= 2 and token[0] == token[-1] and token[0] in "\"'":
        body = token[1:-1]
        if token[0] == '"':
            body = body.replace('\\"', '"').replace("\\\\", "\\")
        return body
    return token


def load_yaml(path: str = MAPPING) -> dict:
    """Parse the restricted YAML subset used by ism-mapping.yml.

    Supported: nested mappings, two-space indentation, scalar values that are
    either bare (taken verbatim to end of line) or double/single quoted.
    Full-line ``#`` comments and ``---`` are ignored.
    """
    root: dict = {}
    stack = [(-1, root)]
    with open(path, encoding="utf-8") as handle:
        for lineno, line in enumerate(handle, 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or stripped == "---":
                continue
            indent = len(line) - len(line.lstrip(" "))
            if indent % 2:
                raise ValueError("%s:%d: indentation must be a multiple of 2" % (path, lineno))
            while stack and indent <= stack[-1][0]:
                stack.pop()
            if not stack:
                raise ValueError("%s:%d: bad indentation" % (path, lineno))
            parent = stack[-1][1]
            if ":" not in stripped:
                raise ValueError("%s:%d: expected 'key:' or 'key: value'" % (path, lineno))
            key, _, value = stripped.partition(":")
            key = _scalar(key)
            if value.strip():
                parent[key] = _scalar(value)
            else:
                child: dict = {}
                parent[key] = child
                stack.append((indent, child))
    return root


# --------------------------------------------------------------------------
# rendering
# --------------------------------------------------------------------------
def cell(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def abridge(text: str, limit: int = MAX_STATEMENT) -> str:
    if len(text) <= limit:
        return text
    cut = text[:limit]
    space = cut.rfind(" ")
    if space > limit * 0.6:
        cut = cut[:space]
    return cut.rstrip(" ,;:.") + " \u2026"


def validate(mapping: dict, controls: dict) -> list:
    problems = []
    themes = mapping.get("themes", {})
    refs = mapping.get("refs", {})
    rows = mapping.get("controls", {})
    if not rows:
        problems.append("ism-mapping.yml has no 'controls:' entries")
    for cid, row in rows.items():
        if cid not in controls:
            problems.append("%s is not present in the ISM dataset" % cid)
        for field in ("theme", "status", "ref", "note"):
            if field not in row:
                problems.append("%s is missing '%s'" % (cid, field))
        if row.get("status") not in STATUS:
            problems.append("%s has unknown status %r" % (cid, row.get("status")))
        if row.get("theme") not in themes:
            problems.append("%s has unknown theme %r" % (cid, row.get("theme")))
        if row.get("ref") not in refs:
            problems.append("%s has unknown ref %r" % (cid, row.get("ref")))
    for name, target in refs.items():
        if "|" not in target:
            problems.append("ref %r must be 'Label|#anchor'" % name)
    return problems


POAM_HEADING = "### 12.2 Residual actions"


def poam_gaps(mapping: dict, document: str) -> list:
    """Every ❌ row must be driven by an action in the §12.2 POA&M seed.

    §12.2 is hand-written prose outside the generated markers, so it can drift
    away from the mapping file. This is the guard against that.
    """
    _, _, poam = document.partition(POAM_HEADING)
    if not poam:
        return ["%s is missing the '%s' section" % (LLD, POAM_HEADING)]
    poam = poam.partition("\n## ")[0]
    cited = set(re.findall(r"ism-[0-9a-z\-]+", poam))
    problems = []
    for cid, row in sorted(mapping["controls"].items()):
        if row["status"] == "not-addressed" and cid not in cited:
            problems.append("%s is '%s' but has no action in §12.2 (POA&M seed)" % (
                cid, row["status"]))
    for cid in sorted(cited):
        if cid not in mapping["controls"]:
            problems.append("§12.2 cites %s, which has no row in the mapping table" % cid)
    return problems


def sort_key(cid: str):
    match = re.match(r"ism-(\d+)$", cid)
    if match:
        return (0, int(match.group(1)), "")
    return (1, 0, cid)


def render(mapping: dict, controls: dict) -> str:
    themes = mapping["themes"]
    refs = mapping["refs"]
    rows = mapping["controls"]

    grouped: dict = {}
    for cid, row in rows.items():
        grouped.setdefault(row["theme"], []).append(cid)

    out = [BEGIN, ""]
    for theme in sorted(themes):
        if theme not in grouped:
            continue
        out.append("#### %s" % themes[theme])
        out.append("")
        out.append("| ISM control | Control statement (abridged from the dataset) "
                   "| Status | Design reference | Coverage in this build |")
        out.append("|---|---|---|---|---|")
        for cid in sorted(grouped[theme], key=sort_key):
            row = rows[cid]
            label, _, anchor = refs[row["ref"]].partition("|")
            out.append("| `%s` | %s | %s | [%s](%s) | %s |" % (
                cid,
                cell(abridge(controls[cid])),
                STATUS[row["status"]],
                cell(label),
                anchor,
                cell(row["note"]),
            ))
        out.append("")
    out.append(END)
    return "\n".join(out)


def stats(mapping: dict) -> dict:
    counts = {key: 0 for key in STATUS}
    for row in mapping["controls"].values():
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    return counts


# --------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="verify the LLD table is current; do not write")
    parser.add_argument("--stats", action="store_true",
                        help="print the status breakdown and exit")
    args = parser.parse_args()

    controls = load_controls()
    mapping = load_yaml()

    problems = validate(mapping, controls)
    if problems:
        for problem in problems:
            sys.stderr.write("ERROR: %s\n" % problem)
        return 2

    counts = stats(mapping)
    total = sum(counts.values())
    summary = "%d controls mapped from %d in the dataset — %s" % (
        total, len(controls),
        ", ".join("%s %d" % (STATUS[k], counts[k]) for k in
                  ("implemented", "partial", "customer", "not-addressed")))
    if args.stats:
        print(summary)
        return 0

    table = render(mapping, controls)
    with open(LLD, encoding="utf-8") as handle:
        document = handle.read()

    if BEGIN not in document or END not in document:
        sys.stderr.write("ERROR: %s is missing the ISM table markers\n" % LLD)
        return 2

    gaps = poam_gaps(mapping, document)
    if gaps:
        for gap in gaps:
            sys.stderr.write("ERROR: %s\n" % gap)
        return 2

    head, _, rest = document.partition(BEGIN)
    _, _, tail = rest.partition(END)
    updated = head + table + tail

    if args.check:
        if updated != document:
            sys.stderr.write("ERROR: docs/LLD-RHEL-IRAP.md is out of date — "
                             "run: python3 scripts/ism_map.py\n")
            return 1
        print("up to date: " + summary)
        return 0

    if updated != document:
        with open(LLD, "w", encoding="utf-8") as handle:
            handle.write(updated)
        print("updated docs/LLD-RHEL-IRAP.md — " + summary)
    else:
        print("no change — " + summary)
    return 0


if __name__ == "__main__":
    sys.exit(main())
