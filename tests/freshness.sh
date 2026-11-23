#!/usr/bin/env bash
# tests/freshness.sh: offline cases for the stale-worktree check in `orchestra-worker run` (issue #1).
# A worktree with no work is rebased onto the base; one with work is refused when the spec changed on the base.
set -uo pipefail

main() {
  local root; root=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
  export ORCHESTRA_TEST_ROOT=$root
  local TMP_DIR cfg; TMP_DIR=$(mktemp -d); cfg=$(mktemp -d)   # never read the developer's own config
  export XDG_CONFIG_HOME=$cfg
  # shellcheck disable=SC2064  # expanded now on purpose: the locals are gone when the trap runs
  trap "rm -rf $(printf '%q' "$TMP_DIR") $(printf '%q' "$cfg")" EXIT
  local W="$root/bin/orchestra-worker" pass=0 fail=0
  local SPEC=docs/work/tasks/F1-x.md
  local REPO="" WT="" FIX="" OUT="$TMP_DIR/out"

  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  export ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_ALLOWED_MODELS=fake/worker-1 FAKE_MODEL=fake/worker-1
  export ORCHESTRA_HARNESS="$root/tests/fixtures/fake-harness.sh"
  export ORCHESTRA_KEY_ENV=FAKE_API_KEY ORCHESTRA_KEY_CMD='printf %s "$FAKE_SECRET"'
  export FAKE_SECRET="sk-test-$RANDOM$RANDOM"
  export ORCHESTRA_TIMEOUT=60s ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1
  export ORCHESTRA_BASE=origin/main
  unset FAKE_REPORT

  ok()  { pass=$((pass+1)); echo "ok   $*"; }
  bad() { fail=$((fail+1)); echo "FAIL $*"; }
  check_rc() { local want=$1 name=$2 got=$3
    if [ "$got" = "$want" ]; then ok "$name (rc $got)"; else bad "$name: rc $got, want $want"; sed 's/^/     /' "$OUT"; fi; }
  has() { if grep -q -- "$2" "$OUT"; then ok "$1"; else bad "$1: output lacks '$2'"; sed 's/^/     /' "$OUT"; fi; }
  hasnt() { if grep -q -- "$2" "$OUT"; then bad "$1: output contains '$2'"; sed 's/^/     /' "$OUT"; else ok "$1"; fi; }

  # new_fixture <name>: a bare remote, a clone with one commit on main, and the task spec committed.
  new_fixture() {
    local name=$1 d="$TMP_DIR/$1"
    mkdir -p "$d"
    git init -q --bare "$d/remote.git" || { bad "fixture $name: bare remote"; return 1; }
    git clone -q "$d/remote.git" "$d/repo" 2>/dev/null || { bad "fixture $name: clone"; return 1; }
    (
      cd "$d/repo" || exit 1
      git checkout -q -B main
      mkdir -p docs/work/tasks
      printf -- '---\nid: F1\ntitle: Freshness fixture\n---\n\nNothing to see.\n' > "$SPEC"
      printf 'base\n' > src.txt
      printf 'other\n' > other.txt
      git add -A && git commit -qm init && git push -q origin main
    ) >/dev/null 2>&1 || { bad "fixture $name: initial commit"; return 1; }
    FIX=$d; REPO=$d/repo; WT=$d/repo-worktrees/$name
  }

  # make_wt <task>: the worktree the fixture cases run in, created at origin/main like the guide says.
  make_wt() {
    local task=$1
    ( cd "$REPO" && git worktree add -q -b "task/$task" "../repo-worktrees/$task" origin/main ) >/dev/null 2>&1 \
      || { bad "worktree $task"; return 1; }
    WT=$FIX/repo-worktrees/$task
  }

  wt_commit() { printf '%s\n' "$2" > "$WT/$1"; git -C "$WT" add -A && git -C "$WT" commit -qm "change $1"; }
  wt_claim()  { git -C "$WT" commit -q --allow-empty -m "$1"; }

  # Moves main on in the repository and pushes it, the way another task landing would.
  move_spec() {
    ( cd "$REPO" || exit 1
      printf -- '---\nid: F1\ntitle: Freshness fixture (rewritten)\n---\n\nRewritten on the base.\n' > "$SPEC"
      git add -A && git commit -qm "rewrite spec" && git push -q origin main
    ) >/dev/null 2>&1 || { bad "move main: spec"; return 1; }
  }
  move_other() {
    ( cd "$REPO" || exit 1
      printf 'changed\n' > other.txt
      git commit -qam other && git push -q origin main
    ) >/dev/null 2>&1 || { bad "move main: other"; return 1; }
  }

  # run_w <task> [args...]: run from the repository, as an orchestrator would.
  run_w() { local task=$1; shift; ( cd "$REPO" && "$W" run "$task" "$@" ) >"$OUT" 2>&1; }
  run_w_base() { local base=$1 task=$2; shift 2; ( cd "$REPO" && ORCHESTRA_BASE=$base "$W" run "$task" "$@" ) >"$OUT" 2>&1; }

  local rc

  echo "--- F1: worktree at the base, main not moved"
  if new_fixture F1 && make_wt F1; then
    rc=0; run_w F1 --spec "$SPEC" || rc=$?
    check_rc 0 "F1 at base exits 0" "$rc"
    hasnt "F1 has no freshness line" "freshness:"
  fi

  echo "--- F2: an empty claim, main rewrote the spec"
  if new_fixture F2 && make_wt F2; then
    wt_claim "claim F2"
    move_spec
    rc=0; run_w F2 --spec "$SPEC" || rc=$?
    check_rc 0 "F2 rebases a worktree with no work" "$rc"
    has "F2 logs the rebase" "rebased"
    if cmp -s "$WT/$SPEC" <(git -C "$REPO" show "origin/main:$SPEC"); then
      ok "F2 worktree spec equals the new base spec"
    else bad "F2 worktree spec differs from the base spec"; fi
    if git -C "$WT" log --format=%s | grep -qxF 'claim F2'; then ok "F2 keeps the empty claim commit"
    else bad "F2 lost the empty claim commit"; fi
  fi

  echo "--- F3: work, main rewrote the spec"
  if new_fixture F3 && make_wt F3; then
    wt_commit src.txt "work"
    move_spec
    rc=0; run_w F3 --spec "$SPEC" || rc=$?
    check_rc 2 "F3 refuses a stale worktree with work" "$rc"
    has "F3 names the spec" "$SPEC"
    has "F3 suggests --allow-stale" -- "--allow-stale"
    if [ ! -e "$WT/.orchestra/runs/run-1.jsonl" ]; then ok "F3 writes no run state"
    else bad "F3 wrote .orchestra/runs/run-1.jsonl"; fi
  fi

  echo "--- F4: work, main rewrote the spec, --allow-stale"
  if new_fixture F4 && make_wt F4; then
    wt_commit src.txt "work"
    move_spec
    rc=0; run_w F4 --spec "$SPEC" --allow-stale || rc=$?
    check_rc 0 "F4 --allow-stale goes on" "$rc"
    has "F4 logs (--allow-stale)" "(--allow-stale)"
  fi

  echo "--- F5: work, main changed an unrelated file"
  if new_fixture F5 && make_wt F5; then
    wt_commit src.txt "work"
    move_other
    rc=0; run_w F5 --spec "$SPEC" || rc=$?
    check_rc 0 "F5 goes on when only other code moved" "$rc"
    has "F5 logs the older code" "reads the older code"
  fi

  echo "--- F6: uncommitted work, main rewrote the spec"
  if new_fixture F6 && make_wt F6; then
    printf 'uncommitted\n' > "$WT/src.txt"
    move_spec
    rc=0; run_w F6 --spec "$SPEC" || rc=$?
    check_rc 2 "F6 counts uncommitted work" "$rc"
  fi

  echo "--- F7: work, base does not exist"
  if new_fixture F7 && make_wt F7; then
    wt_commit src.txt "work"
    move_spec
    rc=0; run_w_base nowhere/main F7 --spec "$SPEC" || rc=$?
    check_rc 0 "F7 skips an unknown base" "$rc"
    has "F7 logs not checked" "freshness: not checked (nowhere/main not found)"
  fi

  echo "--- F8: work, main rewrote the spec, --dry-run"
  if new_fixture F8 && make_wt F8; then
    wt_commit src.txt "work"
    move_spec
    local head_before; head_before=$(git -C "$WT" rev-parse HEAD)
    rc=0; run_w F8 --spec "$SPEC" --dry-run || rc=$?
    check_rc 0 "F8 dry run does not die" "$rc"
    has "F8 reports the refusal" "dry run: freshness would refuse"
    if [ "$(git -C "$WT" rev-parse HEAD)" = "$head_before" ]; then ok "F8 dry run leaves HEAD alone"
    else bad "F8 dry run moved HEAD"; fi
  fi

  echo "--- F9: a feedback round after F4"
  if new_fixture F9 && make_wt F9; then
    wt_commit src.txt "work"
    move_spec
    rc=0; run_w F9 --spec "$SPEC" --allow-stale || rc=$?
    check_rc 0 "F9 first round goes on with --allow-stale" "$rc"
    rc=0; run_w F9 --feedback "$SPEC" || rc=$?
    check_rc 0 "F9 feedback round skips the check" "$rc"
    hasnt "F9 feedback has no freshness line" "freshness:"
  fi

  echo "--- F10: an empty claim, main moved, spec from outside the repository"
  if new_fixture F10 && make_wt F10; then
    wt_claim "claim F10"
    move_other
    local outside="$TMP_DIR/outside-spec.md"
    printf -- '---\nid: F10\ntitle: Outside spec\n---\n\nAn outside spec.\n' > "$outside"
    rc=0; run_w F10 --spec "$outside" || rc=$?
    check_rc 0 "F10 rebases a no-work worktree with an outside spec" "$rc"
    has "F10 logs the rebase" "rebased"
  fi

  echo "freshness: $pass passed, $fail failed"
  [ "$fail" = 0 ]
}

main "$@"
