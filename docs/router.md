# Orchestra router (`orchestra/auto`) and thinking levels

The router is a Pi virtual model: you select one model, and it picks a physical model and thinking level per
request. It exists because the orchestrator's model is expensive and most worker turns are not.

Extension: `examples/pi/orchestra-router.ts`. Enable it with `ORCHESTRA_ROUTER_EXT` (workers) or by linking it
into `~/.pi/agent/extensions/` (interactive pi).

## Profiles

Each profile is one virtual model under the `orchestra` provider. Budgets (`ORCHESTRA_ROUTER_SOFT_BUDGET`,
`ORCHESTRA_ROUTER_HARD_BUDGET`, `ORCHESTRA_ROUTER_CTX_PRESSURE`) are shared: they are session economics, not
model-family properties.

| virtual model | strong | fast | use |
|---|---|---|---|
| `orchestra/auto` (alias of `ds-auto`) | `deepseek/deepseek-v4-pro` | `deepseek/deepseek-flash` | interactive; legacy id |
| `orchestra/ds-auto` | `deepseek/deepseek-v4-pro` | `deepseek/deepseek-flash` | interactive, DeepSeek |
| `orchestra/gemini-auto` | `antigravity/gemini-4-carbon` | `antigravity/gemini-4-hydrogen` | interactive, Gemini |
| `orchestra/claude-auto` | `antigravity/claude-opus-5-5` | `antigravity/claude-sonnet-5-5` | interactive, Claude |
| `orchestra/cb-auto` | `claude-bridge/claude-opus-5-5` | `claude-bridge/claude-sonnet-5-5` | interactive, Claude Code subscription (pi-claude-bridge) |
| `orchestra/flash-auto` | `deepseek/deepseek-flash` | `deepseek/deepseek-flash` | **workers**: one cheap model, thinking only |

Override the models with `ORCHESTRA_ROUTER_STRONG` / `ORCHESTRA_ROUTER_FAST` (the `ds` profile) or
`ORCHESTRA_ROUTER_<PROFILE>_STRONG` / `_FAST` (the others).

`flash-auto` exists because workers must stay on one cheap model (AGENTS.md: workers run on DeepSeek Flash).
Both its strong and fast slots point at Flash, so the *model* never changes and only *thinking* adjusts per turn.
The post-run `ORCHESTRA_ALLOWED_MODELS` guard still applies: any other physical model fails the run with exit 3.

## Thinking levels: frugal by default

Reasoning tokens cost money and mostly do not improve mechanical work, so the router spends them only where
they pay. The mapping is per profile (`tiers` in `PROFILE_DEFAULTS`):

| tier | ds / gemini / claude | flash (workers) |
|---|---|---|
| routine | fast `off` | `off` |
| standard | strong `low` | `low` |
| deep | strong `medium` (`high` only when the virtual level is explicitly `high`) | `high` |

`xhigh` is never emitted. `clampLevel()` maps a requested level onto the levels a profile's physical models
actually offer, never raising the request — Flash has no `medium` tier, so `medium` clamps to `low`.

Continuation turns stay sticky on the same model (prompt cache) and only walk the level: a failing tool result
(`BLOCKING`, `RISK NOTES`, `FAIL`, a non-zero exit) bumps to at least `medium` (strong) / `low` (fast), and two
consecutive clean tool results step the level down one notch.

`direct` requests — compaction summaries and extension calls — always run on the fast model with thinking off.

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

- A physical model missing from the catalog (provider not loaded, no credentials) fails over to the other model
  in the pair instead of failing the turn. Only when neither resolves does routing raise an error.
- `retry` after a provider overload (429/503/529) switches to the other model in the pair; any other error stays
  sticky so the prompt cache survives.
- `/router` prints the last route: profile, model, level, tier, reason, spend against the budgets, context
  percentage, cache hit rate, classifier, and any fallback taken.
