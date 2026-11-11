# Setup — public bridge client

This repo is the **public client** for `pipeline-global` (private). It contains only safe-to-publish files: `AGENTS.base.md`, `skills/`, and an `opencode.json.example` that points at the host bridge via `{env:}`.

## Host (private, has Docker)

```bash
# once per project
bash ../pipeline-global/scripts/sync-remote-mirror.sh --project <id> --url <git-url> --branch main --register
PIPELINE_BRIDGE_TOKEN=$(openssl rand -hex 24) bash ../pipeline-global/scripts/start-remote.sh --project <id>
# start tunnel
ngrok http 8003
# note PIPELINE_BRIDGE_URL + TOKEN — give them to remote over secure channel
```

## Remote (public clone)

```bash
git clone https://github.com/ashup1711/pipeline-remote-public.git
cd pipeline-remote-public
cp opencode.json.example opencode.json
# fill env
export PIPELINE_BRIDGE_URL=https://<ngrok>.ngrok-free.app
export PIPELINE_BRIDGE_TOKEN=<token>
curl -fsS $PIPELINE_BRIDGE_URL/health
# {"status":"ok","transport":"http","tools":38}
# POST /mcp requires Bearer token (401 without)
opencode
```

Verify in editor: `bus_recentContext({projectId:"<id>",taskId:"phase-1-context",limit:1})` returns `state`.
