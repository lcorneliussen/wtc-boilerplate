#!/usr/bin/env python3
"""Display-width helpers for ANSI table rows.

Strips CSI colours and OSC-8 hyperlinks before measuring/fitting so a
truncated never leaves an open hyperlink that eats the next rows.
"""
from __future__ import annotations

import re
import sys

CSI = re.compile(r"\033\[[0-9;]*m")
# OSC-8: ESC ] 8 ; ; url ST   …   ESC ] 8 ; ; ST   (ST = ESC \ or BEL)
OSC8 = re.compile(r"\033\]8;[^\033\x07]*?(?:\033\\|\x07)")


def strip_ansi(s: str) -> str:
    return CSI.sub("", OSC8.sub("", s))


def strip_csi(s: str) -> str:
    """Back-compat name — also drops OSC-8."""
    return strip_ansi(s)


def vislen(s: str) -> int:
    return len(strip_ansi(s))


def visrstrip(s: str) -> str:
    """Drop trailing blanks but keep the colour resets that follow them.

    A row padded out to the pane width has nothing visible in its last column
    yet still occupies it, so the terminal wraps and the record gains a blank
    line it never asked for.
    """
    toks: list[tuple[bool, str]] = []
    i = 0
    while i < len(s):
        m = OSC8.match(s, i)
        if m:
            # Keep as opaque escape so fit does not chop mid-link; vislen ignores.
            toks.append((True, m.group(0)))
            i = m.end()
            continue
        m = CSI.match(s, i)
        if m:
            toks.append((True, m.group(0)))
            i = m.end()
            continue
        toks.append((False, s[i]))
        i += 1
    end = len(toks)
    while end > 0:
        is_esc, val = toks[end - 1]
        if is_esc or val in " \t":
            end -= 1
            continue
        break
    tail = [t for t in toks[end:] if t[0]]
    return "".join(v for _, v in toks[:end] + tail)


def visfit(s: str, width: int) -> str:
    """Fit to width using visible columns; keep OSC-8 when nothing is truncated.

    Truncation flattens hyperlinks to their label text so we never emit a
    partial OSC-8 sequence that would eat the rest of the pane.
    """
    if width < 0:
        width = 0
    if vislen(s) <= width:
        return s
    # Truncating: drop OSC-8 wrappers, keep the visible label.
    s = OSC8.sub("", s)
    out: list[str] = []
    vis = 0
    i = 0
    prefix = ""
    while i < len(s):
        m = CSI.match(s, i)
        if m:
            prefix += m.group(0)
            i = m.end()
            continue
        if vis >= width:
            break
        out.append(s[i])
        vis += 1
        i += 1
    return prefix + "".join(out) + "\033[0m"


def main() -> None:
    if len(sys.argv) < 3 or sys.argv[1] not in ("len", "fit"):
        print("usage: wtc-status-ansi.py len|fit WIDTH", file=sys.stderr)
        sys.exit(2)
    width = int(sys.argv[2])
    text = sys.stdin.read().rstrip("\n")
    if sys.argv[1] == "len":
        print(vislen(text))
    else:
        sys.stdout.write(visfit(visrstrip(text), width))


if __name__ == "__main__":
    main()
