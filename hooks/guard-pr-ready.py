#!/usr/bin/env python3
"""PreToolUse / beforeShellExecution: refuse raw "mark PR ready" commands.

A draft PR is undrafted only through tools/bb-pr-ready.sh, which checks that a
current local review exists (review/README.md § Gate). Blocks, when they are
the command being run (tokenized with shlex; split on ; && || | newline; `bash -c`,
`eval` and $(...) are recursed into; quoted arguments of other commands are not
commands):
  * bb pr ready …
  * gh pr ready …
`bb pr edit` has no draft flag, so there is no second route to guard.

Allows: tools/bb-pr-ready.sh (its own `bb pr ready` runs in a subprocess, not on
the agent's command line — matching the command string is enough).

Escape hatch (explicit user ask only):
  WTC_ALLOW_RAW_PR_READY=1

Exit 2 = deny. Fail-open on parse errors. Same I/O conventions as
block-prod-writes.sh.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import sys

# A command position: start, or after ; & | ( newline, optionally behind env
# assignments and wrappers such as exec/env/command/sudo/time/xargs.
_RAW_READY = re.compile(
    r"(?:^|[;&|(\n`]|\bthen\b|\bdo\b|\$\()\s*"
    r"(?:\w+=\S*\s+)*"
    r"(?:(?:exec|env|command|sudo|time|nohup|xargs)\s+(?:-\S+\s+)*)*"
    r"(?:\S*/)?(?P<cli>bb|gh)\s+(?:-{1,2}\S+(?:\s+\S+)?\s+)*pr\s+ready\b"
)


def extract_command(raw: str) -> str:
    raw = raw.strip()
    if not raw:
        return ""
    try:
        ev = json.loads(raw)
    except Exception:
        return raw
    if not isinstance(ev, dict):
        return ""
    cmd = (
        ev.get("command")
        or (ev.get("toolInput") or {}).get("command")
        or (ev.get("tool_input") or {}).get("command")
        or ""
    )
    return cmd if isinstance(cmd, str) else ""


def deny(reason: str) -> None:
    print(reason, file=sys.stderr)
    payload = {
        "permission": "deny",
        "user_message": reason,
        "agent_message": reason,
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        },
    }
    json.dump(payload, sys.stdout)
    print()
    raise SystemExit(2)


_SEP_CHARS = set(";&|()")
_WRAPPERS = {"exec", "env", "command", "builtin", "sudo", "time", "nohup", "xargs", "nice", "timeout"}
_KEYWORDS = {"then", "do", "else", "elif", "if", "while", "until", "!", "{", "}"}
_SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
_MAX_DEPTH = 6


def _strip_heredocs(cmd: str) -> str:
    """Drop heredoc bodies: they are data, not commands."""
    out, delim = [], None
    for line in cmd.split("\n"):
        if delim is not None:
            if line.strip() == delim:
                delim = None
            continue
        out.append(line)
        m = re.search(r"<<-?\s*(?:'([^']+)'|\"([^\"]+)\"|\\?(\w+))", line)
        if m:
            delim = m.group(1) or m.group(2) or m.group(3)
    return "\n".join(out)


def _newlines_to_semicolons(cmd: str) -> str:
    """Unquoted newlines separate commands; quoted ones are text."""
    out, q, esc = [], None, False
    for ch in cmd:
        if esc:
            esc = False
            out.append(ch)
            continue
        if ch == "\\" and q != "'":
            esc = True
        elif q:
            if ch == q:
                q = None
        elif ch in "'\"":
            q = ch
        elif ch == "\n":
            ch = " ; "
        out.append(ch)
    return "".join(out)


def _substitutions(cmd: str):
    """Bodies of $(...) and `...` outside single quotes (the shell runs them,
    even inside double quotes)."""
    masked, quote, escaped = [], None, False
    for ch in cmd:
        if escaped:
            masked.append(" " if quote == "'" else ch)
            escaped = False
            continue
        if ch == "\\" and quote != "'":
            escaped = True
            masked.append(" " if quote == "'" else ch)
            continue
        if ch == quote:
            masked.append(" " if quote == "'" else ch)
            quote = None
            continue
        if quote is None and ch in "'\"":
            quote = ch
            masked.append(" " if ch == "'" else ch)
            continue
        masked.append(" " if quote == "'" else ch)
    no_single = "".join(masked)
    for m in re.finditer(r"\$\(([^()]*)\)", no_single):
        yield m.group(1)
    for m in re.finditer(r"`([^`]*)`", no_single):
        yield m.group(1)


def _simple_commands(cmd: str):
    lex = shlex.shlex(_newlines_to_semicolons(cmd), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    cur = []
    for tok in lex:  # ValueError on unbalanced quotes: caller falls back
        if tok and set(tok) <= _SEP_CHARS:
            if cur:
                yield cur
            cur = []
        else:
            cur.append(tok)
    if cur:
        yield cur


def _find_raw_ready(cmd: str, depth: int = 0):
    """Return 'bb' | 'gh' when a command in `cmd` marks a PR ready, else None."""
    if depth > _MAX_DEPTH:
        return None
    cmd = _strip_heredocs(cmd)
    for inner in _substitutions(cmd):
        hit = _find_raw_ready(inner, depth + 1)
        if hit:
            return hit
    for words in _simple_commands(cmd):
        i = 0
        while i < len(words):
            w = words[i]
            if re.match(r"^[A-Za-z_]\w*=", w) or w in _KEYWORDS:
                i += 1
            elif w in _WRAPPERS:
                i += 1
                while i < len(words) and (words[i].startswith("-") or words[i].isdigit()
                                          or re.match(r"^[A-Za-z_]\w*=", words[i])):
                    i += 1
            else:
                break
        if i >= len(words):
            continue
        prog = os.path.basename(words[i])
        args = words[i + 1:]
        if prog in ("bb", "gh"):
            if any(a == "pr" and b == "ready" for a, b in zip(args, args[1:])) and "--undo" not in args:
                return prog
        elif prog in _SHELLS:
            for j, a in enumerate(args):
                if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a) and j + 1 < len(args):
                    hit = _find_raw_ready(args[j + 1], depth + 1)
                    if hit:
                        return hit
                    break
        elif prog == "eval":
            hit = _find_raw_ready(" ".join(args), depth + 1)
            if hit:
                return hit
    return None


def check_pr_ready(cmd: str) -> None:
    if os.environ.get("WTC_ALLOW_RAW_PR_READY") == "1":
        return
    try:
        cli = _find_raw_ready(cmd)
    except ValueError:  # shlex could not parse: fail open on the parser, keep the regex net
        m = _RAW_READY.search(cmd)
        cli = m.group("cli") if m else None
    if not cli:
        return
    deny(
        f"Raw `{cli} pr ready` is blocked: a draft PR is marked ready only after a "
        "current local review. Run /wtc-local-review, then use "
        "harness/tools/bb-pr-ready.sh <n> from the repo worktree "
        "(only when the user asked to undraft). "
        "Escape hatch after an explicit user ask: WTC_ALLOW_RAW_PR_READY=1"
    )


def main() -> None:
    raw = sys.stdin.read()
    try:
        cmd = extract_command(raw)
    except Exception:
        return
    if not cmd.strip():
        return
    check_pr_ready(cmd)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception:
        raise SystemExit(0)
