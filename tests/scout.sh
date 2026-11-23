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
if ! command -v bwrap >/dev/null || ! bwrap --ro-bind / / true 2>/dev/null; then
  echo "skip: bubblewrap cannot create namespaces here"; echo "scout: 0 passed, 0 failed"; exit 0
fi
export XDG_CONFIG_HOME="$TMP/cfg" ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_HARNESS="$ROOT/tests/fixtures/scout-harness.sh"
git init -q -b main "$TMP/repo" && git -C "$TMP/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
echo '# draft spec' > "$TMP/draft.md"
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
# A disallowed model fails the scout like a run.
out=$(cd "$TMP/repo" && ORCHESTRA_ALLOWED_MODELS=other/model "$W" scout P2 --spec "$TMP/draft.md" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "model outside the allowlist refused (rc 2)" || bad "allowlist not enforced: rc $rc"
echo "scout: $pass passed, $fail failed"
[ "$fail" = 0 ]
