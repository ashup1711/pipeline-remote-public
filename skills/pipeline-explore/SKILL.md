---
name: pipeline-explore
description: Explore and ground the current phase using RAG-first discovery.
---

# Pipeline explore

Explore the repository for the active phase and produce grounding; never modify product code. Never create `.pipeline/**` files.

## Primary Reference

This skill delegates to the explore agent at `pipeline-global/agents/base/explore.md` for full protocol details including:
- All discovery and persistence via native MCP tools — curl, node -e, and bash are NEVER used by explore
- Fused RAG-first retrieval contract (`code_context` canonical)
- TodoWrite + bus state ownership
- Memory bus protocol (context_boot — canonical `state` + events + first kit in one call; fallback bus_recentContext)
- ONE fused `publish_result` call for the entire handoff (brief + findings + event + bus event + hot context)
- Knowledge platform integration
- File lease protocol

## Quick Reference

### RAG-first workflow (MANDATORY, fused, fileless) — payload-verified, merged tools

MCP calls must be issued as native tool calls with object arguments. Do not write
them as shell commands or call deprecated aliases. The minimum valid shapes are:
`context_boot({projectId,taskId,limit,eventTypes,query,memory_query})`,
`code_context({query,top_k:8,include_graph:true,rerank:true})`,
`knowledge_search({query,top_k:5})`, and
`memory_recall({query,agent_id:"explore",top_k:3})`.
Delivery is ONE fused call — never the 5-call chain:
`publish_result({projectId,taskId,role:"explore",phase,summary:<brief>,memory:{metadata:{type:"context-brief"}},knowledge:[{kind:"finding",finding_type,severity,title,description,file_path,line_start,line_end}],event:{event_type:"explore_completed"},publish:{type:"finding_added",payload:{findings,phase,taskId}},hot_context:<≤200 lines>})`.
Sections you omit return `status:"skipped"`; `role:"explore"` may run memory,
knowledge, event, publish, and hot_context (anything else returns `denied`).
Read `failures[]` and repair an errored/timeout section once with the matching
direct tool. Copy the returned `footer` verbatim — never hand-assemble
`memory_ref`/`knowledge_refs`/`event_ref`/`bus_ref`.

1. **Step 0 BOOT (payload-verified)** — `context_boot({ projectId, taskId, limit: 10, eventTypes: ["finding_added","explore_completed","tasks_allocated","task_completed"], query: "<first FR group query>", memory_query: "P<phase> context brief" })` — ONE round-trip: bus canonical `state`+events + brief recall + first kit; log `boot:{bus,memory,code}` + `retrieval:{bus eventIds}` (fallback: `bus_recentContext` in parallel with `memory_recall`/`code_context`). No file reads before Step 0.
2. **Step 1 FUSED — `code_context` canonical (merged)** — single `code_context({ query: "<FR group keywords + FR ID>", top_k: 8, include_graph: true, rerank: true })` per FR group. All legacy discovery tools (`retrieve_symbols`, `context_compose`, `ast_lookup`, `graph_*`, `rerank`) are merged into `code_context` — not advertised. `query` required non-empty; output `{hits, scores, symbols, graph}` verified and logged as `retrieval:{code_context q/k/hits/symbols/graph}`.
3. **Step 2 READ (payload-verified)** — `read` only cited line ranges from Step 1 symbols (`path:line`, ≤2 files). Bulk reads before Step 1 = VIOLATION (redispatch ONCE; second failure ask user). Log `reads:{path:line}` + `payload_verified:{input,output}`.

### Deliverables (ship via bus — no files)

## BASH IS FORBIDDEN — semantic-only RAG from context (v6.1, hard violation)
Semantic content ONLY from bus + `code_context` per FR group + `knowledge_search`/`memory_recall` + ≤2 cited reads. Curl, node -e, and bash are NEVER used by explore. Allowed fallback ONLY after `RAG unavailable; used targeted read/grep fallback` + attempted `code_context {q}`: `git ls-files`, `grep -n`, `rg`, bounded reads. NEVER `ls -R`/`find`/`ls`/`git status`/`head -n`/`cat`/`fd`. NO_PROPAGATION: brief indexed in RAG, not pasted wholesale downstream. Healthy-RAG scan = VIOLATION (redispatch ONCE).

- §1 FR/NFR inventory, §2 Code anchors, §3 Code gaps
- `## Concrete Filesystem Proposal` (≤30 lines)
- `## Diff Spec (Apple-style, strict)` as nested YAML
- `## File Implementation Order`, `## Dependency-Graph Valence`, `## Discoveries` (errors only)
- `## Continuation Prompt for Next Agent (≤12 lines)`

### Before the handoff (payload-verified)

Make ONE `publish_result({role:"explore", …})` call (payload-verified: `projectId`+`taskId`+`role`+`summary` required), then release any lease. Handoff footer must contain `retrieval:{code_context q/k/hits/symbols/graph}` then `reads:{path:line}` then `payload_verified:{input,output}` then the returned `footer` block, in that order. Do not edit TodoWrite; do not create `.pipeline/**` files. Live RAG only — every tool input/output verified before handoff.
