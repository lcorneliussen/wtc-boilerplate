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

result = json.loads(subprocess.check_output(["wtc", "commands", "--json"], text=True))
commands = {item["name"] for item in result["data"]}
required = {
    "add-repo", "agent-env", "browse", "catch-up", "env", "mcp", "new",
    "open", "pr", "registry", "retire", "review", "secrets", "skills", "status",
}
assert required <= commands, sorted(required - commands)

for path in [*root.glob("*.md"), *(root / "instructions").glob("*.md"),
             *(root / "review").glob("*.md"), *(root / "skills").glob("*/SKILL.md")]:
    text = path.read_text()
    assert not re.search(r"(?:harness/)?tools/[\w.-]+\.sh", text), path

print(f"native reference guidance: wtc {pin}, {len(required)} commands")
