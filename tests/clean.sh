#!/usr/bin/env bash
# clean: list and remove only the worktrees of landed tasks. Offline: no model calls, no network.
# Fixture (a temp repo on main, worktrees under <repo>-worktrees/):
#   A landed   B squash-landed   C dirty   D open   E running   F landed with stale state
#   G untracked file   .scout/S1 scout   outside/H a worktree elsewhere (never listed)
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORKER="$ROOT/bin/orchestra-worker"
TMP=$(mktemp -d)
XDG=$(mktemp -d)
REPO="$TMP/repo"
WT="$TMP/repo-worktrees"
LIVE=""
cleanup() {
  if [ -n "$LIVE" ]; then kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null; fi
  rm -rf "$TMP" "$XDG"
}
trap cleanup EXIT

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
check() { # check <name> <condition...>
  local name=$1; shift
  if "$@"; then ok "$name"; else bad "$name"; fi
}
row_has() { # row_has <description> <task> <class> <action>
  if grep -qF -- "$2 $3 $4 " <<<"$(tr -s ' ' <<<"$OUT")"; then ok "$1"; else bad "$1: no '$2 $3 $4' row"; fi
}
row_hasnt() { # row_hasnt <description> <task> <class> <action>
  if grep -qF -- "$2 $3 $4 " <<<"$(tr -s ' ' <<<"$OUT")"; then bad "$1: found '$2 $3 $4'"; else ok "$1"; fi
}
exists()   { [ -d "$1" ]; }
is_gone()  { [ ! -e "$1" ]; }
branch_exists() { git -C "$REPO" show-ref --verify --quiet "refs/heads/$1"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
sleep 300 & LIVE=$!

build_fixture() (
  set -e
  git init -q -b main "$REPO"
  cd "$REPO"
  # orchestra writes these two lines when it runs a task in a worktree.
  printf '%s\n' '.orchestra/*' '!.orchestra/config.env' > .git/info/exclude
  echo base > base.txt
  git add base.txt
  git commit -qm init
  mkdir -p "$WT"

  # A: a commit that is then fast-forwarded into main.
  git worktree add -q -b A "$WT/A" main
  ( cd "$WT/A"; echo a > a.txt; git add a.txt; git commit -qm "A: work" )
  git merge -q --ff-only A

  # C: landed, then an uncommitted edit to a tracked file.
  git worktree add -q -b C "$WT/C" main
  ( cd "$WT/C"; echo c > c.txt; git add c.txt; git commit -qm "C: work" )
  git merge -q --ff-only C
  ( cd "$WT/C"; echo edit >> base.txt )

  # E: landed, with a live worker state file.
  git worktree add -q -b E "$WT/E" main
  ( cd "$WT/E"; echo e > e.txt; git add e.txt; git commit -qm "E: work" )
  git merge -q --ff-only E
  mkdir -p "$WT/E/.orchestra"
  printf '{"task": "E", "pid": %s}\n' "$LIVE" > "$WT/E/.orchestra/run.json"

  # F: landed, with a stale run state file and other .orchestra state.
  git worktree add -q -b F "$WT/F" main
  ( cd "$WT/F"; echo f > f.txt; git add f.txt; git commit -qm "F: work" )
  git merge -q --ff-only F
  mkdir -p "$WT/F/.orchestra"
  printf '{"task": "F", "pid": 999999}\n' > "$WT/F/.orchestra/run.json"
  echo spec > "$WT/F/.orchestra/spec.md"
  echo '{}' > "$WT/F/.orchestra/report.json"

  # G: landed, plus an untracked file outside .orchestra/.
  git worktree add -q -b G "$WT/G" main
  ( cd "$WT/G"; echo g > g.txt; git add g.txt; git commit -qm "G: work" )
  git merge -q --ff-only G
  echo notes > "$WT/G/notes.txt"

  # B: its own commit; main gets a different commit with a matching squash subject.
  git worktree add -q -b B "$WT/B" main
  ( cd "$WT/B"; echo b > b.txt; git add b.txt; git commit -qm "B: work in progress" )
  git commit -q --allow-empty -m "B: same work"

  # D: its own commit, nothing on main.
  git worktree add -q -b D "$WT/D" main
  ( cd "$WT/D"; echo d > d.txt; git add d.txt; git commit -qm "D: work" )

  # P: its own commit, cherry-picked onto main (an identical patch there): landed.
  git worktree add -q -b P "$WT/P" main
  ( cd "$WT/P"; echo p > p.txt; git add p.txt; git commit -qm "feat: p" )
  git cherry-pick "$(git -C "$WT/P" rev-parse HEAD)" >/dev/null

  # H: landed, but in another directory, so never a candidate.
  mkdir -p "$TMP/elsewhere"
  git worktree add -q -b H "$TMP/elsewhere/H" main
  ( cd "$TMP/elsewhere/H"; echo h > h.txt; git add h.txt; git commit -qm "H: work" )
  git merge -q --ff-only H

  # S1: a scout run (not a git worktree).
  mkdir -p "$WT/.scout/S1"
  echo '{}' > "$WT/.scout/S1/scout.json"
)

if ! build_fixture > "$TMP/fixture.log" 2>&1; then
  bad "fixture"
  sed 's/^/     /' "$TMP/fixture.log"
  printf 'clean: %d passed, %d failed\n' "$pass" "$fail"
  exit 1
fi
ok "fixture"

MAIN_HEAD=$(git -C "$REPO" rev-parse HEAD)
MAIN_STATUS=$(git -C "$REPO" status --porcelain --untracked-files=all)
BRANCHES_BEFORE=$(git -C "$REPO" for-each-ref --format='%(refname)' refs/heads)

run_clean() {
  ( cd "$REPO" && ORCHESTRA_BASE="${CLEAN_BASE:-main}" XDG_CONFIG_HOME="$XDG" "$WORKER" clean "$@" ) 2>&1
}

# 1. Listing only: the table, no changes.
OUT=$(run_clean); rc=$?
check "listing exits 0" [ "$rc" = 0 ]
if head -n1 <<<"$OUT" | grep -qE '^base: main [0-9a-f]+ \(as of the last fetch\)$'; then
  ok "base ref and short sha are the first line"
else bad "first line is not the base line: $(head -n1 <<<"$OUT")"; fi
row_has "A is landed and removable"          A  landed          remove
row_has "B is squash-landed but kept"        B  squash-landed  "keep (needs --include-squashed)"
row_has "C with an uncommitted edit is dirty" C dirty           keep
row_has "D with an unmerged commit is open"  D  open            keep
row_has "E with a live pid is running"       E  running         keep
row_has "F with a dead pid is landed"        F  landed          remove
row_has "G with an untracked file is dirty"  G  dirty           keep
row_has "S1 is a removable scout run"        S1 scout           remove
row_has "P cherry-picked onto main is landed" P landed          remove
if grep -qF "elsewhere/H" <<<"$OUT"; then bad "the outside worktree was listed"; else ok "the outside worktree is not listed"; fi
if grep -qF "4 to remove; run again with --yes to remove them" <<<"$OUT"; then
  ok "listing counts the removable entries"
else bad "listing summary missing or wrong: $(grep 'to remove' <<<"$OUT")"; fi
for t in A B C D E F G; do check "listing kept worktree $t" exists "$WT/$t"; done
check "listing kept scout S1" exists "$WT/.scout/S1"
check "listing kept the outside worktree" exists "$TMP/elsewhere/H"

# A listing with --include-squashed also changes nothing, but offers B.
OUT=$(run_clean --include-squashed); rc=$?
check "listing with --include-squashed exits 0" [ "$rc" = 0 ]
row_has "B becomes removable with --include-squashed" B squash-landed remove
if grep -qF "5 to remove; run again with --yes to remove them" <<<"$OUT"; then
  ok "--include-squashed listing counts B"
else bad "wrong --include-squashed listing summary"; fi
for t in A B C D E F G; do check "--include-squashed listing kept worktree $t" exists "$WT/$t"; done

# 2. --yes without --include-squashed: remove A, F and S1 only.
OUT=$(run_clean --yes); rc=$?
check "--yes exits 0" [ "$rc" = 0 ]
for t in A F P; do check "--yes removed worktree $t" is_gone "$WT/$t"; done
check "--yes removed scout S1" is_gone "$WT/.scout/S1"
for t in B C D E G; do check "--yes kept worktree $t" exists "$WT/$t"; done
check "--yes kept the outside worktree" exists "$TMP/elsewhere/H"
for t in A F S1; do
  if grep -qF "removed $t" <<<"$OUT"; then ok "--yes printed removed $t"; else bad "--yes did not print removed $t"; fi
done
if grep -qF "removed B" <<<"$OUT"; then bad "--yes removed B without --include-squashed"; else ok "--yes kept B"; fi

# 3. --yes --include-squashed: B is now squash-landed and goes.
OUT=$(run_clean --yes --include-squashed); rc=$?
check "--yes --include-squashed exits 0" [ "$rc" = 0 ]
check "--include-squashed removed B" is_gone "$WT/B"
for t in C D E G; do check "the squash run kept worktree $t" exists "$WT/$t"; done
check "the squash run kept the outside worktree" exists "$TMP/elsewhere/H"
if grep -qF "removed B" <<<"$OUT"; then ok "--include-squashed printed removed B"; else bad "--include-squashed did not remove B"; fi

# 4. Nothing that was not removable was touched, and no branch was deleted.
for b in A B C D E F G H P; do check "branch $b still exists" branch_exists "$b"; done
check "the branch list is unchanged" [ "$(git -C "$REPO" for-each-ref --format='%(refname)' refs/heads)" = "$BRANCHES_BEFORE" ]
check "the main checkout HEAD is unchanged" [ "$(git -C "$REPO" rev-parse HEAD)" = "$MAIN_HEAD" ]
check "the main checkout status is unchanged" [ "$(git -C "$REPO" status --porcelain --untracked-files=all)" = "$MAIN_STATUS" ]
check "the main checkout still has its files" [ -f "$REPO/base.txt" ]

# 5. Usage and repository errors.
mkdir -p "$TMP/notgit"
OUT=$( cd "$TMP/notgit" && ORCHESTRA_BASE=main XDG_CONFIG_HOME="$XDG" "$WORKER" clean 2>&1 ); rc=$?
check "clean outside a git repository exits 2" [ "$rc" = 2 ]
if grep -qi "git repository" <<<"$OUT"; then ok "clean explains it is not a git repository"; else bad "no repository error message: $OUT"; fi

OUT=$(python3 -I "$ROOT/lib/clean.py" --repo "$TMP/notgit" --worktrees "$TMP/notgit-worktrees" --base main 2>&1); rc=$?
check "lib clean rejects a non-repository repo with exit 2" [ "$rc" = 2 ]
if grep -q "not a git repository" <<<"$OUT"; then ok "lib clean names the non-repository"; else bad "lib clean gave no error: $OUT"; fi

OUT=$(CLEAN_BASE=no-such-base run_clean); rc=$?
check "an unresolvable base exits 2" [ "$rc" = 2 ]
if grep -q "base not resolvable" <<<"$OUT"; then ok "clean names the unresolvable base"; else bad "wrong base error: $OUT"; fi

EMPTY="$TMP/emptyrepo"
git init -q -b main "$EMPTY"
git -C "$EMPTY" commit -q --allow-empty -m init
OUT=$( cd "$EMPTY" && ORCHESTRA_BASE=main XDG_CONFIG_HOME="$XDG" "$WORKER" clean 2>&1 ); rc=$?
check "a missing worktree directory exits 0" [ "$rc" = 0 ]
if grep -qF "nothing to clean" <<<"$OUT"; then ok "a missing worktree directory says nothing to clean"; else bad "wrong empty answer: $OUT"; fi

printf 'clean: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
