#!/usr/bin/env python3
"""Encode wtc-status snapshot NDJSON into canonical JSON or agent markdown."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from typing import Any


GLYPH = {
    "SUCCESS": "✓",
    "FAILURE": "✗",
    "ERROR": "✗",
    "PENDING": "●",
    "EXPECTED": "●",
    "draft": "D",
    "NONE": "·",
    "approved": "✓",
    "changes": "!",
    "waiting": "…",
    "commented": "✎",
    "noreviewers": "⚠",
    "merged": "·",
    "FOLLOW": "→",
    "MERGED": "·",
}

REVIEW_LABEL = {
    "approved": "approved",
    "changes": "changes requested",
    "waiting": "waiting on reviewers",
    "commented": "reviewer commented",
    "noreviewers": "⚠ no reviewers",
    "merged": "merged",
    "none": "",
}


def glyph(checks: str | None) -> str:
    if not checks:
        return ""
    return GLYPH.get(checks, checks)


def link(url: str | None, text: str) -> str:
    if url:
        return f"[{text}]({url})"
    return text


def build_label(checks: str | None, build: str | None, url: str | None) -> str:
    g = glyph(checks)
    if not g and not build:
        return ""
    if build:
        lbl = link(url, f"#{build}") if url else f"#{build}"
        return f"{g} {lbl}".strip() if g else lbl
    return g


def assemble(records: list[dict[str, Any]]) -> dict[str, Any]:
    meta: dict[str, Any] = {}
    repos: list[dict[str, Any]] = []
    prs: list[dict[str, Any]] = []
    orphans: list[dict[str, Any]] = []

    for rec in records:
        kind = rec.get("kind")
        if kind == "meta":
            meta = rec
        elif kind == "repo":
            repos.append(rec)
        elif kind == "pr":
            prs.append(rec)
        elif kind == "orphan":
            orphans.append(rec)

    if "generated_at" not in meta:
        meta["generated_at"] = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    meta.setdefault("schema", 1)

    snapshot = {
        "schema": meta.get("schema", 1),
        "collection": meta.get("collection", ""),
        "generated_at": meta.get("generated_at"),
        "show_collection_column": bool(meta.get("show_collection_column")),
        "stale_count": int(meta.get("stale_count") or 0),
        "repos": [],
        "prs": [],
        "orphans": [],
    }

    for r in repos:
        pr = {
            "number": r.get("pr_number") or None,
            "checks": r.get("pr_checks") or None,
            "merge": r.get("pr_merge") or None,
            "review": r.get("pr_review") or None,
            "draft": bool(r.get("pr_draft")),
        }
        if not pr["number"]:
            pr = None

        tip = {
            "branch": r.get("tip_branch") or "",
            "checks": r.get("tip_checks") or None,
            "build": r.get("tip_build") or None,
            "url": r.get("tip_url") or None,
        }
        if not tip["checks"] and not tip["build"]:
            tip = None

        prod = None
        if r.get("prod_branch"):
            prod = {
                "branch": r.get("prod_branch") or "",
                "checks": r.get("prod_checks") or None,
                "build": r.get("prod_build") or None,
                "url": r.get("prod_url") or None,
            }
            if not prod["checks"] and not prod["build"]:
                prod = None

        snapshot["repos"].append(
            {
                "collection": r.get("collection") or snapshot["collection"],
                "dir": r.get("dir") or "",
                "repo": r.get("repo") or "",
                "worktree": r.get("worktree") or "",
                "slug": r.get("slug") or "",
                "branch_kind": r.get("branch_kind") or "",
                "branch": r.get("branch") or "",
                "branch_display": r.get("branch_display") or "",
                "ahead": int(r.get("ahead") or 0),
                "behind": int(r.get("behind") or 0),
                "tree": r.get("tree") or "",
                "changed": int(r.get("changed") or 0),
                "pr": pr,
                "tip": tip,
                "prod": prod,
            }
        )

    for p in prs:
        snapshot["prs"].append(
            {
                "repo": p.get("repo") or "",
                "number": p.get("number") or "",
                "checks": p.get("checks") or None,
                "merge": p.get("merge") or None,
                "review": p.get("review") or None,
                "title": p.get("title") or "",
                "display_title": p.get("display_title") or p.get("title") or "",
                "slug": p.get("slug") or "",
                "url": p.get("url") or None,
                "follow_tip_build": p.get("follow_tip_build") or None,
                "follow_prod_build": p.get("follow_prod_build") or None,
                "archived": bool(p.get("archived")),
                "merged_on": p.get("merged_on") or None,
                "draft": bool(p.get("draft")),
                "on_branch": bool(p.get("on_branch")),
            }
        )

    for o in orphans:
        snapshot["orphans"].append(
            {
                "repo": o.get("repo") or "",
                "branch": o.get("branch") or "",
                "state": o.get("state") or "",
            }
        )

    if meta.get("prs_empty_hint"):
        snapshot["prs_empty_hint"] = meta["prs_empty_hint"]

    return snapshot


def sh_quote(value: Any) -> str:
    if value is None:
        return "''"
    text = str(value)
    return "'" + text.replace("'", "'\"'\"'") + "'"


def emit_bash_state(snapshot: dict[str, Any]) -> str:
    lines: list[str] = []
    lines.append(f"_snapshot_stale={int(snapshot.get('stale_count') or 0)}")
    lines.append(
        "_snapshot_prs_empty="
        + ("'yes'" if snapshot.get("prs_empty_hint") else "'no'")
    )

    generated = snapshot.get("generated_at") or ""
    if generated:
        try:
            dt = datetime.strptime(generated, "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=timezone.utc
            )
            lines.append(f"_snapshot_epoch={int(dt.timestamp())}")
        except ValueError:
            pass

    def emit_array(name: str, values: list[str]) -> None:
        body = " ".join(sh_quote(v) for v in values)
        lines.append(f"{name}=( {body} )")

    repos = snapshot.get("repos") or []
    emit_array("CR_COLL", [r.get("collection") or "" for r in repos])
    emit_array("CR_DIR", [r.get("dir") or "" for r in repos])
    emit_array("CR_WT", [r.get("worktree") or "" for r in repos])
    emit_array("CR_SLUG", [r.get("slug") or "" for r in repos])
    emit_array("CR_LABEL", [r.get("branch") or "" for r in repos])
    emit_array(
        "CR_BRANCH",
        [r.get("branch_display") or r.get("branch") or "" for r in repos],
    )
    emit_array("CR_AHEAD", [str(r.get("ahead") or 0) for r in repos])
    emit_array("CR_BEHIND", [str(r.get("behind") or 0) for r in repos])
    emit_array("CR_TREE", [r.get("tree") or "clean" for r in repos])
    emit_array(
        "CR_PR_NUM",
        [(r.get("pr") or {}).get("number") or "" for r in repos],
    )
    emit_array(
        "CR_PR_CHECKS",
        [(r.get("pr") or {}).get("checks") or "" for r in repos],
    )
    emit_array(
        "CR_PR_MERGE",
        [(r.get("pr") or {}).get("merge") or "" for r in repos],
    )
    emit_array(
        "CR_PR_REVIEW",
        [(r.get("pr") or {}).get("review") or "" for r in repos],
    )
    emit_array(
        "CR_PR_DRAFT",
        ["yes" if (r.get("pr") or {}).get("draft") else "no" for r in repos],
    )
    emit_array(
        "CR_TIP_CHECKS",
        [(r.get("tip") or {}).get("checks") or "" for r in repos],
    )
    emit_array(
        "CR_TIP_URL",
        [(r.get("tip") or {}).get("url") or "" for r in repos],
    )
    emit_array(
        "CR_PROD_CHECKS",
        [(r.get("prod") or {}).get("checks") or "" if r.get("prod") else "" for r in repos],
    )
    emit_array(
        "CR_PROD_URL",
        [(r.get("prod") or {}).get("url") or "" if r.get("prod") else "" for r in repos],
    )

    prs = snapshot.get("prs") or []
    emit_array("PR_ROW_REPO", [p.get("repo") or "" for p in prs])
    emit_array("PR_ROW_NUM", [str(p.get("number") or "") for p in prs])
    emit_array("PR_ROW_CHECKS", [p.get("checks") or "" for p in prs])
    emit_array("PR_ROW_MERGE", [p.get("merge") or "" for p in prs])
    emit_array("PR_ROW_REVIEW", [p.get("review") or "" for p in prs])
    emit_array(
        "PR_ROW_TITLE",
        [p.get("display_title") or p.get("title") or "" for p in prs],
    )
    emit_array("PR_ROW_SLUG", [p.get("slug") or "" for p in prs])
    emit_array(
        "PR_ROW_ARCHIVED",
        ["yes" if p.get("archived") else "no" for p in prs],
    )
    emit_array(
        "PR_ROW_DRAFT",
        ["yes" if p.get("draft") else "no" for p in prs],
    )
    emit_array(
        "PR_ROW_ON_BRANCH",
        ["yes" if p.get("on_branch") else "no" for p in prs],
    )

    orphan_lines = [
        f"{o.get('repo', '')}\t{o.get('branch', '')}\t{o.get('state', '')}"
        for o in (snapshot.get("orphans") or [])
    ]
    orphan_blob = "\n".join(orphan_lines)
    if orphan_lines:
        orphan_blob += "\n"
    lines.append(f"SNAPSHOT_PRS_ORPHANS={sh_quote(orphan_blob)}")
    lines.append("snapshot_loaded=yes")
    return "\n".join(lines) + "\n"


def format_md(snapshot: dict[str, Any]) -> str:
    lines: list[str] = []
    coll = snapshot.get("collection") or "(all)"
    lines.append(f"# {coll}")
    lines.append("")
    lines.append(f"Generated: {snapshot.get('generated_at', '')}")
    lines.append("")

    lines.append("## Repos")
    lines.append("")
    if not snapshot.get("repos"):
        lines.append("- (none)")
    else:
        for r in snapshot["repos"]:
            branch = r.get("branch_display") or r.get("branch") or "?"
            tree = r.get("tree") or "clean"
            parts = [f"**{r.get('dir', '?')}** (`{branch}`) — {tree}"]

            ahead = r.get("ahead") or 0
            behind = r.get("behind") or 0
            if ahead:
                parts.append(f"↑{ahead}")
            if behind:
                parts.append(f"↓{behind}")

            pr = r.get("pr")
            if pr and pr.get("number"):
                pr_bits = [f"#{pr['number']}"]
                if pr.get("draft"):
                    pr_bits.append("DRAFT")
                for key in ("checks", "merge", "review"):
                    val = pr.get(key)
                    if key == "review":
                        label = REVIEW_LABEL.get(val or "", "")
                        if label:
                            pr_bits.append(label)
                        elif val and val not in ("none", ""):
                            g = glyph(val)
                            if g and g not in ("·", " "):
                                pr_bits.append(g)
                        continue
                    g = glyph(val)
                    if g and g not in ("·", " "):
                        pr_bits.append(g)
                parts.append("PR " + " ".join(pr_bits))

            tip = r.get("tip")
            prod = r.get("prod")
            build_bits: list[str] = []
            if tip:
                lbl = build_label(tip.get("checks"), tip.get("build"), tip.get("url"))
                if lbl:
                    build_bits.append(f"tip {lbl}")
            if prod:
                lbl = build_label(prod.get("checks"), prod.get("build"), prod.get("url"))
                if lbl:
                    build_bits.append(f"prod {lbl}")
            if build_bits:
                parts.append("; ".join(build_bits))

            lines.append("- " + "; ".join(parts))

    stale = int(snapshot.get("stale_count") or 0)
    if stale:
        lines.append("")
        lines.append(f"_{stale} worktree(s) behind remote — catch-up needed._")

    lines.append("")
    lines.append("## PRs")
    lines.append("")
    prs = snapshot.get("prs") or []
    active = [p for p in prs if not p.get("archived")]
    archived = [p for p in prs if p.get("archived")]
    if not active and not archived:
        hint = snapshot.get("prs_empty_hint")
        if hint:
            lines.append(
                "- (none enlisted — `tools/wtc-pr.sh enlist <repo> <n>`)"
            )
        else:
            lines.append("- (none)")
    else:
        if not active:
            lines.append("- (none open)")
        for p in active:
            bits = [f"**{p.get('repo', '?')}**", f"#{p.get('number', '?')}"]
            if p.get("on_branch"):
                bits.append("⚠ MERGED — still on branch; catch-up")
            elif p.get("draft"):
                bits.append("**DRAFT**")
            merge = p.get("merge")
            if not p.get("on_branch") and merge in ("FOLLOW", "MERGED"):
                bits.append("_merged_")
            if not p.get("on_branch"):
                for key in ("checks", "merge", "review"):
                    val = p.get(key)
                    if key == "review":
                        label = REVIEW_LABEL.get(val or "", "")
                        if label:
                            bits.append(label)
                        continue
                    if key == "merge" and val in ("FOLLOW", "MERGED", "UNKNOWN", None):
                        continue
                    g = glyph(val)
                    if g and g not in ("·", " "):
                        bits.append(g)
            title = p.get("title") or ""
            url = p.get("url")
            if url and p.get("number"):
                bits.append(link(url, title or f"PR #{p['number']}"))
            elif title:
                bits.append(title)
            if not p.get("on_branch"):
                follow_tip = p.get("follow_tip_build")
                follow_prod = p.get("follow_prod_build")
                if follow_tip or follow_prod:
                    follow = []
                    if follow_tip:
                        follow.append(f"tip {follow_tip}")
                    if follow_prod:
                        follow.append(f"prod {follow_prod}")
                    bits.append(" ".join(follow))
            lines.append("- " + " ".join(bits))

        if archived:
            lines.append("")
            lines.append("## Archived")
            lines.append("")
            lines.append(
                "_Merged PRs past 48 weekday-hours (weekends excluded)._"
            )
            lines.append("")
            for p in archived:
                bits = [f"**{p.get('repo', '?')}**", f"#{p.get('number', '?')}"]
                title = p.get("title") or ""
                url = p.get("url")
                if url and p.get("number"):
                    bits.append(link(url, title or f"PR #{p['number']}"))
                elif title:
                    bits.append(title)
                if p.get("merged_on"):
                    bits.append(f"merged {p['merged_on']}")
                lines.append("- " + " ".join(bits))

    orphans = snapshot.get("orphans") or []
    if orphans:
        lines.append("")
        lines.append("## Orphans")
        lines.append("")
        for o in orphans:
            lines.append(
                f"- **{o.get('repo', '?')}** on `{o.get('branch', '?')}` — "
                f"PR {o.get('state', '?')}; catch-up returns it to the tip"
            )

    lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json", action="store_true", help="emit canonical JSON")
    parser.add_argument("--md", action="store_true", help="emit agent markdown")
    parser.add_argument(
        "--bash-state",
        action="store_true",
        help="emit bash assignments from canonical JSON on stdin",
    )
    args = parser.parse_args()

    if args.bash_state:
        snapshot = json.load(sys.stdin)
        sys.stdout.write(emit_bash_state(snapshot))
        return 0

    records: list[dict[str, Any]] = []
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        records.append(json.loads(line))

    snapshot = assemble(records)

    if args.md:
        sys.stdout.write(format_md(snapshot))
    else:
        json.dump(snapshot, sys.stdout, indent=2, sort_keys=False)
        sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
