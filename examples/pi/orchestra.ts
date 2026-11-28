// orchestra: first-class pi tools for the orchestrator to scout, run, review, prove and land worker tasks.
// Wraps `orchestra-worker` (https://github.com/bismigel/orchestra). Install: link this file into
// ~/.pi/agent/extensions/ (only .ts extensions there: pi loads everything in that folder at startup).
//
// Token budget is the design constraint: the orchestrating model gets the run's end card, not its progress lines;
// the review digest, not the diff (ask for the diff explicitly). Progress lines go to pi's tool view as live
// updates, for the person watching. Workers never load extensions (they start pi with --no-extensions).
// @ts-nocheck
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { dirname, isAbsolute, join, relative, resolve } from "node:path";
import { Type } from "typebox";

const BIN = "orchestra-worker";
const TAIL = 3000; // bound any command output handed to the model
const DIFF_CAP = 40000; // the full diff, only when asked for

const MEANING = {
  0: "ok",
  2: "usage or config error",
  3: "DISALLOWED MODEL answered: discard the run",
  4: "NO VALID REPORT",
  5: "OVER BUDGET (ORCHESTRA_MAX_COST)",
  124: "TIMED OUT",
  130: "interrupted",
};

/** Run orchestra-worker, collecting output; stderr lines are passed to onLine as they arrive. */
function runOW(args, cwd, signal, onLine) {
  return new Promise((resolve) => {
    const child = spawn(BIN, args, { cwd, env: process.env, stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    let partial = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => {
      err += d;
      if (!onLine) return;
      partial += d;
      const lines = partial.split("\n");
      partial = lines.pop();
      for (const l of lines) onLine(l);
    });
    // SIGTERM is safe: orchestra-worker >= 0.7 stops the sandboxed worker and cleans up (exit 130).
    const abort = () => child.kill("SIGTERM");
    if (signal) signal.addEventListener("abort", abort);
    child.on("close", (code) => {
      if (signal) signal.removeEventListener("abort", abort);
      resolve({ code, out, err });
    });
    child.on("error", (e) => resolve({ code: -1, out: "", err: "spawn failed: " + e.message }));
  });
}

function tail(s, n) {
  s = String(s ?? "").trimEnd();
  return s.length > n ? "…(start trimmed)\n" + s.slice(-n) : s;
}

/** The end card of a run (from the "── " line on), or the bounded tail when there is none. */
function card(text) {
  const i = text.lastIndexOf("\n── ");
  const j = text.startsWith("── ") ? 0 : i >= 0 ? i + 1 : -1;
  return j >= 0 ? text.slice(j).trimEnd() : tail(text, TAIL);
}

/** Drop the per-tool-call progress lines ("T41 03:12 #14 edit …"): they are for people, not the model. */
function withoutProgress(text, label) {
  const re = new RegExp("^" + label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + " \\d+:\\d{2}(:\\d{2})? ");
  return text
    .split("\n")
    .filter((l) => !re.test(l))
    .join("\n");
}

// A tool's ctx can go stale if the session is replaced while the subprocess runs (run and land take minutes).
// Notifying is a courtesy, never a requirement, so a stale ctx is swallowed instead of crashing pi.
function safeNotify(ctx, text, kind) {
  try {
    if (ctx && ctx.hasUI) ctx.ui.notify(text, kind);
  } catch {
    /* stale ctx after session replacement: ignore */
  }
}

/** Live progress into pi's tool view: the last few lines, throttled. Never required. */
function progressUpdater(onUpdate, header) {
  if (typeof onUpdate !== "function") return undefined;
  const last = [];
  let t = 0;
  return (line) => {
    if (!line.trim()) return;
    last.push(line);
    if (last.length > 8) last.shift();
    const now = Date.now();
    if (now - t < 500) return;
    t = now;
    try {
      onUpdate({ content: [{ type: "text", text: header + "\n" + last.join("\n") }] });
    } catch {
      /* the view went away: keep running */
    }
  };
}

const cwdParam = Type.Optional(Type.String({ description: "Repository directory (default: pi's working directory)" }));
const wtParam = Type.Optional(Type.String({ description: "Worktree directory override" }));

function textResult(title, code, body, extra) {
  const meaning = MEANING[code] ? ` (${MEANING[code]})` : "";
  return {
    content: [{ type: "text", text: `${title} → exit ${code}${meaning}\n${body || "(no output)"}` }],
    details: { exit: code, ...(extra || {}) },
  };
}

// ---- direct-edit nudge ------------------------------------------------------------------------------------------
// An orchestrator that keeps editing source files itself has usually skipped the spec (a `split` task kept on the
// expensive model). In a repository that uses orchestra, count the distinct source files changed with native
// edit/write since the last worker run, and append one reminder to the tool result at the threshold (and at every
// multiple of it). ORCHESTRA_DIRECT_EDIT_WARN sets the threshold (default 3; 0 turns it off). A worker run resets
// the count; `orchestra-worker decide mark <id> split orchestrator` silences it for the session.

/** The repository root above `cwd` that uses orchestra (.orchestra/config.env or a tasks dir), or null. */
export function orchestraRoot(cwd, exists = existsSync) {
  let dir = resolve(cwd || ".");
  for (;;) {
    if (exists(join(dir, ".orchestra", "config.env")) || exists(join(dir, "docs", "work", "tasks"))) return dir;
    if (exists(join(dir, ".git"))) return null;
    const up = dirname(dir);
    if (up === dir) return null;
    dir = up;
  }
}

/** A path the orchestrator is expected to write itself: specs, docs, Markdown, orchestra state, or outside the repo. */
export function isOrchestratorPath(path, root, tasksDir = "docs/work/tasks") {
  const rel = relative(root, isAbsolute(path) ? path : resolve(root, path)).split("\\").join("/");
  if (!rel || rel.startsWith("../") || isAbsolute(rel)) return true;
  const t = String(tasksDir || "").replace(/\/+$/, "");
  return (
    (t && (rel === t || rel.startsWith(t + "/"))) ||
    rel.startsWith(".orchestra/") ||
    rel.startsWith("docs/") ||
    /\.(md|mdx|txt)$/i.test(rel)
  );
}

export function directEditThreshold(env = process.env) {
  const raw = env.ORCHESTRA_DIRECT_EDIT_WARN;
  const n = raw == null || raw === "" ? 3 : Number(raw);
  return Number.isFinite(n) && n >= 0 ? Math.floor(n) : 3;
}

const DECIDE_ORCHESTRATOR = /orchestra-worker\s+decide\s+mark\s+\S+\s+split\s+orchestrator\b/;

export function createDirectEditTracker(env = process.env) {
  const threshold = directEditThreshold(env);
  let files = new Set();
  let quiet = false;
  return {
    reset() {
      files = new Set();
    },
    count() {
      return files.size;
    },
    /** Feed one finished tool call; returns the reminder to append, or null. */
    observe({ toolName, input, isError, cwd }) {
      if (toolName === "orchestra_run") {
        files = new Set();
        return null;
      }
      if (toolName === "bash" && input && DECIDE_ORCHESTRATOR.test(String(input.command || ""))) {
        quiet = true;
        return null;
      }
      if (quiet || threshold === 0 || isError || (toolName !== "edit" && toolName !== "write")) return null;
      const path = input && typeof input.path === "string" ? input.path : "";
      const root = path ? orchestraRoot(cwd) : null;
      if (!root) return null;
      const abs = isAbsolute(path) ? path : resolve(cwd || root, path);
      if (isOrchestratorPath(abs, root, env.ORCHESTRA_TASKS_DIR || "docs/work/tasks")) return null;
      const before = files.size;
      files.add(abs);
      const n = files.size;
      if (n === before || n % threshold !== 0) return null;
      return (
        `[orchestra] ${n} source files edited directly since the last worker run. If this is mechanical multi-file ` +
        "work (call sites, generated code, tests), it is a `split` task: settle the decisions and the risky test " +
        "rows in a spec, `orchestra-task lint <id> --strict`, then orchestra_scout and orchestra_run. If the work " +
        "really is orchestrator-class, record it with `orchestra-worker decide mark <id> split orchestrator` (this " +
        "reminder stops) or set ORCHESTRA_DIRECT_EDIT_WARN=0."
      );
    },
  };
}

export default function (pi) {
  const edits = createDirectEditTracker();
  if (typeof pi.on === "function") {
    pi.on("session_start", () => edits.reset());
    pi.on("tool_result", (event, ctx) => {
      try {
        const note = edits.observe({ toolName: event.toolName, input: event.input, isError: event.isError, cwd: (ctx && ctx.cwd) || process.cwd() });
        if (!note) return undefined;
        const content = Array.isArray(event.content) ? event.content : [];
        return { content: [...content, { type: "text", text: "\n" + note }] };
      } catch {
        return undefined; // a reminder is never worth breaking a tool result
      }
    });
  }

  // ---- scout ---------------------------------------------------------------------------------------
  pi.registerTool({
    name: "orchestra_scout",
    label: "orchestra scout",
    description:
      "Before a spec is final: a read-only worker checks the draft against the code and reports where named things " +
      "really live, files and tests the spec missed, broken commands, size, and undecided calls, ending with lines " +
      "to paste into Touches. Costs cents. You decide what goes into the spec.",
    parameters: Type.Object({
      task: Type.String({ description: "Task id, e.g. T56" }),
      spec: Type.Optional(Type.String({ description: "Path to the draft spec markdown" })),
      prompt: Type.Optional(Type.String({ description: "Inline scout prompt instead of a spec file" })),
      state: Type.Optional(Type.Boolean({ description: "Include the scout's state.md in the result" })),
      cwd: cwdParam,
    }),
    async execute(_id, p, signal, onUpdate, ctx) {
      const cwd = p.cwd || process.cwd();
      if (!p.spec && !p.prompt) {
        return textResult(`orchestra scout ${p.task}`, 2, "provide spec or prompt");
      }
      const args = ["scout", p.task];
      if (p.spec) args.push("--spec", p.spec);
      if (p.prompt) args.push("--prompt", p.prompt);
      if (p.state) args.push("--state");
      const upd = progressUpdater(onUpdate, `scout ${p.task}…`);
      const { code, out, err } = await runOW(args, cwd, signal, upd);
      safeNotify(ctx, `orchestra scout ${p.task} exited ${code}`, code === 0 ? "info" : "error");
      const text = tail(out + (code === 0 ? "" : "\n" + withoutProgress(err, `scout:${p.task}`)), 8000);
      return textResult(`orchestra scout ${p.task}`, code, text);
    },
  });

  // ---- run -----------------------------------------------------------------------------------------
  pi.registerTool({
    name: "orchestra_run",
    label: "orchestra run",
    description:
      "Launch an orchestra worker for one task and wait for it. Returns the exit code and the run's end card " +
      "(status, blocking questions, assumptions, cost); progress shows live in the tool view. Exit codes: 0 ok · " +
      "3 disallowed model (discard) · 4 no valid report · 5 over budget · 124 timed out · 2 refused (stale " +
      "worktree whose spec changed, or the task is already running). Then use orchestra_review.",
    parameters: Type.Object({
      task: Type.String({ description: "Task id, e.g. T56" }),
      spec: Type.Optional(Type.String({ description: "Path to the task spec markdown (first run)" })),
      prompt: Type.Optional(Type.String({ description: "Extra inline instructions for this run" })),
      feedback: Type.Optional(Type.String({ description: "Path to a feedback file (follow-up round)" })),
      allowStale: Type.Optional(Type.Boolean({ description: "Run even though the spec changed on the base" })),
      worktree: wtParam,
      cwd: cwdParam,
    }),
    async execute(_id, p, signal, onUpdate, ctx) {
      const cwd = p.cwd || process.cwd();
      const args = ["run", p.task];
      if (p.spec) args.push("--spec", p.spec);
      if (p.prompt) args.push("--prompt", p.prompt);
      if (p.feedback) args.push("--feedback", p.feedback);
      if (p.allowStale) args.push("--allow-stale");
      if (p.worktree) args.push("--worktree", p.worktree);
      const upd = progressUpdater(onUpdate, `worker ${p.task}…`);
      const { code, out, err } = await runOW(args, cwd, signal, upd);
      safeNotify(ctx, `orchestra run ${p.task} exited ${code}`, code === 0 ? "info" : "error");
      const all = (out || "") + (err || "");
      return textResult(`orchestra run ${p.task}`, code, card(withoutProgress(all, p.task)));
    },
  });

  // ---- artifact ------------------------------------------------------------------------------------
  pi.registerTool({
    name: "orchestra_artifact",
    label: "orchestra artifact",
    description:
      "Render one task's run or scout into a self-contained HTML review artifact: report, BLOCKING questions, risk " +
      "notes, proofs, spec, state and source/rendered diffs. Saves it in the local artifacts folder with an " +
      "index.html (and publishes to the Artifact Server when one is configured). Returns the artifact URL or " +
      "local file:// path and the index path.",
    parameters: Type.Object({
      task: Type.String({ description: "Task id, e.g. T56" }),
      local: Type.Optional(Type.Boolean({ description: "Force the local folder even when a server is configured" })),
      open: Type.Optional(Type.Boolean({ description: "Open the artifact after saving it" })),
      worktree: wtParam,
      cwd: cwdParam,
    }),
    async execute(_id, p, signal) {
      const cwd = p.cwd || process.cwd();
      const args = ["artifact", p.task];
      if (p.local) args.push("--local");
      if (p.open) args.push("--open");
      if (p.worktree) args.push("--worktree", p.worktree);
      const { code, out, err } = await runOW(args, cwd, signal);
      const text = tail((out || "") + (err ? "\n" + err : ""), TAIL);
      const pick = (label) => {
        const m = text.match(new RegExp("^" + label + ": (.+)$", "m"));
        return m ? m[1].trim() : undefined;
      };
      const remote = pick("remote artifact");
      const localPath = pick("local artifact");
      const index = pick("index");
      const target = remote || (localPath ? `file://${localPath}` : undefined);
      const summary = [target ? `artifact: ${target}` : "", index ? `index: ${index}` : ""]
        .filter(Boolean)
        .join("\n");
      return textResult(`orchestra artifact ${p.task}`, code, (summary ? summary + "\n\n" : "") + text, {
        url: remote,
        path: localPath,
        index,
      });
    },
  });

  // ---- guide -------------------------------------------------------------------------------------------
  // Progressive disclosure: the list, then one guide's contents, then one section. The whole text only on request.
  pi.registerTool({
    name: "orchestra_guide",
    label: "orchestra guide",
    description:
      "Read orchestra's guides a piece at a time instead of reading files by path. No name: the list of guides. A " +
      "name: that guide's sections. Add section (a heading or its number) for one section; full=true for the whole " +
      "guide (large).",
    parameters: Type.Object({
      name: Type.Optional(Type.String({ description: "Guide: orchestrator, planning, ops, land, jev, proofs, security, design, harness" })),
      section: Type.Optional(Type.String({ description: "Section heading (a substring is enough) or its number" })),
      full: Type.Optional(Type.Boolean({ description: "The whole guide" })),
      cwd: cwdParam,
    }),
    async execute(_id, p, signal) {
      const args = ["guide"];
      if (!p.name) args.push("--list");
      else if (p.section) args.push(p.name, "--section", p.section);
      else args.push(p.name, p.full ? "--cat" : "--toc");
      const { code, out, err } = await runOW(args, p.cwd || process.cwd(), signal);
      return textResult(`orchestra guide ${args.slice(1).join(" ")}`, code, tail((out || "") + (err ? "\n" + err : ""), 20000));
    },
  });

  // ---- status --------------------------------------------------------------------------------------
  pi.registerTool({
    name: "orchestra_status",
    label: "orchestra status",
    description:
      "What is running now: each worker's elapsed time, tool calls, cost so far and current action; 'stale' means " +
      "the process is gone (never wait on a stale run).",
    parameters: Type.Object({ cwd: cwdParam }),
    async execute(_id, p, signal) {
      const { code, out, err } = await runOW(["status"], p.cwd || process.cwd(), signal);
      return textResult("orchestra status", code, tail(out + err, TAIL));
    },
  });

  // ---- review --------------------------------------------------------------------------------------
  pi.registerTool({
    name: "orchestra_review",
    label: "orchestra review",
    description:
      "Review a finished run in one call: exit meaning, BLOCKING questions (decide them), assumed calls (skim), " +
      "files changed outside the spec's Owns/Touches, the worker's claimed checks, proofs for the exact code, and a " +
      "ranked diff stat. Set diff=true to append the full diff (generated files excluded) when you need the code.",
    parameters: Type.Object({
      task: Type.String({ description: "Task id, e.g. T56" }),
      diff: Type.Optional(Type.Boolean({ description: "Also return the full diff (large)" })),
      worktree: wtParam,
      cwd: cwdParam,
    }),
    async execute(_id, p, signal) {
      const cwd = p.cwd || process.cwd();
      const warg = p.worktree ? ["--worktree", p.worktree] : [];
      const jobs = [runOW(["review", p.task, ...warg], cwd, signal)];
      if (p.diff) jobs.push(runOW(["diff", p.task, ...warg], cwd, signal));
      const [rev, diff] = await Promise.all(jobs);
      let text = tail((rev.out || "") + (rev.err ? "\n" + rev.err : ""), 12000);
      if (diff) text += "\n\n== diff ==\n" + tail((diff.out || "") + (diff.err ? "\n" + diff.err : ""), DIFF_CAP);
      return textResult(`orchestra review ${p.task}`, rev.code, text);
    },
  });

  // ---- prove ---------------------------------------------------------------------------------------
  pi.registerTool({
    name: "orchestra_prove",
    label: "orchestra prove",
    description:
      "Run the repository gate and the spec's `proof:` checks outside the sandbox, bound to a hash of the exact " +
      "code. A report is a claim; a proof is evidence. Use manual to record a check a command cannot do.",
    parameters: Type.Object({
      task: Type.String({ description: "Task id" }),
      manual: Type.Optional(Type.String({ description: "Record a manual proof, e.g. 'checked the empty state at 400px'" })),
      worktree: wtParam,
      cwd: cwdParam,
    }),
    async execute(_id, p, signal, _onUpdate, ctx) {
      const cwd = p.cwd || process.cwd();
      const args = ["prove", p.task];
      if (p.manual) args.push("--manual", p.manual);
      if (p.worktree) args.push("--worktree", p.worktree);
      const { code, out, err } = await runOW(args, cwd, signal);
      safeNotify(ctx, `orchestra prove ${p.task} ${code === 0 ? "PASS" : "FAIL"}`, code === 0 ? "info" : "error");
      return textResult(`orchestra prove ${p.task}`, code, tail((out || "") + (err ? "\n" + err : ""), TAIL));
    },
  });

  // ---- land ----------------------------------------------------------------------------------------
  pi.registerTool({
    name: "orchestra_land",
    label: "orchestra land",
    description:
      "Land a reviewed task: commit, rebase onto ORCHESTRA_BASE, squash, prove the exact code, then push with " +
      "Proof: trailers (or, with pr=true / ORCHESTRA_LAND=pr, push a branch and open a pull request: for protected " +
      "branches). With a local-branch ORCHESTRA_BASE it moves that branch in place instead (no push; pr is refused). " +
      "Refuses on any failing check. Afterwards: orchestra-worker lessons <task> drafts lessons lines.",
    parameters: Type.Object({
      task: Type.String({ description: "Task id" }),
      pr: Type.Optional(Type.Boolean({ description: "Open a pull request instead of pushing to the base" })),
      messageFile: Type.Optional(Type.String({ description: "File holding the commit message (else <task>: <title>)" })),
      worktree: wtParam,
      cwd: cwdParam,
    }),
    async execute(_id, p, signal, _onUpdate, ctx) {
      const cwd = p.cwd || process.cwd();
      const args = ["land", p.task];
      if (p.pr) args.push("--pr");
      if (p.messageFile) args.push("--message-file", p.messageFile);
      if (p.worktree) args.push("--worktree", p.worktree);
      const { code, out, err } = await runOW(args, cwd, signal);
      safeNotify(ctx, `orchestra land ${p.task} ${code === 0 ? "landed" : "FAILED"}`, code === 0 ? "info" : "error");
      return textResult(`orchestra land ${p.task}`, code, tail((out || "") + (err ? "\n" + err : ""), TAIL));
    },
  });
}
