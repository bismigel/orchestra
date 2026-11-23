#!/usr/bin/env python3
"""orchestra clean: list the task worktrees that are safe to remove, and remove exactly those.

A candidate is a git worktree directly under --worktrees for --repo. Each one is classified (first match wins):

  running         .orchestra/run.json has a live pid: a worker is using it now
  dirty           untracked or modified files outside .orchestra/: work that is not in git
  landed          HEAD is an ancestor of --base, or every commit on the branch has an identical patch on --base
                  (cherry-picked or rebased): the task is on the base branch
  squash-landed   a commit on --base has the subject "<task>: ..."; only removed with --include-squashed
  open            anything else: unlanded, so it stays

Every directory under <worktrees>/.scout is a scout run and is removed unless its run.json has a live pid.

Nothing is changed without --yes. Removal uses `git worktree remove` without --force, so git refuses anything it
considers in use; branches, the main checkout and remote-tracking state are never touched.
Exit 0 on success, 1 if a removal failed, 2 on a usage or repository error.
"""
import argparse, json, os, shutil, subprocess, sys


def git(repo, *args):
    return subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)


def pid_alive(path):
    """True only when path is JSON with a positive pid that os.kill(pid, 0) accepts."""
    try:
        with open(path, encoding="utf-8") as f:
            state = json.load(f)
        pid = int(state.get("pid", 0))
    except (OSError, ValueError, TypeError, AttributeError):
        return False
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def under_orchestra(path):
    return path.startswith(".orchestra/")


def dirty(worktree):
    """Any status line whose path is not under .orchestra/ (including both sides of a rename)."""
    result = git(worktree, "status", "--porcelain", "--untracked-files=all")
    if result.returncode != 0:
        return True   # cannot prove it clean: keep it rather than risk deleting work
    for line in result.stdout.splitlines():
        if len(line) < 4:
            continue
        paths = line[3:].split(" -> ") if " -> " in line[3:] else [line[3:]]
        for path in paths:
            path = path.strip()
            if path and not under_orchestra(path):
                return True
    return False


def classify(repo, worktree, task, base, include_squashed):
    """Return (class, action) for one task worktree."""
    if pid_alive(os.path.join(worktree, ".orchestra", "run.json")):
        return "running", "keep"
    if dirty(worktree):
        return "dirty", "keep"
    if git(worktree, "merge-base", "--is-ancestor", "HEAD", base).returncode == 0:
        return "landed", "remove"
    # Cherry-picked or rebased onto the base: every commit of the branch has an identical patch there.
    cherry = git(worktree, "cherry", base, "HEAD")
    marks = [line[:1] for line in cherry.stdout.splitlines() if line.strip()]
    if cherry.returncode == 0 and marks and all(m == "-" for m in marks):
        return "landed", "remove"
    subjects = git(repo, "log", "--format=%s", base)
    if subjects.returncode == 0 and any(s.startswith(task + ":") for s in subjects.stdout.splitlines()):
        return "squash-landed", "remove" if include_squashed else "keep (needs --include-squashed)"
    return "open", "keep"


def worktrees_under(repo, worktrees):
    """(task, path) for every worktree whose parent directory is exactly worktrees, main checkout excluded."""
    result = git(repo, "worktree", "list", "--porcelain")
    if result.returncode != 0:
        return []
    wanted = os.path.realpath(worktrees)
    paths = [line[len("worktree "):] for line in result.stdout.splitlines() if line.startswith("worktree ")]
    # git lists the main checkout first; the caller may also name a subdirectory of it as --repo.
    main = {os.path.realpath(paths[0])} if paths else set()
    top = git(repo, "rev-parse", "--show-toplevel")
    if top.returncode == 0:
        main.add(os.path.realpath(top.stdout.strip()))
    found = []
    for path in paths:
        real = os.path.realpath(path)
        if real in main or os.path.dirname(real) != wanted:
            continue
        found.append((os.path.basename(real), path))
    return found


def scout_dirs(worktrees):
    """(task, path) for every directory directly under worktrees/.scout."""
    root = os.path.join(worktrees, ".scout")
    if not os.path.isdir(root):
        return []
    found = []
    for name in sorted(os.listdir(root)):
        path = os.path.join(root, name)
        if os.path.isdir(path) and not os.path.islink(path):
            found.append((name, path))
    return found


def table(rows):
    head = ("TASK", "CLASS", "ACTION", "PATH")
    widths = [max([len(head[i])] + [len(r[i]) for r in rows]) for i in range(3)]
    fmt = "%%-%ds  %%-%ds  %%-%ds  %%s" % tuple(widths)
    print(fmt % head)
    for task, cls, action, path in rows:
        print(fmt % (task, cls, action, path))


def main():
    parser = argparse.ArgumentParser(description="remove the worktrees of landed orchestra tasks")
    parser.add_argument("--repo", required=True, help="the repository whose worktrees are cleaned")
    parser.add_argument("--worktrees", required=True, help="the directory holding one worktree per task")
    parser.add_argument("--base", required=True, help="the ref tasks land on (never fetched)")
    parser.add_argument("--yes", action="store_true", help="actually remove what the table marks remove")
    parser.add_argument("--include-squashed", action="store_true", help="also remove squash-landed tasks")
    args = parser.parse_args()

    if git(args.repo, "rev-parse", "--git-dir").returncode != 0:
        sys.stderr.write("clean: not a git repository: %s\n" % args.repo)
        return 2
    base = git(args.repo, "rev-parse", "--short", args.base)
    if base.returncode != 0:
        sys.stderr.write("clean: base not resolvable: %s\n" % args.base)
        return 2
    short = base.stdout.strip()

    if not os.path.isdir(args.worktrees):
        print("nothing to clean")
        return 0

    rows = []
    for task, path in worktrees_under(args.repo, args.worktrees):
        cls, action = classify(args.repo, path, task, args.base, args.include_squashed)
        rows.append((task, cls, action, path))
    for task, path in scout_dirs(args.worktrees):
        action = "keep" if pid_alive(os.path.join(path, "run.json")) else "remove"
        rows.append((task, "scout", action, path))
    rows.sort(key=lambda row: row[0])

    print("base: %s %s (as of the last fetch)" % (args.base, short))
    table(rows)
    removable = [row for row in rows if row[2] == "remove"]

    if not args.yes:
        if removable:
            print("%d to remove; run again with --yes to remove them" % len(removable))
        else:
            print("nothing to remove")
        return 0

    failed = False
    for task, cls, action, path in removable:
        if cls == "scout":
            continue   # worktrees first, so git's own checks see the repository as it was
        result = git(args.repo, "worktree", "remove", path)
        if result.returncode == 0:
            print("removed %s" % task)
            continue
        message = next((line.strip() for line in result.stderr.splitlines() if line.strip()), "")
        if not message:
            message = "git worktree remove exited %d" % result.returncode
        print("could not remove %s: %s" % (task, message))
        failed = True

    for task, cls, action, path in removable:
        if cls != "scout":
            continue
        try:
            shutil.rmtree(path)
        except OSError as exc:
            print("could not remove %s: %s" % (task, exc))
            failed = True
        else:
            print("removed %s" % task)

    git(args.repo, "worktree", "prune")
    if not removable:
        print("nothing to remove")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
