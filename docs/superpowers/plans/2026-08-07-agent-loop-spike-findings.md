# Agent-loop composition spike findings

Task 1 of `docs/superpowers/plans/2026-08-07-agent-loop.md`. This is a spike
(GATE): it proves or disproves the assumptions the rest of the plan rests on.
It produces findings, not production code. Every command below was run from
the repo root on branch `tylervick/agent-loop-spec`, against a live
`orca` runtime (`orca status` reported `runtimeReachable: true`).

## Step 1: Orca worker composition end to end

Ran the exact three-command sequence from the brief.

```
orca orchestration run-create --objective "agent-loop spike" --json
```

Returned (trimmed):

```json
{
  "result": {
    "run": {
      "id": "run_29632eb237a8",
      "objective": "agent-loop spike",
      ...
    }
  }
}
```

**The run id is nested at `.result.run.id`, not a top-level `.result.runId`.**

```
orca orchestration task-create --spec "Print the current git branch, then stop." \
  --run run_29632eb237a8 --json
```

Returned (trimmed):

```json
{
  "result": {
    "task": {
      "id": "task_9e8c3e36dfb4",
      "status": "ready",
      "run_id": "run_29632eb237a8",
      ...
    }
  }
}
```

**Same pattern: the task id is nested at `.result.task.id`, snake_case
`run_id` inside the task object.**

```
orca orchestration worker-start --task task_9e8c3e36dfb4 --worktree current \
  --agent claude --timeout-ms 120000 --json
```

Returned (trimmed):

```json
{
  "result": {
    "runId": "run_29632eb237a8",
    "taskId": "task_9e8c3e36dfb4",
    "dispatchId": "ctx_47796e3c3250",
    "state": "ready",
    "stage": "input_accepted",
    "timeoutMs": 120000,
    "effects": [
      {"kind": "terminal", "role": "agent", "action": "created", "id": "term_7966a040-...", "surface": "visible"},
      {"kind": "dispatch_input", "role": "agent", "id": "term_7966a040-...", "state": "accepted"}
    ]
  }
}
```

**`worker-start` returns flat, camelCase `runId` / `taskId` / `dispatchId` at
the top level of `.result` — inconsistent with `run-create` and `task-create`,
which nest their ids one level down under `run.id` / `task.id`. Any script
that parses these with `jq` needs three different paths, not one.** This
directly matters for Task 3 (`loop-prompt.md`), which was going to assume a
single `.id`/`.runId`/`.taskId`/`.dispatchId` convention.

**The mechanical chaining worked** — all three commands returned `"ok":
true` and every id fed cleanly into the next command with no errors.

**The dispatched worker never executed the task.** `worker-read` (see Step 2)
was polled repeatedly for over 100 seconds (well past the requested
120000ms timeout — see Step 3 for why that number is irrelevant) and the
worker's terminal never advanced past Claude Code's cold-start screen:

```
 ▐▛███▜▌   Claude Code v2.1.224
▝▜█████▛▘  Opus 5 (1M context) with xhigh effort · Claude Max
  ▘▘ ▝▝    ~/Documents/doom-ios-2026
                                                                               c
trl+g to edit in Sublime Text
            ◉──────────────────────────────────────────────────────────────────x
high · /───────────────────────────────────────────────────────────────────────f
for⏵ bypass permissions on (shift+tab to cycle)
```

This is the empty startup screen with an idle, empty prompt box — no visible
trace of "Print the current git branch, then stop." ever being typed or
submitted, even though `worker-start`'s own response reported
`"dispatch_input": {"state": "accepted"}`. Across every re-read, the returned
`nextCursor` never advanced, and `orca orchestration check --run
run_29632eb237a8 --all --json` returned zero messages the entire time — no
`worker_done`, no escalation, nothing. The worker sat idle indefinitely. This
was reproduced identically on the second worker started in Step 3 (different
task, different terminal handle, same frozen cold-start screen). Root cause
was not chased further (out of scope for a composition spike — the brief is
explicit: prove or disprove, don't invent workarounds), but one relevant
environmental data point: every ambient `claude` process already running on
this machine (`ps aux`) was launched with an explicit
`--dangerously-skip-permissions` flag; neither of `worker-start`'s two
freshly-created agent terminals had that, and `orca orchestration worker-start
--help`/its schema (`orca agent-context --json`) exposes no flag to request
it. Whatever is stalling the terminal, there is no documented `worker-start`
knob that avoids it.

Both stuck workers had to be force-terminated with `worker-stop` (see
Cleanup).

## Step 2: Reading the worker's output

```
orca orchestration worker-read --dispatch ctx_47796e3c3250 --json
```

Returned:

```json
{
  "result": {
    "dispatchId": "ctx_47796e3c3250",
    "source": "terminal",
    "sourceIdentity": "xvEsj0_YcAnGeTs057AkDluB5xSbiO13",
    "terminal": {
      "handle": "term_7966a040-...",
      "status": "running",
      "tail": ["... 8 raw lines of terminal text ..."],
      "truncated": false,
      "limited": false,
      "oldestCursor": "0",
      "nextCursor": "22",
      "latestCursor": "22",
      "returnedLineCount": 8
    },
    "cursor": "owr1_...(opaque base64)...",
    "status": {"worker": "ready", "terminal": "running"},
    "fallbackReason": "session_not_reported",
    "warnings": []
  }
}
```

**Findings for Task 5's report format:**

- `worker-read` returns **raw terminal text** (a `tail` array of literal
  screen lines), not structured conversation turns. The `source` field was
  `"terminal"` in every call we made — the schema also documents a
  `"transcript"` source, gated by `fallbackReason: "session_not_reported"`
  meaning Orca never saw a hook-reported Claude Code session for either
  worker (consistent with Step 1's finding that neither worker ever actually
  ran). We could not exercise the `transcript` path in this spike.
- **No turn count or token count field exists anywhere in this payload**,
  in either the terminal or (per the command's own documented notes) the
  transcript path.
- **Wall-clock is not derivable from `worker-read`** either — there's no
  timestamp on the response, only an opaque `cursor`.
- After the dispatch was stopped, `worker-read` on the same dispatch returned
  `"status": {"worker": "stopped", "terminal": "exited"}` with an **empty**
  tail (`returnedLineCount: 0`) — the archived output was blank, not
  partial.

**Conclusion for Task 5 (`loop-report.sh`): `turns` and `wall_clock_seconds`
are not available from Orca in any form.** The coordinator must time the
worker itself with `date +%s` around the `worker-start`/`worker-read` loop,
exactly as the brief anticipated as the fallback. `turns` has no fallback at
all inside Orca; if the plan wants a turn count, the coordinator will have to
approximate it by counting turn markers in whatever the worker itself writes
into the trial record, since Orca cannot supply it.

## Step 3: Does the timeout actually fire?

```
orca orchestration task-create --spec "Sleep for 5 minutes, then print done." \
  --run run_29632eb237a8 --json
# -> task_517f02db47a1

orca orchestration worker-start --task task_517f02db47a1 --worktree current \
  --agent claude --timeout-ms 30000 --json
# -> dispatchId ctx_76dbc92c2ea6, dispatched_at 07:23:04
```

Polled `orca orchestration worker-show --dispatch ctx_76dbc92c2ea6 --json`
repeatedly from dispatch time to 07:25:02 (**118 seconds elapsed against a
declared 30000ms / 30s timeout — nearly 4x over**):

| time since dispatch | `worker.state` | `worker.stage` | `dispatch.status` |
| --- | --- | --- | --- |
| ~16s | ready | input_accepted | dispatched |
| ~46s | ready | input_accepted | dispatched |
| ~58s | ready | input_accepted | dispatched |
| ~118s | ready | input_accepted | dispatched |

**No state ever changed on its own.** `orca orchestration check --run
run_29632eb237a8 --all --json` returned `{"messages": [], "count": 0}` the
entire time — no timeout notification was ever delivered to the coordinator's
inbox. The only way to end the dispatch was an explicit
`orca orchestration worker-stop --dispatch ctx_76dbc92c2ea6 --json`, which
returned immediately:

```json
{
  "result": {
    "dispatchId": "ctx_76dbc92c2ea6",
    "state": "stopped",
    "alreadySettled": false,
    "processAction": "closed_agent_terminal",
    "close": {"handle": "term_584a292c-...", "ptyKilled": true}
  }
}
```

After that, `worker-show`/`worker-read` reported `"worker": "stopped"`,
`"terminal": "exited"` (a clean, unambiguous terminal-vs-running signal) but
only because we forced it.

**Conclusion: `--timeout-ms` on `worker-start` does not autonomously enforce
anything.** It is accepted and echoed back (`"timeoutMs": 30000`) but nothing
in Orca polls or kills the dispatch when it elapses. The coordinator cannot
treat "timed out" as a state Orca will ever report on its own; it must track
its own wall-clock deadline (`date +%s` at dispatch time, compare on each
poll) and call `worker-stop` itself once the deadline passes.
`worker-abandon` was not needed — `worker-stop` cleanly killed the pty in one
call (`ptyKilled: true`).

**This, combined with Step 1's finding, means the coordinator/worker
composition itself does not work as designed:** a worker that never starts
working and a timeout that never fires are both failures of the exact
mechanism Task 3's `loop-prompt.md` was going to depend on.

## Step 4: `--precheck` gating semantics

```
orca automations create --name "spike-precheck-exit1" --trigger daily \
  --precheck "bash -c 'exit 1'" --prompt "Print OK" --provider claude \
  --repo path:/Users/tyler/Documents/doom-ios-2026 --disabled --json
# -> automation id (nested, same pattern as Step 1) befdf522-fd27-4ab3-bc93-134fc56a3de1

orca automations run befdf522-fd27-4ab3-bc93-134fc56a3de1 --json
# -> run status "dispatching", precheckResult: null

orca automations runs --id befdf522-fd27-4ab3-bc93-134fc56a3de1 --json
```

After ~62 seconds the run settled:

```json
{
  "status": "completed",
  "outputSnapshot": {"format": "plain_text", "content": "OK", "truncated": false},
  "precheckResult": null,
  "error": null
}
```

**The agent ran anyway and printed "OK" — despite the precheck being `exit
1`.** `precheckResult` was `null` throughout, never populated.

Repeated with the passing variant for completeness:

```
orca automations create --name "spike-precheck-exit0" --trigger daily \
  --precheck "bash -c 'echo 42; exit 0'" --prompt "Print OK" --provider claude \
  --repo path:/Users/tyler/Documents/doom-ios-2026 --disabled --json
orca automations run 7b761fc8-e636-4ec7-b9f5-d714a6178f4f --json
```

Same result: `status: "completed"`, `outputSnapshot.content: "OK"`,
`precheckResult: null`.

**Conclusion: manually triggering a disabled automation with `orca
automations run <id>` does not exercise the precheck at all — for either
exit code.** The command's own schema notes say precheck runs "before
**scheduled** runs," and this is exactly consistent with that: `run <id>` is
an explicit manual override that appears to skip the gate entirely. This
means **the exact test method specified in the brief cannot answer the
question it was designed to answer.** Confirming real precheck-gating
behavior (skip on nonzero exit, proceed on zero) and whether precheck stdout
reaches the agent's prompt would require waiting for/forcing an actual
*scheduled* fire, which is outside a spike's time budget and was not
attempted.

**Open question, with the brief's own documented fallback already in
hand:** since precheck stdout pass-through could not be observed either way,
`Scripts/loop-precheck.sh` cannot be assumed to hand the chosen issue number
to the coordinator through stdout. Task 3's coordinator should plan to
re-run its own selection logic rather than trust an unverified stdout
channel, exactly as the brief's fallback anticipates.

Both spike automations were removed per Step 4's instructions (see
Cleanup) — this surfaced an unrelated but relevant finding: `automations
remove` does **not** clean up the per-run git worktree/branch it created
under `new_per_run` workspace mode (see Cleanup below).

## Step 5: CodeRabbit comment shape on PR #36

```
gh pr view 36 --json reviews,comments --jq '.reviews[] | {author: .author.login, state: .state, body: .body[0:400]}'
gh api repos/tylervick/waddle/pulls/36/comments --jq '.[] | {user: .user.login, body: .body[0:300]}'
```

The review summary line: `"Actionable comments posted: 6"`, `state:
"CHANGES_REQUESTED"`, author `coderabbitai`.

All 6 individual review comments (`gh api .../pulls/36/comments`, 6 total)
open with the exact same three-part pipe-delimited prefix pattern:

```
_📐 Maintainability & Code Quality_ | _🟡 Minor_ | _⚡ Quick win_
_📐 Maintainability & Code Quality_ | _🟡 Minor_ | _⚡ Quick win_
_🎯 Functional Correctness_ | _🟡 Minor_ | _⚡ Quick win_
_🗄️ Data Integrity & Integration_ | _🟠 Major_ | _🏗️ Heavy lift_
_🗄️ Data Integrity & Integration_ | _🟡 Minor_ | _⚡ Quick win_
_🎯 Functional Correctness_ | _🟠 Major_ | _⚡ Quick win_
```

**This repo's CodeRabbit configuration does not use the `_⚠️ Potential
issue_` / `_🛠️ Refactor suggestion_` markers the brief's phrasing assumed —
those strings do not appear anywhere in the 6 comments.** Instead it emits a
`_<category>_ | _<severity>_ | _<effort>_` triple, where the **severity**
field is the reliable, machine-readable, grep-able token: `🔴 Critical`
(not observed here, but implied by the color scheme), `🟠 Major` (2 of 6),
`🟡 Minor` (4 of 6). Recommended grep for "does this PR have
actionable-and-serious CodeRabbit findings":

```bash
gh api repos/tylervick/waddle/pulls/<N>/comments --jq '.[].body' | grep -c '🟠 Major\|🔴 Critical'
```

A plain count of all review comments (`gh api .../comments --jq 'length'` →
`6`) is the correct fallback if the severity marker format ever changes, per
the brief's own suggested fallback.

## Surprises (not part of the five questions, but relevant to later tasks)

- **Inconsistent id nesting across Orca commands** (Step 1) — `run-create`
  and `task-create` nest under `.result.<noun>.id`; `worker-start` and
  `automations create`/`automations run` return `.result.automation.id` /
  `.result.run.id` for automations but flat `.result.runId` for the
  orchestration worker path. Any parsing script needs per-command paths, not
  one convention.
- `orca orchestration worker-show --json`'s raw output contains literal
  unescaped control characters inside the terminal preview string, which
  broke Python's strict `json.loads` (`Invalid control character`). Had to
  parse with `strict=False`. Worth checking whether `jq` tolerates this
  before Task 3/5 build scripts around it.
- `orca orchestration worker-release --dispatch <id>` refuses
  (`dispatch_inactive`) on a dispatch you already ended with `worker-stop`
  — it's only for a dispatch that reached `succeeded`/`failed` on its own.
  `worker-stop` already fully kills the pty (`"ptyKilled": true`), so no
  separate release call is needed or possible after a manual stop.
- Both spike automations (`--repo path:/Users/tyler/Documents/doom-ios-2026`,
  currently GitHub `tylervick/waddle`) resolved their `runContext`/
  `sourceContext` to `"projectId": "github:tylervick/boombox"` /
  `"providerIdentity": {"owner": "tylervick", "repo": "boombox"}` — an
  apparently stale project mapping (presumably from before the repo was
  renamed). Not chased further; worth a note for whoever wires the real
  automation in Task 6, since a wrong `providerIdentity` could misdirect
  `gh`-based steps that rely on Orca's resolved repo context instead of the
  worktree's own `git remote`.
- `automations remove` deletes the automation record but does **not** clean
  up the git worktree/branch it created for a `new_per_run` workspace-mode
  run. Two orphaned worktrees
  (`/Users/tyler/orca/workspaces/doom-ios-2026/auto-spike-precheck-exit{0,1}-run-1-...`)
  and their branches
  (`tylervick/auto-spike-precheck-exit{0,1}-run-1-...`) were left behind and
  had to be removed manually with `git worktree remove --force` and `git
  branch -D`.

## Cleanup

Everything created during this spike was torn down:

| Resource | Action | Result |
| --- | --- | --- |
| Dispatch `ctx_47796e3c3250` (Step 1 worker) | `orca orchestration worker-stop` | `state: stopped`, `ptyKilled: true` |
| Dispatch `ctx_76dbc92c2ea6` (Step 3 worker) | `orca orchestration worker-stop` | `state: stopped`, `ptyKilled: true` |
| Task `task_9e8c3e36dfb4` | `orca orchestration task-update --status failed` | closed |
| Task `task_517f02db47a1` | `orca orchestration task-update --status failed` | closed |
| Automation `befdf522-...` (spike-precheck-exit1) | `orca automations remove` | `removed: true` |
| Automation `7b761fc8-...` (spike-precheck-exit0) | `orca automations remove` | `removed: true` |
| Worktree `auto-spike-precheck-exit0-run-1-...` | `git worktree remove --force` | removed |
| Worktree `auto-spike-precheck-exit1-run-1-...` | `git worktree remove --force` | removed |
| Branch `tylervick/auto-spike-precheck-exit0-run-1-...` | `git branch -D` | deleted |
| Branch `tylervick/auto-spike-precheck-exit1-run-1-...` | `git branch -D` | deleted |

Orchestration run `run_29632eb237a8` itself was left as-is — it is a
lightweight namespace record with no live process attached, and no
`run-delete`/`run-stop` command exists in `orca agent-context --json`'s
command list. `git status` and `git worktree list` were confirmed clean of
spike artifacts afterward.

## Verdict

**COMPOSITION FAILED — the worker never executes its task, and the declared
timeout never fires to recover from that.**

Per the brief: if any of Steps 1–3 fails, the verdict is FAILED regardless of
Steps 4/5, because the coordinator/worker split is the architecture. Both
Step 1 and Step 3 failed:

- Step 1: the exact `run-create` → `task-create` → `worker-start` sequence
  chains correctly (ids flow, no errors), but the resulting worker terminal
  never advances past Claude Code's cold-start screen. Reproduced on both
  workers started in this spike. `worker-read`/`worker-show` showed zero
  progress for 100+ seconds; `orchestration check` delivered zero messages.
- Step 3: `--timeout-ms` is accepted and echoed but is not self-enforcing.
  The declared 30-second timeout was still not reflected in any state field
  or inbox message 118 seconds later (nearly 4x over). The dispatch had to be
  killed manually with `worker-stop`.

STOP. Do not proceed to Task 2. The documented fallback (spec shape A: a
single automation whose agent does the work and writes its own record, with
the precheck stamping a run-start marker so an unfinished stamp registers as
a failed trial) needs its own plan — escalate rather than improvising a way
around the worker composition.

Steps 4 and 5, run for completeness per the brief, surfaced their own open
questions independent of the Step 1/3 failure:

- Step 4: manually triggering an automation bypasses `--precheck` entirely
  (observed for both a failing and a passing precheck), so the exact and/or
  skip semantics, and precheck-stdout pass-through, remain unverified.
- Step 5: CodeRabbit's severity marker exists and is reliable, but it is
  `_🟠 Major_` / `_🟡 Minor_` (a category/severity/effort triple), not the
  `_⚠️ Potential issue_` string the brief's phrasing assumed.
