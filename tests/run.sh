#!/usr/bin/env bash
# orchestra tests: no model calls, no network. Run from anywhere: tests/run.sh
set -euo pipefail
main() {
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
  hasnt() { if grep -q -- "$2" "$tmp/out"; then bad "$1: output contains '$2'"; else ok "$1"; fi; }

  # A throwaway repository with one commit.
  local repo="$tmp/demo"; git init -q -b main "$repo"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  cp "$root/examples/hello/spec.md" "$repo/spec.md"
  cd "$repo"

  export ORCHESTRA_MODEL=fake/worker-1 ORCHESTRA_ALLOWED_MODELS=fake/worker-1
  export ORCHESTRA_HARNESS="$root/tests/fixtures/fake-harness.sh" ORCHESTRA_KEY_ENV=FAKE_API_KEY
  export FAKE_SECRET="sk-test-$RANDOM$RANDOM" ORCHESTRA_KEY_CMD='printf %s "$FAKE_SECRET"' ORCHESTRA_TIMEOUT=60s

  # Parsers of the real pi adapter on a fixture.
  ( die() { echo "$*"; exit 2; }; . "$root/lib/harness/pi.sh"
    m=$(harness_models_used "$root/tests/fixtures/pi-events.jsonl"); u=$(harness_usage "$root/tests/fixtures/pi-events.jsonl")
    [ "$m" = "deepseek/deepseek-flash" ] && python3 -c 'import json,sys; u=json.loads(sys.argv[1]); assert u["responses"]==2 and u["input"]==300 and abs(u["cost"]-0.003)<1e-9' "$u" ) \
    && ok "pi adapter parses models and usage" || bad "pi adapter parsing"

  # Config and usage errors.
  expect_rc 2 "rejects a model outside the allowlist" env ORCHESTRA_ALLOWED_MODELS=other/model "$W" run t1 --spec spec.md --dry-run
  expect_rc 2 "rejects a bad task id" "$W" run 'bad id' --spec spec.md --dry-run
  expect_rc 2 "feedback needs an existing worktree" "$W" run nope --feedback spec.md

  # Dry run: shows the plan, never fetches or prints the key.
  if command -v bwrap >/dev/null; then
    expect_rc 0 "dry run (bwrap)" env FAKE_MODEL=fake/worker-1 "$W" run t1 --spec spec.md --dry-run
    has "dry run builds a bwrap sandbox" "bwrap"
    hasnt "dry run does not contain the key" "$FAKE_SECRET"
    expect_rc 0 "dry run with a worktree command" env FAKE_MODEL=fake/worker-1 ORCHESTRA_WORKTREE_CMD='touch "$PWD/CLAIMED"; git worktree add -q -b x/{task} ../demo-worktrees/{task} HEAD' "$W" run dry1 --spec spec.md --dry-run
    if [ ! -e "$repo/CLAIMED" ] && [ ! -d "$(dirname "$repo")/demo-worktrees/dry1" ]; then ok "dry run has no side effects"; else bad "dry run ran the worktree command"; fi
  else
    echo "skip bwrap tests: bubblewrap not installed"
  fi

  # Real runs with the fake harness, in every sandbox available.
  local modes="none"; command -v bwrap >/dev/null && bwrap --ro-bind / / true 2>/dev/null && modes="bwrap none"
  local sb
  for sb in $modes; do
    export ORCHESTRA_SANDBOX=$sb ORCHESTRA_ALLOW_UNSANDBOXED=1
    expect_rc 0 "[$sb] valid run" env FAKE_MODEL=fake/worker-1 "$W" run "ok-$sb" --spec spec.md
    hasnt "[$sb] key not printed" "$FAKE_SECRET"
    cp "$(dirname "$repo")/demo-worktrees/ok-$sb/.orchestra/runs/run-1.err" "$tmp/out"
    has "[$sb] key reached the harness" "key-present"
    hasnt "[$sb] key not in any command line" "KEY-IN-CMDLINE"
    hasnt "[$sb] key not in the harness log" "$FAKE_SECRET"
    has "[$sb] python3 on the worker PATH" "tool-python3-ok"
    has "[$sb] git on the worker PATH" "tool-git-ok"
    if [ -f "$(dirname "$repo")/demo-worktrees/ok-$sb/.orchestra/spec.md" ]; then ok "[$sb] uncommitted spec copied into the worktree"
    else bad "[$sb] uncommitted spec not copied into the worktree"; fi
    expect_rc 0 "[$sb] valid run (again, for the summary checks)" env FAKE_MODEL=fake/worker-1 "$W" run "ok2-$sb" --spec spec.md
    has "[$sb] cost summary" 'task total: \$0.0010'
    expect_rc 3 "[$sb] a disallowed model fails the run" env FAKE_MODEL=fake/expensive "$W" run "model-$sb" --spec spec.md
    expect_rc 4 "[$sb] missing report fails the run" env FAKE_MODEL=fake/worker-1 FAKE_REPORT=none "$W" run "norep-$sb" --spec spec.md
    expect_rc 4 "[$sb] invalid report fails the run" env FAKE_MODEL=fake/worker-1 FAKE_REPORT=invalid "$W" run "badrep-$sb" --spec spec.md
    expect_rc 0 "[$sb] feedback round reuses the worktree" env FAKE_MODEL=fake/worker-1 "$W" run "ok-$sb" --feedback spec.md
    has "[$sb] second run counted" "run 2 exit 0"
    if [ -s "$(dirname "$repo")/demo-worktrees/ok-$sb/.orchestra/report.json" ] && \
       ! git -C "$(dirname "$repo")/demo-worktrees/ok-$sb" status --short | grep -q orchestra; then
      ok "[$sb] state stays out of git status"; else bad "[$sb] .orchestra/ shows in git status"; fi
  done
  if [ "${modes%% *}" = none ]; then echo "skip bwrap run tests: bubblewrap cannot create namespaces here"; fi

  # Profiles: the ops profile picks the ops worker prompt; dev keeps the default one.
  expect_rc 0 "ops profile dry run" env FAKE_MODEL=fake/worker-1 ORCHESTRA_PROFILE=ops "$W" run prof1 --spec spec.md --dry-run
  ( cd "$repo" && git worktree add -q -b orchestra/prof2 "$(dirname "$repo")/demo-worktrees/prof2" HEAD )
  expect_rc 0 "ops profile dry run on an existing worktree" env FAKE_MODEL=fake/worker-1 ORCHESTRA_PROFILE=ops "$W" run prof2 --spec spec.md --dry-run
  has "ops profile selects the ops worker prompt" "prompts/worker-ops.md"
  expect_rc 0 "dev profile dry run" env FAKE_MODEL=fake/worker-1 "$W" run prof2 --spec spec.md --dry-run
  has "dev profile keeps the default prompt" "prompts/worker.md"

  # orchestra-task lint on a fixture board: every rule must fire on the bad task and none on the good ones.
  local lrepo="$tmp/lintrepo"; mkdir -p "$lrepo/src" "$lrepo/docs/work/tasks"; git init -q -b main "$lrepo"
  echo x > "$lrepo/src/greet.py"; echo x > "$lrepo/README.md"; cp "$root"/tests/fixtures/board/*.md "$lrepo/docs/work/tasks/"
  git -C "$lrepo" add -A; git -C "$lrepo" -c user.email=t@t -c user.name=t commit -q -m init
  ( cd "$lrepo" && "$root/bin/orchestra-task" lint --base HEAD A1 A2 A3 A4 ) > "$tmp/out" 2>&1 && bad "lint passes a broken board" || ok "lint fails a broken board"
  has "lint: good task passes" "ok   A1"
  has "lint: chained task may share ownership" "ok   A3"
  has "lint: an unchained overlap fails both tasks" "FAIL A4"
  for rule in "L1 front matter missing" "L1 delegation must be" "L1 status must be" "L5 Owns" "L6 owns path \`nowhere" \
              "L6 touches path \`docs/missing.md\`" "L8 acceptance has no command" "L8 visual check not marked" \
              "L10 depends on unknown task A9" "L11 no 'Out of scope'"; do
    has "lint rule fires: $rule" "$rule"
  done
  hasnt "lint: marked new file is accepted" "new_module.py"
  ( cd "$lrepo" && "$root/bin/orchestra-task" lint --base HEAD --profile ops O1 ) > "$tmp/out" 2>&1 || true
  has "lint (ops): risk and rollback required" "L1 front matter missing: risk, rollback"
  ( cd "$lrepo" && "$root/bin/orchestra-task" lint --base HEAD O1 ) > "$tmp/out" 2>&1 && ok "lint (dev): no risk/rollback needed" || bad "lint (dev) wrongly needs risk/rollback"

  echo "---"; echo "$pass passed, $fail failed"
  [ "$fail" = 0 ]
}
main "$@"
