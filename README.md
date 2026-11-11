# Remote adapter — running the pipeline against a repo on another machine

This runbook covers the case where **the repository lives on a different
machine** than the pipeline. Everything heavy stays on the host; the remote
machine keeps only the repository, the editor, and the agent prompts.

> If the repository is already on the host, you do not need any of this. The
> ordinary flow (`scripts/pipeline-health.sh --strict` → dispatch) applies.

---

## 1. The shape of it

```
┌──────────────────────────── HOST ────────────────────────────┐
│                                                              │
│  ┌──────────────┐   ┌──────────────┐   ┌──────────────────┐  │
│  │ Redis bus    │   │ indexer-v4   │   │ zed-mcp-v4       │  │
│  │ :6380        │◀──│ AST/FTS5     │◀──│ bridge (stdio +  │  │
│  │ (bus state)  │   │ :8002        │   │ HTTP + token)    │  │
│  └──────────────┘   └──────┬───────┘   └────────▲─────────┘  │
│                             │                    │            │
│                    ┌────────▼────────┐           │            │
│                    │ git MIRROR of   │───────────┘            │
│                    │ the remote repo │  index_codebase        │
│                    └─────────────────┘  (fetch+reset first)   │
└──────────────────────────────────────────────────────────────┘
                                     │  HTTPS (tunnel + Bearer token)
┌────────────────────────────────────▼─────────────────────────┐
│                      REMOTE MACHINE                          │
│   repo + .opencode/agents/*.md + .pipeline-remote/           │
│   editor (OpenCode / Zed) → mcp.servers.pipeline = "remote"  │
└──────────────────────────────────────────────────────────────┘
```

**Nothing from the pipeline's implementation is copied to the remote machine.**
No bridge, no indexer, no Redis, no `services/`, no `scripts/`. The remote
machine gets:

| What | Where it comes from |
|---|---|
| The repository | It already has it — that is the premise. |
| The agent prompts | `.opencode/agents/*.md`, rendered on the host and committed. |
| The pipeline skills | The **adapter pack** (`.pipeline-remote/skills`). |
| The generic contract | The **adapter pack** (`.pipeline-remote/AGENTS.base.md`). |
| The MCP wiring | The **adapter pack** (`.pipeline-remote/opencode.json`). |

---

## 2. One-time host setup

### 2.1 Register the project with a `sync` block

The host needs to know that this project's repo is a *mirror* of something
else. `config/projects.json` carries that:

```json
{
  "projects": {
    "acme-app": {
      "hostPath": "/Users/ashutoshraval/www/acme-app",
      "pgSchema": "p_acme_app",
      "sync": { "url": "git@github.com:acme/app.git", "branch": "main" }
    }
  }
}
```

`url` + `branch` are required. `timeoutMs` is optional (default 20000) and
bounds the fetch.

### 2.2 Create the host mirror

```bash
bash scripts/sync-remote-mirror.sh --project acme-app
```

This clones the remote into `hostPath` (or refreshes it if it already exists)
and records the `sync` block in the registry if it is not there yet:

```bash
bash scripts/sync-remote-mirror.sh --project acme-app \
  --url git@github.com:acme/app.git --branch main --register
```

The mirror must live somewhere the **indexer can read** — the indexer mounts
the parent directory of `pipeline-global` read-only, so a sibling of
`pipeline-global` (`~/www/<slug>`) is the natural place.

> The bridge **never clones**. It only refreshes a mirror that already exists.
> A missing mirror is reported, not silently created.

### 2.3 Bring up the host side

```bash
bash scripts/start-remote.sh --project acme-app
```

This verifies the host stack, starts the token-gated HTTP bridge, refreshes
the mirror, builds the adapter pack, and prints the exact values for the
remote machine.

---

## 3. The remote machine

### 3.1 Environment

```bash
export PIPELINE_BRIDGE_URL=https://<tunnel-host>
export PIPELINE_BRIDGE_TOKEN=<the token the host is running with>
```

`PIPELINE_BRIDGE_TOKEN` must match the host's. The host prints it once when
`start-remote.sh` generates it.

**Never commit either value.** The pack's `opencode.json` reads them through
OpenCode's `{env:VAR}` substitution, so only the variable *names* are in git.

### 3.2 Get the pack and the prompts

```bash
git pull
cp .pipeline-remote/opencode.json opencode.json
```

`opencode.json` on the remote machine points at the remote bridge:

```json
"mcp": {
  "servers": {
    "pipeline": {
      "type": "remote",
      "url": "{env:PIPELINE_BRIDGE_URL}/mcp",
      "headers": { "Authorization": "Bearer {env:PIPELINE_BRIDGE_TOKEN}" },
      "timeout": { "catalog": 60000, "execution": 60000 }
    }
  }
}
```

### 3.3 Verify the tunnel

```bash
curl -fsS "$PIPELINE_BRIDGE_URL/health"
# {"status":"ok","transport":"http","tools":38}
```

`GET /health` is unauthenticated and exposes nothing but a status line. Every
other endpoint (`POST /mcp`) requires the Bearer token.

---

## 4. How a change travels

This is the loop the whole setup exists for.

1. **The remote agent writes code** in the repository on the remote machine.
2. **It commits and pushes** to the branch the host mirrors (`main` by
   default). The push is what crosses the network — the pipeline never
   rsyncs a working tree.
3. **The host refreshes the mirror.** `index_codebase` does this automatically
   (bounded `git fetch` + `git reset --hard FETCH_HEAD`) whenever the
   project's registry entry has a `sync` block. `scripts/sync-remote-mirror.sh`
   does it by hand.
4. **The host re-indexes** the refreshed mirror, so the next retrieval on
   either side sees the new code.

The refresh is **non-fatal**: if the fetch fails, the index runs against the
previous checkout and the result carries `sync: {synced:false, error:...}`.
A network hiccup degrades the corpus; it never stops the pipeline.

> The mirror is a mirror, not a working copy. It holds no work of its own, so
> `git reset --hard` discarding its local state is correct — the remote is the
> single source of truth. Do not hand-edit a mirror.

---

## 5. What runs where

| Concern | Host | Remote machine |
|---|---|---|
| MCP bridge | ✅ | ❌ (talks to the host over HTTPS) |
| AST/FTS5 indexer | ✅ | ❌ |
| Redis bus (task state, events, hot context) | ✅ | ❌ (accessed through the bridge) |
| Git mirror of the repo | ✅ | ❌ (the original lives here) |
| Agent prompts | rendered here, committed | ✅ (read from the repo) |
| Pipeline skills | rendered into the pack | ✅ (read from the pack) |
| Product code | ❌ | ✅ (this is the point) |
| `TodoWrite` | ❌ | ✅ (the orchestrator lives with the editor) |

### The fix-loop cap

The verify fix-loop cap (`fix_loops.verify`, max 3) used to be readable only
through `scripts/manage-fix-loops.sh`, which shelled into the host's Redis
container. A remote machine has no Docker daemon, so the cap was invisible
there — it would have been advisory exactly where it matters.

It is now behind the `bus_fixLoops` MCP tool, which reads and writes the same
Redis key (`pipeline:{projectId}:fix_loops:{stage}`) from either side. The
cap is **enforced**, not reported: `increment` refuses to move the counter
past the max and returns `maxReached: true`.

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `MCP TOOLS UNAVAILABLE` on the remote | The remote editor has not bound the `pipeline` server. | Restart the editor's MCP registry; confirm `opencode.json` has the `mcp.servers.pipeline` block. |
| `401 unauthorized` | The token on the remote differs from the host's, or the header is missing. | Re-export `PIPELINE_BRIDGE_TOKEN` with the host's value. |
| `sync: {synced:false, reason:"... not a git repository"}` | No mirror at `hostPath`. | `bash scripts/sync-remote-mirror.sh --project <id>` |
| `sync: {synced:false, error:"git fetch ..."}` | The remote is unreachable, or the ssh key is missing. | Test `git ls-remote <url>` on the host. The fetch is bounded — it never hangs. |
| The index is stale after a remote push | The push happened but no index ran. | `index_codebase({paths:[...]})` — it syncs first. |
| `bus_fixLoops` reports `maxReached` | The verify cap of 3 is spent. | The route must stop and ask the user; that is the contract. |

---

## 7. Commands

| Command | What it does |
|---|---|
| `bash scripts/sync-remote-mirror.sh --project <id>` | Create or refresh the host mirror. `--register` also writes the `sync` block. |
| `bash scripts/pack-remote-adapter.sh --repo <dir>` | Build `.pipeline-remote/` in the adapter repo. |
| `bash scripts/start-remote.sh --project <id>` | Host side end-to-end: health, bridge, mirror, pack, and the printed values. |
| `bash scripts/start-http-bridge.sh` | The token-gated HTTP bridge (used by `start-remote.sh`). |

---

## 8. The rules this design keeps

- **The host owns the state.** Redis, the index, and the corpus never leave
  the host. The remote machine is an editor with a thin client.
- **The pack never carries a secret.** Only environment variable *names* are
  committed; the values live on the remote machine.
- **The bridge never clones.** Mirrors are created deliberately, by a script a
  human ran.
- **Every network operation is bounded.** The git fetch has a timeout, and the
  git environment disables terminal prompts and ssh batch mode, so a missing
  credential fails fast instead of hanging the MCP connection.
- **The mirror is refreshed at exactly one moment that matters** — before an
  index — so the corpus always reflects the remote's latest push.
