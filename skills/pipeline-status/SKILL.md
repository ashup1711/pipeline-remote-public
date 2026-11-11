---
name: pipeline-status
description: Report pipeline state without modifying files.
---

# Pipeline status

Provide a read-only pipeline report. Never dispatch agents, edit product files, edit TodoWrite, or create `.pipeline/**`.

1. Read `TodoWrite` list + `bus_recentContext` for active phase (limit 10).
2. Report current phase/stage from TodoWrite, active bus task state, hot context presence, the last 5 bus events, `fix_loops` (from bus task blockers), and the next required stage/action.
3. Check whether bus tasks exist; report missing or stale TodoWrite entries without repairing them (orchestrator repairs).
4. Mention whether the verifier's stage verdicts exist in bus/memory (`build_passed`/`build_failed`, `qa_verdict`, `review_verdict` — via `bus_recentContext` events plus `memory_recall`/`knowledge_search`) and whether the pipeline appears ready for a gate. A run that published a failing verdict with `needs_implementer` is NOT ready for the gate.

Use only `TodoWrite`, `bus_recentContext`, `memory_recall`, `knowledge_search`. Do not invoke `code_context` for status, alter state, or claim a stage passed without a bus event.

## BASH IS FORBIDDEN — semantic-only RAG from context (v6.1, hard violation)
Read-only status. NEVER `ls -R`/`find`/`ls`/`git status`/`head -n`/`cat`/`fd` for discovery. State comes ONLY from TodoWrite + bus + memory/knowledge recall. NO_PROPAGATION: report refs and summaries, never paste full prior artifacts wholesale.
