# Pipeline contract — generic base (no product content)

This repository is a **fileless, bus-backed delivery pipeline**. Product deltas
live only in the project adapter (`.pipeline-project/`); this file defines the
mechanism every adapter inherits.

## Configuration architecture

```
pipeline-global/                       # SHARED mechanism (single source of truth)
├── agents/base/      # orchestrator, explore, task-allocator, implementer, verifier (generic)
├── skills/pipeline-*/ # generic skill bodies (no product refs)
├── services/         # zed-mcp-v4, indexer-v4, memory-bus, shared
├── scripts/          # start-*, pipeline-health.sh, sync-*, lint-*
├── config/           # mcp.env, ports.env.example, project.env.example
├── docs/             # adapter-authoring.md (overlay contract, placeholders, setup flow)
├── AGENTS.base.md    # this contract
└── VERSION            # release pin source (PIPELINE_REF)
```

- Agent prompts live only in `agents/base/`; project deltas live in
  `.pipeline-project/agents/*-overlay.md` (fragments) + `roles.conf` aliases
  (e.g. `android-dev=implementer` renders the base implementer + overlay under
  the project's implementer name).
- Editor mirrors (`.opencode/agents/`, `.zed/agents/`) are rendered by
  `scripts/sync-all-agents.sh` (`--base-dir` + `--overlay-dir` merge).
- `opencode.json` points at the adapter prompts and declares
  `instructions: ["AGENTS.base.md"]` (or the adapter's composed contract).
- **No `.pipeline/` directory exists at runtime.** All state, findings, tasks,
  handoffs, and reports live in `TodoWrite` + Redis bus + memory/knowledge
  stores. Do not create `.pipeline/**` files.

## Pipeline contract

- **TodoWrite** is the live human-visible plan. The **orchestrator is the ONLY
  writer** of TodoWrite. Agents never edit it; they return footer JSON and the
  orchestrator applies the patch.
- **Redis-backed memory bus** is the durable canonical projection for task
  state, events, leases, and presence. TodoWrite mirrors it for human
  visibility. If they disagree, trust bus state and repair TodoWrite.
- **Live index only — AST/FTS5 already warm.** No symbols cache file. The
  per-project SQLite index (indexer-v4 on `:8002`) is pre-populated — **do NOT
  re-read/reindex the product spec at startup**. The orchestrator checks
  health via `pipeline-health.sh --strict`; only if the index is stale (SHA
  mismatch or health = degraded) run `index_codebase()` (full reindex).
  Incremental `index_codebase({ paths: changedFiles })` is batched by the
  orchestrator at end of **build**, plus once after **verify** when the
  verifier's stage verdicts report `changed_files`.
- Read TodoWrite before acting. Follow the `in_progress` item for
  `current_phase`/`current_stage`. Bus context (`bus_recentContext` — it
  returns canonical task `state`, recent events, and hot context) provides the
  rest.
- Pipeline agents must invoke MCP tools natively with object arguments. Do not
  emulate MCP calls with Bash/curl/node/python, invent positional arguments, or
  use deprecated aliases. Bash is reserved for the orchestrator health gate and
  explicit RAG-down fallback instructions.
- The fixed route is **context → allocate → build → verify → gate**. Do not
  skip a stage. `verify` = ONE dispatch of the `verifier`, which runs the three
  `project.env` gates (`BUILD_CMD`/`TEST_CMD`/`LINT_CMD`) and then the QA and
  security/test review over the batched-reindex tree, publishing ≤3 fused calls
  back-to-back (`build_passed`/`build_failed`, `qa_verdict`, `review_verdict`) —
  it stops after the first failing stage. A gate failure first gets the named-fix
  application inside the verifier (capped); once a cap is hit the failing verdict
  carries `needs_implementer:true` + `named_fixes` and routes the implementer fix
  loop (`fix_loops.verify` max 3). The counter is read and consumed through the
  `bus_fixLoops` MCP tool — never through a shell script, because the
  host-only `scripts/manage-fix-loops.sh` needs `docker exec redis-cli` and
  therefore cannot run on a remote adapter. The cap is **enforced**:
  `increment` refuses to move the counter past the max and returns
  `maxReached:true`, so the route stops and asks the user. Stage-to-agent
  binding (which implementer, which gates) is defined by the adapter overlay,
  not here.
- **Task complexity routing (build + fix loops).** `task-allocator` scores every task
  from objective factors (`est_loc`, `files_touched`, `fr_count`, `branches`,
  `new_files`, `dep_fanout`, `hard_gate`) and stamps a `tier` of `T1-inline`,
  `T2-dispatch`, or `T3-isolated` into the task-spec `memory_write` metadata **and**
  the `tasks_allocated` event payload (`complexity_by_task`) so a resumed run routes
  identically without re-scoring. `bus_createTask`/`bus_updateTask` carry a closed
  `TaskState` schema and cannot hold the tier. The orchestrator routes on the tier
  alone: `T2-dispatch`/`T3-isolated` dispatch the implementer as usual (`T3-isolated`
  is never batched and never inline, and any hard-gated task is `T3-isolated` regardless
  of score); `T1-inline` (score ≤4 **and** files ≤2 **and** est_loc ≤80 **and** FR ≤2
  **and** branches ≤2 **and** not hard-gated) is executed in the orchestrator's own
  session under the INLINE EXECUTION CONTRACT in `agents/base/orchestrator.md`. That
  contract is a capped exception to "the orchestrator never writes product code": the
  full RAG-first retrieval chain, failing-test-first TDD, evidence footer, lease, and
  findings publication still apply, and orchestrator Bash additionally covers only the
  targeted `TEST_CMD` for an inline task. Named verify fixes inherit the owning
  task's tier under the same caps; QA/review verification always runs as the
  dispatched `verifier` and is never inlined. A missing tier means `T3-isolated`, never an inferred small task.
- Phase context is assembled by ONE `publish_result` call — no `context-brief.md`
  file. Inventory, tasks, handoffs, reports, and reviews all close the same way:
  a single `publish_result({projectId, taskId, role, summary, …})` whose sections
  stand in for `memory_write` + `knowledge_write`×N + `bus_createTask`×N +
  `bus_updateTask` + `bus_appendDecision` + `event_append` + `bus_publishEvent` +
  `bus_setHotContext`. Individual tools remain for repair only.
- A task spec is emitted by `task-allocator` via one `publish_result` whose
  `memory.docs[]` carry `metadata: { type: "task-spec", taskId, phase }`, whose
  `tasks[]` create the bus tasks, and whose `publish: { type: "tasks_allocated" }`
  announces them — all in ONE call regardless of task count. The
  **allocator owns bus task creation**; the **orchestrator owns TodoWrite**.
- Handoffs are ONE `publish_result` per agent (`verifier`: one per stage, ≤3). Include exact paths changed,
  commands/results, decisions/deviations, blockers, and `retrieval:{...}` +
  `reads:{path:line}` evidence (see below), then the returned `footer` block
  copied verbatim — never hand-assembled.
- Agents do not edit TodoWrite. If a standalone action must change state,
  describe the required `TodoWrite` patch in the footer.

## Mandatory RAG-first discovery protocol (fileless, fused)

Every investigation and task must follow this order; file reads must not replace
the initial retrieval.

> **Shared-context rule:** Redis carries current state and event references;
> RAG carries reusable context. Downstream agents retrieve relevant slices
> instead of consuming the previous agent's complete context artifact. Every
> tool input/output is payload-verified.

| Step | Call | Payload verified | Output logged |
|---|---|---|---|
| **0 BOOT (fused)** | `context_boot({projectId, taskId, limit:10, eventTypes, query, memory_query})` — ONE round-trip = bus canonical `state`+events+hot context + optional exact-spec recall (`memory_query`) + optional first RAG kit (`query`, full `code_context` param pass-through). Fallback when `context_boot` is not in your tool surface: `bus_recentContext` + `memory_recall` + `code_context` issued **in parallel in one turn** (identical payloads). | `projectId`+`taskId` required; `query`/`memory_query` optional | `boot:{bus,memory,code}` section statuses + `retrieval:{bus eventIds}` via XREVRANGE |
| **1 SHARED RAG (toon-only)** | `code_context({query, top_k:8, include_graph:true, rerank:true, task_id, project_id, phase, agent_role, current_only:true, corpora, symbol_paths})` — the first kit rides the Step 0 `query`; call standalone for **every additional** fresh query (per FR group, follow-ups, re-orientation) | `query` required, anchored to task/phase + finding titles/anchors | `retrieval:{query,top_k,hits,scores,sourceRefs,symbols(toon)/graph,source_ids}` |
| **1A EXACT SPEC** | `memory_recall({query:<taskId or exact spec anchor>})` only when the task spec is authoritative/immutable — rides the Step 0 `memory_query` when the anchor is known upfront | `query` non-empty | `memory_ref:{id,type,taskId}` |
| **1B ORIENTATION** | `code_context({query, symbol_view:"toon", symbol_scope:"file", symbol_paths:[task file_anchors]})` when task `file_anchors` exist | anchors from task spec (≤5 hard cap) | `symbols(toon)` cited via `toon:{path}` source_ids |
| **2 READ** | narrow reads of ONLY toon `L`-ranges cited from Step 1/1B (≤2 files, `path:line`) | must match Step-1/1B toon `L` spans | `reads:{path:line}` + `files_read:<=2` |
| **3 EXECUTE** | implement / verify | — | `payload_verified:{input,output}` |

- **Context kit:** handoffs use artifact v2 (`memory_type: handoff|brief|report`
  plus `metadata.task_id`, `phase`, `fr_refs`, `supersedes`, `supersedes_event`).
  **`supersedes` must be a MEMORY document id** (from a `memory_recall` hit or a
  `memory_write` response `ids[]`) — anything else is rejected `400 supersedes
  id not found`. A bus `eventId` lives in a different id space: put it in
  **`supersedes_event`** (opaque, never validated). `current_only: true` hides
  superseded/archived rows.
- **Retrieval policy:** the bus answers **what is current**; RAG answers **what
  is relevant**. A prior artifact stays complete in storage while only a few
  chunks enter the next prompt. Do not propagate full prior briefs — pass task
  identity + bus event IDs + compact RAG results.
- **RAG-down exception:** log exactly
  `RAG unavailable; used targeted read/grep fallback` + attempted
  `code_context` + fallback commands (`git ls-files`, `grep -n`, `rg`) +
  `path:line` anchors.
- **Call-shape discipline (this incident's lesson):** prefer the fused
  `context_boot` (one round-trip for bus + first memory + first RAG kit). When
  using the fallback path, Step 0's bus call and Steps 1A+1B are independent —
  issue them **in parallel in one turn**, never as a serial chain. Do not interleave a bus call behind a long RAG call: they
  share one stdio connection, so a stall in either is visible in both. If any
  call returns a timeout, abandon it after one retry, run
  `bash scripts/pipeline-health.sh --strict`, and report — see
  "Never hang on a stalled tool call" below.

Every handoff must include these evidence sections in this order:

```text
retrieval:{code_context q/k/hits/sourceRefs/symbols(toon)/graph}
reads:{path:line}
payload_verified:{input,output}
proofs:{structural:N, graph:M, lexical:K}
index_version:N
```

`proofs` counts the proof-bearing results actually used (`structural` = symbol/file rows,
`graph` = edge traversals, `lexical` = FTS hits); `index_version` is the AST index
version at retrieval time. A handoff whose `proofs` is all zeros relied on memory
alone — the verifier flags it for review.

**Recommended query shape:** `<goal> + <phase> + <requirement ids> +
<file/symbol names> + <finding titles / decision anchors> + <constraints>`.

## Cold-start token budget + proper start point (binding)

**Proper start point (no file reads before dispatch):** `TodoWrite` → `bash
scripts/pipeline-health.sh --strict` → optional `bus_recentContext` (only on
TodoWrite↔bus mismatch) → `dispatch explore`. No bulk reads of the product
spec, `IMPLEMENTATION_PLAN.md`, `agents/*.md`, or all `SKILL.md` before
dispatch — runtime injects the dispatched agent's prompt, and the product spec
is already indexed in SQLite AST/FTS5 (retrieve slices via `code_context`).

## Findings bus (Redis streams, reuse-only)

- One shared Redis; per-project isolation via logical DB (`REDIS_DB`) +
  `pipeline:{project}:` key prefix; `projectId` required on every `bus_*`.
- Keys: `pipeline:task:{id}:events` — written by the agent's single
  `publish_result` (`publish:{type:"finding_added", payload:{findings:[{finding_type,
  title, files:["path:Lx-Ly"], score, fr_ids, producer}], phase, taskId}}`, plus
  its `decision:` section) and mirrored in the `## Findings (bus, N)` section
  (≤10 lines) of that same call's 200-line `hot_context`. No new keyspaces; the
  `publish` section runs last inside the fused call, so an event never outlives
  the report it points at.
- **`ROLE_SECTIONS` gates the fused call.** The bridge hard-codes which sections
  each `role` may run, mirroring the per-agent `deny` rules in the adapter's
  `opencode.json` — the bridge cannot see the caller's permission rules, so this
  map is the only enforcement on the fused path. A forbidden section returns
  `status:"denied"` rather than executing. Keep both in sync when a role's
  permissions change.
- Publishers: `explore` + `task-allocator` (NEW gaps found during its RAG sweep —
  a limited publisher, not consume-only) + implementers (explicit `findings:none`
  with `N=0` still publishes) + `verifier` (verdicts only:
  `build_passed`/`build_failed`, `qa_verdict`, `review_verdict` — never
  `finding_added`). The verifier is **CONSUME-ONLY** on `finding_added`.
- Consume (every agent Step 0): `bus_recentContext({limit:10, eventTypes})` —
  XREVRANGE, non-destructive. Footer: publishers `bus:{task,eventId,findings:N}`;
  consumers `bus:{task,eventId}` + cited `eventId`.
- The bus event carries compact metadata/anchors; the reusable finding body is
  indexed into shared RAG. Consumers formulate `code_context` queries from
  finding titles, requirement IDs, file anchors, or decision names.

## Shared RAG handoff pattern

Producer writes complete artifact → memory/knowledge + publishes compact event
→ Redis bus + indexes reusable content → shared RAG. Next agent reads task/event
refs from Redis, formulates a query from task+phase+keywords+anchors, calls
`code_context`, retains only relevant chunks, reads ≤2 cited ranges when needed.

## Native MCP client binding (contract-critical)

The tool tables in this contract name the bridge's **canonical MCP tools** and
their object-argument schemas. The active host decides how those tools are
registered and named in its callable tool surface. Invoke a tool only through
the exact identifier and schema exposed by that surface; examples such as
`pipeline_<tool>`, `mcp__pipeline__<tool>`, and `default.pipeline_<tool>` are
host-specific, not names to guess. Always use native MCP calls with object
arguments. Never proxy MCP JSON-RPC through Bash, curl, Node, or Python.

- A prompt, project config, healthy bridge, or successful `tools/list`
  handshake cannot add tools to a host session that has not connected the MCP
  server. Host configuration and runtime tool exposure are separate checks.
- Before dispatch, verify that the active session exposes the required
  canonical tools. The orchestrator's `bus_recentContext` capability call is
  the runtime gate; an agent that lacks a required tool stops rather than
  claiming RAG is down or falling back to shell emulation.
- If a required tool is absent, report exactly:
  `MCP TOOLS UNAVAILABLE; required pipeline MCP tools are not exposed in the active host session. Configure/connect the pipeline server in that host and refresh its tool registry or start a new session if needed; verify the tools are callable before resuming.`
  Refresh/restart only when the active host requires it; do not assume
  restarting OpenCode applies to another client.
- `scripts/mcp-handshake-probe.sh` verifies that the bridge responds to
  `initialize` and advertises tools. `pipeline-health.sh --strict` can verify
  this bridge-level availability, but neither proves that a particular host
  session has bound the tools.

### OpenCode-specific binding

- OpenCode prefixes registered tools with the MCP server name, so this
  project's `pipeline` server exposes identifiers such as
  `pipeline_bus_recentContext`.
- Per-agent gating uses those prefixed ids in
  `agent.<name>.permission` (last matching rule wins: allow `pipeline_*` first,
  then explicit denies). Never use a per-agent `tools` map with bare MCP names.
- Configure the server as `mcp.pipeline` in `opencode.json`; do not put a
  top-level `context_servers` block there (that is Zed configuration).
- The bridge is launched by `scripts/start-mcp-bridge.sh`. If OpenCode binds
  manifests only at process startup, changes to its MCP config require
  restarting that OpenCode process.

### Zed-specific binding

Zed's project MCP server configuration lives at top level in
`.zed/settings.json` under `context_servers.<server>`. Agent profiles and
their MCP tool allowlists belong in the Zed **user** `settings.json`, under
`agent.profiles.<profile>.context_servers.<server>.tools`; Zed rejects the
`agent` key in project settings. The bridge is launched on demand by Zed.
Zed's tool identifiers and TodoWrite support are host-specific; use the actual
native tools exposed to the active profile.

## Remote adapters (repo on another machine)

When the repository lives on a **different machine**, the host keeps every
service — bridge, indexer, Redis — and mirrors the remote repo in git. The
remote machine holds only the repo, the editor, the rendered agent prompts, and
the **adapter pack** (`.pipeline-remote/`: the pipeline skills, the generic
contract, and an `opencode.json` whose MCP server is a `remote` entry pointing
at the host bridge over HTTPS with a Bearer token).

Rules that hold on both sides:

- **No pipeline code is copied to the remote machine.** If the remote needs a
  behaviour change, it is made on the host and re-rendered into the pack.
- **The pack never carries a secret.** The bridge URL and token are read from
  environment variables on the remote machine via `{env:VAR}` substitution;
  only the variable *names* are committed.
- **State stays on the host.** Task state, events, hot context, the corpus, and
  the fix-loop counters are all reached through the bridge — which is why the
  fix-loop counter had to become an MCP tool (`bus_fixLoops`) rather than a
  host-only shell script.
- **The mirror is refreshed before an index, not continuously.** A project's
  registry entry may carry a `sync:{url,branch}` block; `index_codebase` then
  does a bounded `git fetch` + `git reset --hard FETCH_HEAD` on the host
  mirror before indexing. The refresh is non-fatal (a failed fetch downgrades
  to the previous checkout) and the bridge **never clones**.

Runbook: `docs/remote-adapter.md`. Host commands: `scripts/start-remote.sh`,
`scripts/sync-remote-mirror.sh`, `scripts/pack-remote-adapter.sh`.

## Never hang on a stalled tool call (contract-critical)

Every tool shares **one** stdio connection to the editor. A single unbounded
call is therefore a shared-availability problem, not just a slow answer: while
it is pending the connection is not draining, and unrelated tools look dead
too. This is not hypothetical — a half-open Redis socket once made *every*
`pipeline_bus_*` call time out while Redis itself answered `PONG` with zero
blocked clients.

- **Every tool call is now bounded.** The bridge aborts at
  `MCP_TOOL_TIMEOUT_MS` (25s) and returns a retryable error; RAG fetches abort
  at `RAG_FETCH_TIMEOUT_MS`; Redis commands abort at
  `BUS_REDIS_COMMAND_TIMEOUT_MS`. Treat a `timed out` / `Command timed out`
  result as a **failed call with a known cause**, never as a silent no-op.
- **Abandon a stalled call, do not wait on it.** Do not re-issue the same call
  in a loop hoping it lands. After **one** retry: run
  `bash scripts/pipeline-health.sh --strict` and report the blocker.
- **Never let one stall cascade.** If the bus is timing out, do not keep
  issuing RAG calls "to make progress" — every additional call shares the same
  connection. Stop, diagnose, report.
- **Issue independent calls in parallel**, not sequentially. Prefer
  `context_boot` (fuses Step 0 + first Step 1A/1 into one call); on the
  fallback path, Step 0 (`bus_recentContext`) and the Step 1A/1B retrieval
  pair are independent — batch them in one turn. Only chain calls with a real data
  dependency (a task spec's ids into `code_context`).
- **A full `index_codebase` legitimately exceeds the deadline** (~100s). Use
  `index_codebase({ paths })` for incremental work and batch it at the end of
  **build**. Never run a full reindex mid-task to "fix" retrieval.
- **Verify the bridge is on the right Redis logical DB** with
  `pipeline_bus_health` (it reports `db`). It must equal `REDIS_DB` from
  `.pipeline-project/config/project.env`. A bridge on the wrong DB still
  answers healthy — the project's state is simply invisible.

`pipeline-health.sh --strict` probes the bridge in a fresh process — it cannot
detect whether the current host session has bound the advertised tools. The
orchestrator tool-binding gate (mandatory `bus_recentContext` before dispatch)
covers that.

## Native Zed tool contract — summary

Canonical tools (fused, merged, payload-verified): `code_context` +
`context_boot` (fused dispatch boot: bus + optional memory + optional first
RAG kit) + `publish_result` (fused publish: the ONLY sanctioned publish path —
memory + knowledge×N + tasks×N + task_patch + decision + event + bus event +
hot context, gated by `ROLE_SECTIONS`, bus event last) + `index_codebase` +
`memory_recall`/`memory_write` +
`knowledge_search`/`knowledge_write{kind}` + `event_append`/`event_query` +
bus (`bus_health`/`bus_createTask`/`bus_getTask`/`bus_updateTask`/
`bus_publishEvent`/`bus_consumeEvents`/`bus_ackEvent`/`bus_heartbeat`/
`bus_recentContext`/`bus_lease`/`bus_setHotContext`/`bus_appendDecision`/
`bus_enqueueWork`/`bus_dequeueWork`/`bus_getAgentState`/`bus_getPresence`) +
AST/graph (`ast_retrieve`/`repo_map`/`get_definition`/`get_callers`/
`get_callees`/`get_references`/`get_imports`/`get_dependents`/`get_outline`/
`get_source`). Manifest synced via `python3 scripts/sync-tool-manifest.py --check`.

## Editing and testing rules (generic)

- Inspect the relevant task, brief, and existing implementation before editing.
  Keep changes within the task scope.
- Do not commit, create branches, or rewrite editor configs unless asked.
- The implementer writes tests alongside prod code for every business-rule
  branch (failing test first, then prod code, then edge cases). Stack-specific
  bars (commands, coverage thresholds, corpus sizes) are defined by the adapter
  overlay — this base file sets no numbers.
- Verification is independent: it re-runs the adapter's acceptance gates from
  scratch and reports `gates:{...}` honestly. Failed verification returns only
  the named fixes to the implementer, respecting the loop caps.
- Report failures honestly with reproduction steps. Do not mark a stage
  complete without its durable handoff/report.
- Use exact project paths in all handoffs. If blocked (lease, missing context,
  unavailable service, conflicting files), stop and document the blocker.

## Skills

- Pipeline coordination and gate: `skills/pipeline/SKILL.md`
- Read-only status: `skills/pipeline-status/SKILL.md`
- Exploration/research: `skills/pipeline-explore/SKILL.md`
- Task creation: `skills/pipeline-task-allocator/SKILL.md`
- Compile + QA + security/test review: `skills/pipeline-verifier/SKILL.md`
- Implementer skills live in the adapter (one per stack).
