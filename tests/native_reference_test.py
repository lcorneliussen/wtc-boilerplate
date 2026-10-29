#!/usr/bin/env python3
"""Check that the reference guidance targets the pinned native CLI."""

import json
import re
import subprocess
import tomllib
from pathlib import Path


root = Path(__file__).resolve().parents[1]
pin = (root / ".wtc-cli-version").read_text().strip()
version = subprocess.check_output(["wtc", "--version"], text=True).strip()
assert version == f"wtc version {pin}", (version, pin)

major, minor, patch = map(int, pin.split("."))
assert (major, minor, patch) >= (0, 1, 40), "service guidance needs released wtc >=0.1.40"
compat = re.search(r'(?m)^requires = "([^"]+)"$', (root / "wtc.toml").read_text())
assert compat and compat.group(1) == f">={pin},<{major}.{minor + 1}", compat.group(1) if compat else None

result = json.loads(subprocess.check_output(["wtc", "commands", "--json"], text=True))
commands = {item["name"] for item in result["data"]}
required = {
    "add-repo", "agent-env", "browse", "catch-up", "customize", "env", "mcp", "new",
    "open", "pr", "registry", "retire", "review", "secrets", "skills", "status",
    "svc", "up", "down", "restart", "logs", "docs", "harness",
}
assert required <= commands, sorted(required - commands)

add_repo_help = subprocess.check_output(["wtc", "add-repo", "--help"], text=True)
assert "wtc add-repo <repo|clone-url|path> [...]" in add_repo_help, add_repo_help
assert "--collection string" in add_repo_help, add_repo_help
for relative in ("skills/wtc-add-repo/SKILL.md", "instructions/worktree-workspace.md"):
    guidance = (root / relative).read_text()
    assert "wtc add-repo <repo>" in guidance, relative
    assert "wtc add-repo <collection>" not in guidance, relative

documented_options = {
    ("svc", "tunnel"): ("--public", "--stop"),
    ("svc", "render"): ("--dry-run",),
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

# Check the opt-in recipe against the installed release, without starting services.
runtime = (root / "instructions/runtime.md").read_text()
embedded = subprocess.check_output(["wtc", "docs", "instructions/runtime.md"], text=True)
recipe = re.search(r"```toml\n(.*?)```", runtime, re.S)
assert recipe, "missing harness enablement recipe"
config = tomllib.loads(recipe.group(1))
assert config["runtime"]["backend"] == "dekit"
assert config["mise"]["tools"]["github:pvolok/dekit"] == "0.10.0"
assert recipe.group(1).strip() in embedded, "enablement recipe differs from pinned CLI"
assert "runtime" not in tomllib.loads((root / "wtc.toml").read_text()), "runtime must remain opt-in"

# Bootstrap and runtime references must resolve to the selected published version,
# rather than a mutable development branch. Local links are checked from their
# installed location: collection-AGENTS.md becomes the collection's AGENTS.md.
for relative in ("bootstrap.md", "instructions/runtime.md", "examples/runtime/README.md",
                 "collection-AGENTS.md"):
    text = (root / relative).read_text()
    assert not re.search(r"candidate|unreleased|locally built candidate", text, re.I), relative
    for url in re.findall(r"https://github.com/lcorneliussen/wtc-cli/blob/([^ )]+)", text):
        assert url.startswith(f"v{pin}/"), (relative, url)
    for target in re.findall(r"\]\(([^)]+)\)", text):
        if "://" in target or target.startswith("#"):
            continue
        target = target.split("#")[0]
        if relative == "collection-AGENTS.md":
            assert target.startswith("harness/"), target
            resolved = root / target.removeprefix("harness/")
        else:
            resolved = (root / relative).parent / target
        assert resolved.exists(), (relative, target)

agent_entry = (root / "collection-AGENTS.md").read_text()
assert "[runtime] backend = \"dekit\"" in agent_entry
assert "/wtc-svc" in agent_entry and "wtc svc" in agent_entry
print("released runtime/bootstrap structure: opt-in recipe, service entry point, versioned links")
