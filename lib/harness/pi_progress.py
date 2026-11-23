#!/usr/bin/env python3
"""Read pi's JSON event log and report live progress.

Commands:
  follow <events> --task <T> --start <epoch> [--heartbeat <secs>] [--poll <secs>]
  snapshot <events>
  tail <events> [--lines N]

The log is pi's ``--mode json`` output: one JSON object per line. Logs reach 15 MB, almost all of it
``message_update`` lines, so a line is only parsed when it contains one of the event names below.
Standard library only.
"""

import argparse
import json
import os
import re
import signal
import sys
import time

# Cheap substring gate before json.loads. A line without one of these cannot be an event we use.
NEEDLES = ('"tool_execution_start"', '"turn_end"', '"message_end"', '"agent_end"', '"type":"session"')

SHORT_TOOLS = ("read", "edit", "write")


def want(line):
    for needle in NEEDLES:
        if needle in line:
            return True
    return False


def load_event(line):
    """Return the decoded object, or None for a line we ignore or that is not valid JSON."""
    if not want(line):
        return None
    try:
        event = json.loads(line)
    except ValueError:
        return None
    return event if isinstance(event, dict) else None


def collapse(text):
    return re.sub(r"\s+", " ", text).strip()


def cut(text):
    return text if len(text) <= 72 else text[:71] + "\u2026"


def strip_cwd(path, cwd):
    if cwd and path.startswith(cwd + "/"):
        return path[len(cwd) + 1:]
    return path


def action(event, cwd):
    """Return ``(tool name, target)`` for a tool_execution_start event."""
    tool = event.get("toolName") or ""
    args = event.get("args")
    if not isinstance(args, dict):
        args = {}
    if tool == "bash":
        command = args.get("command")
        if not isinstance(command, str):
            return tool, ""
        command = collapse(command)
        # Workers often start every command with "cd <worktree> &&": noise that would fill the whole line.
        if cwd:
            command = re.sub(r"^cd\s+['\"]?" + re.escape(cwd) + r"/?['\"]?\s*(&&|;)\s*", "", command)
        return tool, cut(command)
    if tool in SHORT_TOOLS:
        path = args.get("path")
        return tool, strip_cwd(path, cwd) if isinstance(path, str) else ""
    for value in args.values():
        if isinstance(value, str):
            return tool, cut(collapse(value))
    return tool, ""


def elapsed_text(seconds):
    seconds = max(0, int(seconds))
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes:02d}:{secs:02d}"


def cmd_snapshot(path):
    try:
        last_activity = int(os.path.getmtime(path))
        events = open(path, "r", encoding="utf-8", errors="replace")
    except OSError:
        return 1
    tool_calls = turns = responses = 0
    cost = 0.0
    last_action = ""
    files_touched = []
    seen = set()
    cwd = ""
    with events:
        for line in events:
            if not line.endswith("\n"):
                continue  # a partial last line is still being written
            event = load_event(line)
            if event is None:
                continue
            kind = event.get("type")
            if kind == "session":
                cwd = event.get("cwd") or ""
            elif kind == "tool_execution_start":
                tool, target = action(event, cwd)
                tool_calls += 1
                last_action = f"{tool} {target}".rstrip()
                if tool in ("edit", "write") and target not in seen:
                    seen.add(target)
                    files_touched.append(target)
            elif kind == "turn_end":
                turns += 1
            elif kind == "message_end":
                message = event.get("message")
                if isinstance(message, dict) and message.get("role") == "assistant":
                    responses += 1
                    usage = message.get("usage")
                    if isinstance(usage, dict):
                        cost_info = usage.get("cost")
                        if isinstance(cost_info, dict):
                            try:
                                cost += float(cost_info.get("total") or 0)
                            except (TypeError, ValueError):
                                pass
    print(json.dumps({
        "tool_calls": tool_calls,
        "turns": turns,
        "responses": responses,
        "cost": cost,
        "last_action": last_action,
        "last_activity": last_activity,
        "files_touched": files_touched,
    }))
    return 0


def cmd_tail(path, count):
    try:
        events = open(path, "r", encoding="utf-8", errors="replace")
    except OSError:
        return 1
    calls = []
    cwd = ""
    number = 0
    with events:
        for line in events:
            if not line.endswith("\n"):
                continue  # a partial last line is still being written
            event = load_event(line)
            if event is None:
                continue
            if event.get("type") == "session":
                cwd = event.get("cwd") or ""
            elif event.get("type") == "tool_execution_start":
                number += 1
                tool, target = action(event, cwd)
                calls.append(f"#{number} {tool:<5} {target}".rstrip())
    for text in calls[-count:] if count > 0 else []:
        print(text)
    return 0


class Follower:
    def __init__(self, path, task, start, heartbeat, poll, max_cost=0.0, kill_pid=0, flag="", quiet=False):
        self.max_cost = max_cost      # 0: no cap
        self.kill_pid = kill_pid      # the run's process, stopped when the cap is passed
        self.flag = flag              # written when the cap stopped the run, so the run can say why
        self.quiet = quiet            # cap only, no progress lines (ORCHESTRA_PROGRESS=0)
        self.cost = 0.0
        self.tripped = False
        self.path = path
        self.task = task
        self.start = start
        self.heartbeat = heartbeat
        self.poll = poll
        self.stop = False
        self.agent_end = False
        self.done = False
        self.buffer = ""
        self.cwd = ""
        self.calls = 0
        self.last_tool = start
        self.last_beat = start

    def emit(self, text, always=False):
        if self.quiet and not always:
            return
        sys.stdout.write(text + "\n")
        sys.stdout.flush()

    def on_term(self, signum, frame):
        self.stop = True

    def elapsed(self):
        return elapsed_text(time.time() - self.start)

    def handle(self, line):
        event = load_event(line)
        if event is None:
            return
        kind = event.get("type")
        if kind == "session":
            self.cwd = event.get("cwd") or ""
        elif kind == "tool_execution_start":
            tool, target = action(event, self.cwd)
            self.calls += 1
            self.emit(f"{self.task} {self.elapsed()} #{self.calls} {tool:<5} {target}".rstrip())
            now = time.time()
            self.last_tool = now
            self.last_beat = now
        elif kind == "agent_end":
            self.agent_end = True
        elif kind == "message_end":
            message = event.get("message")
            if isinstance(message, dict) and message.get("role") == "assistant":
                usage = message.get("usage") if isinstance(message.get("usage"), dict) else {}
                cost = usage.get("cost") if isinstance(usage.get("cost"), dict) else {}
                try:
                    self.cost += float(cost.get("total") or 0)
                except (TypeError, ValueError):
                    pass
                self.check_budget()

    def check_budget(self):
        """Stop the run once its cost passes the cap: a looping worker cannot spend more than you allowed."""
        if self.tripped or self.max_cost <= 0 or self.cost <= self.max_cost:
            return
        self.tripped = True
        self.emit(f"{self.task} {self.elapsed()} ■ over budget: ${self.cost:.4f} > ${self.max_cost:.4f}, stopping the run",
                  always=True)
        if self.flag:
            try:
                with open(self.flag, "w", encoding="utf-8") as f:
                    f.write(f"{self.cost:.6f} {self.max_cost:.6f}\n")
            except OSError:
                pass
        if self.kill_pid > 0:
            try:
                os.kill(self.kill_pid, signal.SIGTERM)
            except OSError:
                pass

    def drain(self, events):
        chunk = events.read()
        if chunk:
            self.buffer += chunk
            while "\n" in self.buffer:
                line, self.buffer = self.buffer.split("\n", 1)
                self.handle(line + "\n")

    def finish(self):
        if self.done:
            return
        self.done = True
        self.emit(f"{self.task} {self.elapsed()} \u25a0 done: {self.calls} tool calls")

    def run(self):
        signal.signal(signal.SIGTERM, self.on_term)
        while not os.path.exists(self.path):
            if self.stop:
                self.finish()
                return 0
            time.sleep(self.poll)
        try:
            events = open(self.path, "r", encoding="utf-8", errors="replace")
        except OSError:
            self.finish()
            return 0
        with events:
            while True:
                self.drain(events)
                if self.agent_end:
                    break
                if self.stop:
                    # Read everything already complete in the file before saying good-bye.
                    self.drain(events)
                    break
                now = time.time()
                if now - self.last_beat >= self.heartbeat:
                    quiet = int(now - self.last_tool)
                    self.emit(f"{self.task} {self.elapsed()} \u2026 quiet for {quiet}s")
                    self.last_beat = now
                time.sleep(self.poll)
        self.finish()
        return 0


def build_parser():
    parser = argparse.ArgumentParser(description="Read pi's JSON event log.")
    sub = parser.add_subparsers(dest="command", required=True)

    follow = sub.add_parser("follow", help="print one line per tool call as the log grows")
    follow.add_argument("events")
    follow.add_argument("--task", required=True)
    follow.add_argument("--start", required=True, type=float)
    follow.add_argument("--heartbeat", type=float, default=60.0)
    follow.add_argument("--poll", type=float, default=0.5)
    follow.add_argument("--max-cost", type=float, default=0.0)
    follow.add_argument("--kill", type=int, default=0)
    follow.add_argument("--flag", default="")
    follow.add_argument("--quiet", action="store_true")

    snapshot = sub.add_parser("snapshot", help="one JSON object summarising the log")
    snapshot.add_argument("events")

    tail = sub.add_parser("tail", help="the last few tool calls")
    tail.add_argument("events")
    tail.add_argument("--lines", type=int, default=6)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    if args.command == "snapshot":
        return cmd_snapshot(args.events)
    if args.command == "tail":
        return cmd_tail(args.events, args.lines)
    follower = Follower(args.events, args.task, args.start, args.heartbeat, args.poll,
                        args.max_cost, args.kill, args.flag, args.quiet)
    return follower.run()


if __name__ == "__main__":
    sys.exit(main())
