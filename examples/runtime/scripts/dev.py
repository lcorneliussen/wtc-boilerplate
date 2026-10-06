#!/usr/bin/env python3
"""Synthetic existing launch command: cached build plus a nested web process."""
import os
import pathlib
import signal
import subprocess
import sys

cache = pathlib.Path('.build-cache')
print('BUILD cached' if cache.exists() else 'BUILD fresh', flush=True)
cache.touch()
# SIGTERM must unwind through `finally`, or the nested web process is orphaned.
signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
child = subprocess.Popen([sys.executable, str(pathlib.Path(__file__).with_name('server.py'))])
pathlib.Path('child.pid').write_text(str(child.pid))
try:
    sys.exit(child.wait())
finally:
    if child.poll() is None:
        child.terminate()
        child.wait()
