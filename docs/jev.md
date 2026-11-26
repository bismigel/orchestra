# Jev: an advisory second opinion

Jev is a *classifier* model (TypeSafe, served by Cloudflare Workers AI and others). It does not chat: it answers typed
questions about JSON state (pick one label, or yes/no) and returns a probability for each answer. orchestra uses it
for three decisions, so the orchestrator spends its own judgment where Jev is unsure or disagrees.

**It can only ask you to look harder. It never approves, lands or skips anything.** Off by default.

## The three decisions

| kind | when | question | Jev flags when |
|---|---|---|---|
| `split` | `run <id> --spec` (spec files only, not `--prompt`) | worker, split or orchestrator? | the spec says `worker` but P(worker) is under 0.8 |
| `ready` | `run <id> --spec` | five yes/no checks: decisions written, risky tests listed, paths named, a proof command, out of scope | the spec says ready (or has no status) and a check is under 0.5 |
| `triage` | `review <id>` (text screen only) | clean, look or block, from the review digest | Jev's verdict is above what the facts already say |

The questions are in `config/decisions.json`. A repository can replace the file with `.orchestra/decisions.json`.
`triage` has a deterministic floor from the review facts (no valid report, failed proof, open questions, files outside
the spec = `block`; risk notes, assumptions, proofs not run = `look`). The shown verdict is the higher of the floor and
Jev's, so a confident "clean" from Jev never lowers it. A spec that already says `split` or `draft` is never flagged
for being cautious: Jev asking for *less* scrutiny is logged and nothing more.

## Modes (`ORCHESTRA_JEV`)

| mode | calls Jev | prints | use |
|---|---|---|---|
| `off` (default) | no, ever | nothing | `decide split|ready|triage` exits 2 and says how to turn it on |
| `shadow` | in `run` and `review` | nothing | collect Jev's answers next to your decisions; changes no behaviour |
| `advise` | in `run` and `review` | one line, only for a flag | the same, plus the flag in front of you |

Turn it off again by unsetting it, or `ORCHESTRA_JEV=off`. A failure (no credentials, network, a bad answer) is logged,
printed as `unavailable: <why>` where the verdict would be, and **never changes an exit code**.

## Setup (Cloudflare Workers AI)

1. In the Cloudflare dashboard create an API token whose only permission is **Workers AI** (account level). Do not reuse
   a DNS, tunnel or Access token: this one needs to run a model and nothing else, so a leak costs a few cents.
2. Store it in your secret manager, and put its account id (not a secret) and a command that prints the token in
   `~/.config/orchestra/config.env`:

```sh
ORCHESTRA_JEV=shadow
ORCHESTRA_JEV_ACCOUNT_ID=<cloudflare account id>
ORCHESTRA_JEV_KEY_CMD='agent-jev-key'     # prints the token; never put the token itself in a config file
# Optional: ORCHESTRA_JEV_MODEL (default typesafe/jev), ORCHESTRA_JEV_URL, ORCHESTRA_JEV_TIMEOUT (default 20 s)
# ORCHESTRA_JEV_REDACT='[A-Za-z0-9.-]*example\.com'   # extra pattern to remove from what Jev sees
```

3. `orchestra-worker doctor` reports the mode (it does not run the key command), and
   `orchestra-worker decide split <id> --spec <file>` asks once by hand.

The endpoint is `POST https://api.cloudflare.com/client/v4/accounts/<account>/ai/run` with `{model, input: {state,
questions}}`. A local server that speaks the same body works too: point `ORCHESTRA_JEV_URL` at it.

## What leaves the machine

Only a whitelist, redacted and capped. `split` and `ready` send the spec text (12,000 characters at most). `triage`
sends counts and short strings from the review digest: status, summary, open questions, assumptions, risk notes, the
files outside the spec, check and proof counts, diff counts. **Never** the diff, the key, or the config.

Redaction removes private keys, bearer tokens, `token|secret|password|api_key = value` assignments, any 32+ character
token that mixes letters and digits, private IPv4 addresses, emails, `*.internal|lan|local|home.arpa` host names, and
whatever `ORCHESTRA_JEV_REDACT` matches. It is conservative, not a guarantee: a spec is data about your own
infrastructure, so keep it in mind before turning this on for a repository that should not talk to a third party. A
worker's report is untrusted text, and small classifiers can follow instructions written inside their state. That is why
Jev can raise attention and never lower it.

## Compare it with your own calls

Every call is one line in `<git dir>/orchestra/decisions.jsonl` (answers, probabilities, a hash of what was sent, never
the token). For `split` your call is the spec's `delegation:` line and for `ready` its `status:` line; for `triage`, and
to overrule the others, record yours:

```sh
orchestra-worker decide mark T12 triage look
orchestra-worker decide report          # per kind: agree, disagree, without your call; and every difference
```

Turn a flag into a gate only for a kind where, over a few dozen tasks, Jev agreed with you and its probabilities meant
what they said. There is deliberately no `enforce` mode: tuning thresholds from this log is a judgment call.
