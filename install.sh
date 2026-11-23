#!/usr/bin/env bash
# Install orchestra for the current user: links the CLI, the Claude Code skills and a starter config.
#   ./install.sh            install (idempotent; links point at this checkout, so `git pull` updates them)
#   ./install.sh --ops      also link the ops skills (ops-change, ops-incident)
#   ./install.sh --uninstall
set -euo pipefail

usage() {
  cat <<'EOF'
usage: ./install.sh [--ops] [--uninstall]
  --ops        also install the ops skills (ops-change and ops-incident)
  --uninstall  remove the CLI and skill links that point into this checkout; keep the config
EOF
}

main() {
  local here; here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
  local bin="$HOME/.local/bin" cfg="${XDG_CONFIG_HOME:-$HOME/.config}/orchestra" skills="$HOME/.claude/skills"
  local ops=0 uninstall=0 arg
  for arg in "$@"; do
    case "$arg" in
      --ops) ops=1 ;;
      --uninstall) uninstall=1 ;;
      *) usage >&2; exit 2 ;;
    esac
  done
  if [ "$uninstall" = 1 ]; then
    rm -f "$bin/orchestra-worker" "$bin/orchestra-task"
    local l; for l in "$skills"/*; do
      [ -L "$l" ] && case "$(readlink "$l")" in "$here"/skills/*) rm -f "$l" ;; esac
    done
    echo "removed the CLI and skill links; your config in $cfg is kept"
    return
  fi
  mkdir -p "$bin" "$cfg" "$skills"
  # Drop dangling links left by removed skills, but only when they point into this checkout.
  local target
  for l in "$skills"/*; do
    [ -L "$l" ] || continue
    target=$(readlink "$l")
    case "$target" in
      "$here"/skills/*) [ -e "$l" ] || rm -f "$l" ;;
    esac
  done
  ln -sfn "$here/bin/orchestra-worker" "$bin/orchestra-worker"
  ln -sfn "$here/bin/orchestra-task" "$bin/orchestra-task"
  local d name names=""
  local -a linked=()
  for d in "$here"/skills/claude-code/*/; do
    [ -d "$d" ] || continue
    name=${d%/}; name=${name##*/}
    case "$name" in
      ops-*) [ "$ops" = 1 ] || continue ;;
    esac
    ln -sfn "${d%/}" "$skills/$name"
    linked+=("$name")
  done
  for name in "${linked[@]}"; do names="$names $name"; done
  if [ ! -f "$cfg/config.env" ]; then
    cp "$here/config/config.example.env" "$cfg/config.env"
    echo "wrote $cfg/config.env: set ORCHESTRA_MODEL, ORCHESTRA_KEY_ENV and ORCHESTRA_KEY_CMD"
  fi
  local missing=""
  for c in git python3 timeout; do command -v "$c" >/dev/null || missing="$missing $c"; done
  command -v bwrap >/dev/null || missing="$missing bwrap(bubblewrap)"
  command -v pi >/dev/null || missing="$missing pi(harness)"
  [ -z "$missing" ] || echo "missing:$missing"
  case ":$PATH:" in *":$bin:"*) ;; *) echo "add $bin to your PATH" ;; esac
  cat <<EOF
installed:
  $bin/orchestra-worker -> $here/bin/orchestra-worker
  $bin/orchestra-task   -> $here/bin/orchestra-task
  Claude Code skills in $skills:$names
To make every Claude Code session use it, add to ~/.claude/CLAUDE.md:
  - Delegate mechanical coding work with the orchestra skill: I decide (design, rules, risky test cases) and review;
    workers (orchestra-worker) only implement settled specs. Never delegate judgment calls.
Other orchestrators: point their instruction file at $here/docs/orchestrator-guide.md
EOF
  if [ "$ops" = 0 ]; then
    echo 'ops skills not installed (./install.sh --ops adds ops-change and ops-incident)'
  fi
}
main "$@"
