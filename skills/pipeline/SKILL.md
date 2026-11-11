---
name: pipeline
description: Run or resume the fileless delivery pipeline via TodoWrite + Redis bus.
---

# Pipeline

Coordinate the fileless delivery pipeline; do not write product code.

## Primary Reference

This skill delegates to the orchestrator agent at `pipeline-global/agents/base/orchestrator.md` for full protocol details including:
- Canonical MCP tool contract (38 tools): `code_context`, `context_boot`, `index_codebase`, `index_status`, `memory_recall`, `memory_write`, `knowledge_search`, `knowledge_write`, `event_append`, `event_query`, `publish_result`, `bus_health`, `bus_createTask`, `bus_getTask`, `bus_updateTask`, `bus_publishEvent`, `bus_consumeEvents`, `bus_ackEvent`, `bus_heartbeat`, `bus_recentContext`, `bus_lease`, `bus_setHotContext`, `bus_appendDecision`, `bus_enqueueWork`, `bus_dequeueWork`, `bus_getAgentState`, `bus_getPresence`, `bus_fixLoops`, `ast_retrieve`, `repo_map`, `get_definition`, `get_callers`, `get_callees`, `get_references`, `get_imports`, `get_dependents`, `get_outline`, `get_source`
- Fused publish contract: EVERY agent closes with exactly ONE `publish_result` call per stage of its run (the `verifier` alone publishes up to three — compile, QA, review — after the tree settles) — it fuses memory_write + knowledge_write×N + bus_createTask×N + bus_updateTask + bus_appendDecision + event_append + bus_publishEvent + bus_setHotContext. `role` selects both the section defaults and the permitted sections (`ROLE_SECTIONS` mirrors each agent's `opencode.json` deny rules; a forbidden section returns `denied`). `publish` runs LAST, so no agent ever announces a verdict whose report is not yet retrievable. Agents copy the returned `footer` block verbatim.
- Fused RAG-first retrieval contract (`code_context` canonical)
- TodoWrite + Redis bus state ownership
- Memory bus protocol (context_boot — canonical `state` + events + first kit in one call; fallback bus_recentContext — memory_write)
- Knowledge platform integration
- File lease protocol
- Validation rules for each agent type

## Quick Reference

### RAG-first route invariant (fused, fileless, shared RAG v6) — 50K SAVINGS: NEVER bulk-read SRS — payload-verified

Before any discovery, require this exact order (every tool input/output payload verified). **The SQLite AST/FTS5 index is warm — never bulk-read `{{SPEC_DOC}}`:**

> **Shared-context rule:** Redis carries current state and event references; RAG carries reusable context. Do not propagate full prior briefs into next prompt — pass task identity + bus event IDs + compact RAG results.

| Step | Call | Payload verified | Output logged |
|---|---|---|---|
| **0 BOOT (fused)** | `context_boot({projectId, taskId, limit:10, eventTypes:[...], query, memory_query})` — ONE round-trip = bus canonical `state`+events + optional exact-spec recall + optional first RAG kit; fallback (tool absent): `bus_recentContext` + `memory_recall` + `code_context` in parallel | `projectId`+`taskId` required | `boot:{bus,memory,code}` + `retrieval:{bus eventIds}` via XREVRANGE |
| **1 SHARED RAG** | `code_context({query, top_k:8, include_graph:true, rerank:true})` | `query` required and must be anchored to current task/phase + FR/keywords + finding titles/anchors | `retrieval:{q/k/hits/scores/sourceRefs/symbols/graph}` |
| **1A EXACT SPEC** | `memory_recall({query:<taskId or exact spec anchor>})` only when task spec is authoritative/immutable | `query` non-empty | `memory_ref:{id,type,taskId}` |
| **2 READ** | `get_source`/`code_context` ONLY cited ranges from Step 1 (≤2 files, `path:line`) | must match Step-1 symbols/anchors | `reads:{path:line}` + `files_read:<=2` |
| **3 EXECUTE** | implement / verify | — | `payload_verified:{input,output}` |

**Shared RAG scope:** `code_context` is the common context-retrieval surface across code/AST, SRS slices, memory/knowledge, and prior phase artifacts. **Retrieval policy:** bus answers **what is current**; RAG answers **what is relevant**.

- Legacy `retrieve_symbols`/`context_compose`/`ast_lookup`/`graph_*` are not advertised in v4 — use `code_context`/`ast_retrieve` plus the first-class graph tools.
- **Do not pass full prior-agent briefs/handoffs into the next prompt.** Use shared RAG slices. Bulk file reads/`grep`/`glob` before Step 1 = VIOLATION.

Require every handoff to contain `retrieval:{code_context q/k/hits/sourceRefs/symbols/graph}` then `reads:{path:line}` then `payload_verified:{input,output}` then `proofs:{structural:N, graph:M, lexical:K}` and `index_version:N` in that order. A missing RAG result requires a more specific retry before fallback. Live index only — `.pipeline/cic/symbols.json` is service-owned (written by `index_codebase`); agents never read it, symbols arrive via `code_context`.

### Start — PROPER START POINT (LEAN COLD START — RAG-FIRST, NO 50K, PAYLOAD-VERIFIED)

Token budget before `explore` dispatch: **≤2K** (AGENTS.md § Cold-start token budget + Proper Start Point). **The SQLite AST/FTS5 index is already warm — do NOT reindex 50K tokens. Proper start point = TodoWrite → health gate → bus context → dispatch, no file reads before dispatch.**

1. `TodoWrite` first (no file reads): read TodoWrite list (orchestrator is ONLY writer). Find `in_progress` phase. If none, ask user.
2. Single bash: `bash ../pipeline-global/scripts/pipeline-health.sh --strict 2>&1` only — no `ls dist/index.js || pnpm build` bundling (health script handles `[warn] memory-bus not built`). If the index is healthy, SKIP `index_codebase()` at cold start (50K savings); only index if `degraded`/`stale`. Second health call only if first exit !=0 (then `bash ../pipeline-global/scripts/start-all-services.sh` + re-check).
3. Consistency check (only if TodoWrite vs bus mismatch suspected): `bus_recentContext({projectId, taskId:"phase-1-context", limit:10})` — payload-verified (`projectId`+`taskId` required). If it shows `explore_completed` but TodoWrite disagrees, trust bus.
4. Dispatch `explore` immediately — **STRICTLY FORBIDDEN BEFORE DISPATCH:** bulk `read` of `{{SPEC_DOC}}`, `@{{SPEC_DOC}}` injection, bulk `read` of `IMPLEMENTATION_PLAN.md` / all `agents/*.md` / all `skills/**/SKILL.md`, any `grep/glob/cat/ls` before dispatch. Spec is indexed in SQLite AST/FTS5 — subagents use `code_context({ query: "<requirement ID + keywords>", top_k: 8 })` (payload-verified). Use `{{SPEC_SUMMARY}}` only if needed after a failure, never before dispatch.
5. Coordinator alone updates `TodoWrite` + canonical state (payload-verified: `projectId`+`taskId`+`expectedVersion` finite) — the `task_patch` section of its own `publish_result`, or `bus_updateTask` to repair it. Agents return footer JSON; they do not mutate state. Never create `.pipeline/**`.

Enforce fused workflow after dispatch: bus first → `code_context` → cited `get_source` ≤2 files → implement/verify. If RAG unavailable, require `RAG unavailable; used targeted read/grep fallback` with anchors.

## BASH IS FORBIDDEN — semantic-only RAG from context (v6.1, hard violation)
Orchestrator Bash = health gate only. Agent semantic content ONLY from bus + `memory_recall` + `code_context` + ≤2 cited reads. Allowed agent fallback ONLY after the exact RAG-unavailable sentence + attempted `code_context {q}`: `git ls-files`, `grep -n`, `rg`, bounded reads. NEVER `ls -R`/`find`/`ls`/`git status`/`head -n`/`cat`/`fd` (piped `| head` still a scan). Dispatch refs only — NEVER full prior brief/handoff bodies. Healthy-RAG scan or wholesale propagation = VIOLATION (redispatch ONCE; second failure → stop + ask user).

### Stage contracts (all tools payload-verified, shared RAG v6)

- **Context:** invoke `pipeline-global/agents/base/explore.md`; require ONE `publish_result({role:"explore"})` carrying the context brief (`summary`), findings (`knowledge`), the `explore_completed` event, the `finding_added` bus event, and hot context (≤200 lines). Shared RAG: explore publishes findings indexed for reuse.
- **Allocate:** invoke `pipeline-global/agents/base/task-allocator.md` with bus refs only (do not inject full explore brief); require ONE `publish_result({role:"task-allocator"})` carrying every task spec (`memory.docs[]`), every bus task (`tasks[]`), and `publish:{type:"tasks_allocated", payload:{task_list, first_task, complexity_by_task}}` — however many tasks, one call (all payload-verified). Allocator issues shared RAG query (goal+requirement+finding anchors) to retrieve relevant slices, scores each task's complexity, and stamps `metadata.complexity.{score,tier,factors,hard_gate}`; owns bus tasks; orchestrator mirrors TodoWrite.
- **Build:** route each task by its allocator-assigned tier — `T1-inline` (score ≤4 and files ≤2 and est_loc ≤80 and FR ≤2 and branches ≤2 and not hard-gated) is executed inline in the coordinator session under the INLINE EXECUTION CONTRACT (full RAG-first chain + failing-test-first TDD + evidence footer + lease + findings; orchestrator Bash additionally covers only the targeted `TEST_CMD`); `T2-dispatch` and `T3-isolated` are dispatched to `{{IMPLEMENTER_ROLE}}` with **task ID + bus refs only** (no full handoff), `T3-isolated` in isolation and never batched. A missing tier means `T3-isolated`. Implementer retrieves exact immutable task spec via `memory_recall` + shared `code_context` query anchored to task requirements + findings, parallelize only tasks with no file/dependency overlap. Batched `index_codebase({paths})` at end of build, plus once after verify when the verifier reports `changed_files`.
- **Verify:** invoke `pipeline-global/agents/base/verifier.md` with bus refs only — ONE dispatch runs all three gates in order (A compile: the three `project.env` gate commands → `build_passed`/`build_failed`; B QA: **fresh RAG query per requirement/gate group**, never build context wholesale → `qa_verdict`; C review: read-only security + test audit → `review_verdict`), publishing ≤3 fused calls back-to-back after the tree settles (stop after the first failing stage). It applies named fixes in place only within its Fix Application Contract (≤2 files / ≤80 LOC / 3 rounds / `file_anchors` only); on a cap it publishes the failing verdict with `needs_implementer:true` + `named_fixes`. Validate the verdicts with `bus_recentContext({projectId, taskId, limit:10, eventTypes:["build_passed","build_failed","qa_verdict","review_verdict"]})` — never the default boot filter, which would hide a verdict the call does not name. A failing verdict with `needs_implementer` short-circuits the run: later-stage absences are expected, not lost, and the gate does not open. On all-pass, run one batched `index_codebase({paths})` over the union of the verdicts' `changed_files` before the gate.
- **Fix loops (verify):** named fixes inherit the owning task's tier — inline them only when the owner was `T1-inline` and the fix set still fits the same caps and touches only the task's `file_anchors`; still consume a loop with `bus_fixLoops({projectId, stage:"verify", action:"increment"})` (the cap of 3 is ENFORCED — `maxReached:true` means stop and ask the user, never retry), dispatch the implementer otherwise, and stop after 3. QA/review verification always runs as the dispatched `verifier`.
- **Gate:** retrieve compact QA/review conclusions via **targeted RAG queries** plus current bus state, summarize artifacts and ask for approval. No `clear/archive` script — `.pipeline` does not exist.

### Shared RAG handoff (v6)

Producer writes complete artifact → memory/knowledge + publishes compact event → Redis bus + indexes reusable content → shared RAG. Next agent reads task/event refs from Redis, formulates query from task+phase+FR/keywords+anchors, calls `code_context({query:"<goal+phase+FR+findings>", top_k:8, include_graph:true, rerank:true})`, retains only relevant chunks, reads ≤2 cited ranges when needed. Complete artifact remains available but **prompt context stays selective**. Recommended query shape: `<goal> + <phase> + <FR IDs> + <file/symbol> + <finding titles> + <constraints>`.

### Findings bus (reuse-only, shared RAG)

Reuse existing `pipeline:task:{id}:events` via `finding_added` + `bus_appendDecision` + `## Findings (bus, N)` (≤10 lines) in hot context. Publishers ONLY: explore + task-allocator (NEW gaps only — limited publisher) + {{IMPLEMENTER_ROLE}} (or `findings:none` N=0). The verifier is CONSUME-ONLY (verdicts only, never `finding_added`). RAG handoff: bus event carries compact metadata; finding body is indexed in shared RAG for consumers via `code_context` queries. Hot-context is routing snapshot only — not a second full handoff channel.

### Bus handoff (payload-verified)

Every stage leaves a bus-native handoff via exactly ONE `publish_result` call (the `verifier` may emit up to three, one per gate stage) (all payload-verified: `projectId`+`taskId`+`role`+`summary` required; read `failures[]` and repair any errored/timeout section once). Handoffs include, in this exact order, `retrieval:{code_context q/k/hits/symbols/graph}` then `reads:{path:line}` then `payload_verified:{input,output}` then `proofs:{structural:N, graph:M, lexical:K}` and `index_version:N`, followed by status, exact files, validation commands/results, decisions/deviations, blockers, RAG/MCP status, and next action. Context passes via `context_boot` (bus + memory + first kit; fallback `memory_recall` + `bus_recentContext`) + `bus_setHotContext` (all payload-verified); the coordinator alone updates `TodoWrite`. Do not invent bus events.

## Agent Dispatch Reference

| Stage | Agent File | Output |
|-------|------------|--------|
| Context | `pipeline-global/agents/base/explore.md` | Context brief + findings + `finding_added` + hot context via ONE `publish_result` |
| Allocate | `pipeline-global/agents/base/task-allocator.md` | Task specs + bus tasks + `tasks_allocated` via ONE `publish_result` |
| Build | `{{IMPLEMENTER_ROLE}}` (see overlay) | Implementation + bus handoff (payload-verified, RAG-first) |
| Verify | `pipeline-global/agents/base/verifier.md` | `build_passed`/`build_failed` + `qa_verdict` + `review_verdict` via ≤3 `publish_result` calls |
