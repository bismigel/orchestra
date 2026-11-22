# Planning guide: `plan` and `refine`

For the orchestrating agent. Workers do better work from better specs; this is how specs get good. The why is in
[proposals/0001](proposals/0001-plan-and-refine.md). Templates are in [`templates/`](../templates/).

## `plan`: a new project (or a major new phase)
Lead a planning session with the human. Its output is a **planning pack** in the repository, which is also the state:
the session can stop at any checkpoint and resume from the files.

| Path | From template | Phase |
|---|---|---|
| `docs/plan/brief.md` | `brief.md` | Discover |
| `docs/plan/decisions.md` | `decisions.md` | Decide (and every phase after) |
| `docs/plan/scope.md` | `scope.md` | Decide |
| `docs/plan/architecture.md` | `architecture.md` | Decide |
| `docs/plan/wireframes/*.html` | `wireframe.html` | Design |
| `docs/work/BOARD.md`, `docs/work/tasks/Txx-*.md` | `task.md` | Decompose |
| `docs/work/lessons.md` | `lessons.md` | after every landed task |
| `AGENTS.md` (or `CLAUDE.md`) | | Check |
| `.orchestra/config.env` | `config/config.example.env` | Check |

### 1. Discover
Ask only what the human knows and the repository can't tell you. Rounds of **at most four questions**, each with a
recommended answer the human can just accept. Cover: who uses it and for what, what "working" looks like, budget and
deadline, hosting, data sensitivity (personal data? money?), hard constraints, what it must not do. Write
`brief.md`. **Checkpoint:** the human confirms the brief.

### 2. Decide
Propose, don't ask: the stack, the architecture, the data and security rules, the MVP cut line. Each becomes a row in
`decisions.md` (D1…Dn) with the reason and the rejected alternatives. Bring the human only the decisions that need
them (product, money, risk), with a recommendation each. Write `scope.md` and `architecture.md`; every rule in
architecture's "Hard rules" must be testable. **Checkpoint:** decisions approved; approved ones are frozen.

### 3. Design
One wireframe per MVP screen from `wireframe.html`: real content, empty and error states, phone width, both themes.
Number every element that matters and map each number to a story and any rule. APIs and CLIs get request/response or
command transcripts instead. **Checkpoint:** the human has looked at them (send the file path or a preview link).

### 4. Decompose
Turn stories into tasks of one worker run each (rule of thumb ≤ 8 files, ≤ 400 changed lines). For each: delegation
class, Owns (disjoint unless chained), Touches with rules, decisions, worker-runnable acceptance, orchestrator checks,
out of scope. Group into waves; chain tasks that must edit the same file. Contracts (shared interfaces, schema,
deploy config) get their own tasks done by the orchestrator first.

### 5. Check
Run `refine all`. Write `AGENTS.md`/`CLAUDE.md` from decisions and hard rules, and `.orchestra/config.env`. The pack
is done when the first wave is ready and `orchestra-task lint` passes.

## `refine`: make tasks ready
`refine <task>`, `refine <wave>` or `refine all`. Run it before launching workers, after any decision changes, and on a
task that came back with open questions.

1. Run `orchestra-task lint <ids>` and fix everything it reports (the mechanical half).
2. For each task, check the judgment half of the **definition of ready**:
   - The goal states the **user-visible result** (what changes for the person using it), not only markup or code.
   - **Every decision** the task needs is written as a rule. Search the spec for "should", "maybe", "or", "decide",
     "appropriate": each is a judgment call to settle now.
   - `split` tasks: the risky cases are **test rows you wrote** (input, exact expected output), including negatives:
     what must not change.
   - **Paths hold what the spec says.** Open each one: the page, handler or test the spec means really lives there
     (a spec that names a page but not the file it lives in sends the worker somewhere else).
   - **Tests that assert behaviour this task changes** are listed in Touches (grep for the strings and markup it
     changes).
   - **Visual and live checks** are orchestrator checks, never worker acceptance.
   - The spec matches the **current base branch** (decisions or files changed since it was written?).
   - It fits one worker run; otherwise split it into chained tasks.
3. Read `docs/work/lessons.md` and apply every rule that fits.
4. Output per task: the rewritten spec, **ready / not ready**, and the decisions still needed, asked as questions with
   a recommended answer. Set `status: ready` only when it is.

## After each landed task
Add a line to `docs/work/lessons.md` for every spec gap the review found: what the spec missed, and the rule that
would have caught it. `refine` reads that file, so the checklist grows from real misses.
