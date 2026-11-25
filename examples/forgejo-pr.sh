#!/usr/bin/env bash
# forgejo-pr.sh: open a pull request on a Forgejo instance (the ORCHESTRA_PR_CMD for a Forgejo base).
#
# Reads the variables land --pr provides: ORCHESTRA_PR_HEAD, ORCHESTRA_PR_BASE, ORCHESTRA_PR_TITLE and
# ORCHESTRA_PR_BODY (a file path). The host, owner and repository come from the `forgejo` (or `origin`) git remote,
# or from FORGEJO_URL / FORGEJO_REPO. The token comes from FORGEJO_TOKEN or ~/.config/git/credentials; it is handed
# to curl in a 0600 temp config and is never printed. Prints the pull request's html_url.
#
#   ORCHESTRA_PR_CMD='examples/forgejo-pr.sh'
#   FORGEJO_URL=https://git.example.com FORGEJO_REPO=team/repo FORGEJO_TOKEN=... examples/forgejo-pr.sh
set -euo pipefail

die() { echo "forgejo-pr: $*" >&2; exit 2; }

main() {
  local head=${ORCHESTRA_PR_HEAD:-} base=${ORCHESTRA_PR_BASE:-}
  local title=${ORCHESTRA_PR_TITLE:-} body=${ORCHESTRA_PR_BODY:-}
  [ -n "$head" ] || die "ORCHESTRA_PR_HEAD is not set (run via orchestra-worker land --pr)"
  [ -n "$base" ] || die "ORCHESTRA_PR_BASE is not set (run via orchestra-worker land --pr)"
  [ -n "$title" ] || die "ORCHESTRA_PR_TITLE is not set (run via orchestra-worker land --pr)"
  [ -z "$body" ] || [ -f "$body" ] || die "ORCHESTRA_PR_BODY is not a file: $body"

  local host="" owner="" repo="" url="" rest="" scheme="https"
  if [ -z "${FORGEJO_URL:-}" ] || [ -z "${FORGEJO_REPO:-}" ]; then
    local remote=${FORGEJO_REMOTE:-}
    if [ -z "$remote" ]; then
      if git remote get-url forgejo >/dev/null 2>&1; then remote=forgejo
      elif git remote get-url origin >/dev/null 2>&1; then remote=origin
      else die "no forgejo or origin remote: set FORGEJO_URL and FORGEJO_REPO"
      fi
    fi
    url=$(git remote get-url "$remote") || die "no such git remote: $remote"
    case "$url" in
      http://*)
        scheme=http
        rest=${url#http://}; host=${rest%%/*}; rest=${rest#*/}
        owner=${rest%%/*}; repo=${rest#*/} ;;
      https://*)
        scheme=https
        rest=${url#https://}; host=${rest%%/*}; rest=${rest#*/}
        owner=${rest%%/*}; repo=${rest#*/} ;;
      ssh://*)
        rest=${url#ssh://}; rest=${rest#*@}; host=${rest%%/*}; rest=${rest#*/}
        owner=${rest%%/*}; repo=${rest#*/} ;;
      *@*:*)
        rest=${url#*@}; host=${rest%%:*}; rest=${rest#*:}
        owner=${rest%%/*}; repo=${rest#*/} ;;
      *) die "cannot parse the $remote remote URL" ;;
    esac
    repo=${repo%.git}
    [ -n "$host" ] && [ -n "$owner" ] && [ -n "$repo" ] || die "cannot parse the $remote remote URL"
  fi

  local base_url
  if [ -n "${FORGEJO_URL:-}" ]; then
    base_url=${FORGEJO_URL%/}
    rest=${base_url#*://}
    host=${rest%%/*}
  else
    base_url="${scheme}://$host"
  fi
  if [ -n "${FORGEJO_REPO:-}" ]; then
    owner=${FORGEJO_REPO%%/*}; repo=${FORGEJO_REPO#*/}
    [ -n "$owner" ] && [ -n "$repo" ] && [ "$owner" != "$repo" ] || die "FORGEJO_REPO must be owner/repo"
  fi
  [ -n "$host" ] && [ -n "$owner" ] && [ -n "$repo" ] || die "cannot work out the Forgejo host and repository"

  local token=${FORGEJO_TOKEN:-}
  if [ -z "$token" ]; then
    local cred
    for cred in "${XDG_CONFIG_HOME:-$HOME/.config}/git/credentials" "$HOME/.config/git/credentials"; do
      [ -f "$cred" ] || continue
      token=$(python3 -I - "$cred" "$host" <<'PY'
import sys
from urllib.parse import unquote, urlsplit
path, want = sys.argv[1:]
want_lo = want.lower()
want_host = want_lo.split(":", 1)[0]
with open(path, encoding="utf-8", errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            parts = urlsplit(line)
        except ValueError:
            continue
        netloc = unquote(parts.netloc.rsplit("@", 1)[-1]).lower()
        h = (parts.hostname or "").lower()
        if netloc != want_lo and h != want_host:
            continue
        token = unquote(parts.password or parts.username or "")
        if token:
            print(token)
            break
PY
)
      [ -z "$token" ] || break
    done
  fi
  [ -n "$token" ] || die "no token: set FORGEJO_TOKEN or add a credential for $host to ~/.config/git/credentials"
  if [[ $token == *$'\n'* || $token == *$'\r'* || $token == *'"'* || $token == *'\\'* ]]; then
    die "the token contains characters that cannot go in a curl config"
  fi

  local tmp; tmp=$(mktemp -d)
  # shellcheck disable=SC2064  # expanded now on purpose: tmp is out of scope when the trap runs
  trap "rm -rf $(printf '%q' "$tmp")" EXIT
  umask 077
  local curl_cfg="$tmp/curl.cfg" payload="$tmp/payload.json" response="$tmp/response.json"
  printf 'header = "Authorization: token %s"\n' "$token" > "$curl_cfg"
  chmod 600 "$curl_cfg"
  python3 -I - "$title" "$head" "$base" "$body" > "$payload" <<'PY'
import json, sys
title, head, base, body = sys.argv[1:]
text = ""
if body:
    with open(body, encoding="utf-8") as f:
        text = f.read()
print(json.dumps({"title": title, "head": head, "base": base, "body": text}))
PY
  chmod 600 "$payload"

  local api="$base_url/api/v1/repos/$owner/$repo/pulls"
  if ! curl -sS --config "$curl_cfg" -H 'Content-Type: application/json' \
       --data-binary "@$payload" "$api" > "$response"; then
    die "Forgejo request to $api failed"
  fi
  python3 -I - "$response" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        data = json.load(f)
except (OSError, ValueError) as e:
    sys.exit(f"forgejo-pr: response is not JSON: {e}")
if not isinstance(data, dict) or not data.get("html_url"):
    message = data.get("message") if isinstance(data, dict) else None
    sys.exit("forgejo-pr: no html_url in the response" + (f": {message}" if message else ""))
print(data["html_url"])
PY
}

main "$@"
