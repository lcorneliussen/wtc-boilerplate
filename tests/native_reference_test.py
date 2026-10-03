#!/usr/bin/env python3
"""Check that the reference guidance targets the pinned native CLI."""

import json
import re
import subprocess
from pathlib import Path


root = Path(__file__).resolve().parents[1]
pin = (root / ".wtc-cli-version").read_text().strip()
version = subprocess.check_output(["wtc", "--version"], text=True).strip()
assert version == f"wtc version {pin}", (version, pin)

major, minor, _ = map(int, pin.split("."))
compat = re.search(r'(?m)^requires = "([^"]+)"$', (root / "wtc.toml").read_text())
assert compat and compat.group(1) == f">={pin},<{major}.{minor + 1}", compat.group(1) if compat else None

result = json.loads(subprocess.check_output(["wtc", "commands", "--json"], text=True))
commands = {item["name"] for item in result["data"]}
required = {
    "add-repo", "agent-env", "browse", "catch-up", "env", "mcp", "new",
    "open", "pr", "registry", "retire", "review", "secrets", "skills", "status",
}
assert required <= commands, sorted(required - commands)

add_repo_help = subprocess.check_output(["wtc", "add-repo", "--help"], text=True)
assert "wtc add-repo <repo> [repo ...]" in add_repo_help, add_repo_help
assert "--collection string" in add_repo_help, add_repo_help
for relative in ("skills/wtc-add-repo/SKILL.md", "instructions/worktree-workspace.md"):
    guidance = (root / relative).read_text()
    assert "wtc add-repo <repo>" in guidance, relative
    assert "wtc add-repo <collection>" not in guidance, relative

documented_options = {
    ("new",): ("--issue", "--tracker", "--pr"),
    ("catch-up",): ("--all", "--repos", "--reload-status"),
    ("status",): ("--tui", "--no-watch", "--silent"),
    ("secrets", "link"): ("--repo", "--include-prod"),
    ("skills", "render"): ("--seed-scope", "--all"),
    ("mcp", "render"): ("--all", "--dry-run"),
    ("review", "bundle"): ("--public", "--no-catch-up"),
}
for command, flags in documented_options.items():
    help_text = subprocess.check_output(["wtc", *command, "--help"], text=True)
    for flag in flags:
        assert flag in help_text, (command, flag)

for path in [*root.glob("*.md"), *(root / "instructions").glob("*.md"),
             *(root / "review").glob("*.md"), *(root / "skills").glob("*/SKILL.md")]:
    text = path.read_text()
    assert not re.search(r"(?:harness/)?tools/[\w.-]+\.sh", text), path

print(f"native reference guidance: wtc {pin}, {len(required)} commands")
