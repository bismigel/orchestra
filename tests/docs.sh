#!/usr/bin/env bash
# tests/docs.sh: the docs must match the CLI. A doc or skill that names a command that does not exist, links to a
# missing file or uses a fragile relative path fails here. Offline, read-only.
set -uo pipefail

main() {
  local root; root=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)
  local W="$root/bin/orchestra-worker"
  local pass=0 fail=0 tmp; tmp=$(mktemp -d)
  # shellcheck disable=SC2064  # expanded now on purpose: tmp is out of scope when the trap runs
  trap "rm -rf $(printf '%q' "$tmp")" EXIT

  ok()  { pass=$((pass+1)); echo "ok   $*"; }
  bad() { fail=$((fail+1)); echo "FAIL $*"; }

  # The commands the CLI answers: the words before ")" in its `case "$cmd" in` block, split on "|".
  awk '/case "\$cmd" in/{f=1;next} f&&/^[[:space:]]*esac/{f=0} f' "$W" \
    | sed -E 's/^[[:space:]]*//; s/\).*$//' \
    | tr '|' '\n' \
    | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//; s/^"(.*)"$/\1/' \
    | grep -vE '^(-h|--help|help|\*|)$' \
    | sort -u > "$tmp/commands"
  if [ -s "$tmp/commands" ]; then
    ok "parsed $(wc -l < "$tmp/commands") commands from $W"
  else
    bad "parsed no commands from $W"
  fi

  echo "--- commands exist"
  # Files whose prose may name an orchestra-worker command: docs, prompts, skills and examples.
  local -a files=(README.md)
  local f
  while IFS= read -r f; do files+=("$f"); done < <(
    cd "$root" || exit 1
    find docs -maxdepth 1 -name '*.md' -print
    find prompts -name '*.md' -print
    find skills -name SKILL.md -print
    find examples -type f -print
  )
  local line word offenders
  for f in "${files[@]}"; do
    offenders=0
    while IFS=: read -r line word; do
      grep -qxF "$word" "$tmp/commands" && continue
      bad "$f:$line: unknown command $word"
      offenders=1
    done < <(grep -noE 'orchestra-worker[[:space:]]+[a-z][a-z-]*' "$root/$f" \
               | sed -E 's/orchestra-worker[[:space:]]+//')
    [ "$offenders" = 0 ] && ok "commands: $f"
  done

  echo "--- main skill covers the CLI"
  local cmd covered
  while IFS= read -r cmd; do
    case "$cmd" in summary|ps|docs|help) continue ;; esac
    covered=0
    for f in skills/claude-code/orchestra/SKILL.md README.md; do
      if grep -qE "orchestra-worker[[:space:]]+$cmd([[:space:]]|$|\`)" "$root/$f"; then covered=1; break; fi
    done
    if [ "$covered" = 1 ]; then ok "covered: $cmd"
    else bad "the orchestra skill and README never mention: orchestra-worker $cmd"; fi
  done < "$tmp/commands"

  echo "--- links resolve"
  local -a linkfiles=(README.md CONTRIBUTING.md)
  while IFS= read -r f; do linkfiles+=("$f"); done < <(cd "$root" || exit 1; find docs -name '*.md' -print)
  local link target dead
  for f in "${linkfiles[@]}"; do
    dead=0
    while IFS=: read -r line link; do
      link=${link#']('}; link=${link%')'}
      link=${link%%#*}
      link=${link%% *}
      [ -n "$link" ] || continue
      case "$link" in http://*|https://*|mailto:*|'#'*) continue ;; esac
      target="$root/$(dirname "$f")/$link"
      if [ ! -e "$target" ]; then
        bad "$f:$line: dead link $link"
        dead=1
      fi
    done < <(grep -noE '\]\([^)]+\)' "$root/$f")
    [ "$dead" = 0 ] && ok "links: $f"
  done

  echo "--- no fragile paths"
  local fragile=0
  while IFS= read -r f; do
    if grep -qF '../../../' "$f"; then
      bad "fragile path in ${f#"$root"/}: ../../../"
      fragile=1
    fi
  done < <(find "$root/skills" -name SKILL.md)
  [ "$fragile" = 0 ] && ok "no SKILL.md uses ../../../"

  echo "--- guide works"
  local name path rc
  for name in orchestrator planning ops security proofs design harness; do
    path=$("$W" guide "$name" 2>/dev/null); rc=$?
    if [ "$rc" = 0 ] && [ -f "$path" ]; then ok "guide $name prints an existing file"
    else bad "guide $name: rc $rc, '$path' is not an existing file"; fi
  done
  path=$("$W" guide templates 2>/dev/null); rc=$?
  if [ "$rc" = 0 ] && [ -d "$path" ]; then ok "guide templates prints an existing directory"
  else bad "guide templates: rc $rc, '$path' is not an existing directory"; fi
  "$W" guide frobnicate >/dev/null 2>&1; rc=$?
  if [ "$rc" = 2 ]; then ok "guide with an unknown name exits 2"
  else bad "guide frobnicate: rc $rc, want 2"; fi

  echo "docs: $pass passed, $fail failed"
  [ "$fail" = 0 ]
}

main "$@"
