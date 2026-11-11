---
name: pipeline-verifier
description: Verify a completed <PROJECT> phase with compile + expert business-logic QA + security/test review in one dispatch (see overlay for gates)
---

# Pipeline Verifier — Compile + QA + Review

Run all three gates over the completed phase in ONE dispatch via fused bus-first expert workflow: build/test/lint verdict, business-logic QA, read-only security + test audit. Product code changes only under the agent's Fix Application Contract (named fixes, ≤2 files / ≤80 LOC / 3 rounds, `file_anchors` only, never hard-gated paths). Never edit TodoWrite and never create `.pipeline/**`. Spec = `{{SPEC_DOC}}` (see overlay).

## Primary Reference

This skill delegates to the `verifier` agent at `pipeline-global/agents/base/verifier.md` (the merged build + qa-engineer + reviewer protocol; see overlay for per-group gates and checklists).

## RAG-first (MANDATORY, fused) — payload-verified, merged tools

1. **Step 0 BOOT (payload-verified)** — `context_boot({projectId, taskId, limit:10, eventTypes:["finding_added","explore_completed","tasks_allocated","task_completed","build_passed","build_failed","qa_verdict","review_verdict"], query:"<first FR group kit>", memory_query:"P<phase> context brief"})` — ONE round-trip: bus canonical `state`+events + brief recall + first kit; log `boot:{bus,memory,code}` + `retrieval:{bus eventIds}` (fallback: `bus_recentContext` in parallel with `memory_recall`/`code_context`).
2. **Step 1 FUSED — `code_context` canonical (merged)** — single `code_context({ query: "<requirement keywords + requirement ID>", top_k:8, include_graph:true, rerank:true })` **per requirement group, fresh for every stage** (a prior stage's output is never evidence for the next one) — all legacy tools merged; `query` required non-empty, output `{hits,scores,symbols,graph}` verified.
3. **Step 2 READ (payload-verified)** — `read` ONLY cited ranges from Step 1 (`path:line`, ≤2 files). Bulk before = VIOLATION. Log `retrieval:{code_context q/k/hits/symbols/graph}` + `reads:{path:line}` + `payload_verified:{input,output}`.

## Stage protocol (bus-first, fused, expert)

1. `context_boot` → `memory_recall` task specs (task-allocator) → `code_context` per additional requirement group (see overlay for requirement index).
2. **A compile** — run the three `project.env` gate commands; verdict `build_passed`/`build_failed` (with `log_tail`). **B QA** — unit slice + integration (isolated temp store + migration helper) + fuzz (long/unicode/empty) + golden diff if applicable + manifest scan + size/a11y checks per group; assert gates per {{QA_GATES}}. **C review** — read-only audit: `tests_written` unit+corpus+integration (+ golden if export), `coverage` per {{COVERAGE_FLOOR}}, manifest rules per {{MANIFEST_RULES}}, secrets/keystore rule per {{KEYSTORE_RULE}}.
3. Apply named fixes in place only within the Fix Application Contract, re-run the touched gate, then continue; when a cap is hit, stop that stage and publish the failing verdict with `needs_implementer:true` + `named_fixes` so the orchestrator routes the implementer loop (`fix_loops.verify`, max 3).
4. `APPROVE` only if build + gates + coverage + security all pass.

## Handoff (bus-only)

## BASH IS FORBIDDEN — semantic-only RAG from context (v6.1, hard violation)
Semantic content ONLY from bus + fresh `code_context` per FR group + `memory_recall` (authoritative only) + ≤2 cited reads per group. The ONLY shell this skill ever invokes is the three gate commands (`BUILD_CMD`/`TEST_CMD`/`LINT_CMD` from `project.env`) plus the capped fix re-run, governed by the agent's `BASH IS RESTRICTED` policy — bash stays forbidden for retrieval, discovery, and reporting. Allowed fallback ONLY after `RAG unavailable; used targeted read/grep fallback` + attempted `code_context {q}`: `git ls-files`, `grep -n`, `rg`, bounded reads. NEVER `ls -R`/`find`/`ls`/`git status`/`head -n`/`cat`/`fd`. NO_PROPAGATION: the verifier report is indexed, not injected wholesale into the gate. Healthy-RAG scan = VIOLATION (redispatch ONCE).

## Publish (≤3 fused calls per run, back-to-back)

ONE `publish_result` per stage after the tree settles (or immediately on a stage failure, then stop), each carrying `role:"verifier"` (memory, knowledge, event, publish only — `task_patch`/`decision`/`hot_context`/`tasks` return `denied`):

1. `publish_result({projectId, taskId, role:"verifier", phase, summary:<build report: commands, verdict, log_tail>, memory:{metadata:{type:"build-report", verdict}}, knowledge:[], event:{event_type:"build_completed", payload:{verdict, commands}}, publish:{type:"build_passed"|"build_failed", payload:{verdict, log_tail}}})`.
2. `publish_result({... summary:<QA report: per-requirement PASS/FAIL + gates:{{QA_GATES}}>, memory:{metadata:{type:"qa-report", verdict}}, knowledge:[{kind:"finding", finding_type:"gap", severity, title, description, fr_nfr_ids:["<REQ-ID>"], file_path, line_start, line_end}], event:{event_type:"qa_completed", payload:{verdict, gates, failedFRs}}, publish:{type:"qa_verdict", payload:{verdict:"PASS"|"FAIL", failures, gates, needs_implementer, named_fixes}}})`.
3. `publish_result({... summary:<review: verdict, gates, coverage, security>, memory:{metadata:{type:"review", verdict}}, knowledge:[{kind:"finding", ...}, {kind:"decision", decision_type, title, context, decision}], event:{event_type:"review_completed", payload:{verdict}}, publish:{type:"review_verdict", payload:{verdict:"APPROVE"|"CHANGES_REQUESTED", changes_requested, gates}}})`.

Issues AND decisions share the one `knowledge` array — `kind` selects. `knowledge: []` on a clean pass is correct — the verifier is CONSUME-ONLY on `finding_added` and never publishes it, but the three verdict events are mandatory on a full run (stop early after the first failing stage). Read `failures[]` and repair an errored/timeout section once.

Footer JSON with `retrieval:{code_context q/k/hits/symbols/graph}`, `reads:{path:line}`, `payload_verified:{input,output}`, `files_read:<=2`, then the returned `footer` block (`bus_ref`, `memory_ref`, `knowledge_refs`, `event_ref`) verbatim, plus per-stage `verdict` + `gates`. No product files. Live RAG only.

## Tooling
Unit + integration fixtures, coverage report, package-manifest scan, diff harness for golden files, and the three gate commands (see overlay for product tooling).
