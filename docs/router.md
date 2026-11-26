# Orchestra router (`orchestra/auto`) and thinking levels

The router is a Pi virtual model: you select one model, and it picks a **thinking level** per request. It never
changes the physical model. Switching models makes the next model read the whole context again at full price (prompt
caches are per model) and drops thinking blocks the other model cannot replay, so the model is fixed per profile and
only the thinking level moves. If you want a smarter model for planning, delegate that to a read-only run in its own
small context instead of swapping the session's model.

Extension: `examples/pi/orchestra-router.ts`. Enable it with `ORCHESTRA_ROUTER_EXT` (workers) or by linking it
into `~/.pi/agent/extensions/` (interactive pi).

## Profiles

Each profile is one virtual model under the `orchestra` provider, with exactly one physical model. Budgets
(`ORCHESTRA_ROUTER_SOFT_BUDGET`, `ORCHESTRA_ROUTER_HARD_BUDGET`, `ORCHESTRA_ROUTER_CTX_PRESSURE`) are shared: they are
session economics, not model-family properties.

| virtual model | model | use |
|---|---|---|
| `orchestra/auto` (alias of `ds-auto`) | `deepseek/deepseek-v4-pro` | interactive; legacy id |
| `orchestra/ds-auto` | `deepseek/deepseek-v4-pro` | interactive, DeepSeek |
| `orchestra/gemini-auto` | `antigravity/gemini-4-carbon` | interactive, Gemini |
| `orchestra/claude-auto` | `antigravity/claude-opus-5-5` | interactive, Claude |
| `orchestra/cb-auto` | `claude-bridge/claude-opus-5-5` | interactive, Claude Code subscription (pi-claude-bridge) |
| `orchestra/flash-auto` | `deepseek/deepseek-flash` | **workers**: the one cheap model |

Override a model with `ORCHESTRA_ROUTER_MODEL` (the `ds` profile) or `ORCHESTRA_ROUTER_<PROFILE>_MODEL` (the others).
The old `ORCHESTRA_ROUTER_STRONG` pin still works as an alias; `ORCHESTRA_ROUTER_FAST` is ignored.

### One router per physical model

Besides the named profiles, every reasoning chat model in your catalog gets its own router,
`orchestra/<provider>-<model>-auto` (the last segment of the model id), for example
`orchestra/claude-bridge-claude-sonnet-5-5-auto` or `orchestra/cloudflare-workers-ai-kimi-k2.7-code-auto`. Each one is
pinned to that model and uses the same frugal tiers, mapped onto the model's own thinking levels: `deep` is `medium`,
or `high` when the model has no `medium`. Models without reasoning get no router, because there is no thinking level to
route. When two short ids collide, both fall back to the full model id.

Pi has no catalog while extensions load. So the list is built at `session_start` from the available models (the
providers that have credentials) and cached in `$XDG_CACHE_HOME/orchestra/router-models.json` (override it with
`ORCHESTRA_ROUTER_CACHE`). The next start registers the cached list at load time, so `--model orchestra/<x>-auto`,
`pi --list-models` and resumed sessions find it. A session that cannot see a provider, such as a worker started with
`--no-extensions` or without that provider's key, unregisters that provider's routers for itself but leaves them in the
cache. `ORCHESTRA_ROUTER_PER_MODEL=0` turns per-model routers off. Env model pins
(`ORCHESTRA_ROUTER_<PROFILE>_MODEL`) apply only to the named profiles.

`flash-auto` exists because workers must stay on one cheap model (AGENTS.md: workers run on DeepSeek Flash). The post-run
`ORCHESTRA_ALLOWED_MODELS` guard still applies: any other physical model fails the run with exit 3.

## Thinking levels: frugal by default

Reasoning tokens cost money and mostly do not improve mechanical work, so the router spends them only where
they pay. The mapping is per profile (`tiers` in `PROFILE_DEFAULTS`):

| tier | ds / gemini / claude | flash (workers) |
|---|---|---|
| routine | `off` | `off` |
| standard | `low` | `low` |
| deep | `medium` (`high` only when the virtual level is explicitly `high`) | `high` |

`xhigh` is never emitted. `clampLevel()` maps a requested level onto the levels a profile's physical model
actually offers, never raising the request — Flash has no `medium` tier, so `medium` clamps to `low`.

Continuation turns keep the model and only walk the level: a failing tool result (`BLOCKING`, `RISK NOTES`, `FAIL`, a
non-zero exit) bumps to at least the deep level (the standard level when the turn started routine), and two
consecutive clean tool results step the level down one notch.

Spend and context only lower the level: past the soft budget or the context-pressure threshold a standard or routine
turn steps down one notch and a deep `high` turn is capped at `medium`; past the hard budget routine is `off` and
everything else is capped at `low`.

`direct` requests — compaction summaries and extension calls — run on the same model with thinking off.

## Benchmark: is `low` too low?

Four tasks, DeepSeek Flash, four thinking levels, each run with a self-correcting test loop (the agent writes
code, runs the tests, fixes until green). Cost is the sum of the run's response costs.

| task | off | low | medium | high |
|---|---|---|---|---|
| roman numerals (mechanical) | $0.0026 · 4 resp · pass | **$0.0024 · 3 · pass** | $0.0028 · 3 · pass | $0.0034 · 6 · pass |
| subtle bug fix, TTL store | $0.0012 · 4 · pass | $0.0018 · 5 · pass | $0.0018 · 5 · pass | **$0.0016 · 5 · pass** |
| intervals + Kadane + LRU | $0.0048 · 5 · pass | **$0.0035 · 3 · pass** | $0.0043 · 4 · pass | $0.0056 · 4 · pass |
| duration/IPv4 parser, edge cases | $0.0089 · 12 · pass | **$0.0057 · 5 · pass** | $0.0077 · 6 · pass | $0.0071 · 8 · pass |

Every level passed every task; the test loop self-corrects. Two findings:

- **`low` is the sweet spot for ordinary work** — cheapest on three of four tasks, fewest retries. This
  validates `standard → low`.
- **`off` can cost more than `low`** — on the edge-case parser it thrashed: zero reasoning, 12 responses,
  highest cost of the run. `off` only pays when the task is truly mechanical, which is why the router reserves
  it for routine prompts.

If a worker is ever seen thrashing on work that looked routine, the cheap fix is bumping `routine` from `off`
to `low` in the profile's `tiers` map.

### Reproduce

Each task needs only a directory, a prompt and (for the self-correcting loop) a test file the agent may run:

```sh
mkdir -p /tmp/rt/run-off && cd /tmp/rt/run-off
printf '%s\n' "Implement roman.py with int_to_roman/roman_to_int, then write test_roman.py and run it until green." > prompt.txt
for lvl in off low medium high; do
  cp prompt.txt "prompt.$lvl.txt"
  DEEPSEEK_API_KEY=$(agent-deepseek-key) pi -p --mode json \
    --model deepseek/deepseek-flash --thinking "$lvl" \
    --no-mcp --no-extensions --no-skills --no-approve "$(cat prompt.txt)" > "out.$lvl.json"
done
```

Sum `message.usage.cost.total` over `message_end` events for the cost, and count assistant `message_end`
events for the response count. The offline suite (`tests/router.sh`) covers the routing decisions themselves
and makes no model calls.

## Failure behaviour

- A model missing from the catalog (provider not loaded, no credentials) raises a setup error. There is no
  alternate model to fall back to.
- `retry` always keeps the failed request's model, including after a provider overload (429/503/529): pi backs off
  and retries the same route.
- `/router` prints the last route: profile, model, level, tier, reason, spend against the budgets, context
  percentage, cache hit rate and classifier.
