"""orchestra lessons: draft lessons.md lines from what a run's review shows the spec missed.

Reads the object `orchestra-worker review --json` writes on stdin (the `lessons` command pipes it) and prints
ready-to-edit lines: one per spec gap, with the date, the task and a placeholder for the rule. Nothing is written;
an orchestrator keeps the lines that would change a future spec and appends them to the lessons file.
"""
import argparse
import datetime
import json
import sys

LIMIT = 200
ELLIPSIS = "\u2026"  # `…`: one character, so a cut item is exactly LIMIT characters


def collapse(item):
    """One line, no runs of whitespace, cut to LIMIT characters."""
    text = " ".join(str(item).split())
    if len(text) > LIMIT:
        text = text[:LIMIT - 1] + ELLIPSIS
    return text


def text_list(value):
    return [str(item) for item in value] if isinstance(value, list) else []


def main(argv):
    ap = argparse.ArgumentParser(prog="lessons.py")
    ap.add_argument("--task", required=True)
    a = ap.parse_args(argv)

    try:
        data = json.load(sys.stdin)
    except ValueError:
        print("lessons: invalid review JSON on stdin", file=sys.stderr)
        return 2
    if not isinstance(data, dict):
        print("lessons: invalid review JSON on stdin", file=sys.stderr)
        return 2

    blocking = text_list(data.get("blocking"))
    assumed = text_list(data.get("assumed"))
    outside_scope = text_list(data.get("outside_scope_needed"))
    paths = data.get("paths")
    outside = text_list(paths.get("outside")) if isinstance(paths, dict) else []

    total = len(blocking) + len(outside) + len(outside_scope) + len(assumed)
    task = a.task
    if total == 0:
        print(f"no spec gaps in {task}'s last run: nothing to record")
        return 0

    run = data.get("run")
    run_n = run.get("n") if isinstance(run, dict) else None
    suffix = f", run {run_n}" if run_n is not None else ""
    print(f"# lessons draft for {task}{suffix}: keep the lines that would change a future spec, write the rule, "
          "then append")
    print("# them to docs/work/lessons.md (ORCHESTRA_TASKS_DIR's sibling lessons.md)")

    date = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    for item in blocking:
        print(f"- {date} {task}: the spec left this open: {collapse(item)}. Rule: <write the rule>")
    for path in outside:
        print(f"- {date} {task}: the worker had to change `{collapse(path)}`, outside Owns/Touches. "
              "Rule: <write the rule>")
    for item in outside_scope:
        print(f"- {date} {task}: the worker needed, outside scope: {collapse(item)}. Rule: <write the rule>")
    for item in assumed:
        print(f"- {date} {task}: the worker assumed: {collapse(item)}. "
              "Rule (only if it should have been decided): <write the rule>")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
