"""orchestra artifact: one self-contained HTML review artifact for a run or scout task.

Read-only and offline by default. It reads the task worktree's `.orchestra/` state (report, proofs, runs, spec,
state.md) and a scout directory when one is given, renders the source diff on a temporary copy of the git index, and
writes a single HTML file with no external CDN dependency. Every artifact is saved in one local folder with an
auto-maintained index.html and manifest.json; when an Artifact Server is configured it also tries to publish a copy.

The local copy is written first and always kept, so a remote failure never loses the review artifact. The agent
token is never printed, embedded in the HTML, or passed on a command line.
"""
import argparse
import datetime as dt
import fnmatch
import glob
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import task_lint  # noqa: E402  (same directory; imported, never edited)

DIFF_CAP = 250 * 1024
SAFE_NAME = re.compile(r"[^A-Za-z0-9._-]+")
EXIT_MEANING = {
    0: "ok",
    3: "disallowed model: discard",
    4: "no valid report",
    124: "timed out",
}


def esc(value):
    """Escape untrusted text for HTML. Everything that comes from a repository, a report or a diff goes through here."""
    return html.escape("" if value is None else str(value), quote=True)


def load_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def load_text(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return ""


def number(value):
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def int_or_none(value):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def text_list(value):
    if isinstance(value, list):
        return [str(item) for item in value]
    return []


def short(value, limit=110):
    text = " ".join(str(value).split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


def duration(secs):
    secs = int_or_none(secs)
    if secs is None:
        return ""
    if secs < 60:
        return f"{secs}s"
    minutes, rest = divmod(secs, 60)
    return f"{minutes}m{rest:02d}s"


def safe_name(value):
    name = SAFE_NAME.sub("_", str(value or "")).strip("._")
    return name or "artifact"


def http_url(value):
    """Only http(s) links are rendered or opened; a server answer cannot smuggle another scheme in."""
    return value if re.match(r"^https?://", value or "", re.I) else ""


def run_numbers(runs_dir, suffix):
    nums = set()
    for path in glob.glob(os.path.join(runs_dir, f"run-*.{suffix}")):
        stem = os.path.basename(path)[len("run-"):-len(suffix) - 1]
        try:
            nums.add(int(stem))
        except ValueError:
            continue
    return nums


# ---- reading the task's state -------------------------------------------------------------------------------------

def read_run(state):
    runs_dir = os.path.join(state, "runs")
    nums = run_numbers(runs_dir, "jsonl")
    usage_nums = run_numbers(runs_dir, "usage.json")
    all_nums = nums | usage_nums

    total_cost = 0.0
    total_responses = 0
    for path in glob.glob(os.path.join(runs_dir, "run-*.usage.json")):
        data = load_json(path)
        if isinstance(data, dict):
            total_cost += number(data.get("cost"))
            total_responses += int_or_none(data.get("responses")) or 0

    latest = None
    if all_nums:
        n = max(all_nums)
        result = load_json(os.path.join(runs_dir, f"run-{n}.result.json"))
        usage = load_json(os.path.join(runs_dir, f"run-{n}.usage.json"))
        if not isinstance(usage, dict):
            usage = {}
        exit_code = int_or_none(result.get("exit")) if isinstance(result, dict) else None
        latest = {
            "n": n,
            "exit": exit_code,
            "meaning": EXIT_MEANING.get(exit_code, "harness failed") if exit_code is not None else "",
            "secs": int_or_none(result.get("secs")) if isinstance(result, dict) else None,
            "responses": int_or_none(usage.get("responses")) or 0,
            "cost": number(usage.get("cost")),
        }
    return {
        "latest": latest,
        "runs": len(all_nums),
        "responses": total_responses,
        "cost": total_cost,
    }


def read_proofs(state):
    rows = []
    try:
        with open(os.path.join(state, "proofs.jsonl"), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if isinstance(row, dict):
                    rows.append(row)
    except OSError:
        pass
    return rows


def spec_sections(spec_path):
    if not spec_path or not os.path.isfile(spec_path):
        return None
    try:
        _fm, sections = task_lint.parse(spec_path)
    except (OSError, ValueError, IndexError):
        return None
    if "owns" not in sections and "touches" not in sections:
        return None
    paths = []
    for name in ("owns", "touches"):
        for path, _is_new in task_lint.paths_in(sections.get(name, "")):
            paths.append(path)
    return paths


def covered(path, paths):
    for p in paths:
        if not p:
            continue
        if path == p:
            return True
        if path.startswith(p.rstrip("/") + "/"):
            return True
        if any(c in p for c in "*?[") and fnmatch.fnmatch(path, p):
            return True
    return False


def index_path_for(worktree, base):
    """A ref to diff against: the merge base, or the base when there is no merge base (as review.py does)."""
    try:
        mb = subprocess.run(["git", "-C", worktree, "merge-base", "HEAD", base],
                            capture_output=True, text=True, check=False)
        if mb.returncode == 0 and mb.stdout.strip():
            return mb.stdout.strip()
        verify = subprocess.run(["git", "-C", worktree, "rev-parse", "--verify", "--quiet", base],
                                capture_output=True, text=True, check=False)
        if verify.returncode == 0 and verify.stdout.strip():
            return base
    except OSError:
        pass
    return ""


def read_diff(worktree, base):
    """Return (diff text, changed paths, note). Untracked files are included through a temporary index copy."""
    if not worktree or not os.path.isdir(worktree):
        return "", [], "no worktree"
    try:
        index = subprocess.run(
            ["git", "-C", worktree, "rev-parse", "--path-format=absolute", "--git-path", "index"],
            capture_output=True, text=True, check=False)
        index_path = index.stdout.strip()
    except OSError:
        index_path = ""

    tmp_fd, tmp_path = tempfile.mkstemp(prefix="orchestra-artifact-index-")
    os.close(tmp_fd)
    try:
        if index_path and os.path.exists(index_path):
            shutil.copyfile(index_path, tmp_path)
        env = dict(os.environ, GIT_INDEX_FILE=tmp_path)
        ref = index_path_for(worktree, base)
        if not ref:
            return "", [], f"no merge base with {base} (fetch first?)"

        def git(args, extra_env=None):
            return subprocess.run(["git", "-C", worktree, "--no-pager", *args], env=extra_env or os.environ,
                                  capture_output=True, text=True, check=False)

        # Tracked changes come from the worktree itself (the index's stat cache can miss a same-size edit made in
        # the same second). Untracked files are rendered through the temporary index copy, exactly like review.py.
        pathspec = ["--", ".", ":(exclude).orchestra"]
        tracked = git(["diff", "--no-renames", ref, *pathspec])
        names = git(["diff", "--no-renames", "--name-only", ref, *pathspec])
        others = git(["ls-files", "--others", "--exclude-standard", *pathspec])
        changed = [line for line in names.stdout.splitlines() if line] if names.returncode == 0 else []
        untracked = [line for line in others.stdout.splitlines() if line] if others.returncode == 0 else []
        changed += [path for path in untracked if path not in changed]

        parts = [tracked.stdout] if tracked.returncode == 0 and tracked.stdout.strip() else []
        if untracked:
            subprocess.run(["git", "-C", worktree, "add", "-A"], env=env,
                           capture_output=True, text=True, check=False)
            new_diff = git(["diff", "--cached", "--no-renames", ref, "--", *untracked], extra_env=env)
            if new_diff.returncode == 0 and new_diff.stdout.strip():
                parts.append(new_diff.stdout)
        return ("\n".join(part.rstrip("\n") for part in parts) + "\n" if parts else ""), changed, ""
    finally:
        try:
            os.remove(tmp_path)
        except OSError:
            pass


def read_scout(scout_dir):
    if not scout_dir or not os.path.isdir(scout_dir):
        return None
    data = load_json(os.path.join(scout_dir, "scout.json"))
    return data if isinstance(data, dict) else None


def find_state_md(worktree, scout_dir):
    candidates = []
    if scout_dir:
        candidates.append(os.path.join(scout_dir, "state.md"))
    if worktree:
        candidates.append(os.path.join(worktree, ".orchestra", "state.md"))
    for path in candidates:
        if os.path.isfile(path):
            return path, load_text(path)
    return "", ""


def collect(args):
    repo = os.path.abspath(args.repo)
    worktree = os.path.abspath(args.worktree) if args.worktree else ""
    if not worktree:
        # The conventional sibling worktree orchestra creates; the repository itself is the fallback.
        guess = os.path.join(os.path.dirname(repo), os.path.basename(repo) + "-worktrees", args.task)
        worktree = guess if os.path.isdir(guess) else repo
    if not os.path.isdir(worktree):
        worktree = repo
    state = os.path.join(worktree, ".orchestra")

    report = load_json(os.path.join(state, "report.json"))
    if not isinstance(report, dict):
        report = None

    diff_text, changed, diff_note = read_diff(worktree, args.base)
    truncated = len(diff_text.encode("utf-8", errors="replace")) > DIFF_CAP
    if truncated:
        diff_text = diff_text.encode("utf-8", errors="replace")[:DIFF_CAP].decode("utf-8", errors="ignore")

    spec_path = os.path.join(state, "spec.md")
    spec_text = load_text(spec_path) if os.path.isfile(spec_path) else ""
    paths = spec_sections(spec_path)
    outside = []
    if paths is not None:
        outside = [path for path in changed if not covered(path, paths)]

    rendered_parts = []
    if args.rendered_diff_file:
        rendered_parts.append(load_text(args.rendered_diff_file))
    if report is not None:
        for entry in text_list(report.get("rendered_diff")):
            rendered_parts.append(entry)

    state_md_path, state_md = find_state_md(worktree, args.scout_dir)
    return {
        "repo": repo,
        "repo_name": os.path.basename(repo.rstrip(os.sep)) or repo,
        "worktree": worktree,
        "task": args.task,
        "base": args.base,
        "report": report,
        "run": read_run(state),
        "proofs": read_proofs(state),
        "diff": diff_text,
        "diff_note": diff_note,
        "diff_truncated": truncated,
        "changed": changed,
        "outside": outside,
        "spec": spec_text,
        "spec_checked": paths is not None,
        "rendered_diff": "\n\n".join(part for part in rendered_parts if part.strip()),
        "state_md": state_md,
        "state_md_source": state_md_path,
        "scout": read_scout(args.scout_dir),
    }


# ---- HTML rendering -----------------------------------------------------------------------------------------------

def render_markdown(text):
    """A small, escape-first markdown renderer: headings, lists, quotes, fenced code, bold/italic/inline code."""
    if not text or not text.strip():
        return '<p class="muted">(empty)</p>'
    out = []
    code = []
    para = []
    items = []
    list_kind = None
    in_code = False

    def flush_para():
        nonlocal para
        if para:
            out.append("<p>" + "<br>".join(inline_md(esc(line)) for line in para) + "</p>")
            para = []

    def flush_list():
        nonlocal items, list_kind
        if items:
            tag = list_kind or "ul"
            out.append(f"<{tag}>" + "".join(f"<li>{inline_md(esc(item))}</li>" for item in items) + f"</{tag}>")
        items = []
        list_kind = None

    for raw in text.splitlines():
        line = raw.rstrip()
        if line.startswith("```"):
            flush_para()
            flush_list()
            if in_code:
                out.append('<pre class="code">' + esc("\n".join(code)) + "</pre>")
                code = []
                in_code = False
            else:
                in_code = True
            continue
        if in_code:
            code.append(raw)
            continue
        if not line.strip():
            flush_para()
            flush_list()
            continue
        heading = re.match(r"^(#{1,6})\s+(.*)$", line)
        if heading:
            flush_para()
            flush_list()
            level = len(heading.group(1))
            out.append(f"<h{level}>{inline_md(esc(heading.group(2)))}</h{level}>")
            continue
        bullet = re.match(r"^\s*[-*]\s+(.*)$", line)
        numbered = re.match(r"^\s*\d+[.)]\s+(.*)$", line)
        if bullet or numbered:
            flush_para()
            kind = "ul" if bullet else "ol"
            if list_kind and list_kind != kind:
                flush_list()
            list_kind = kind
            items.append((bullet or numbered).group(1))
            continue
        if line.startswith(">"):
            flush_para()
            flush_list()
            out.append(f"<blockquote>{inline_md(esc(line[1:].strip()))}</blockquote>")
            continue
        flush_list()
        para.append(line)
    flush_para()
    flush_list()
    if in_code and code:
        out.append('<pre class="code">' + esc("\n".join(code)) + "</pre>")
    return "\n".join(out)


def inline_md(text):
    """Inline markdown over already-escaped text: code, then bold/italic (never links)."""
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<!\*)\*([^*]+)\*(?!\*)", r"<em>\1</em>", text)
    return text


def diff_class(line):
    if line.startswith("+++") or line.startswith("---"):
        return "d-file"
    if line.startswith("@@"):
        return "d-hunk"
    if line.startswith("+"):
        return "d-add"
    if line.startswith("-"):
        return "d-del"
    return "d-ctx"


def render_diff(text):
    if not text.strip():
        return '<p class="muted">(no diff)</p>'
    out = ['<pre class="diff">']
    for line in text.splitlines():
        out.append(f'<span class="{diff_class(line)}">{esc(line)}</span>')
    out.append("</pre>")
    return "\n".join(out)


def html_list(items, cls=""):
    if not items:
        return ""
    klass = f' class="{cls}"' if cls else ""
    return f"<ul{klass}>" + "".join(f"<li>{esc(item)}</li>" for item in items) + "</ul>"


def card(title, body, subtitle=""):
    head = f"<h2>{esc(title)}</h2>"
    if subtitle:
        head += f'<p class="sub">{esc(subtitle)}</p>'
    return f'<div class="card">{head}{body}</div>'


def proof_table(proofs):
    if not proofs:
        return '<p class="muted">No proofs recorded.</p>'
    rows = []
    for row in proofs[-200:]:
        if "manual" in row and "check" not in row:
            rows.append("<tr><td>manual</td><td class=\"pass\">recorded</td><td colspan=\"4\">"
                        + esc(row.get("manual")) + "</td></tr>")
            continue
        exit_code = int_or_none(row.get("exit"))
        state = "pass" if exit_code == 0 else "FAIL" if exit_code is not None else "not run"
        cls = "pass" if state == "pass" else "fail" if state == "FAIL" else "muted"
        rows.append(
            "<tr>"
            f"<td><code>{esc(row.get('check', ''))}</code></td>"
            f'<td class="{cls}">{state}</td>'
            f"<td>{esc(exit_code if exit_code is not None else '')}</td>"
            f"<td>{esc(duration(row.get('secs')))}</td>"
            f"<td><code>{esc(short(row.get('tree', ''), 12))}</code></td>"
            f"<td>{esc(short(row.get('log', ''), 80))}</td>"
            "</tr>")
    return ('<table class="proofs"><thead><tr><th>check</th><th>result</th><th>exit</th><th>took</th>'
            "<th>tree</th><th>log</th></tr></thead><tbody>" + "".join(rows) + "</tbody></table>")


def render_scout(scout):
    if not isinstance(scout, dict):
        return ""
    chunks = []
    drift = scout.get("drift")
    if drift:
        if isinstance(drift, str):
            body = f"<p>{esc(drift)}</p>"
        elif isinstance(drift, list) and all(not isinstance(item, (dict, list)) for item in drift):
            body = html_list([str(item) for item in drift])
        else:
            body = f'<pre class="code">{esc(json.dumps(drift, indent=1, ensure_ascii=False))}</pre>'
        chunks.append(card("Drift", body))

    undecided = text_list(scout.get("undecided"))
    if undecided:
        chunks.append(card("Undecided", html_list(undecided)))

    files = scout.get("files_to_change")
    if isinstance(files, list) and files:
        items = []
        for entry in files:
            if isinstance(entry, dict):
                line = f"<code>{esc(entry.get('path', ''))}</code>"
                if entry.get("what"):
                    line += " — " + esc(short(entry["what"], 160))
                if entry.get("in_spec") is False:
                    line += ' <span class="warn">(not in the spec)</span>'
                items.append(line)
            else:
                items.append(esc(entry))
        chunks.append(card("Files to change", '<ul class="scout-files">' + "".join(
            f"<li>{item}</li>" for item in items) + "</ul>"))
    return "\n".join(chunks)


def render_overview(data):
    report = data["report"]
    run = data["run"]
    parts = []

    meta = [
        ("Task", data["task"]),
        ("Repository", data["repo_name"]),
        ("Base", data["base"]),
        ("Worktree", data["worktree"]),
    ]
    parts.append('<div class="card"><h2>Overview</h2><dl class="meta">' + "".join(
        f"<dt>{esc(k)}</dt><dd>{esc(v)}</dd>" for k, v in meta) + "</dl></div>")

    if report is None:
        status_body = '<p class="muted">No valid <code>.orchestra/report.json</code> found.</p>'
    else:
        lines = [f"<p><strong>{esc(report.get('status', 'unknown'))}</strong> — {esc(report.get('summary', ''))}</p>"]
        lines.append(html_list(text_list(report.get("files_changed")), "files"))
        status_body = "\n".join(lines)
    parts.append(card("Report", status_body))

    latest = run["latest"]
    metrics = [("Runs", str(run["runs"])), ("Responses", str(run["responses"])),
               ("Task cost", f"${run['cost']:.4f}")]
    if latest:
        exit_label = "?" if latest["exit"] is None else str(latest["exit"])
        meaning = f" ({latest['meaning']})" if latest["meaning"] else ""
        metrics.append(("Latest run", f"{latest['n']} · exit {exit_label}{meaning}"))
        if latest["secs"] is not None:
            metrics.append(("Latest duration", duration(latest["secs"])))
        metrics.append(("Latest cost", f"${latest['cost']:.4f}"))
    parts.append('<div class="card"><h2>Run</h2><dl class="meta">' + "".join(
        f"<dt>{esc(k)}</dt><dd>{esc(v)}</dd>" for k, v in metrics) + "</dl></div>")

    if report is not None:
        blocking = text_list(report.get("open_questions"))
        parts.append(card(f"BLOCKING questions ({len(blocking)})",
                          html_list(blocking, "blocking") or '<p class="muted">None.</p>'))

        risks = text_list(report.get("risk_notes"))
        parts.append(card(f"RISK NOTES ({len(risks)})",
                          html_list(risks, "risks") or '<p class="muted">None.</p>'))

        assumed = text_list(report.get("assumptions"))
        parts.append(card(f"Assumptions ({len(assumed)})",
                          html_list(assumed, "assumed") or '<p class="muted">None.</p>'))

        outside_scope = text_list(report.get("out_of_scope_needed"))
        parts.append(card(f"Outside scope needed ({len(outside_scope)})",
                          html_list(outside_scope) or '<p class="muted">None.</p>'))

    if data["spec_checked"]:
        outside = data["outside"]
        parts.append(card(f"Outside-path files ({len(outside)})",
                          html_list(outside) or '<p class="muted">All changed files are inside Owns/Touches.</p>'))
    else:
        parts.append(card("Outside-path files",
                          '<p class="muted">Not checked (no Owns/Touches in the spec).</p>'))

    parts.append(card(f"Proof results ({len(data['proofs'])})", proof_table(data["proofs"])))

    if data["spec"]:
        parts.append(card("Spec", '<details open><summary>spec.md</summary><div class="md">'
                          + render_markdown(data["spec"]) + "</div></details>"))
    else:
        parts.append(card("Spec", '<p class="muted">No .orchestra/spec.md found.</p>'))
    return "\n".join(parts)


def render_state(data):
    chunks = []
    if data["state_md"]:
        source = os.path.basename(os.path.dirname(data["state_md_source"])) + "/" + os.path.basename(
            data["state_md_source"])
        chunks.append(card("State", '<div class="md">' + render_markdown(data["state_md"]) + "</div>",
                           source))
    chunks.append(render_scout(data["scout"]))
    return "\n".join(chunk for chunk in chunks if chunk)


def render_source_diff(data):
    chunks = []
    if data["diff_truncated"]:
        chunks.append('<div class="banner">Source diff truncated at 250 KiB. Open the worktree for the full diff.</div>')
    if data["diff_note"]:
        chunks.append(f'<p class="muted">{esc(data["diff_note"])}</p>')
    chunks.append(render_diff(data["diff"]))
    return "\n".join(chunks)


def page(title, repo_name, tabs):
    nav = "".join(
        f'<button class="tab-btn{" active" if i == 0 else ""}" data-tab="{esc(tab_id)}">{esc(label)}</button>'
        for i, (tab_id, label, _panel) in enumerate(tabs))
    panels = "".join(
        f'<section class="tab{" active" if i == 0 else ""}" id="{esc(tab_id)}">{panel}</section>'
        for i, (tab_id, _label, panel) in enumerate(tabs))
    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<style>
:root {{ color-scheme: light dark; --bg:#f7f7f5; --fg:#1d1d1b; --card:#fff; --muted:#6b6b66; --line:#ddd; --accent:#2f6f4e; --add:#d8f5df; --del:#ffe0e0; --hunk:#e8eefc; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#171816; --fg:#ecece7; --card:#20221f; --muted:#a6a79f; --line:#3a3d37; --accent:#8fd3a8; --add:#183d26; --del:#481f1f; --hunk:#1e2c4a; }} }}
body.dark {{ --bg:#171816; --fg:#ecece7; --card:#20221f; --muted:#a6a79f; --line:#3a3d37; --accent:#8fd3a8; --add:#183d26; --del:#481f1f; --hunk:#1e2c4a; color-scheme: dark; }}
body.light {{ --bg:#f7f7f5; --fg:#1d1d1b; --card:#fff; --muted:#6b6b66; --line:#ddd; --accent:#2f6f4e; --add:#d8f5df; --del:#ffe0e0; --hunk:#e8eefc; color-scheme: light; }}
* {{ box-sizing: border-box; }}
body {{ margin:0; background:var(--bg); color:var(--fg); font:15px/1.55 system-ui,-apple-system,"Segoe UI",sans-serif; }}
header {{ display:flex; align-items:center; gap:1rem; padding:1.25rem 2rem; border-bottom:1px solid var(--line); background:var(--card); position:sticky; top:0; z-index:2; }}
header h1 {{ font-size:1.15rem; margin:0; flex:1; }}
header .repo {{ color:var(--muted); font-size:.85rem; }}
button {{ font:inherit; color:inherit; background:var(--card); border:1px solid var(--line); border-radius:6px; padding:.4rem .7rem; cursor:pointer; }}
button:hover {{ border-color:var(--accent); }}
.tabs {{ display:flex; gap:.35rem; flex-wrap:wrap; padding:.75rem 2rem 0; }}
.tab-btn.active {{ border-color:var(--accent); color:var(--accent); }}
main {{ padding:1rem 2rem 3rem; }}
.tab {{ display:none; }}
.tab.active {{ display:block; }}
.card {{ background:var(--card); border:1px solid var(--line); border-radius:10px; padding:1rem 1.25rem; margin:0 0 1rem; }}
.card h2 {{ font-size:1rem; margin:0 0 .6rem; }}
.sub {{ color:var(--muted); font-size:.8rem; margin:-.2rem 0 .6rem; }}
.meta {{ display:grid; grid-template-columns:max-content 1fr; gap:.25rem 1rem; margin:0; }}
.meta dt {{ color:var(--muted); }}
.meta dd {{ margin:0; overflow-wrap:anywhere; }}
ul {{ margin:.25rem 0; padding-left:1.3rem; }}
li {{ margin:.2rem 0; overflow-wrap:anywhere; }}
.blocking li {{ color:#9b2c2c; }}
body.dark .blocking li {{ color:#ff9b9b; }}
.risks li {{ color:#8a5a00; }}
body.dark .risks li {{ color:#e8c170; }}
.warn {{ color:#9b2c2c; }}
.muted {{ color:var(--muted); }}
.pass {{ color:var(--accent); font-weight:600; }}
.fail {{ color:#b02a2a; font-weight:600; }}
table {{ border-collapse:collapse; width:100%; font-size:.86rem; }}
th, td {{ text-align:left; border-bottom:1px solid var(--line); padding:.3rem .45rem; vertical-align:top; }}
code {{ font:.9em ui-monospace,SFMono-Regular,Menlo,monospace; background:rgba(127,127,127,.13); padding:.05rem .25rem; border-radius:3px; overflow-wrap:anywhere; }}
pre.diff, pre.code {{ margin:0; overflow:auto; background:var(--bg); border:1px solid var(--line); border-radius:8px; padding:.75rem; font:12.5px/1.45 ui-monospace,SFMono-Regular,Menlo,monospace; }}
pre.diff span {{ display:block; white-space:pre; }}
.d-add {{ background:var(--add); }}
.d-del {{ background:var(--del); }}
.d-hunk {{ background:var(--hunk); color:var(--muted); }}
.d-file {{ color:var(--muted); font-weight:600; }}
.banner {{ background:#fff3cd; color:#5c4500; border:1px solid #e4c96b; border-radius:8px; padding:.6rem .8rem; margin:0 0 .75rem; }}
body.dark .banner {{ background:#3d3416; color:#f4dfa0; border-color:#6b5a22; }}
.md h1, .md h2, .md h3 {{ font-size:1.05rem; margin:1rem 0 .4rem; }}
.md h1 {{ font-size:1.2rem; }}
.md blockquote {{ margin:.5rem 0; padding:.2rem .8rem; border-left:3px solid var(--line); color:var(--muted); }}
details summary {{ cursor:pointer; color:var(--muted); margin-bottom:.5rem; }}
</style>
</head>
<body>
<header>
  <h1>{esc(title)}</h1>
  <span class="repo">{esc(repo_name)}</span>
  <button id="theme" type="button" title="Toggle dark/light">Theme</button>
</header>
<nav class="tabs">{nav}</nav>
<main>{panels}</main>
<script>
(function () {{
  var buttons = Array.prototype.slice.call(document.querySelectorAll('.tab-btn'));
  buttons.forEach(function (button) {{
    button.addEventListener('click', function () {{
      buttons.forEach(function (other) {{ other.classList.remove('active'); }});
      document.querySelectorAll('.tab').forEach(function (panel) {{ panel.classList.remove('active'); }});
      button.classList.add('active');
      var panel = document.getElementById(button.dataset.tab);
      if (panel) panel.classList.add('active');
    }});
  }});
  try {{
    var saved = localStorage.getItem('orchestra-theme');
    if (saved) document.body.classList.add(saved);
  }} catch (e) {{}}
  document.getElementById('theme').addEventListener('click', function () {{
    var dark = document.body.classList.contains('dark') ||
      (!document.body.classList.contains('light') && window.matchMedia &&
       window.matchMedia('(prefers-color-scheme: dark)').matches);
    var next = dark ? 'light' : 'dark';
    document.body.classList.remove('dark', 'light');
    document.body.classList.add(next);
    try {{ localStorage.setItem('orchestra-theme', next); }} catch (e) {{}}
  }});
}})();
</script>
</body>
</html>
"""


def render_artifact(data):
    tabs = [("overview", "Overview", render_overview(data))]
    state = render_state(data)
    if state:
        tabs.append(("state", "State", state))
    tabs.append(("diff", "Source Diff", render_source_diff(data)))
    if data["rendered_diff"].strip():
        tabs.append(("rendered", "Rendered Diff", render_diff(data["rendered_diff"])))
    title = f"{data['task']} · {data['repo_name']}"
    return page(title, data["repo_name"], tabs)


# ---- local storage: one flat folder, index.html, manifest.json -----------------------------------------------------

def write_text(path, text):
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".orchestra-artifact.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass


def unique_artifact_path(out_dir, repo_name, task, when):
    while True:
        name = f"{safe_name(repo_name)}-{safe_name(task)}-{when.strftime('%Y%m%d-%H%M%S')}.html"
        path = os.path.join(out_dir, name)
        if not os.path.exists(path):
            return path, when
        when += dt.timedelta(seconds=1)


def load_manifest(out_dir):
    data = load_json(os.path.join(out_dir, "manifest.json"))
    if isinstance(data, dict) and isinstance(data.get("artifacts"), list):
        return [record for record in data["artifacts"] if isinstance(record, dict)]
    return []


def save_local(out_dir, html_text, data, mode, url=""):
    os.makedirs(out_dir, exist_ok=True)
    now = dt.datetime.now()
    path, stamped = unique_artifact_path(out_dir, data["repo_name"], data["task"], now)
    latest = os.path.join(out_dir, f"{safe_name(data['repo_name'])}-{safe_name(data['task'])}-latest.html")

    write_text(path, html_text)
    try:
        shutil.copyfile(path, latest)
    except OSError:
        pass

    created = dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    report = data["report"] or {}
    record = {
        "file": os.path.basename(path),
        "path": path,
        "task": data["task"],
        "repo": data["repo_name"],
        "base": data["base"],
        "created": created,
        "stamp": stamped.strftime("%Y%m%d-%H%M%S"),
        "status": report.get("status", ""),
        "cost": data["run"]["cost"],
        "mode": mode,
        "url": url,
    }
    records = [record] + [r for r in load_manifest(out_dir) if r.get("file") != record["file"]]
    records.sort(key=lambda r: str(r.get("created", "")), reverse=True)
    write_manifest(out_dir, records)
    write_index(out_dir, records)
    return path, latest, os.path.join(out_dir, "index.html")


def write_manifest(out_dir, records):
    write_text(os.path.join(out_dir, "manifest.json"),
               json.dumps({"artifacts": records}, indent=1, ensure_ascii=False) + "\n")


def write_index(out_dir, records):
    rows = []
    for record in records:
        file = str(record.get("file") or os.path.basename(str(record.get("path", ""))))
        if not file or not os.path.isfile(os.path.join(out_dir, file)):
            continue
        link = esc(urllib.parse.quote(file))
        url = http_url(str(record.get("url") or ""))
        remote = f' · <a href="{esc(url)}">remote</a>' if url else ""
        rows.append(
            f'<li><a href="{link}">{esc(record.get("task", file))}</a>'
            f' <span class="muted">{esc(record.get("repo", ""))} · {esc(record.get("created", ""))}</span>'
            f' <span class="status">{esc(record.get("status", ""))}</span>'
            f' <span class="muted">${number(record.get("cost")):.4f}</span>{remote}</li>')
    body = "\n".join(rows) or '<li class="muted">No artifacts yet.</li>'
    title = f"orchestra artifacts · {len(rows)}"
    write_text(os.path.join(out_dir, "index.html"), f"""<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>{esc(title)}</title>
<style>
:root {{ color-scheme: light dark; --bg:#f7f7f5; --fg:#1d1d1b; --card:#fff; --muted:#6b6b66; --line:#ddd; --accent:#2f6f4e; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg:#171816; --fg:#ecece7; --card:#20221f; --muted:#a6a79f; --line:#3a3d37; --accent:#8fd3a8; }} }}
body {{ margin:0; padding:2rem; background:var(--bg); color:var(--fg); font:15px/1.6 system-ui,-apple-system,"Segoe UI",sans-serif; }}
h1 {{ font-size:1.3rem; margin:0 0 .25rem; }}
p.intro {{ color:var(--muted); margin:0 0 1.5rem; }}
ul {{ list-style:none; margin:0; padding:0; display:grid; gap:.5rem; }}
li {{ background:var(--card); border:1px solid var(--line); border-radius:10px; padding:.75rem 1rem; }}
a {{ color:var(--accent); font-weight:600; text-decoration:none; overflow-wrap:anywhere; }}
a:hover {{ text-decoration:underline; }}
.muted {{ color:var(--muted); font-weight:400; font-size:.85rem; }}
.status {{ font-size:.8rem; border:1px solid var(--line); border-radius:999px; padding:.05rem .45rem; }}
</style></head>
<body>
<h1>{esc(title)}</h1>
<p class="intro">Newest first. Every orchestra run or scout task saved on this machine.</p>
<ul>
{body}
</ul>
</body>
</html>
""")


# ---- remote Artifact Server ---------------------------------------------------------------------------------------

class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect with the bearer token attached."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def remote_origin():
    return (os.environ.get("ORCHESTRA_ARTIFACT_SERVER_ORIGIN")
            or os.environ.get("ARTIFACT_SERVER_ORIGIN") or "").strip()


def remote_token():
    token = (os.environ.get("ARTIFACT_SERVER_AGENT_TOKEN") or "").strip()
    if token:
        return token
    command = (os.environ.get("ORCHESTRA_ARTIFACT_TOKEN_CMD") or "").strip()
    if not command:
        return ""
    try:
        result = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def publish_remote(origin, token, path, task):
    """Best-effort publish. Returns (url, reason); never logs or returns the token."""
    if not origin:
        return "", "no origin"
    if not re.match(r"^https?://", origin, re.I):
        return "", "origin is not http(s)"

    executable = shutil.which("artifactserver")
    if executable:
        env = dict(os.environ)
        env["ARTIFACT_SERVER_ORIGIN"] = origin
        env["ORCHESTRA_ARTIFACT_SERVER_ORIGIN"] = origin
        env["ARTIFACT_SERVER_AGENT_TOKEN"] = token
        try:
            result = subprocess.run([executable, "publish", path], env=env,
                                    capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            result = None
        if result is not None and result.returncode == 0:
            for line in reversed(result.stdout.splitlines()):
                line = line.strip()
                if not re.match(r"^https?://", line):
                    continue
                if token and token in line:
                    return "", "artifactserver returned the token in its URL"
                return line, ""
            return origin, ""

    with open(path, "rb") as f:
        payload_bytes = f.read()
    request = urllib.request.Request(
        origin,
        data=payload_bytes,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "text/html; charset=utf-8",
            "User-Agent": "orchestra-artifact",
            "X-Orchestra-Task": task,
        },
    )
    opener = urllib.request.build_opener(NoRedirect)
    try:
        with opener.open(request, timeout=10) as response:
            status = getattr(response, "status", 0)
            body = response.read()
    except urllib.error.HTTPError as e:
        return "", f"HTTP {e.code}"
    except (urllib.error.URLError, OSError, ValueError) as e:
        reason = short(getattr(e, "reason", e), 120)
        if token:
            reason = reason.replace(token, "***")
        return "", reason
    if status < 200 or status >= 300:
        return "", f"HTTP {status}"
    url = ""
    try:
        payload = json.loads(body.decode("utf-8", errors="replace"))
        if isinstance(payload, dict):
            for key in ("url", "review_url", "html_url", "href"):
                if isinstance(payload.get(key), str) and payload[key]:
                    url = payload[key]
                    break
    except ValueError:
        pass
    if url and token and token in url:
        return "", "server returned the token in its URL"
    return url or origin, ""


def open_target(target):
    for name in ("xdg-open", "open"):
        executable = shutil.which(name)
        if not executable:
            continue
        try:
            subprocess.Popen([executable, target], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return
        except OSError:
            continue


# ---- CLI ----------------------------------------------------------------------------------------------------------

def main(argv):
    ap = argparse.ArgumentParser(prog="artifact.py")
    ap.add_argument("--repo", required=True, help="repository directory")
    ap.add_argument("--task", required=True, help="task id")
    ap.add_argument("--base", default="origin/main", help="ref to diff against (default: origin/main)")
    ap.add_argument("--worktree", help="task worktree directory")
    ap.add_argument("--scout-dir", help=".scout/<task> directory")
    ap.add_argument("--rendered-diff-file", help="precomputed rendered diff text")
    ap.add_argument("--out-dir", help="local artifacts folder")
    ap.add_argument("--local", action="store_true", help="force the local folder, even with a server configured")
    ap.add_argument("--open", action="store_true", help="open the artifact when possible")
    ap.add_argument("--json", action="store_true", help="print a JSON summary to stdout")
    args = ap.parse_args(argv)

    if not os.path.isdir(args.repo):
        print(f"artifact: no repository at {args.repo}", file=sys.stderr)
        return 2
    if not args.task.strip():
        print("artifact: task id is empty", file=sys.stderr)
        return 2

    out_dir = args.out_dir or os.environ.get("ORCHESTRA_ARTIFACTS_DIR") \
        or os.path.expanduser("~/.local/share/orchestra/artifacts")

    data = collect(args)
    html_text = render_artifact(data)

    origin = "" if args.local else remote_origin()
    token = remote_token() if origin else ""
    remote_url = ""
    mode = "local"

    # The local copy always exists first: a remote failure must never lose the review artifact.
    path, _latest, index = save_local(out_dir, html_text, data, "local")

    if origin and token:
        remote_url, remote_reason = publish_remote(origin, token, path, data["task"])
        if remote_url:
            mode = "remote"
            # Record the remote URL against this artifact in the manifest and index.
            records = load_manifest(out_dir)
            for record in records:
                if record.get("file") == os.path.basename(path):
                    record["mode"] = "remote"
                    record["url"] = remote_url
            write_manifest(out_dir, records)
            write_index(out_dir, records)
        else:
            warning = f"remote publish unavailable ({remote_reason}); saved locally: {path}"
            print(warning, file=sys.stderr)
    elif origin and not token and not args.local:
        print(f"remote publish unavailable (no agent token); saved locally: {path}", file=sys.stderr)

    if args.open:
        open_target(http_url(remote_url) or "file://" + os.path.abspath(path))

    if args.json:
        print(json.dumps({
            "mode": mode,
            "path": path,
            "url": remote_url or None,
            "index": index,
            "task": data["task"],
            "repo": data["repo_name"],
        }, ensure_ascii=False))
    else:
        if remote_url:
            print(f"remote artifact: {remote_url}")
        print(f"local artifact: {path}")
        print(f"index: {index}")
        print(f"file://{os.path.abspath(path)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
