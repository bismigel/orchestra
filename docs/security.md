# Security model

Workers run code written by a model you did not review yet, with a shell. Treat each worker as an untrusted
contractor with a laptop: it gets the task's files and nothing else.

## What the sandbox gives the worker (Linux, bubblewrap)
| Path | Access |
|---|---|
| the task's worktree | read-write |
| the worktree's git admin dir (`.git/worktrees/<task>`) | read-write (index, HEAD) |
| the repository's shared git dir (objects, refs) | read-only, so the worker cannot commit or rewrite history |
| `/usr`, `/bin`, `/lib*`, `/etc`, `/nix`, `/opt` | read-only |
| a scratch home (`<worktree>/.orchestra/home`) | read-write |
| `ORCHESTRA_RO_BINDS` / `ORCHESTRA_RW_BINDS` | as you configure (keep to caches) |
| everything else in your home (ssh keys, cloud config, password stores, other repositories) | **not visible** |

The environment is cleared (`--clearenv`); only `HOME`, `USER`, `LANG`, `TERM`, `PATH`, the dev-env exports and the
one API key variable exist inside.

## The API key
- Fetched outside the sandbox by `ORCHESTRA_KEY_CMD` (or read from your environment).
- Passed on file descriptor 9, read into the named variable by a tiny inner shell, and fd 9 is closed before the
  harness starts. It never appears in a process's command line and is never written to disk by orchestra.
- The harness itself holds the key in its environment, so the worker's model could ask the shell to print it. Use a
  **dedicated key with a spend limit** for workers, never your main key.

## Network: open by default, or an allowlist
By default the sandbox shares the host network (`--share-net`), because the worker must reach its model API and
package registries. A worker could then send the worktree's contents or its key anywhere.

Set `ORCHESTRA_EGRESS_ALLOW` to confine it:
```sh
ORCHESTRA_EGRESS_ALLOW='api.deepseek.com proxy.golang.org sum.golang.org'
```
- The sandbox gets its **own network namespace with only loopback**: no route out, no DNS.
- Its one way out is a unix socket to **orchestra's egress proxy, running outside the sandbox**
  (`lib/egress_proxy.py`). The proxy accepts only `CONNECT host:port` to listed hosts (port 443 unless the entry
  names one; `*.example.com` for subdomains; IP addresses only when listed literally) and refuses everything else,
  including plain HTTP. The policy lives outside, so nothing the worker does inside can widen it.
- Inside, a forwarder on `127.0.0.1:3128` relays to that socket and `HTTPS_PROXY`/`HTTP_PROXY` (and
  `NODE_USE_ENV_PROXY=1` for Node) point at it. Tools that ignore proxy variables simply cannot connect: the run
  fails closed, it never falls back to an open network.
- Every attempt is logged to `runs/run-N.egress.log` (time, allow/deny, host:port; never content), and the finish
  card counts them: `egress    12 allowed · 1 host(s) denied: pastebin.com`.
- Needs `ORCHESTRA_SANDBOX=bwrap`; a bad allowlist entry stops the run before it starts.
- List the model API host first, then only what the task needs (module proxies, registries). An allowed host can
  still receive data: the allowlist bounds where data can go, not what is sent there.

## Known gaps (contributions welcome)
- **Network is open unless `ORCHESTRA_EGRESS_ALLOW` is set** (above).
- **No CPU/memory limits** beyond the wall-clock timeout. Use `systemd-run --user -p MemoryMax=…` around the
  command if needed.
- **macOS/Windows** have no bubblewrap. `ORCHESTRA_SANDBOX=none` (with `ORCHESTRA_ALLOW_UNSANDBOXED=1`) runs
  unsandboxed: only do that in a throwaway VM or container.
- `/etc` is mounted read-only in full; on most systems that is harmless, but check your `/etc` holds no secrets
  readable by your user.
- Never put real personal data, production dumps or secrets in a worktree a worker can read.

## Reporting a vulnerability
Open a private security advisory on the GitHub repository rather than a public issue.
