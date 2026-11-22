#!/usr/bin/env bash
# Install orchestra for the current user: links the CLI, the Claude Code skill and a starter config.
#   ./install.sh            install (idempotent; links point at this checkout, so `git pull` updates them)
#   ./install.sh --uninstall
set -euo pipefail
main() {
  local here; here=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
  local bin="$HOME/.local/bin" cfg="${XDG_CONFIG_HOME:-$HOME/.config}/orchestra" skills="$HOME/.claude/skills"
  if [ "${1:-}" = --uninstall ]; then
    rm -f "$bin/orchestra-worker"
    [ -L "$skills/orchestra" ] && rm -f "$skills/orchestra"
    echo "removed the CLI and skill links; your config in $cfg is kept"
    return
  fi
  mkdir -p "$bin" "$cfg" "$skills"
  ln -sfn "$here/bin/orchestra-worker" "$bin/orchestra-worker"
  ln -sfn "$here/skills/claude-code/orchestra" "$skills/orchestra"
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
  $skills/orchestra     -> $here/skills/claude-code/orchestra   (Claude Code skill: /orchestra)
To make every Claude Code session use it, add to ~/.claude/CLAUDE.md:
  - Delegate mechanical coding work with the orchestra skill: I decide (design, rules, risky test cases) and review;
    workers (orchestra-worker) only implement settled specs. Never delegate judgment calls.
Other orchestrators: point their instruction file at $here/docs/orchestrator-guide.md
EOF
}
main "$@"
