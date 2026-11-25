#!/usr/bin/env bash
# install.sh tests: offline, never touches the real home. Run from anywhere: tests/install.sh
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

OUT=""; RC=0
run_install() {
  local home=$1 xdg=$2; shift 2
  if OUT=$(HOME="$home" XDG_CONFIG_HOME="$xdg" bash "$ROOT/install.sh" "$@" 2>&1); then
    RC=0
  else
    RC=$?
  fi
}

new_home() {
  local d="$TMP/$1"
  mkdir -p "$d/home" "$d/xdg"
  printf '%s\n' "$d"
}

case_dir() {
  new_home "$1"
}

# Default install: exactly the three non-ops skills, no ops skills, and the explanatory line.
D=$(case_dir default); run_install "$D/home" "$D/xdg"
S="$D/home/.claude/skills"
if [ "$RC" = 0 ]; then ok "default install succeeds"; else bad "default install failed (rc $RC): $OUT"; fi
got=$(find "$S" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')
if [ "$got" = "orchestra orchestra-land orchestra-plan orchestra-refine " ]; then
  ok "default links exactly orchestra, orchestra-plan, orchestra-refine"
else
  bad "default links are: $got"
fi
if grep -qF 'ops skills not installed (./install.sh --ops adds ops-change and ops-incident)' <<<"$OUT"; then
  ok "default install says how to add the ops skills"
else
  bad "default install lacks the ops-skills line"
fi

# --ops: adds ops-change and ops-incident on top of the defaults.
D=$(case_dir with-ops); run_install "$D/home" "$D/xdg" --ops
S="$D/home/.claude/skills"
if [ "$RC" = 0 ]; then ok "--ops install succeeds"; else bad "--ops install failed (rc $RC): $OUT"; fi
got=$(find "$S" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort | tr '\n' ' ')
if [ "$got" = "ops-change ops-incident orchestra orchestra-land orchestra-plan orchestra-refine " ]; then
  ok "--ops adds ops-change and ops-incident"
else
  bad "--ops links are: $got"
fi
if [ -L "$S/ops-change" ] && [ "$(readlink -f "$S/ops-change")" = "$ROOT/skills/claude-code/ops-change" ]; then
  ok "ops-change points at this checkout"
else
  bad "ops-change link is wrong"
fi
if grep -qF 'ops skills not installed' <<<"$OUT"; then bad "--ops still says ops skills are not installed"; else ok "--ops does not print the not-installed line"; fi

# A dangling link into this checkout (a deleted skill) is removed.
D=$(case_dir dangling); mkdir -p "$D/home/.claude/skills"
S="$D/home/.claude/skills"
[ ! -e "$ROOT/skills/claude-code/ops-review" ] || bad "fixture for deleted ops-review unexpectedly exists"
ln -s "$ROOT/skills/claude-code/ops-review" "$S/ops-review"
run_install "$D/home" "$D/xdg"
if [ ! -L "$S/ops-review" ] && [ ! -e "$S/ops-review" ]; then
  ok "dangling link into this checkout is removed"
else
  bad "dangling ops-review link was kept"
fi

# Links elsewhere and real directories are left alone.
D=$(case_dir foreign); mkdir -p "$D/home/.claude/skills" "$D/outside" "$D/home/.claude/skills/local-skill"
S="$D/home/.claude/skills"
echo keep > "$D/outside/SKILL.md"
echo keep > "$S/local-skill/SKILL.md"
ln -s "$D/outside" "$S/other-skill"
run_install "$D/home" "$D/xdg"
if [ -L "$S/other-skill" ] && [ "$(readlink "$S/other-skill")" = "$D/outside" ]; then
  ok "a link to another location is left alone"
else
  bad "a link to another location was removed or changed"
fi
if [ -d "$S/local-skill" ] && [ -f "$S/local-skill/SKILL.md" ]; then
  ok "a real directory in the skills dir is left alone"
else
  bad "a real directory in the skills dir was removed"
fi

# An existing ops link survives a later install without --ops.
D=$(case_dir keep-ops); run_install "$D/home" "$D/xdg" --ops
S="$D/home/.claude/skills"
run_install "$D/home" "$D/xdg"
if [ -L "$S/ops-change" ] && [ "$(readlink -f "$S/ops-change")" = "$ROOT/skills/claude-code/ops-change" ]; then
  ok "an existing ops-change link survives an install without --ops"
else
  bad "an existing ops-change link was removed by an install without --ops"
fi
if [ -L "$S/ops-incident" ]; then
  ok "an existing ops-incident link survives an install without --ops"
else
  bad "an existing ops-incident link was removed by an install without --ops"
fi

# --uninstall removes links into this checkout and keeps the config.
D=$(case_dir uninstall); run_install "$D/home" "$D/xdg" --ops
S="$D/home/.claude/skills"
CFG="$D/xdg/orchestra/config.env"
mkdir -p "$D/outside"; echo keep > "$D/outside/SKILL.md"; ln -s "$D/outside" "$S/other-skill"
echo 'kept-marker' >> "$CFG"
run_install "$D/home" "$D/xdg" --uninstall
if [ "$RC" = 0 ]; then ok "--uninstall succeeds"; else bad "--uninstall failed (rc $RC): $OUT"; fi
if [ -f "$CFG" ] && grep -q 'kept-marker' "$CFG"; then ok "--uninstall keeps the config"; else bad "--uninstall removed or changed the config"; fi
left=0
for l in "$S"/*; do
  [ -L "$l" ] || continue
  case "$(readlink "$l")" in "$ROOT"/skills/*) left=1 ;; esac
done
if [ "$left" = 0 ]; then ok "--uninstall removes links into this checkout"; else bad "--uninstall left links into this checkout"; fi
if [ -L "$S/other-skill" ]; then ok "--uninstall keeps a link pointing elsewhere"; else bad "--uninstall removed a link pointing elsewhere"; fi
if [ ! -e "$D/home/.local/bin/orchestra-worker" ]; then ok "--uninstall removes the CLI link"; else bad "--uninstall kept the CLI link"; fi

# An unknown flag prints usage and exits 2.
D=$(case_dir bad-flag); run_install "$D/home" "$D/xdg" --ops --bogus
if [ "$RC" = 2 ]; then ok "an unknown flag exits 2"; else bad "unknown flag exited $RC, want 2"; fi
if grep -q 'usage:' <<<"$OUT"; then ok "an unknown flag prints usage"; else bad "unknown flag did not print usage: $OUT"; fi

printf 'install: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
