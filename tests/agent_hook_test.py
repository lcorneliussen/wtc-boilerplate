#!/usr/bin/env python3
"""The generated agent hook reaches the CLI from nested worktree folders."""

import json
import os
import subprocess
import tempfile
from pathlib import Path


root = Path(__file__).resolve().parents[1]
hooks = json.loads((root / "hooks/agent-env.json").read_text())["hooks"]
guard_command = hooks["PreToolUse"][0]["hooks"][1]["command"]
commands = {
    "--write": hooks["SessionStart"][0]["hooks"][0]["command"],
    "--wrap": hooks["PreToolUse"][0]["hooks"][0]["command"],
}

with tempfile.TemporaryDirectory() as tmp:
    base = Path(tmp)
    collection = base / "topic"
    nested = collection / "app" / "src"
    nested.mkdir(parents=True)
    (collection / "harness").mkdir()
    (collection / "harness" / "hooks").mkdir()
    (collection / "harness" / "hooks" / "guard-pr-ready.py").write_bytes(
        (root / "hooks" / "guard-pr-ready.py").read_bytes()
    )
    (collection / "harness" / ".wtc-cli-version").write_text(
        (root / ".wtc-cli-version").read_text()
    )
    binary = base / "bin"
    binary.mkdir()
    log = base / "calls"
    wtc = binary / "wtc"
    wtc.write_text('#!/bin/sh\nprintf "%s|%s\\n" "$PWD" "$*" >> "$WTC_HOOK_LOG"\n')
    wtc.chmod(0o755)
    env = dict(os.environ, PATH=f"{binary}:/usr/bin:/bin", WTC_HOOK_LOG=str(log), CLAUDE_PROJECT_DIR=str(nested))

    for mode, command in commands.items():
        subprocess.run(["bash", "-c", command], cwd=nested, env=env, input="{}", text=True, check=True)
    assert log.read_text().splitlines() == [
        f"{collection}|agent-env --write",
        f"{collection}|agent-env --wrap",
    ]

    mise = binary / "mise"
    mise.write_text('#!/bin/sh\nprintf "%s|%s\\n" "$PWD" "$*" >> "$WTC_HOOK_LOG"\n')
    mise.chmod(0o755)
    log.unlink()
    subprocess.run(["bash", "-c", commands["--wrap"]], cwd=nested, env=env, input="{}", text=True, check=True)
    assert log.read_text().splitlines() == [f"{collection}|exec -- wtc agent-env --wrap"]
    mise.write_text('#!/bin/sh\nprintf "%s|%s\\n" "$PWD" "$*" >> "$WTC_HOOK_LOG"\nexit 42\n')
    log.unlink()
    for mode, command in commands.items():
        subprocess.run(["bash", "-c", command], cwd=nested, env=env, input="{}", text=True, check=True)
    assert log.read_text().splitlines() == [
        f"{collection}|exec -- wtc agent-env --write",
        f"{collection}|agent-env --write",
        f"{collection}|exec -- wtc agent-env --wrap",
        f"{collection}|agent-env --wrap",
    ]
    mise.unlink()

    log.unlink()
    env["CLAUDE_PROJECT_DIR"] = str(base)
    subprocess.run(["bash", "-c", commands["--wrap"]], cwd=base, env=env, input="{}", text=True, check=True)
    assert not log.exists(), "hook acted outside a collection"

    guarded = subprocess.run(["bash", "-c", guard_command], cwd=nested, env=dict(env, CLAUDE_PROJECT_DIR=str(nested)),
                             input=json.dumps({"tool_input": {"command": "gh pr ready 12"}}),
                             text=True, capture_output=True)
    assert guarded.returncode == 2, guarded
    assert json.loads(guarded.stdout)["hookSpecificOutput"]["permissionDecision"] == "deny"

print("agent hook: nested collection routing and outside fail-open")

guard = root / "hooks" / "guard-pr-ready.py"
for command in ("gh pr ready 12", "bb pr ready 12", "bash -c 'gh pr ready 12'",
                "eval 'gh pr ready 12'", "echo $(gh pr ready 12)"):
    result = subprocess.run(["python3", str(guard)], input=json.dumps({"tool_input": {"command": command}}),
                            text=True, capture_output=True)
    assert result.returncode == 2, (command, result)
    assert "wtc review ready" in result.stderr, result.stderr
    assert json.loads(result.stdout)["hookSpecificOutput"]["permissionDecision"] == "deny"
for command in ("wtc review ready 12", 'echo "gh pr ready 12"'):
    result = subprocess.run(["python3", str(guard)], input=json.dumps({"tool_input": {"command": command}}),
                            text=True, capture_output=True)
    assert result.returncode == 0, (command, result)
result = subprocess.run(["python3", str(guard)], input=json.dumps({"tool_input": {"command": "gh pr ready 12"}}),
                        text=True, capture_output=True, env=dict(os.environ, WTC_ALLOW_RAW_PR_READY="1"))
assert result.returncode == 0, result
print("ready guard: raw commands denied; native command and explicit escape allowed")
