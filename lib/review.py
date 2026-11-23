"""orchestra review: one screen of what the orchestrator must act on after a worker run.

Read-only and offline. Called by `orchestra-worker review`; see that command for the flags. The only state it
touches is the worktree's .orchestra/ directory, and it never modifies the worktree's real git index: changed files
are computed on a temporary copy of the index.

The digest is built once in `collect()` and rendered twice: as the text screen (`render_text`) and, with --json, as
one JSON object (`render_json`).
"""
import argparse
import fnmatch
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import task_lint  # noqa: E402  (same directory; imported, never edited)

EXIT_MEANING = {
    0: "ok",
    3: "disallowed model: discard",
    4: "no valid report",
    124: "timed out",
}


def fail(message):
    print(f"review: {message}", file=sys.stderr)
    return 2


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def run_numbers(runs_dir, suffix):
    nums = set()
    for path in glob.glob(os.path.join(runs_dir, f"run-*.{suffix}")):
        name = os.path.basename(path)
        stem = name[len("run-"):-len(suffix) - 1]
        try:
            nums.add(int(stem))
        except ValueError:
            continue
    return nums


def duration(secs):
    try:
        secs = int(secs)
    except (TypeError, ValueError):
        return ""
    if secs < 60:
        return f"{secs}s"
    minutes, rest = divmod(secs, 60)
    return f"{minutes}m{rest:02d}s"


def number(value):
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def int_or_none(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def text_list(value):
    if isinstance(value, list):
        return [str(item) for item in value]
    return []


def str_or_none(value):
    if value is None:
        return None
    return value if isinstance(value, str) else str(value)


def changed_files(worktree, base):
    """git diff --cached --numstat against the merge base, on a temporary copy of the index."""
    try:
        index = subprocess.run(
            ["git", "-C", worktree, "rev-parse", "--path-format=absolute", "--git-path", "index"],
            capture_output=True, text=True, check=False)
        index_path = index.stdout.strip()
    except OSError:
        index_path = ""

    tmp_fd, tmp_path = tempfile.mkstemp(prefix="orchestra-review-index-")
    os.close(tmp_fd)
    try:
        if index_path and os.path.exists(index_path):
            shutil.copyfile(index_path, tmp_path)
        env = dict(os.environ, GIT_INDEX_FILE=tmp_path)
        subprocess.run(["git", "-C", worktree, "add", "-A"], env=env,
                       capture_output=True, text=True, check=False)
        mb = subprocess.run(["git", "-C", worktree, "merge-base", "HEAD", base],
                            capture_output=True, text=True, check=False)
        ref = mb.stdout.strip() if mb.returncode == 0 else ""
        if not ref:
            verify = subprocess.run(["git", "-C", worktree, "rev-parse", "--verify", "--quiet", base],
                                    capture_output=True, text=True, check=False)
            ref = base if verify.returncode == 0 else ""
        if not ref:
            return []
        diff = subprocess.run(
            ["git", "-C", worktree, "--no-pager", "diff", "--cached", "--numstat", "--no-renames", ref, "--",
             ".", ":(exclude).orchestra"],
            env=env, capture_output=True, text=True, check=False)
        if diff.returncode != 0:
            return []
        out = []
        for line in diff.stdout.splitlines():
            parts = line.split("\t", 2)
            if len(parts) != 3:
                continue
            added, removed, path = parts
            try:
                a = 0 if added == "-" else int(added)
                r = 0 if removed == "-" else int(removed)
            except ValueError:
                a = r = 0
            out.append({"path": path, "added": a, "removed": r})
        return out
    finally:
        try:
            os.remove(tmp_path)
        except OSError:
            pass


def is_generated(path, globs):
    base = os.path.basename(path)
    return any(fnmatch.fnmatch(base, g) or fnmatch.fnmatch(path, g) for g in globs)


def spec_paths(spec):
    """Return (has_sections, [paths]) from the spec's Owns and Touches, or None when it has neither."""
    if not spec or not os.path.isfile(spec):
        return None
    try:
        _fm, sections = task_lint.parse(spec)
    except OSError:
        return None
    if "owns" not in sections and "touches" not in sections:
        return None
    paths = []
    for name in ("owns", "touches"):
        for path, _is_new in task_lint.paths_in(sections.get(name, "")):
            paths.append(path)
    return paths


def covered(path, paths, worktree):
    for p in paths:
        if not p:
            continue
        if path == p:
            return True
        # Anything under a spec path is covered, whether that directory still exists or the task deleted it.
        if path.startswith(p.rstrip("/") + "/"):
            return True
        if any(c in p for c in "*?[") and fnmatch.fnmatch(path, p):
            return True
    return False


def read_proofs(state):
    rows = []
    try:
        with open(os.path.join(state, "proofs.jsonl"), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict):
                    rows.append(row)
    except OSError:
        pass
    return rows


def collect(args, state):
    """Everything the text screen and the JSON object need, in one dict."""
    runs_dir = os.path.join(state, "runs")
    nums = run_numbers(runs_dir, "jsonl")

    run = None
    run_display = None
    if nums:
        n = max(nums)
        result = load_json(os.path.join(runs_dir, f"run-{n}.result.json"))
        usage = load_json(os.path.join(runs_dir, f"run-{n}.usage.json")) or {}

        exit_code = None
        meaning = ""
        secs = None
        if isinstance(result, dict) and "exit" in result:
            raw = result.get("exit")
            exit_code = int_or_none(raw)
            if exit_code is not None:
                meaning = EXIT_MEANING.get(exit_code, "harness failed")
            secs = int_or_none(result.get("secs"))
            # The text header has always shown a non-numeric exit as-is; keep that byte for byte.
            try:
                display_code = int(raw)
            except (TypeError, ValueError):
                display_code = str(raw)
            took = duration(result.get("secs"))
            run_display = {
                "exit": f"exit {display_code} ({EXIT_MEANING.get(display_code, 'harness failed')})",
                "took": f" · {took}" if took else "",
            }
        else:
            run_display = {"exit": "exit ?", "took": ""}

        responses = usage.get("responses", 0) if isinstance(usage, dict) else 0
        cost = number(usage.get("cost")) if isinstance(usage, dict) else 0.0

        total = 0.0
        for path in glob.glob(os.path.join(runs_dir, "run-*.usage.json")):
            data = load_json(path)
            if isinstance(data, dict):
                total += number(data.get("cost"))
        count = len(set(nums) | run_numbers(runs_dir, "usage.json"))

        run = {
            "n": n,
            "exit": exit_code,
            "meaning": meaning,
            "secs": secs,
            "responses": responses,
            "cost": cost,
            "task_total": total,
            "runs": count,
        }

    report = load_json(os.path.join(state, "report.json"))
    valid = isinstance(report, dict)
    data = {
        "_run_display": run_display,
        "task": args.task,
        "run": run,
        "report_valid": valid,
        "status": str_or_none(report.get("status")) if valid else None,
        "summary": str_or_none(report.get("summary")) if valid else None,
        "blocking": text_list(report.get("open_questions")) if valid else [],
        "assumed": text_list(report.get("assumptions")) if valid else [],
        "outside_scope_needed": text_list(report.get("out_of_scope_needed")) if valid else [],
    }
    if valid:
        data["_status_line"] = f"{report.get('status', '')}: {report.get('summary', '')}"

    changed = changed_files(args.worktree, args.base)
    generated_globs = args.generated.split()
    for f in changed:
        f["generated"] = is_generated(f["path"], generated_globs)

    paths = spec_paths(args.spec)
    if paths is None:
        outside = []
    else:
        outside = [f["path"] for f in changed
                   if not f["generated"] and not covered(f["path"], paths, args.worktree)]
    data["paths"] = {"checked": paths is not None, "outside": outside}
    data["spec_gaps"] = len(data["blocking"]) + len(outside) + len(data["outside_scope_needed"]) \
        + len(data["assumed"])

    worker_checks = None
    acceptance = None
    if valid:
        checks = report.get("checks") or []
        if isinstance(checks, list) and checks:
            passed = sum(1 for c in checks if isinstance(c, dict) and c.get("result") == "pass")
            failing = [str(c.get("command", "")) for c in checks
                       if isinstance(c, dict) and c.get("result") == "fail"]
            worker_checks = {"pass": passed, "fail": len(failing), "failing": failing}
        if "acceptance" in report and isinstance(report.get("acceptance"), list):
            rows = report["acceptance"]
            met = sum(1 for a in rows if isinstance(a, dict) and a.get("met") is True)
            unmet = [str(a.get("item", "")) for a in rows
                     if isinstance(a, dict) and a.get("met") is not True]
            acceptance = {"met": met, "total": len(rows), "unmet": unmet}
    data["worker_checks"] = worker_checks
    data["acceptance"] = acceptance

    configured = [line.strip() for line in args.checks.splitlines() if line.strip()]
    proofs = read_proofs(state)
    manual = [str(r.get("manual", "")) for r in proofs
              if "manual" in r and r.get("tree") == args.tree]
    last = {}
    for row in proofs:
        if row.get("tree") == args.tree and row.get("check") in configured:
            last[row.get("check")] = row
    proof_checks = []
    for command in configured:
        row = last.get(command)
        if row is None:
            state_label = "not run"
        elif row.get("exit") == 0:
            state_label = "pass"
        else:
            state_label = "fail"
        proof_checks.append({"check": command, "state": state_label})
    data["proofs"] = {"tree": args.tree, "checks": proof_checks, "manual": manual}

    ranked = sorted(changed, key=lambda f: (-(f["added"] + f["removed"]), f["path"]))
    data["diff"] = {
        "files": len(changed),
        "added": sum(f["added"] for f in changed),
        "removed": sum(f["removed"] for f in changed),
        "generated": sum(1 for f in changed if f["generated"]),
        "list": [{"path": f["path"], "added": f["added"], "removed": f["removed"],
                  "generated": f["generated"]} for f in ranked],
    }
    return data


def render_text(data):
    task = data["task"]
    run = data["run"]
    if run is None:
        print(f"{task} · no worker runs")
    else:
        display = data["_run_display"]
        count = run["runs"]
        print(f"{task} · run {run['n']} {display['exit']}{display['took']} · {run['responses']} responses · "
              f"${run['cost']:.4f} (task total: ${run['task_total']:.4f}, {count} run{'' if count == 1 else 's'})")

    if not data["report_valid"]:
        print(f"{'status':<10}no valid report")
    else:
        print(f"{'status':<10}{data['_status_line']}")
        blocking = data["blocking"]
        if blocking:
            print(f"BLOCKING ({len(blocking)})")
            for i, item in enumerate(blocking, 1):
                print(f"  {i}. {item}")
        assumed = data["assumed"]
        if assumed:
            print(f"assumed ({len(assumed)})")
            for i, item in enumerate(assumed, 1):
                print(f"  {i}. {item}")
        outside_scope = data["outside_scope_needed"]
        if outside_scope:
            print(f"outside scope needed ({len(outside_scope)})")
            for item in outside_scope:
                print(f"  - {item}")

    paths = data["paths"]
    if not paths["checked"]:
        print(f"{'paths':<10}not checked (no Owns/Touches in the spec)")
    elif paths["outside"]:
        print(f"OUTSIDE PATHS ({len(paths['outside'])}): changed files the spec's Owns/Touches do not cover")
        for path in paths["outside"]:
            print(f"  {path}")
    else:
        print(f"{'paths':<10}all inside Owns/Touches.")

    worker_checks = data["worker_checks"]
    if worker_checks is not None:
        print(f"{'worker checks':<15}{worker_checks['pass']} pass, {worker_checks['fail']} fail")
        for command in worker_checks["failing"]:
            print(f"  fail: {command}")
    acceptance = data["acceptance"]
    if acceptance is not None:
        print(f"{'acceptance':<15}{acceptance['met']}/{acceptance['total']} met")
        for item in acceptance["unmet"]:
            print(f"  unmet: {item}")

    proofs = data["proofs"]
    if not proofs["checks"] and not proofs["manual"]:
        print(f"{'proofs':<15}none configured")
    else:
        print(f"{'proofs':<15}(tree {proofs['tree'][:12]})")
        labels = {"pass": "pass", "fail": "FAIL", "not run": "not run"}
        for row in proofs["checks"]:
            print(f"  {labels[row['state']]:<7}  {row['check']}")
        for text in proofs["manual"]:
            print(f"  {'manual':<7}  {text}")

    diff = data["diff"]
    if diff["files"]:
        print(f"{'diff':<15}{diff['files']} files · +{diff['added']} −{diff['removed']} · "
              f"{diff['generated']} generated")
        for f in diff["list"][:12]:
            payload = f"+{f['added']} −{f['removed']}"
            suffix = " (generated)" if f["generated"] else ""
            print(f"  {payload:<11}{f['path']}{suffix}")
        if len(diff["list"]) > 12:
            print(f"  … and {len(diff['list']) - 12} more")

    if data["spec_gaps"]:
        print(f"{'lessons':<10}{data['spec_gaps']} spec gap(s): orchestra-worker lessons {task}")

    print(f"{'next':<10}orchestra-worker diff {task} · prove {task} · land {task}")


PUBLIC_KEYS = ("task", "run", "report_valid", "status", "summary", "blocking", "assumed",
               "outside_scope_needed", "paths", "spec_gaps", "worker_checks", "acceptance", "proofs", "diff")


def render_json(data):
    print(json.dumps({key: data[key] for key in PUBLIC_KEYS}, indent=1))


def main(argv):
    ap = argparse.ArgumentParser(prog="review.py")
    ap.add_argument("--task", required=True)
    ap.add_argument("--worktree", required=True)
    ap.add_argument("--base", required=True)
    ap.add_argument("--spec", required=True)
    ap.add_argument("--generated", default="")
    ap.add_argument("--checks", default="")
    ap.add_argument("--tree", required=True)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)

    worktree = os.path.abspath(args.worktree)
    if not os.path.isdir(worktree):
        return fail(f"no worktree at {args.worktree}")
    args.worktree = worktree
    state = os.path.join(worktree, ".orchestra")

    data = collect(args, state)
    if args.json:
        render_json(data)
    else:
        render_text(data)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
