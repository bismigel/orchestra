#!/usr/bin/env bash
# scout: the sandbox is read-only for the repository and git, the report is validated, and the view is printed.
# Offline: a fake harness tries to write, then reports. Needs bubblewrap able to create namespaces.
set -uo pipefail
ROOT=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
W="$ROOT/bin/orchestra-worker"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "ok   $*"; }
bad() { fail=$((fail+1)); echo "FAIL $*"; }
CAN_BWRAP=0
if command -v bwrap >/dev/null && bwrap --ro-bind / / true 2>/dev/null; then CAN_BWRAP=1; fi
SANDBOX_ARGS=()
if [ "$CAN_BWRAP" = 0 ]; then
  echo "note: bubblewrap cannot create namespaces here: read-only checks are skipped, feature checks run unsandboxed"
  SANDBOX_ARGS=(env ORCHESTRA_SANDBOX=none ORCHESTRA_ALLOW_UNSANDBOXED=1)
fi
export XDG_CONFIG_HOME="$TMP/cfg" ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_HARNESS="$ROOT/tests/fixtures/scout-harness.sh"
git init -q -b main "$TMP/repo" && git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
echo '# draft spec' > "$TMP/draft.md"
if [ "$CAN_BWRAP" = 1 ]; then
  head0=$(git -C "$TMP/repo" rev-parse HEAD)
  out=$(cd "$TMP/repo" && "$W" scout P1 --spec "$TMP/draft.md" 2>&1); rc=$?
  err="$TMP/repo-worktrees/.scout/P1/runs/run-1.err"
  [ "$rc" = 0 ] && ok "scout exits 0" || bad "scout exit $rc: $out"
  grep -q repo-readonly "$err" && [ ! -e "$TMP/repo/PROBE-repo" ] && ok "repository is read-only" || bad "scout wrote the repository"
  grep -q git-readonly "$err" && [ ! -e "$TMP/repo/.git/PROBE-git" ] && ok "git directory is read-only" || bad "scout wrote .git"
  grep -q commit-refused "$err" && [ "$(git -C "$TMP/repo" rev-parse HEAD)" = "$head0" ] && ok "scout cannot commit" || bad "scout committed"
  [ -z "$(git -C "$TMP/repo" status --porcelain)" ] && ok "checkout unchanged" || bad "checkout changed"
  grep -q 'x.go → y.go:3' <<<"$out" && ok "view shows a misplaced path" || bad "view lacks the mapping: $out"
  grep -q '^- `y.go`: wiring' <<<"$out" && ok "view prints the paste block" || bad "no paste block: $out"
  [ -f "$TMP/repo-worktrees/.scout/P1/scout.json" ] && ok "report kept next to the run" || bad "scout.json not kept"
  [ ! -f "$TMP/repo-worktrees/.scout/P1/run.json" ] && ok "run state removed after the run" || bad "run.json left behind"
else
  echo "skip read-only sandbox checks: bubblewrap cannot create namespaces here"
fi
# A disallowed model fails the scout like a run.
out=$(cd "$TMP/repo" && ORCHESTRA_ALLOWED_MODELS=other/model "${SANDBOX_ARGS[@]}" "$W" scout P2 --spec "$TMP/draft.md" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "model outside the allowlist refused (rc 2)" || bad "allowlist not enforced: rc $rc"

# --prompt works without a spec file; a host-side ORCHESTRA_STATE_CMD becomes live-state.txt, state.md and drift.
out=$(cd "$TMP/repo" && ORCHESTRA_STATE_CMD='printf "live replicas: 2\n"' SCOUT_STATE=1 "${SANDBOX_ARGS[@]}" \
      "$W" scout P3 --prompt "Add a widget" --state 2>&1); rc=$?
[ "$rc" = 0 ] && ok "scout --prompt exits 0" || bad "scout --prompt exit $rc: $out"
grep -qx 'Add a widget' "$TMP/repo-worktrees/.scout/P3/home/spec.md" \
  && ok "scout --prompt writes the prompt as its spec" || bad "scout --prompt did not write home/spec.md"
grep -qx 'live replicas: 2' "$TMP/repo-worktrees/.scout/P3/home/live-state.txt" \
  && ok "ORCHESTRA_STATE_CMD runs on the host into live-state.txt" || bad "no live-state.txt content"
[ -f "$TMP/repo-worktrees/.scout/P3/state.md" ] && ok "state.md is copied next to scout.json" || bad "no state.md snapshot"
grep -q 'Drift' "$TMP/repo-worktrees/.scout/P3/state.md" && ok "state.md has the drift section" || bad "state.md lacks drift"
grep -q '^state snapshot: ' <<<"$out" && ok "the run names the state snapshot" || bad "no state snapshot line: $out"
grep -q 'drift' <<<"$out" && grep -q 'live replicas 2, git replicas 1' <<<"$out" \
  && ok "the scout view shows drift" || bad "the scout view lacks drift: $out"

# A failing state command warns and continues, and the snapshot says the live state is incomplete.
out=$(cd "$TMP/repo" && ORCHESTRA_STATE_CMD='printf "partial\n"; exit 7' SCOUT_STATE=1 "${SANDBOX_ARGS[@]}" \
      "$W" scout P4 --prompt "Another widget" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "a failing ORCHESTRA_STATE_CMD still lets the scout finish" || bad "state failure aborted the scout: rc $rc"
grep -q 'warning: ORCHESTRA_STATE_CMD exited 7' <<<"$out" && ok "the state command failure is warned about" || bad "no warning: $out"
grep -q 'incomplete' "$TMP/repo-worktrees/.scout/P4/home/live-state.txt" \
  && ok "live-state.txt notes the failed snapshot" || bad "live-state.txt lacks the failure note"
[ -f "$TMP/repo-worktrees/.scout/P4/state.md" ] && ok "a non-empty live state asks for state.md without --state" \
  || bad "no state.md without --state"

# --spec and --prompt are mutually exclusive.
out=$(cd "$TMP/repo" && "${SANDBOX_ARGS[@]}" "$W" scout P5 --spec "$TMP/draft.md" --prompt x 2>&1); rc=$?
[ "$rc" = 2 ] && ok "scout refuses --spec with --prompt (rc 2)" || bad "spec+prompt rc $rc, want 2"

echo "scout: $pass passed, $fail failed"
[ "$fail" = 0 ]
