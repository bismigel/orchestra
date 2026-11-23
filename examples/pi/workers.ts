// workers: show what orchestra is doing right now, in the footer and one widget, so an orchestrator never has to
// guess whether a worker is still running.
//
// It reads `orchestra-worker status --json` (orchestra 0.4.0; 0.5.0 adds tool calls, cost and the current action) —
// one call, no log parsing. The state file it reads
// is written by orchestra and removed on every exit path, so a run that died without cleaning up shows as `stale`
// instead of quietly looking alive. That distinction is the whole point: waiting on a dead run is the failure mode
// this exists to prevent.
//
// Cheap by construction: the poll is one short-lived process every 10s, and it stops as soon as no run is left.
// @ts-nocheck
import { execFile } from "node:child_process";

const POLL_MS = 10_000;
const BIN = "orchestra-worker";

function dur(s) {
  s = Math.max(0, Math.round(s));
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
  if (h) return `${h}h${String(m).padStart(2, "0")}m`;
  if (m) return `${m}m${String(s % 60).padStart(2, "0")}s`;
  return `${s}s`;
}

function query(cwd) {
  return new Promise((resolve) => {
    execFile(BIN, ["status", "--json"], { cwd, timeout: 5000 }, (err, stdout) => {
      if (err) return resolve(null); // not a repo, orchestra missing, or no runs: silence is correct
      try {
        resolve(JSON.parse(stdout));
      } catch {
        resolve(null);
      }
    });
  });
}

export default function (pi) {
  let timer = null;
  let last = { runs: [], running: 0 };

  const render = (ctx) => {
    const running = last.runs.filter((r) => r.state === "running");
    const stale = last.runs.filter((r) => r.state === "stale");

    if (!running.length && !stale.length) {
      ctx.ui.setStatus("orchestra-workers", undefined);
      ctx.ui.setWidget("orchestra-workers", undefined);
      return;
    }

    const head = [
      running.length ? `⚡ ${running.length} running` : "",
      stale.length ? ctx.ui.theme.fg("warning", `${stale.length} stale`) : "",
    ].filter(Boolean).join(" · ");
    ctx.ui.setStatus(
      "orchestra-workers",
      ctx.ui.theme.fg(stale.length ? "warning" : "accent", `⚡ ${running.length}${stale.length ? `/!${stale.length}` : ""}`),
    );

    const lines = [ctx.ui.theme.fg("accent", `orchestra · ${head}`)];
    for (const r of running) {
      // orchestra 0.5: tool calls, cost so far and the current action (absent on older versions: shown as blanks).
      const task = r.kind === "scout" ? `${r.task}·scout` : r.task;
      const tools = r.tool_calls != null ? `${r.tool_calls} tools` : "";
      const cost = r.cost != null ? `$${r.cost.toFixed(3)}` : "";
      let now = r.last_action || "";
      if (r.quiet_seconds != null && r.quiet_seconds >= 120) now = ctx.ui.theme.fg("warning", `quiet ${dur(r.quiet_seconds)}`) + (now ? ` · ${now}` : "");
      lines.push(`  ${task.padEnd(8)} ${dur(r.elapsed_seconds).padStart(7)}  ${tools.padStart(9)} ${cost.padStart(7)}  ${now.slice(0, 70)}`);
    }
    for (const r of stale) {
      lines.push(
        ctx.ui.theme.fg("warning", `  ${r.task.padEnd(6)} stale    the process is gone, run.json was not cleaned up`),
      );
    }
    if (stale.length) lines.push(ctx.ui.theme.fg("warning", `  review: orchestra-worker status`));
    ctx.ui.setWidget("orchestra-workers", lines, { placement: "belowEditor" });
  };

  const refresh = async (ctx) => {
    const d = await query(process.cwd());
    last = d || { runs: [], running: 0 };
    // render() touches ctx.ui, which throws if this ctx went stale during the await (a reload/replacement while
    // the subprocess ran). Catch it and stop the timer instead of letting the rejection crash pi; the new session
    // restarts the poll with a fresh ctx.
    try {
      render(ctx);
    } catch {
      stop();
    }
  };

  const start = (ctx) => {
    stop(); // in case a session_start arrives without a shutdown (defensive)
    refresh(ctx);
    timer = setInterval(() => refresh(ctx), POLL_MS);
    timer.unref?.();
  };

  const stop = () => {
    if (timer) clearInterval(timer);
    timer = null;
  };

  pi.on("session_start", async (_e, ctx) => start(ctx));
  // Session teardown: clear the timer BEFORE the old ctx goes stale. Holding ctx in the interval across
  // a reload is exactly the crash this avoids — the docs forbid using a captured ctx after replacement.
  pi.on("session_shutdown", () => { stop(); });
  // A finished tool call is the moment the picture can change; the interval covers everything else.
  pi.on("tool_execution_end", async (_e, ctx) => {
    if (last.running > 0 || /orchestra|worker/.test(String(_e?.toolName || ""))) refresh(ctx);
  });
  pi.registerCommand("workers", {
    description: "What orchestra is running now (calls `orchestra-worker status`)",
    handler: async (_args, ctx) => {
      await refresh(ctx);
      const running = last.runs.filter((r) => r.state === "running");
      const stale = last.runs.filter((r) => r.state === "stale");
      if (!running.length && !stale.length) return ctx.ui.notify("no orchestra runs", "info");
      for (const r of running)
        ctx.ui.notify(
          `${r.task} running ${dur(r.elapsed_seconds)} · run ${r.run} · ${r.model}` +
            (r.last_action ? ` · now: ${r.last_action}` : ""),
          "info",
        );
      for (const r of stale)
        ctx.ui.notify(`${r.task} STALE (pid ${r.pid} gone) — /workers clean removes these`, "warning");
    },
  });

  pi.registerCommand("workers clean", {
    description: "Remove stale orchestra run state files (runs whose process is gone)",
    handler: async (_args, ctx) => {
      execFile(BIN, ["status", "--prune"], { cwd: process.cwd(), timeout: 5000 }, async (err, _out, stderr) => {
        await refresh(ctx);
        if (err) return ctx.ui.notify("orchestra-worker status --prune failed", "error");
        ctx.ui.notify(String(stderr).trim() || "nothing to prune", "info");
      });
    },
  });
}
