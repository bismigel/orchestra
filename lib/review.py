"""orchestra review: one screen of what the orchestrator must act on after a worker run.

Read-only and offline. Called by `orchestra-worker review`; see that command for the flags. The only state it
touches is the worktree's .orchestra/ directory, and it never modifies the worktree's real git index: changed files
are computed on a temporary copy of the index.
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


def header(task, state):
    runs_dir = os.path.join(state, "runs")
    nums = run_numbers(runs_dir, "jsonl")
    if not nums:
        print(f"{task} · no worker runs")
        return
    n = max(nums)
    result = load_json(os.path.join(runs_dir, f"run-{n}.result.json"))
    usage = load_json(os.path.join(runs_dir, f"run-{n}.usage.json")) or {}

    if isinstance(result, dict) and "exit" in result:
        code = result.get("exit")
        try:
            code = int(code)
        except (TypeError, ValueError):
            code = str(code)
        meaning = EXIT_MEANING.get(code, "harness failed")
        exit_part = f"exit {code} ({meaning})"
        took = duration(result.get("secs"))
        took_part = f" · {took}" if took else ""
    else:
        exit_part = "exit ?"
        took_part = ""

    responses = usage.get("responses", 0) if isinstance(usage, dict) else 0
    cost = number(usage.get("cost")) if isinstance(usage, dict) else 0.0

    total = 0.0
    for path in glob.glob(os.path.join(runs_dir, "run-*.usage.json")):
        data = load_json(path)
        if isinstance(data, dict):
            total += number(data.get("cost"))
    count = len(set(nums) | run_numbers(runs_dir, "usage.json"))

    print(f"{task} · run {n} {exit_part}{took_part} · {responses} responses · "
          f"${cost:.4f} (task total: ${total:.4f}, {count} run{"" if count == 1 else "s"})")


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
            out.append({"path": path, "add": a, "del": r})
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


def main(argv):
    ap = argparse.ArgumentParser(prog="review.py")
    ap.add_argument("--task", required=True)
    ap.add_argument("--worktree", required=True)
    ap.add_argument("--base", required=True)
    ap.add_argument("--spec", required=True)
    ap.add_argument("--generated", default="")
    ap.add_argument("--checks", default="")
    ap.add_argument("--tree", required=True)
    args = ap.parse_args(argv)

    worktree = os.path.abspath(args.worktree)
    if not os.path.isdir(worktree):
        return fail(f"no worktree at {args.worktree}")
    state = os.path.join(worktree, ".orchestra")

    header(args.task, state)

    report = load_json(os.path.join(state, "report.json"))
    if not isinstance(report, dict):
        print(f"{'status':<10}no valid report")
        report = None
    else:
        print(f"{'status':<10}{report.get('status', '')}: {report.get('summary', '')}")
        blocking = report.get("open_questions") or []
        if isinstance(blocking, list) and blocking:
            print(f"BLOCKING ({len(blocking)})")
            for i, item in enumerate(blocking, 1):
                print(f"  {i}. {item}")
        assumed = report.get("assumptions") or []
        if isinstance(assumed, list) and assumed:
            print(f"assumed ({len(assumed)})")
            for i, item in enumerate(assumed, 1):
                print(f"  {i}. {item}")
        outside_scope = report.get("out_of_scope_needed") or []
        if isinstance(outside_scope, list) and outside_scope:
            print(f"outside scope needed ({len(outside_scope)})")
            for item in outside_scope:
                print(f"  - {item}")

    changed = changed_files(worktree, args.base)
    generated_globs = args.generated.split()
    for f in changed:
        f["generated"] = is_generated(f["path"], generated_globs)

    paths = spec_paths(args.spec)
    if paths is None:
        print(f"{'paths':<10}not checked (no Owns/Touches in the spec)")
    else:
        outside = [f["path"] for f in changed
                   if not f["generated"] and not covered(f["path"], paths, worktree)]
        if outside:
            print(f"OUTSIDE PATHS ({len(outside)}): changed files the spec's Owns/Touches do not cover")
            for path in outside:
                print(f"  {path}")
        else:
            print(f"{'paths':<10}all inside Owns/Touches.")

    if report is not None:
        checks = report.get("checks") or []
        if isinstance(checks, list) and checks:
            passed = sum(1 for c in checks if isinstance(c, dict) and c.get("result") == "pass")
            failed = [c for c in checks if isinstance(c, dict) and c.get("result") == "fail"]
            print(f"{'worker checks':<15}{passed} pass, {len(failed)} fail")
            for c in failed:
                print(f"  fail: {c.get('command', '')}")
        if "acceptance" in report and isinstance(report.get("acceptance"), list):
            acceptance = report["acceptance"]
            met = sum(1 for a in acceptance if isinstance(a, dict) and a.get("met") is True)
            print(f"{'acceptance':<15}{met}/{len(acceptance)} met")
            for a in acceptance:
                if isinstance(a, dict) and a.get("met") is not True:
                    print(f"  unmet: {a.get('item', '')}")

    checks = [line.strip() for line in args.checks.splitlines() if line.strip()]
    proofs = read_proofs(state)
    manual = [r for r in proofs if "manual" in r and r.get("tree") == args.tree]
    if not checks and not manual:
        print(f"{'proofs':<15}none configured")
    else:
        print(f"{'proofs':<15}(tree {args.tree[:12]})")
        last = {}
        for row in proofs:
            if row.get("tree") == args.tree and row.get("check") in checks:
                last[row.get("check")] = row
        for command in checks:
            row = last.get(command)
            if row is None:
                label = "not run"
            elif row.get("exit") == 0:
                label = "pass"
            else:
                label = "FAIL"
            print(f"  {label:<7}  {command}")
        for row in manual:
            print(f"  {'manual':<7}  {row.get('manual', '')}")

    if changed:
        total_add = sum(f["add"] for f in changed)
        total_del = sum(f["del"] for f in changed)
        generated = sum(1 for f in changed if f["generated"])
        print(f"{'diff':<15}{len(changed)} files · +{total_add} −{total_del} · {generated} generated")
        ranked = sorted(changed, key=lambda f: (-(f["add"] + f["del"]), f["path"]))
        for f in ranked[:12]:
            payload = f"+{f['add']} −{f['del']}"
            suffix = " (generated)" if f["generated"] else ""
            print(f"  {payload:<11}{f['path']}{suffix}")
        if len(ranked) > 12:
            print(f"  … and {len(ranked) - 12} more")

    print(f"{'next':<10}orchestra-worker diff {args.task} · prove {args.task} · land {args.task}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
