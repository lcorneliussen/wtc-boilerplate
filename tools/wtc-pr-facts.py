#!/usr/bin/env python3
"""Shared PR review / archive facts for wtc-status.

CLI:
  wtc-pr-facts.py gh-from-json          # stdin: gh pr view JSON → TSV enrich line
  wtc-pr-facts.py is-archived <iso>     # exit 0 past the archive window
                                        # (48 weekday-hours; WTC_PR_ARCHIVE_HOURS)
  wtc-pr-facts.py weekday-hours <iso>   # print elapsed weekday hours (float)

GitHub-only: this implementation talks to GitHub (gh) and nothing else. A
second forge was dropped rather than stubbed — there is nothing here that
would ever call it. The seam is `forge_for_repo` / `pr_url_for` in lib.sh,
which is where one would attach.

Enrich TSV (same shape as wtc_pr_enrich):
  number \\t state \\t checks \\t merge \\t review \\t title \\t merge_commit \\t merged_on

state is OPEN|DRAFT|MERGED|DECLINED|CLOSED|SUPERSEDED (DRAFT = open draft).
review tokens: noreviewers|waiting|commented|changes|approved|merged|none|<N>
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from typing import Any


# How long a merged PR keeps its row before collapsing behind the `a` toggle.
# Weekday hours, so a Friday merge is still visible on Monday rather than
# ageing out across a weekend nobody was working. Override with
# WTC_PR_ARCHIVE_HOURS: a team on a different rhythm should not have to patch
# this file. A bad value falls back rather than raising — this number decides
# what is *shown*, so getting it wrong must never break a render.
ARCHIVE_WEEKDAY_HOURS = 48.0
try:
    _h = float(os.environ.get("WTC_PR_ARCHIVE_HOURS") or ARCHIVE_WEEKDAY_HOURS)
    if _h > 0:
        ARCHIVE_WEEKDAY_HOURS = _h
except ValueError:
    pass


def parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    text = value.strip()
    if not text:
        return None
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc)


def weekday_hours_between(start: datetime, end: datetime) -> float:
    """Count hours between start and end that fall on Mon-Fri (UTC)."""
    if end <= start:
        return 0.0
    total = 0.0
    cur = start
    while cur < end:
        # advance to next midnight or end, whichever first
        next_midnight = (cur.replace(hour=0, minute=0, second=0, microsecond=0)
                         + timedelta(days=1))
        chunk_end = end if end < next_midnight else next_midnight
        if cur.weekday() < 5:  # Mon=0 ... Fri=4
            total += (chunk_end - cur).total_seconds() / 3600.0
        cur = chunk_end
    return total


def is_archived(merged_on: str | None, now: datetime | None = None,
                hours: float = ARCHIVE_WEEKDAY_HOURS) -> bool:
    start = parse_iso(merged_on)
    if start is None:
        return False
    if now is None:
        now = datetime.now(timezone.utc)
    return weekday_hours_between(start, now) >= hours


def review_token_gh(pr: dict[str, Any], *, merged: bool = False) -> str:
    state = (pr.get("state") or "").upper()
    if merged or state == "MERGED":
        return "merged"
    decision = (pr.get("reviewDecision") or "").upper()
    if decision == "CHANGES_REQUESTED":
        return "changes"
    if decision == "APPROVED":
        return "approved"
    # requestedReviews / latestReviews when present
    requested = pr.get("reviewRequests") or pr.get("requestedReviews") or []
    # gh --json reviewRequests yields [{login...}] or similar
    latest = pr.get("latestReviews") or []
    if bool(pr.get("isDraft")):
        if not requested and not latest:
            return "none"
        if decision == "REVIEW_REQUIRED" or (requested and not latest):
            return "waiting"
        if latest:
            return "commented"
        return "none"
    if not requested and not latest and decision in ("", "NONE"):
        # No reviewers assigned
        return "noreviewers"
    if latest and decision in ("", "NONE", "REVIEW_REQUIRED"):
        return "commented"
    if requested or decision == "REVIEW_REQUIRED":
        return "waiting"
    return "none"


def enrich_gh(pr: dict[str, Any], num: str, title: str) -> str:
    state = (pr.get("state") or "OPEN").upper()
    if state == "OPEN" and pr.get("isDraft"):
        state = "DRAFT"
    t = (pr.get("title") or title or "").replace("\t", " ").replace("\n", " ")
    checks = "NONE"
    rollup = pr.get("statusCheckRollup") or []
    bad = {"FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"}
    concl = [(c.get("conclusion") or c.get("state") or "").upper() for c in rollup]
    stat = [(c.get("status") or "").upper() for c in rollup]
    if any(c in bad for c in concl):
        checks = "FAILURE"
    elif any(st and st != "COMPLETED" for st in stat):
        checks = "PENDING"
    elif any(c in ("SUCCESS", "NEUTRAL", "SKIPPED") for c in concl):
        checks = "SUCCESS"
    if pr.get("isDraft") and checks == "NONE":
        checks = "draft"
    review = review_token_gh(pr, merged=(state == "MERGED"))
    mc = ((pr.get("mergeCommit") or {}) or {}).get("oid") or ""
    merged_on = ""
    if state == "MERGED":
        merged_on = pr.get("mergedAt") or pr.get("updatedAt") or ""
    return "\t".join([
        str(pr.get("number") or num),
        state,
        checks,
        "UNKNOWN",
        review,
        t,
        mc,
        merged_on,
    ])


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "cmd",
        choices=(
            "gh-from-json",
            "is-archived",
            "weekday-hours",
        ),
    )
    parser.add_argument("arg", nargs="?", default="")
    parser.add_argument("--title", default="")
    parser.add_argument("--num", default="")
    args = parser.parse_args()

    if args.cmd == "is-archived":
        return 0 if is_archived(args.arg) else 1

    if args.cmd == "weekday-hours":
        start = parse_iso(args.arg)
        if start is None:
            print("0")
            return 1
        print(f"{weekday_hours_between(start, datetime.now(timezone.utc)):.2f}")
        return 0

    raw = sys.stdin.read()

    if args.cmd == "gh-from-json":
        pr = json.loads(raw)
        print(enrich_gh(pr, args.num or "0", args.title))
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
