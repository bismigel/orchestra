#!/usr/bin/env bash
# Pre-run task lint (run refuses, scout only warns), --local-worktree / ORCHESTRA_WORKTREE_LOCAL, and guide --cat.
# Offline: a throwaway repository, the fake harness and the scout fixture harness. No model calls, no network.
set -euo pipefail
main() {
  # Isolate from any outer orchestra-worker invocation (e.g. ORCHESTRA_PR_BRANCH during self-landing).
  local _v; for _v in $(compgen -e | grep '^ORCHESTRA_' || true); do unset "$_v"; done
  local root; root=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
  export ORCHESTRA_TEST_ROOT=$root XDG_CONFIG_HOME
  XDG_CONFIG_HOME=$(mktemp -d)   # never read the developer's own config
  TMP_DIR=$(mktemp -d); trap 'rm -rf "$TMP_DIR" "$XDG_CONFIG_HOME"' EXIT
  local tmp=$TMP_DIR
  local W="$root/bin/orchestra-worker" pass=0 fail=0

  ok()   { pass=$((pass+1)); echo "ok   $*"; }
  bad()  { fail=$((fail+1)); echo "FAIL $*"; }
  expect_rc() { local want=$1 name=$2; shift 2; local rc=0; "$@" >"$tmp/out" 2>&1 || rc=$?
    if [ "$rc" = "$want" ]; then ok "$name (rc $rc)"; else bad "$name: rc $rc, want $want"; sed 's/^/     /' "$tmp/out"; fi; }
  has() { if grep -q -- "$2" "$tmp/out"; then ok "$1"; else bad "$1: output lacks '$2'"; sed 's/^/     /' "$tmp/out"; fi; }

  # A throwaway repository with one commit.
  local repo="$tmp/demo"; git init -q -b main "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  cd "$repo"

  # 1. guide --cat prints the text; guide land names the skill file.
  local rc=0
  "$W" guide orchestrator --cat > "$tmp/guide.out" 2>&1 || rc=$?
  if [ "$rc" = 0 ] && cmp -s "$tmp/guide.out" "$root/docs/orchestrator-guide.md"; then
    ok "guide orchestrator --cat prints docs/orchestrator-guide.md"; else bad "guide orchestrator --cat differs (rc $rc)"; fi
  rc=0
  "$W" guide land --cat > "$tmp/guide.out" 2>&1 || rc=$?
  if [ "$rc" = 0 ] && cmp -s "$tmp/guide.out" "$root/skills/claude-code/orchestra-land/SKILL.md"; then
    ok "guide land --cat prints the orchestra-land skill"; else bad "guide land --cat differs (rc $rc)"; fi
  rc=0
  "$W" guide land > "$tmp/guide.out" 2>&1 || rc=$?
  local land_path=""; land_path=$(cat "$tmp/guide.out") || true
  case "$land_path" in
    */orchestra-land/SKILL.md) [ "$rc" = 0 ] && ok "guide land prints a path to orchestra-land/SKILL.md" \
      || bad "guide land printed $land_path (rc $rc)" ;;
    *) bad "guide land printed $land_path, want a path ending in orchestra-land/SKILL.md (rc $rc)" ;;
  esac

  export ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_ALLOWED_MODELS=fake/worker-1
  export ORCHESTRA_HARNESS="$root/tests/fixtures/fake-harness.sh" ORCHESTRA_TIMEOUT=60s
  export FAKE_MODEL=fake/worker-1 ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1

  # The task board: one spec that fails lint only on Out of scope, one that passes.
  mkdir -p "$repo/docs/work/tasks"
  cat > "$repo/docs/work/tasks/X1-bad.md" <<'TASK'
---
id: X1
title: A spec without an out-of-scope section
status: ready
depends: none
delegation: worker
---
## Goal
Write the greeting file.

## Owns
- `src/x1.py` (new)

## Acceptance
- `test -f src/x1.py`
- proof: `test -f src/x1.py`
TASK
  cat > "$repo/docs/work/tasks/X2-good.md" <<'TASK'
---
id: X2
title: A spec that passes the lint
status: ready
depends: none
delegation: worker
---
## Goal
Write the good file.

## Owns
- `src/x2.py` (new)

## Acceptance
- `test -f src/x2.py`
- proof: `test -f src/x2.py`

## Out of scope
Anything outside `src/x2.py`.
TASK
  # A spec outside the task board: front matter, but no Out of scope. It must not be linted.
  cat > "$repo/spec.md" <<'SPEC'
---
id: OUT
title: A draft kept in the repository root
status: ready
depends: none
delegation: worker
---
## Goal
A draft that the board has not seen yet.
SPEC
  git -C "$repo" add -A
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m "board"

  # 2. run refuses a board spec that fails lint, before any worktree.
  expect_rc 2 "run refuses a spec that fails lint" "$W" run X1 --spec docs/work/tasks/X1-bad.md --dry-run
  has "the lint error is shown" "L11 no 'Out of scope'"
  if grep -qF -- '--skip-lint' "$tmp/out"; then ok "the refusal names the way out (--skip-lint)"; else
    bad "the refusal does not mention --skip-lint"; sed 's/^/     /' "$tmp/out"; fi
  expect_rc 2 "the refusal names the task" "$W" run X1 --spec docs/work/tasks/X1-bad.md --dry-run
  has "the refusal says task lint failed for X1" "task lint failed for X1"
  if [ ! -d "$tmp/demo-worktrees/X1" ]; then ok "a refused run creates no worktree"; else bad "a refused run created a worktree"; fi

  # 3. --skip-lint turns the check off.
  expect_rc 0 "run --skip-lint lets a failing spec through (dry run)" \
    "$W" run X1 --spec docs/work/tasks/X1-bad.md --dry-run --skip-lint

  # 4. A spec that passes lint runs.
  expect_rc 0 "run accepts a spec that passes lint (dry run)" "$W" run X2 --spec docs/work/tasks/X2-good.md --dry-run

  # 5. A spec outside the tasks dir is not linted, even without Out of scope.
  expect_rc 0 "a spec outside the tasks dir is not linted (dry run)" "$W" run OUT --spec spec.md --dry-run

  # 6. scout only warns: the lint problem goes to stderr and the scout runs.
  rc=0
  ORCHESTRA_HARNESS="$root/tests/fixtures/scout-harness.sh" \
    "$W" scout X1 --spec docs/work/tasks/X1-bad.md > "$tmp/scout.out" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then ok "scout runs despite a lint failure (rc 0)"; else bad "scout exit $rc, want 0"; sed 's/^/     /' "$tmp/scout.out"; fi
  if grep -q "task lint found problems" "$tmp/scout.out"; then ok "scout warns about the lint problem"; else
    bad "scout output lacks the lint warning"; sed 's/^/     /' "$tmp/scout.out"; fi
  if [ -f "$tmp/demo-worktrees/.scout/X1/scout.json" ]; then ok "the scout still wrote its report"; else bad "no scout.json"; fi

  # 7. --local-worktree (and ORCHESTRA_WORKTREE_LOCAL=1) skip ORCHESTRA_WORKTREE_CMD.
  export ORCHESTRA_HARNESS="$root/tests/fixtures/fake-harness.sh"
  expect_rc 0 "run --local-worktree ignores ORCHESTRA_WORKTREE_CMD" \
    env ORCHESTRA_WORKTREE_CMD='touch "$PWD/cmd-was-run"; false' "$W" run t9 --prompt "x" --local-worktree
  if [ -d "$tmp/demo-worktrees/t9" ]; then ok "run --local-worktree created the worktree"; else bad "no worktree t9"; fi
  if [ ! -e "$repo/cmd-was-run" ]; then ok "run --local-worktree did not run the worktree command"; else bad "the worktree command ran"; fi
  expect_rc 0 "ORCHESTRA_WORKTREE_LOCAL=1 ignores ORCHESTRA_WORKTREE_CMD without a flag" \
    env ORCHESTRA_WORKTREE_CMD='touch "$PWD/cmd-was-run"; false' ORCHESTRA_WORKTREE_LOCAL=1 "$W" run t10 --prompt "x"
  if [ -d "$tmp/demo-worktrees/t10" ]; then ok "ORCHESTRA_WORKTREE_LOCAL=1 created the worktree"; else bad "no worktree t10"; fi
  if [ ! -e "$repo/cmd-was-run" ]; then ok "ORCHESTRA_WORKTREE_LOCAL=1 did not run the worktree command"; else bad "the worktree command ran"; fi
  # The dry-run message names the command that would really be used.
  expect_rc 0 "dry run with --local-worktree" \
    env ORCHESTRA_WORKTREE_CMD='scripts/claim.sh {task}' "$W" run t11 --prompt "x" --dry-run --local-worktree
  has "the dry-run message names the local worktree command" "git worktree add -q -b orchestra/t11"
  expect_rc 0 "dry run without --local-worktree" \
    env ORCHESTRA_WORKTREE_CMD='scripts/claim.sh {task}' "$W" run t12 --prompt "x" --dry-run
  has "the dry-run message names ORCHESTRA_WORKTREE_CMD" "scripts/claim.sh t12"

  echo "---"; echo "$pass passed, $fail failed"
  [ "$fail" = 0 ]
}
main "$@"
