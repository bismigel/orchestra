"""orchestra scout view: a short, paste-ready view of one scout report.

Reads the scout's JSON, checks its shape, and prints only what the orchestrator acts on: names that are not where
the spec says, other files the task must change, affected tests, patterns, commands that do not run, size, open
questions, and a block ready to paste into the spec's Touches section.
"""
import json
import sys



def short(text, limit=110):
    """One line, at most limit characters: the full text stays in scout.json."""
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[:limit - 1] + "…"

def invalid(reason):
    print(f"scout_view: invalid scout report: {reason}", file=sys.stderr)
    return 1


def load_usage(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return 0, 0.0
    if not isinstance(data, dict):
        return 0, 0.0
    responses = data.get("responses", 0)
    try:
        responses = int(responses or 0)
    except (TypeError, ValueError):
        responses = 0
    try:
        cost = float(data.get("cost") or 0)
    except (TypeError, ValueError):
        cost = 0.0
    return responses, cost


def entry_list(value):
    return [e for e in value if isinstance(e, dict)]


def main(argv):
    if len(argv) != 3:
        print("usage: scout_view.py SCOUT_JSON TASK USAGE_JSON", file=sys.stderr)
        return 2
    path, task, usage_path = argv

    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        return invalid(f"cannot read {path}: {e}")
    try:
        report = json.loads(text)
    except ValueError as e:
        return invalid(f"not valid JSON: {e}")
    if not isinstance(report, dict):
        return invalid("not a JSON object")
    if report.get("task") != task:
        return invalid(f"task is {report.get('task')!r}, expected {task!r}")
    for key in ("named", "files_to_change", "tests_affected", "patterns", "commands", "undecided"):
        if key in report and not isinstance(report[key], list):
            return invalid(f"{key} is not a list")
    if "size" in report and not isinstance(report["size"], dict):
        return invalid("size is not an object")

    responses, cost = load_usage(usage_path)
    print(f"scout {task} · {responses} responses · ${cost:.4f}")

    named = entry_list(report.get("named") or [])
    not_found = [e for e in named if e.get("found") is False]
    if not_found:
        print(f"{'named':<11}{len(named)} checked · {len(not_found)} not where the spec says")
        for e in not_found:
            line = f"  {e.get('spec_says', '')}"
            if e.get("actual"):
                line += f" → {short(e['actual'])}"
            if e.get("note"):
                line += f" ({short(e['note'])})"
            print(line)

    files = entry_list(report.get("files_to_change") or [])
    if files:
        outside = [e for e in files if e.get("in_spec") is False]
        print(f"{'change':<11}{len(files)} files · {len(outside)} not in the spec")

    tests = entry_list(report.get("tests_affected") or [])
    if tests:
        print(f"{'tests':<11}{len(tests)} affected")

    patterns = entry_list(report.get("patterns") or [])
    if patterns:
        print("patterns")
        for e in patterns:
            print(f"  {e.get('path', '')}: {short(e.get('what', ''))}")

    broken = [e for e in entry_list(report.get("commands") or []) if e.get("runs") is False]
    if broken:
        print(f"{'commands':<11}{len(broken)} does not run")
        for e in broken:
            line = f"  `{e.get('command', '')}`"
            if e.get("fixed"):
                line += f" → `{e['fixed']}`"
            print(line)

    size = report.get("size")
    if isinstance(size, dict):
        line = f"{'size':<11}~{size.get('files', 0)} files, ~{size.get('lines', 0)} lines"
        if size.get("split"):
            line += f" · split: {short(size['split'])}"
        print(line)

    undecided = [str(item) for item in (report.get("undecided") or [])]
    if undecided:
        print("undecided")
        for item in undecided:
            print(f"  - {item}")

    paste, seen = [], set()
    for e in files:
        if e.get("in_spec") is False:
            paste.append((e.get("path", ""), e.get("why", ""), "", False))
    for e in tests:
        paste.append((e.get("path", ""), e.get("why", ""), e.get("test", ""), True))
    lines = []
    for path_, why, test, is_test in paste:
        if not path_ or path_ in seen:
            continue
        seen.add(path_)
        line = f"- `{path_}`"
        if is_test:
            line += f": asserts {short(why)}" if why else ": asserts"
            if test:
                line += f" ({test})"
        elif why:
            line += f": {short(why)}"
        lines.append(line)
    if lines:
        print("")
        print("add to the spec (Touches):")
        for line in lines:
            print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
