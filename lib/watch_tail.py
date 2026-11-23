#!/usr/bin/env python3
"""Print a running worker's last few actions for ``orchestra-worker watch``.

Usage: lib/watch_tail.py <run.json> <N>

Read-only and best-effort: a dead pid, a missing log or a broken progress reader prints nothing,
and the exit status is always 0 so one bad run cannot break the watch view.
"""

import json
import os
import subprocess
import sys


def show(path, count):
    try:
        with open(path, encoding="utf-8") as state_file:
            state = json.load(state_file)
        pid = int(state.get("pid") or 0)
        if pid <= 0:
            return
        try:
            os.kill(pid, 0)  # raises when the process is gone
        except PermissionError:
            pass  # alive, just not ours
        events = state.get("events") or ""
        progress = state.get("progress") or ""
        if not (os.path.isfile(events) and os.path.isfile(progress)):
            return
        result = subprocess.run(
            [sys.executable, "-I", progress, "tail", events, "--lines", str(count)],
            capture_output=True, text=True, timeout=5,
        )
        lines = result.stdout.splitlines()
        if not lines:
            return
        task = state.get("task", "?")
        suffix = " (scout)" if state.get("kind") == "scout" else ""
        sys.stdout.write("\n" + f"{task}{suffix}:" + "\n")
        for line in lines:
            sys.stdout.write("  " + line + "\n")
        sys.stdout.flush()
    except Exception:
        return


def main(argv):
    if len(argv) < 3:
        return
    try:
        count = int(argv[2])
    except (TypeError, ValueError):
        return
    show(argv[1], count)


if __name__ == "__main__":
    main(sys.argv)
    sys.exit(0)
