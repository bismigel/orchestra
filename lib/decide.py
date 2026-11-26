#!/usr/bin/env python3
"""orchestra decide: Jev, a classifier model, as an advisory second opinion on three decisions.

Jev does not chat. It answers typed questions about JSON state (choice, bool) with probabilities. orchestra asks it
three things (questions live in config/decisions.json): `split` (worker, split or orchestrator?), `ready` (is the
spec ready?) and `triage` (clean, look or block?). It only ever *flags*: it can ask the orchestrator to look
harder, never to look less. `triage` also has a deterministic floor from the review facts, and the effective
verdict is the higher of the floor and Jev's.

  decide.py run    --kind split|ready|triage --task T --log FILE --decisions FILE
                   (--spec FILE | --review-json FILE) [--print always|flags|never] [--mode shadow|advise]
  decide.py mark   --log FILE --task T --kind K --value V     record the orchestrator's own call
  decide.py report --log FILE [--json]                        Jev against the orchestrator's calls

Configuration comes from the environment (set by orchestra-worker from config.env):
  ORCHESTRA_JEV_ACCOUNT_ID  Cloudflare account id           ORCHESTRA_JEV_MODEL    default typesafe/jev
  ORCHESTRA_JEV_KEY_CMD     prints the API token            ORCHESTRA_JEV_URL      default Cloudflare Workers AI
  ORCHESTRA_JEV_TIMEOUT     seconds, default 20             ORCHESTRA_JEV_REDACT   extra regex (or-ed) to redact

The token is read from the command's output into memory and sent as a bearer header: never logged or printed. State
sent to the model is built from a whitelist of fields and redacted (secrets, long tokens, private IPs, emails, and
ORCHESTRA_JEV_REDACT) and capped in size. Any failure (no credentials, network, bad answer) is logged and reported
as "unavailable"; it never changes an exit code. Offline: the tests use a fake endpoint.
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

LEVEL = {"clean": 0, "look": 1, "block": 2}
NAME = {v: k for k, v in LEVEL.items()}
SPEC_CAP = 12000
DEFAULT_MODEL = "typesafe/jev"
DEFAULT_URL = "https://api.cloudflare.com/client/v4/accounts/{account}/ai/run"

PEM = re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", re.S)
BEARER = re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{16,}")
SECRET_ASSIGN = re.compile(
    r"(?i)\b([A-Za-z0-9_]*(?:token|secret|passw(?:or)?d|api[_-]?key|access[_-]?key|private[_-]?key)[A-Za-z0-9_]*)"
    r"(\s*[:=]\s*)(\S+)")
LONG_TOKEN = re.compile(r"\b[A-Za-z0-9_\-]{32,}\b")
PRIVATE_IP = re.compile(r"\b(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b")
EMAIL = re.compile(r"\b[\w.+-]+@[\w-]+(?:\.[\w-]+)+\b")
INTERNAL_HOST = re.compile(r"\b[\w.-]+\.(?:internal|lan|local|home\.arpa)\b")


def fail(message):
    print(f"decide: {message}", file=sys.stderr)
    return 2


def redact(text, extra=""):
    """Remove what must not leave the machine. Conservative: it may over-redact, never under-redact on purpose."""
    text = str(text)
    text = PEM.sub("[redacted key]", text)
    text = BEARER.sub("Bearer [redacted]", text)
    text = SECRET_ASSIGN.sub(lambda m: f"{m.group(1)}{m.group(2)}[redacted]", text)
    text = LONG_TOKEN.sub(lambda m: "[redacted]" if re.search(r"\d", m.group(0)) and re.search(r"[A-Za-z]", m.group(0))
                          else m.group(0), text)
    text = PRIVATE_IP.sub("[ip]", text)
    text = EMAIL.sub("[email]", text)
    text = INTERNAL_HOST.sub("[host]", text)
    if extra:
        try:
            text = re.sub(extra, "[redacted]", text)
        except re.error:
            raise SystemExit(fail("ORCHESTRA_JEV_REDACT is not a valid regular expression"))
    return text


def clip(text, limit):
    text = str(text)
    return text if len(text) <= limit else text[:limit] + " [truncated]"


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def front_matter(text):
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    fm = {}
    if m:
        for line in m.group(1).splitlines():
            line = re.sub(r"\s+#.*$", "", line)
            if ":" in line:
                k, v = line.split(":", 1)
                fm[k.strip()] = v.strip()
    return fm


# ---- the state each decision sends -------------------------------------------------------------------------------

def spec_state(path, extra):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        raise SystemExit(fail(f"cannot read the spec: {e}"))
    return {"spec": clip(redact(text, extra), SPEC_CAP)}, front_matter(text)


def triage_facts(review):
    """A whitelist of the review digest: counts and short strings, never the diff or the spec."""
    proofs = (review.get("proofs") or {}).get("checks") or []
    states = [p.get("state") for p in proofs if isinstance(p, dict)]
    checks = review.get("worker_checks") or {}
    acceptance = review.get("acceptance") or {}
    paths = review.get("paths") or {}
    diff = review.get("diff") or {}
    run = review.get("run") or {}
    return {
        "report_valid": bool(review.get("report_valid")),
        "status": review.get("status"),
        "summary": review.get("summary"),
        "run_exit": run.get("exit") if run else None,
        "open_questions": review.get("blocking") or [],
        "assumptions": review.get("assumed") or [],
        "out_of_scope_needed": review.get("outside_scope_needed") or [],
        "risk_notes": review.get("risk_notes") or [],
        "files_outside_the_spec": (paths.get("outside") or [])[:20],
        "paths_checked": bool(paths.get("checked")),
        "worker_checks": {"pass": checks.get("pass", 0), "fail": checks.get("fail", 0)} if checks else None,
        "acceptance_unmet": acceptance.get("unmet") or [] if acceptance else None,
        "proofs": {"pass": states.count("pass"), "fail": states.count("fail"), "not_run": states.count("not run")},
        "diff": {"files": diff.get("files", 0), "added": diff.get("added", 0), "removed": diff.get("removed", 0)},
    }


def redact_deep(value, extra):
    if isinstance(value, str):
        return clip(redact(value, extra), 600)
    if isinstance(value, list):
        return [redact_deep(v, extra) for v in value]
    if isinstance(value, dict):
        return {k: redact_deep(v, extra) for k, v in value.items()}
    return value


def triage_floor(facts):
    """The deterministic minimum attention, from facts alone. Jev can only raise it."""
    block, look = [], []
    if not facts["report_valid"]:
        block.append("no valid report")
    if facts["status"] not in (None, "done"):
        block.append(f"status {facts['status']}")
    if facts["run_exit"] not in (None, 0):
        block.append(f"run exit {facts['run_exit']}")
    if facts["open_questions"]:
        block.append("open questions")
    if facts["proofs"]["fail"]:
        block.append("a proof failed")
    if (facts["worker_checks"] or {}).get("fail"):
        block.append("a worker check failed")
    if facts["files_outside_the_spec"]:
        block.append("files outside the spec")
    if facts["out_of_scope_needed"]:
        look.append("out-of-scope work needed")
    if facts["risk_notes"]:
        look.append("risk notes")
    if facts["assumptions"]:
        look.append("assumptions")
    if facts["proofs"]["not_run"]:
        look.append("proofs not run")
    if facts["acceptance_unmet"]:
        look.append("acceptance unmet")
    if block:
        return "block", block + look
    return ("look", look) if look else ("clean", [])


# ---- the call ----------------------------------------------------------------------------------------------------

def wire_questions(questions):
    return {k: ({**q, "type": "noul"} if q["type"] == "bool" else q) for k, q in questions.items()}


def api_key(cmd):
    if not cmd:
        raise RuntimeError("ORCHESTRA_JEV_KEY_CMD is not set")
    try:
        done = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        raise RuntimeError("ORCHESTRA_JEV_KEY_CMD failed to run")
    key = done.stdout.strip()
    if done.returncode != 0 or not key:
        raise RuntimeError(f"ORCHESTRA_JEV_KEY_CMD gave no key (exit {done.returncode})")
    return key


def classify(env, state, questions):
    """One Workers AI call. Returns (answers, usage) or raises RuntimeError with a message safe to print."""
    account = env.get("ORCHESTRA_JEV_ACCOUNT_ID", "")
    url = env.get("ORCHESTRA_JEV_URL") or DEFAULT_URL
    if "{account}" in url:
        if not account:
            raise RuntimeError("ORCHESTRA_JEV_ACCOUNT_ID is not set")
        url = url.replace("{account}", account)
    key = api_key(env.get("ORCHESTRA_JEV_KEY_CMD", ""))
    body = json.dumps({"model": env.get("ORCHESTRA_JEV_MODEL") or DEFAULT_MODEL,
                       "input": {"state": state, "questions": wire_questions(questions)}}).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Authorization": f"Bearer {key}", "Content-Type": "application/json", "User-Agent": "orchestra-worker"})
    try:
        timeout = float(env.get("ORCHESTRA_JEV_TIMEOUT") or 20)
    except ValueError:
        timeout = 20.0
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code} from the classifier endpoint")
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise RuntimeError(f"classifier endpoint unreachable or unreadable ({type(e).__name__})")
    if not isinstance(payload, dict) or payload.get("success") is False:
        errors = payload.get("errors") if isinstance(payload, dict) else None
        msgs = [str(e.get("message")) for e in errors if isinstance(e, dict)] if isinstance(errors, list) else []
        raise RuntimeError("classifier error: " + ("; ".join(msgs)[:200] or "request failed"))
    result = payload.get("result")
    if isinstance(result, dict) and "answers" not in result and isinstance(result.get("result"), dict):
        if result.get("state") != "Completed":
            raise RuntimeError(f"classifier run did not complete (state: {result.get('state')})")
        result = result["result"]
    if not isinstance(result, dict) or not isinstance(result.get("answers"), dict):
        raise RuntimeError("classifier returned an unexpected response")
    answers = {}
    for qid, q in questions.items():
        a = result["answers"].get(qid)
        try:
            if q["type"] == "choice":
                answers[qid] = {"choice": str(a["choice"]),
                                "probabilities": {str(k): float(v) for k, v in a["probabilities"].items()},
                                "confidence": float(a.get("confidence", 0.0))}
            else:
                answers[qid] = {"p": float(a["noul"])}
        except (TypeError, KeyError, ValueError, AttributeError):
            raise RuntimeError(f"classifier gave no usable answer for {qid}")
    return answers, result.get("usage")


# ---- judging -----------------------------------------------------------------------------------------------------

def judge_split(answers, kind_cfg, front):
    probs = answers["route"]["probabilities"]
    p_worker = probs.get("worker", 0.0)
    if p_worker >= kind_cfg.get("min_confidence", 0.8):
        rec = "worker"
    else:
        rec = "orchestrator" if probs.get("orchestrator", 0.0) > probs.get("split", 0.0) else "split"
    human = front.get("delegation") or None
    flag = None
    if rec != "worker" and human in (None, "worker"):
        flag = f"split? P(worker)={p_worker:.2f}, Jev says {rec}" + (f" (spec says {human})" if human else "")
    line = f"{rec} (P(worker)={p_worker:.2f})" + (f"; spec says {human}" if human else "")
    return {"effective": rec, "human": human, "flag": flag, "line": line}


def judge_ready(answers, kind_cfg, front):
    floor = kind_cfg.get("min_probability", 0.5)
    ps = {q: a["p"] for q, a in answers.items()}
    missing = sorted(q for q, p in ps.items() if p < floor)
    status = front.get("status") or None
    human = None if status is None else ("ready" if status in ("ready", "done") else "draft")
    eff = "not-ready" if missing else "ready"
    flag = None
    if missing and human != "draft":
        flag = "spec may not be ready: " + ", ".join(f"{q} (P={ps[q]:.2f})" for q in missing)
    line = eff + " · " + " ".join(f"{q}={p:.2f}" for q, p in ps.items()) + (f"; spec status {status}" if status else "")
    return {"effective": eff, "human": human, "flag": flag, "line": line}


def judge_triage(answers, floor, reasons):
    probs = answers["verdict"]["probabilities"]
    p_block = probs.get("block", 0.0)
    p_not_clean = 1.0 - probs.get("clean", 0.0)
    jev = "block" if p_block >= 0.5 else ("look" if p_not_clean >= 0.5 else "clean")
    eff = NAME[max(LEVEL[floor], LEVEL[jev])]
    why = "; ".join(reasons)
    flag = None
    if LEVEL[jev] > LEVEL[floor]:
        flag = f"{jev}, above the facts' {floor} (P(clean)={probs.get('clean', 0.0):.2f}, P(block)={p_block:.2f})"
    line = f"{eff} · jev {jev} (P(clean)={probs.get('clean', 0.0):.2f} P(look)={probs.get('look', 0.0):.2f} " \
           f"P(block)={p_block:.2f}) · facts {floor}" + (f" ({why})" if why else "")
    return {"effective": eff, "human": None, "flag": flag, "line": line, "jev": jev, "floor": floor}


# ---- commands ----------------------------------------------------------------------------------------------------

def append(log, record):
    os.makedirs(os.path.dirname(log), exist_ok=True)
    with open(log, "a", encoding="utf-8") as f:
        f.write(json.dumps(record, sort_keys=True) + "\n")


def read_log(log):
    rows = []
    try:
        with open(log, encoding="utf-8") as f:
            for line in f:
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict):
                    rows.append(row)
    except OSError:
        pass
    return rows


def cmd_run(args):
    cfg = load_json(args.decisions)
    kind_cfg = ((cfg or {}).get("kinds") or {}).get(args.kind)
    if not kind_cfg:
        return fail(f"no decision '{args.kind}' in {args.decisions}")
    questions = kind_cfg["questions"]
    extra = os.environ.get("ORCHESTRA_JEV_REDACT", "")
    front, floor, reasons = {}, "clean", []
    if args.kind == "triage":
        review = load_json(args.review_json) if args.review_json else None
        if not isinstance(review, dict):
            return fail("triage needs --review-json <file> (orchestra-worker review --json)")
        facts = triage_facts(review)
        floor, reasons = triage_floor(facts)
        state = {"review": redact_deep(facts, extra)}
    else:
        if not args.spec:
            return fail(f"{args.kind} needs --spec <file>")
        state, front = spec_state(args.spec, extra)
    record = {"ts": int(time.time()), "task": args.task, "kind": args.kind, "mode": args.mode,
              "model": os.environ.get("ORCHESTRA_JEV_MODEL") or DEFAULT_MODEL,
              "questions_sha": hashlib.sha256(json.dumps(questions, sort_keys=True).encode()).hexdigest()[:12],
              "state_sha": hashlib.sha256(json.dumps(state, sort_keys=True).encode()).hexdigest()[:12]}
    if args.kind == "triage":
        record["floor"] = floor
    try:
        answers, usage = classify(os.environ, state, questions)
    except RuntimeError as e:
        record["error"] = str(e)
        append(args.log, record)
        if args.print != "never":
            print(f"jev [{args.kind}] unavailable: {e}" + (f" · facts say {floor}" if args.kind == "triage" else ""))
        return 0
    if args.kind == "split":
        verdict = judge_split(answers, kind_cfg, front)
    elif args.kind == "ready":
        verdict = judge_ready(answers, kind_cfg, front)
    else:
        verdict = judge_triage(answers, floor, reasons)
    record.update({"answers": answers, "usage": usage, "effective": verdict["effective"],
                   "human": verdict["human"], "flag": verdict["flag"]})
    append(args.log, record)
    if args.print == "always":
        print(f"jev [{args.kind}] {verdict['line']}" + (f"\n     flag: {verdict['flag']}" if verdict["flag"] else ""))
        print("     advisory: Jev can ask for a closer look, never for less. The decision is yours.")
    elif args.print == "flags" and verdict["flag"]:
        print(f"jev [{args.kind}] {verdict['flag']}")
    return 0


def cmd_mark(args):
    if not args.value:
        return fail("usage: mark <task> <kind> <value>")
    append(args.log, {"ts": int(time.time()), "task": args.task, "kind": args.kind, "mark": True,
                      "human": args.value})
    return 0


def coarse(kind, value):
    if kind == "split":
        return "worker" if value == "worker" else "not-worker"
    return value


def cmd_report(args):
    latest, marks = {}, {}
    for row in read_log(args.log):
        key = (row.get("task"), row.get("kind"))
        if row.get("mark"):
            marks[key] = row.get("human")
        elif "effective" in row:
            latest[key] = row
    out, rows = {}, []
    for (task, kind), row in sorted(latest.items(), key=lambda kv: (str(kv[0][1]), str(kv[0][0]))):
        human = marks.get((task, kind)) or row.get("human")
        agree = None if human is None else coarse(kind, human) == coarse(kind, row["effective"])
        bucket = out.setdefault(kind, {"n": 0, "agree": 0, "disagree": 0, "unknown": 0})
        bucket["n"] += 1
        bucket["unknown" if agree is None else ("agree" if agree else "disagree")] += 1
        rows.append({"task": task, "kind": kind, "jev": row["effective"], "human": human, "agree": agree})
    if args.json:
        print(json.dumps({"kinds": out, "rows": rows}, indent=1))
        return 0
    if not rows:
        print("no Jev decisions logged yet")
        return 0
    for kind, b in sorted(out.items()):
        print(f"{kind}: {b['n']} decision(s), {b['agree']} agree, {b['disagree']} disagree, "
              f"{b['unknown']} without your call (orchestra-worker decide mark <task> {kind} <value>)")
    for r in rows:
        if r["agree"] is False:
            print(f"  differ  {r['task']} {r['kind']}: jev {r['jev']}, you {r['human']}")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="decide.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--kind", required=True)
    r.add_argument("--task", required=True)
    r.add_argument("--log", required=True)
    r.add_argument("--decisions", required=True)
    r.add_argument("--spec")
    r.add_argument("--review-json")
    r.add_argument("--print", choices=["always", "flags", "never"], default="always")
    r.add_argument("--mode", choices=["shadow", "advise", "manual"], default="manual")
    m = sub.add_parser("mark")
    m.add_argument("--log", required=True)
    m.add_argument("--task", required=True)
    m.add_argument("--kind", required=True)
    m.add_argument("--value", required=True)
    p = sub.add_parser("report")
    p.add_argument("--log", required=True)
    p.add_argument("--json", action="store_true")
    args = ap.parse_args(argv)
    return {"run": cmd_run, "mark": cmd_mark, "report": cmd_report}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
