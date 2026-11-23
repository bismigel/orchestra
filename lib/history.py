#!/usr/bin/env python3
"""orchestra history: every task's runs, cost and outcome, including the tasks `clean` removed.

Live worktrees are read directly; removed ones come from the ledger (`--ledger`, one JSON line per removal, written
by `clean` before it removes anything). A live task that also has a ledger line shows once, as live.

  history.py --worktrees DIR --ledger FILE [--json]

Text: one aligned row per task/scout, sorted by task then kind, then the project totals. --json: the same rows (each
with "live": true|false) and the totals. Malformed ledger lines are skipped and counted on stderr. Read-only.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time

RUN_FILE = re.compile(r"run-(\d+)\.(?:usage|result)\.json\Z")
EGRESS_FILE = re.compile(r"run-\d+\.egress\.log\Z")
HOST_PORT = re.compile(r"\S+:\d+\Z")


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def number(value):
    if isinstance(value, bool):
        return 0.0
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def int_or_none(value):
    if value is None or isinstance(value, bool):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def str_or_none(value):
    if value is None:
        return None
    return value if isinstance(value, str) else str(value)


def text_list(value):
    if isinstance(value, list):
        return [str(item) for item in value]
    return []


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def run_records(runs_dir):
    """One record per run number found in runs/run-N.usage.json or runs/run-N.result.json, sorted by n."""
    try:
        names = os.listdir(runs_dir)
    except OSError:
        return []
    numbers = sorted({int(m.group(1)) for m in map(RUN_FILE.match, names) if m})
    records = []
    for n in numbers:
        usage = load_json(os.path.join(runs_dir, "run-%d.usage.json" % n))
        result = load_json(os.path.join(runs_dir, "run-%d.result.json" % n))
        usage = usage if isinstance(usage, dict) else {}
        result = result if isinstance(result, dict) else {}
        records.append({
            "n": n,
            "exit": int_or_none(result.get("exit")),
            "secs": int_or_none(result.get("secs")),
            "responses": int_or_none(usage.get("responses")) or 0,
            "cost": number(usage.get("cost")),
        })
    return records


def egress_denied(runs_dir):
    """Unique host:port targets the egress proxy denied, from every run-*.egress.log."""
    denied = set()
    try:
        names = sorted(os.listdir(runs_dir))
    except OSError:
        return []
    for name in names:
        if not EGRESS_FILE.match(name):
            continue
        try:
            with open(os.path.join(runs_dir, name), encoding="utf-8") as f:
                lines = f.readlines()
        except OSError:
            continue
        for line in lines:
            fields = line.split()
            if len(fields) > 2 and fields[1] == "deny" and HOST_PORT.match(fields[2]):
                denied.add(fields[2])
    return sorted(denied)


def report_record(state):
    """The worker's report, reduced to what history shows. Missing or not an object: null."""
    report = load_json(os.path.join(state, "report.json"))
    if not isinstance(report, dict):
        return None
    return {
        "status": str_or_none(report.get("status")),
        "summary": str_or_none(report.get("summary")),
        "blocking": text_list(report.get("open_questions")),
        "assumed": text_list(report.get("assumptions")),
        "outside_scope_needed": text_list(report.get("out_of_scope_needed")),
    }


def git(worktree, *args):
    try:
        result = subprocess.run(["git", "-C", worktree, *args], capture_output=True, text=True)
    except OSError:
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def head_of(worktree):
    return git(worktree, "rev-parse", "HEAD") or None


def branch_of(worktree):
    name = git(worktree, "rev-parse", "--abbrev-ref", "HEAD")
    return name if name and name != "HEAD" else None


def total_cost(runs):
    return sum(run["cost"] for run in runs)


def task_record(task, state, removed_at, cls, branch, head):
    """The ledger record for a task worktree; `state` is its .orchestra directory."""
    runs = run_records(os.path.join(state, "runs"))
    return {
        "task": task,
        "kind": "task",
        "removed_at": removed_at,
        "class": cls,
        "branch": branch,
        "head": head,
        "runs": runs,
        "cost": total_cost(runs),
        "report": report_record(state),
        "egress_denied": egress_denied(os.path.join(state, "runs")),
    }


def scout_record(task, scout_dir, removed_at):
    """The ledger record for a scout directory; its runs live directly in runs/."""
    runs = run_records(os.path.join(scout_dir, "runs"))
    return {
        "task": task,
        "kind": "scout",
        "removed_at": removed_at,
        "runs": runs,
        "cost": total_cost(runs),
    }


def write_record(ledger, record):
    """Append one JSON line and flush it to disk. Raises OSError when the ledger cannot be written."""
    parent = os.path.dirname(os.path.abspath(ledger))
    os.makedirs(parent, exist_ok=True)
    with open(ledger, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")
        f.flush()
        os.fsync(f.fileno())


def valid_record(record):
    return (isinstance(record, dict) and isinstance(record.get("task"), str)
            and record.get("kind") in ("task", "scout"))


def read_ledger(path):
    """(records, skipped): ledger lines in file order; malformed ones are counted, not raised."""
    records = []
    skipped = 0
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return records, skipped
    for line in lines:
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except ValueError:
            skipped += 1
            continue
        if not valid_record(record):
            skipped += 1
            continue
        records.append(record)
    return records, skipped


def live_task_records(worktrees):
    """Every directory directly under worktrees/ that is a task worktree with .orchestra/runs."""
    try:
        names = sorted(os.listdir(worktrees))
    except OSError:
        return []
    records = []
    for name in names:
        path = os.path.join(worktrees, name)
        state = os.path.join(path, ".orchestra")
        if name == ".scout" or not os.path.isdir(os.path.join(state, "runs")):
            continue
        records.append(task_record(name, state, None, "live", branch_of(path), head_of(path)))
    return records


def live_scout_records(worktrees):
    """Every directory directly under worktrees/.scout."""
    root = os.path.join(worktrees, ".scout")
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return []
    return [scout_record(name, os.path.join(root, name), None)
            for name in names if os.path.isdir(os.path.join(root, name))]


def collect(worktrees, ledger):
    """(rows, skipped, live_keys): ledger rows plus live rows, de-duplicated, sorted by task then kind."""
    ledger_rows, skipped = read_ledger(ledger)
    live = live_task_records(worktrees) + live_scout_records(worktrees)
    live_keys = {(row.get("task"), row.get("kind")) for row in live}

    # A live task hides its ledger history; ledger duplicates (a record written twice) keep the latest line.
    latest = {}
    for row in ledger_rows:
        if (row.get("task"), row.get("kind")) in live_keys:
            continue
        latest[(row.get("task"), row.get("kind"), row.get("head"))] = row
    rows = list(latest.values()) + live
    rows.sort(key=lambda row: (str(row.get("task")), str(row.get("kind"))))
    return rows, skipped, live_keys


def report_of(row):
    report = row.get("report")
    return report if isinstance(report, dict) else None


def when_of(row):
    if row.get("removed_at") is None:
        return "live"
    removed = str_or_none(row.get("removed_at")) or ""
    return removed[:10] if removed else "-"


def cells(row):
    report = report_of(row)
    runs = row.get("runs")
    runs = runs if isinstance(runs, list) else []
    return [
        str(row.get("task", "")),
        str(row.get("kind", "")),
        str(len(runs)),
        "$%.4f" % number(row.get("cost")),
        (str_or_none(report.get("status")) or "-") if report else "-",
        str(len(text_list(report.get("blocking")))) if report else "-",
        str(len(text_list(report.get("assumed")))) if report else "-",
        when_of(row),
    ]


def table(rows):
    head = ("TASK", "KIND", "RUNS", "COST", "STATUS", "BLOCKING", "ASSUMED", "WHEN")
    body = [cells(row) for row in rows]
    padded = len(head) - 1
    widths = [max([len(head[i])] + [len(row[i]) for row in body]) for i in range(padded)]
    fmt = "  ".join(["%%-%ds" % width for width in widths] + ["%s"])
    print(fmt % head)
    for row in body:
        print(fmt % tuple(row))


def totals(rows):
    runs = sum(len(row.get("runs") or []) for row in rows if isinstance(row.get("runs"), list))
    cost = sum(number(row.get("cost")) for row in rows)
    tasks = sum(1 for row in rows if row.get("kind") == "task")
    return {"tasks": tasks, "runs": runs, "cost": cost}


def main():
    parser = argparse.ArgumentParser(description="every orchestra task's runs, cost and outcome")
    parser.add_argument("--worktrees", required=True, help="the directory holding one worktree per task")
    parser.add_argument("--ledger", required=True, help="the JSON Lines ledger written by clean")
    parser.add_argument("--json", action="store_true", help="print the rows and totals as JSON")
    args = parser.parse_args()

    rows, skipped, live_keys = collect(args.worktrees, args.ledger)
    if skipped:
        sys.stderr.write("history: skipped %d malformed ledger line(s)\n" % skipped)
    total = totals(rows)

    if args.json:
        out = {
            "rows": [dict(row, live=((row.get("task"), row.get("kind")) in live_keys)) for row in rows],
            "total": total,
        }
        print(json.dumps(out, ensure_ascii=False))
        return 0

    if not rows:
        print("no history")
        return 0
    table(rows)
    print("total: %d tasks, %d runs, $%.4f" % (total["tasks"], total["runs"], total["cost"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
