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

## Known gaps (contributions welcome)
- **Network is open** (`--share-net`) because the worker must reach its model API and package registries. A worker
  could exfiltrate the worktree's contents or its key. Planned: an optional allowlisting proxy.
- **No CPU/memory limits** beyond the wall-clock timeout. Use `systemd-run --user -p MemoryMax=…` around the
  command if needed.
- **macOS/Windows** have no bubblewrap. `ORCHESTRA_SANDBOX=none` (with `ORCHESTRA_ALLOW_UNSANDBOXED=1`) runs
  unsandboxed: only do that in a throwaway VM or container.
- `/etc` is mounted read-only in full; on most systems that is harmless, but check your `/etc` holds no secrets
  readable by your user.
- Never put real personal data, production dumps or secrets in a worktree a worker can read.

## Reporting a vulnerability
Open a private security advisory on the GitHub repository rather than a public issue.
