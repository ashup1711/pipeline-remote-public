---
name: pipeline-task-allocator
description: Convert context into ordered, independently verifiable tasks.
---

# Pipeline task allocator

Convert the context brief into ordered, small, independently verifiable tasks. Allocator owns `bus_createTask`; orchestrator mirrors `TodoWrite`. Never create `.pipeline/**` files.

## Primary Reference

This skill delegates to the task-allocator agent at `pipeline-global/agents/base/task-allocator.md` for full protocol details including:
- Canonical MCP tool contract: `code_context`, `context_boot`, `memory_recall`, `publish_result`, `knowledge_search`, `bus_recentContext`, `index_status`
- ONE fused `publish_result` call ships every task spec + every bus task + the `tasks_allocated` event, no matter how many tasks the phase needs

## Quick Reference

### RAG-first workflow (MANDATORY, fused) — payload-verified, merged tools

1. **Step 0 BOOT (payload-verified)** — `context_boot({projectId, taskId, limit:10, query:"<first FR group kit>", memory_query:"P<phase> context brief"})` — ONE round-trip: bus canonical `state`+events + brief recall + first kit; log `boot:{bus,memory,code}` + `retrieval:{bus eventIds}` (fallback: `bus_recentContext` in parallel with `memory_recall`/`code_context`).
1A. **Step 0A RAG HEALTH** — if the boot `code` section is `skipped`/`error`/`timeout` or returns 0 hits, call `index_status({projectId})` once. If the indexer is unreachable or the index is stale, log exactly `RAG unavailable; used targeted read/grep fallback` (brief-first) and switch to the brief-first path. A present-but-empty `code_context` is NOT "no data".
1B. **Step 0B BRIEF-FIRST FALLBACK** — when RAG is degraded, `memory_recall({query:"P<phase> context brief", agent_id:"explore", top_k:3})` is authoritative: seed task drafts from the brief's FR/NFR inventory + gaps + anchors, then verify each anchor with targeted reads (Step 2). Never skip the brief recall.
2. **Step 1 FUSED — `code_context` canonical (merged)** — `code_context({ query, top_k: 8, include_graph: true, rerank: true })` per FR group (≤4 per turn; the bridge caps concurrent RAG calls at 4). All legacy discovery tools merged into `code_context`; `query` required non-empty, output `{hits,scores,symbols,graph}` verified. Log `retrieval:{code_context q/k/hits/symbols/graph}`.
3. **Step 2 READ (payload-verified)** — `read` only cited ranges from Step 1 (`path:line`, ≤2 files). Bulk before = VIOLATION. Log `reads:{path:line}` + `payload_verified:{input,output}`.
4. **Step 2B ANCHORS (reuse-first)** — reuse `source_id`s/`L` spans already cited in Step 1 for each task's `file_anchors` (≤2/task); only if missing, issue ≤2 fresh `code_context({query:"<task objective + FR IDs>", top_k:5, symbol_paths:[candidate files]})` calls.
5. **Step 2B-VERIFY ANCHORS** — before publishing, every task must have ≥1 anchor with a real `path` + `lines`. If one has none, issue ONE more targeted `code_context` or drop the task and note it in `## Discoveries`. A task without an anchor is a violation — the implementer cannot orient.
6. **Step 2C COMPLEXITY** — score every task and stamp `complexity:{score,tier,factors,hard_gate,confidence}`. `confidence:high` when anchors + brief agree; `confidence:low` when RAG was degraded or the area is unknown. The tier is an estimate, not a verdict.

### Deliverables (ship via bus — no files)

## BASH IS FORBIDDEN — semantic-only RAG from context (v6.1, hard violation)
Semantic content ONLY from bus + `code_context` per FR group + ≤2 cited reads. Allowed fallback ONLY after `RAG unavailable; used targeted read/grep fallback` + attempted `code_context {q}`: `git ls-files`, `grep -n`, `rg`, bounded reads. NEVER `ls -R`/`find`/`ls`/`git status`/`head -n`/`cat`/`fd`. NO_PROPAGATION: pass phase goal + FR IDs + finding titles/anchors + bus eventIds only; implementers retrieve slices via `memory_recall` + fresh `code_context`. Healthy-RAG scan = VIOLATION (redispatch ONCE).

- Task specs in the fused call's `memory.docs[]` (one doc per task, `metadata:{type:"task-spec", taskId, phase, file_anchors:[{path, lines}], complexity:{score, tier, factors, hard_gate, confidence, rationale}}` — anchors and complexity both REQUIRED; each spec ≤~3k chars so TDD guidance, exact signatures, and edge cases survive).
- Bus tasks in the same call's `tasks[]` (allocator owns). `TaskState` is a closed schema — the tier cannot ride here, only in the spec metadata and the event payload.
- Task list in the same call's `publish:{type:"tasks_allocated", idempotencyKey:"<PROJECT_SLUG>:<phase>-context:tasks_allocated", payload:{task_list, first_task, complexity_by_task}}` (orchestrator mirrors to TodoWrite). The `idempotencyKey` dedupes a retried publish instead of writing a second event.
- Score every task from `est_loc`, `files_touched`, `fr_count`, `branches`, `new_files`, `dep_fanout`, `hard_gate` and assign `T1-inline` (score ≤4 and files ≤2 and est_loc ≤80 and FR ≤2 and branches ≤2 and not hard-gated), `T2-dispatch` (score ≤9, not hard-gated), or `T3-isolated` (everything else, plus **every** hard-gated task regardless of score). The orchestrator executes `T1-inline` in its own session, dispatches `T2-dispatch`, and treats `T3-isolated` as isolated-forever. A task published without a tier is a contract violation. A `low`-confidence tier is a soft hint — the implementer re-assesses on boot and reports the delta; the orchestrator may re-route on it.
- **Findings:** you are a **limited publisher** on `finding_added`. If your RAG sweep finds a NEW gap explore missed (missing model, unwired endpoint, schema inconsistency), publish it via `knowledge:[{kind:"finding", finding_type:"gap", severity, title, description, file_path, line_start, line_end}]` + `publish:{type:"finding_added", payload:{findings:[…]}}`. Do NOT restate explore's findings — consume those.

### Handoff (payload-verified)

ONE call, however many tasks you drafted:
`publish_result({projectId, taskId, role:"task-allocator", phase, memory:{docs:[{text: task_spec, metadata:{type:"task-spec", taskId, phase, file_anchors, complexity}}]}, tasks:[{taskId:"T-001", goal, phase, assignedAgent, priority}], knowledge:[…NEW gaps only…], event:{event_type:"tasks_allocated", summary}, publish:{type:"tasks_allocated", idempotencyKey:"<PROJECT_SLUG>:<phase>-context:tasks_allocated", payload:{task_list, first_task, complexity_by_task}}})`
(payload-verified: `projectId`+`taskId`+`role`+`summary` required; `memory.docs[].text` non-empty; each `tasks[]` item needs `taskId`+`goal`+`assignedAgent`). Ordering is guaranteed: specs are indexed into RAG and bus tasks are created BEFORE the `tasks_allocated` event announces them, so an implementer can never boot on an event whose spec is not yet retrievable. `role:"task-allocator"` may run memory, knowledge, tasks, event, publish, and `finding_added` only. Read `failures[]`: repair an errored/timeout section ONCE with the matching direct tool using the SAME taskId — never re-publish the whole call (duplicate tasks). A `section:"memory"` entry with `status:"invalid"` means the bridge rejected a spec for a missing `file_anchors` or `complexity.tier` — fix that spec and rewrite it; **a task published without a `tier` is a violation** (the orchestrator treats it as `T3-isolated`).

Footer JSON with `retrieval:{code_context q/k/hits/symbols/graph}` + `reads:{path:line}` + `payload_verified:{input,output}` + `complexity:{score,tier,factors,hard_gate,confidence}` + the returned `footer` block (`memory_ref`, `event_ref`, `bus_ref`) verbatim. Do not edit TodoWrite. Live RAG only — every I/O payload verified.
