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

  # The progress follower can exit on its own (it saw the end event) before the run kills it: the run must still
  # finish, write its usage and result files and print the card.
  expect_rc 0 "run survives a follower that already exited" env FAKE_MODEL=fake/worker-1 FAKE_END=1 ORCHESTRA_SANDBOX=none "$W" run "fend" --spec spec.md
  has "the card is printed after an early follower exit" "── fend · run 1 exit 0"
  has "progress lines were printed" "■ done"
  if [ -s "$(dirname "$repo")/demo-worktrees/fend/.orchestra/runs/run-1.result.json" ]; then ok "result file written"; else bad "no result file after an early follower exit"; fi

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


  # diff, prove, land: a bare remote, a task worktree, a gate and a spec proof line. No model involved.
  ( set -e
    local_r="$tmp/landing"; mkdir -p "$local_r"; cd "$local_r"
    git init -q --bare remote.git
    git clone -q remote.git repo 2>/dev/null; cd repo
    git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init; git push -q origin HEAD:main 2>/dev/null
    git fetch -q origin; git checkout -q -B main origin/main
    mkdir -p docs/work/tasks
    printf -- '---\nid: P1\ntitle: Add greeting\n---\n## Acceptance\n- proof: `test -f greet.txt`\n' > docs/work/tasks/P1-greet.md
    git add -A; git -c user.email=t@t -c user.name=t commit -qm spec; git push -q origin HEAD:main
    git worktree add -q -b task/P1 ../repo-worktrees/P1 origin/main
    cd ../repo-worktrees/P1; echo hi > greet.txt; echo gen > view_templ.go
    git -c user.email=t@t -c user.name=t commit -qm "claim P1" --allow-empty
  ) >/dev/null 2>&1 && ok "landing fixture" || bad "landing fixture"
  local LR="$tmp/landing/repo" LW="$tmp/landing/repo-worktrees/P1"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  ( cd "$LR" && ORCHESTRA_BASE=origin/main "$W" diff P1 ) > "$tmp/out" 2>&1
  has "diff shows the changed file" "greet.txt"
  has "diff lists generated files in the stat" "view_templ.go"
  if grep -q '^+gen$' "$tmp/out"; then bad "diff hides generated content"; else ok "diff hides generated content"; fi
  expect_rc 1 "prove fails when the gate fails" env -C "$LR" ORCHESTRA_GATE=false "$W" prove P1
  has "a failing check shows FAIL" "FAIL"
  expect_rc 0 "prove passes" env -C "$LR" ORCHESTRA_GATE=true "$W" prove P1
  has "the spec proof line runs" "test -f greet.txt"
  expect_rc 0 "an unchanged tree reuses its proof" env -C "$LR" ORCHESTRA_GATE=true "$W" prove P1
  has "proven checks are not run again" "(proven)"
  echo more > "$LW/greet.txt"
  expect_rc 0 "a change invalidates the proof" env -C "$LR" ORCHESTRA_GATE=true "$W" prove P1
  hasnt "a changed tree is not reported as proven" "(proven)  test -f"
  expect_rc 0 "manual proof" env -C "$LR" "$W" prove P1 --manual "looked at it in a browser"
  expect_rc 2 "land refuses when a check fails" env -C "$LR" ORCHESTRA_GATE=false "$W" land P1
  expect_rc 0 "land" env -C "$LR" ORCHESTRA_GATE=true "$W" land P1
  git -C "$tmp/landing/remote.git" log -1 --format=%B main > "$tmp/out"
  has "landed as '<task>: <title>'" "P1: Add greeting"
  has "the commit carries a Proof trailer" "Proof: pass"
  has "the commit carries the manual proof" "Proof: manual: looked at it in a browser"
  if [ "$(git -C "$tmp/landing/remote.git" rev-list --count main)" = 3 ]; then ok "land squashes the claim commit away"; else bad "land did not squash (commits: $(git -C "$tmp/landing/remote.git" rev-list --count main))"; fi
  # A message written on the branch survives the squash (claim commits do not).
  ( cd "$LR" && git fetch -q origin && git worktree add -q -b task/P2 ../repo-worktrees/P2 origin/main && cd ../repo-worktrees/P2 &&
    git commit -qm "claim P2" --allow-empty && echo x > two.txt && git add -A && git commit -qm "P2: keep my words" -m "Body line." ) >/dev/null 2>&1
  expect_rc 0 "land keeps a written message" env -C "$LR" ORCHESTRA_GATE=true "$W" land P2
  git -C "$tmp/landing/remote.git" log -1 --format=%B main > "$tmp/out"
  has "the written subject is kept" "P2: keep my words"
  has "the written body is kept" "Body line."
  hasnt "no squash placeholder in the message" "squash P2"
  echo "---"; echo "$pass passed, $fail failed"
  [ "$fail" = 0 ]
}
main "$@"
