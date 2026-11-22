"""orchestra task lint: the deterministic half of the definition of ready (docs/planning-guide.md).

Checks every task file (Markdown with front matter) without a model:
  L1  front matter: id, title, status, depends, delegation (ops profile: risk, rollback too)
  L5  Owns disjoint from every other open task, unless one depends on the other (transitively)
  L6  paths in Owns/Touches exist on the base branch, or are clearly new (a glob, or marked "(new)")
  L8  Acceptance: at least one command in backticks; screenshots and browser checks marked Orchestrator/Human
  L10 every dependency exists; a ready task's dependencies are done or chained
  L11 Out of scope section present
A task is done when the base branch has a commit whose subject starts with "<id>:".
Exit 0 when every checked task passes, 1 otherwise, 2 on usage errors.
"""
import argparse, json, os, re, subprocess, sys

REQUIRED = ["id", "title", "status", "depends", "delegation"]
OPS_REQUIRED = ["risk", "rollback"]
DELEGATION = {"worker", "split", "orchestrator"}
STATUS = {"draft", "ready", "done"}
UI_ONLY = re.compile(r"\b(screenshot|screenshots|in a browser|browser\)|visually|by eye)\b", re.I)
HUMAN = re.compile(r"\b(orchestrator|human)\b", re.I)


def git(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)


def parse(path):
    text = open(path, encoding="utf-8").read()
    fm, body = {}, text
    m = re.match(r"^---\n(.*?)\n---\n(.*)$", text, re.S)
    if m:
        for line in m.group(1).splitlines():
            line = re.sub(r"\s+#.*$", "", line)
            if ":" in line:
                k, v = line.split(":", 1)
                fm[k.strip()] = v.strip()
        body = m.group(2)
    sections, cur = {}, None
    for line in body.splitlines():
        h = re.match(r"^##\s+(.+?)\s*$", line)
        if h:
            cur = h.group(1).strip().lower()
            sections[cur] = []
        elif cur is not None:
            sections[cur].append(line)
    return fm, {k: "\n".join(v) for k, v in sections.items()}


def expand_braces(p):
    m = re.search(r"\{([^{}]+)\}", p)
    if not m:
        return [p]
    out = []
    for alt in m.group(1).split(","):
        out += expand_braces(p[:m.start()] + alt.strip() + p[m.end():])
    return out


def paths_in(section_text):
    """Backticked paths at the start of list items, e.g. "- `internal/app/x.go`: rule" or "- `a/`, `b/`"."""
    found = []
    for line in section_text.splitlines():
        s = line.strip()
        if not s.startswith(("-", "*")):
            continue
        is_new = "(new" in s.lower()
        lead = s.split(":", 1)[0] if re.search(r"`\s*:", s) else s
        prev_dir = ""
        for tok in re.findall(r"`([^`]+)`", lead):
            tok = tok.strip()
            if not tok or " " in tok or tok.startswith(("-", "$")) or "/" not in tok and "." not in tok:
                continue
            if "/" not in tok and prev_dir:
                tok = prev_dir + "/" + tok   # shorthand: "`internal/web/a.go`, `a.templ`" means internal/web/a.templ
            elif "/" in tok:
                prev_dir = os.path.dirname(tok.rstrip("/").split("{")[0].split("*")[0]) or prev_dir
            for p in expand_braces(tok):
                found.append((p, is_new))
    # Plain text after the backticks ("`jobs.go`, `jobs_view.go`, `jobs.templ`: rule") also uses shorthand.
    return found


def exists_on_base(repo, base, path):
    p = path.rstrip("/")
    if any(c in p for c in "*?["):
        d = os.path.dirname(p.split("*")[0]) or "."
        return git("cat-file", "-e", f"{base}:{d}", cwd=repo).returncode == 0 or d == "."
    return git("cat-file", "-e", f"{base}:{p}", cwd=repo).returncode == 0


def overlaps(a, b):
    a, b = a.rstrip("/"), b.rstrip("/")
    if "*" in a or "*" in b:
        pa, pb = a.split("*")[0], b.split("*")[0]
        return pa.startswith(pb) or pb.startswith(pa)
    return a == b or a.startswith(b + "/") or b.startswith(a + "/")


def main(argv):
    ap = argparse.ArgumentParser(prog="orchestra-task lint")
    ap.add_argument("ids", nargs="*", help="task ids to check (default: all not done)")
    ap.add_argument("--tasks-dir", default=os.environ.get("ORCHESTRA_TASKS_DIR", "docs/work/tasks"))
    ap.add_argument("--base", default=os.environ.get("ORCHESTRA_BASE", "origin/main"))
    ap.add_argument("--profile", default=os.environ.get("ORCHESTRA_PROFILE", "dev"))
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)

    repo = git("rev-parse", "--show-toplevel", cwd=os.getcwd()).stdout.strip()
    if not repo:
        print("orchestra-task: run inside a git repository", file=sys.stderr); return 2
    if git("rev-parse", "--verify", "--quiet", a.base, cwd=repo).returncode != 0:
        a.base = "HEAD"
    tdir = os.path.join(repo, a.tasks_dir)
    if not os.path.isdir(tdir):
        print(f"orchestra-task: no tasks directory {a.tasks_dir}", file=sys.stderr); return 2

    tasks = {}
    for f in sorted(os.listdir(tdir)):
        if not f.endswith(".md") or f.startswith("_"):
            continue
        fm, sec = parse(os.path.join(tdir, f))
        tid = fm.get("id") or f.split("-")[0]
        tasks[tid] = {"file": os.path.join(a.tasks_dir, f), "fm": fm, "sec": sec}

    log = git("log", "--format=%s", a.base, cwd=repo).stdout.splitlines()
    done = {t for t in tasks if any(s.startswith(t + ":") for s in log)}
    deps = {t: [d for d in re.split(r"[\s,]+", v["fm"].get("depends", "")) if d and d.lower() != "none"] for t, v in tasks.items()}

    def ancestors(t, seen=None):
        seen = set() if seen is None else seen
        for d in deps.get(t, []):
            if d not in seen:
                seen.add(d); ancestors(d, seen)
        return seen

    open_ids = [t for t in tasks if t not in done and tasks[t]["fm"].get("status") != "done"]
    check = a.ids or open_ids
    owns = {t: paths_in(tasks[t]["sec"].get("owns", "")) for t in open_ids}
    results, failed = {}, False

    for t in check:
        if t not in tasks:
            results[t] = {"errors": [f"no task file for {t}"], "warnings": []}; failed = True; continue
        fm, sec = tasks[t]["fm"], tasks[t]["sec"]
        errs, warns = [], []
        need = REQUIRED + (OPS_REQUIRED if a.profile == "ops" else [])
        missing = [k for k in need if not fm.get(k)]
        if missing:
            errs.append(f"L1 front matter missing: {', '.join(missing)}")
        if fm.get("delegation") and fm["delegation"].split()[0] not in DELEGATION:
            errs.append(f"L1 delegation must be one of {', '.join(sorted(DELEGATION))}")
        if fm.get("status") and fm["status"] not in STATUS:
            errs.append(f"L1 status must be one of {', '.join(sorted(STATUS))}")
        if a.profile == "ops" and fm.get("risk") and fm["risk"].split()[0] not in {"low", "medium", "high"}:
            errs.append("L1 risk must be low, medium or high")

        if t in done:
            results[t] = {"errors": errs, "warnings": ["done on the base branch"], "done": True}
            failed |= bool(errs); continue

        if not sec.get("owns", "").strip():
            errs.append("L5 no Owns section (or it is empty)")
        chain = ancestors(t)
        for other in open_ids:
            if other == t or other in chain or t in ancestors(other):
                continue
            for p, _ in owns.get(t, []):
                for q, _ in owns.get(other, []):
                    if overlaps(p, q):
                        errs.append(f"L5 Owns `{p}` overlaps {other}'s `{q}` and the tasks are not chained")

        for name in ("owns", "touches"):
            for p, is_new in paths_in(sec.get(name, "")):
                if is_new or exists_on_base(repo, a.base, p):
                    continue
                parent = os.path.dirname(p.rstrip("/"))
                if name == "owns" and (not parent or exists_on_base(repo, a.base, parent + "/")):
                    continue   # a new file in an existing folder: plausible, the task creates it
                errs.append(f"L6 {name} path `{p}` not on {a.base}" +
                            (" (nor its folder: typo?)" if name == "owns" else " (Touches must name existing files)"))

        acc = sec.get("acceptance", "")
        if not acc.strip():
            errs.append("L8 no Acceptance section")
        else:
            if "`" not in acc:
                errs.append("L8 acceptance has no command in backticks for the worker to run")
            for line in acc.splitlines():
                if UI_ONLY.search(line) and not HUMAN.search(line):
                    errs.append(f"L8 visual check not marked Orchestrator/Human: {line.strip()[:90]}")

        for d in deps.get(t, []):
            if d not in tasks:
                errs.append(f"L10 depends on unknown task {d}")
            elif fm.get("status") == "ready" and d not in done:
                warns.append(f"L10 ready but {d} is not done yet (fine only if it is chained on purpose)")

        if "out of scope" not in sec:
            errs.append("L11 no 'Out of scope' section")

        results[t] = {"errors": errs, "warnings": warns}
        failed |= bool(errs)

    if a.json:
        print(json.dumps(results, indent=2))
    else:
        for t, r in results.items():
            mark = "done" if r.get("done") else ("FAIL" if r["errors"] else "ok  ")
            print(f"{mark} {t}  {tasks.get(t, {}).get('file', '')}")
            for e in r["errors"]:
                print(f"     error: {e}")
            for w in r["warnings"]:
                print(f"     warn:  {w}")
        print(f"--- {sum(1 for r in results.values() if not r['errors'])}/{len(results)} pass")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
