#!/usr/bin/env bash
# scripts/index-via-bridge.sh — register/refresh a mirror and send it to the MCP bridge for indexing.
#
# Usage (HOST — has the mirror + pipeline-global checkout):
#   bash scripts/index-via-bridge.sh --project <projectId> [--url <git-url> --branch <branch>] [--paths a,b] [--bridge http://127.0.0.1:8003] [--skip-verify]
#
# Usage (REMOTE — no host filesystem, only the bridge URL+token):
#   PIPELINE_BRIDGE_URL=https://<ngrok>.ngrok-free.app PIPELINE_BRIDGE_TOKEN=<token> \
#     bash scripts/index-via-bridge.sh --project <projectId> [--bridge https://<ngrok>.ngrok-free.app] [--paths a,b]
#   # or on Windows PowerShell: use the Invoke-RestMethod snippet printed by --help
#
# Why: a remote agent lives on another machine and has no host filesystem.
# The host keeps the mirror at hostPath (config/projects.json) and the bridge
# (zed-mcp-v4 over HTTP on :8003) indexes it. This script is the glue:
#  HOST: 1. register/refresh the mirror via scripts/sync-remote-mirror.sh
#        2. POST tools/call index_codebase (+ poll index_status) to the HTTP bridge
#        3. verify with a sample code_context call
#  REMOTE: skips (1) and just POSTs to $PIPELINE_BRIDGE_URL/mcp — the host's
#        index_codebase handler refreshes the mirror itself (sync block) before indexing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_ID=""
URL=""
BRANCH=""
MIRROR_PATH=""
BRIDGE="${PIPELINE_BRIDGE_URL:-http://127.0.0.1:8003}"
SKIP_VERIFY=0
PATHS_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT_ID="$2"; shift 2 ;;
    --project=*) PROJECT_ID="${1#--project=}"; shift ;;
    --url) URL="$2"; shift 2 ;;
    --url=*) URL="${1#--url=}"; shift ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --branch=*) BRANCH="${1#--branch=}"; shift ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --bridge=*) BRIDGE="${1#--bridge=}"; shift ;;
    --path) MIRROR_PATH="$2"; shift 2 ;;
    --path=*) MIRROR_PATH="${1#--path=}"; shift ;;
    --paths) PATHS_ARG="$2"; shift 2 ;;
    --paths=*) PATHS_ARG="${1#--paths=}"; shift ;;
    --skip-verify) SKIP_VERIFY=1; shift ;;
    -h|--help)
      sed -n '2,60p' "$0"
      echo ""
      echo "Env: PIPELINE_BRIDGE_TOKEN (or /tmp/pipeline-bridge-token), PIPELINE_BRIDGE_URL, GITHUB_TOKEN (private repos on host)"
      echo ""
      echo "Remote (Windows PowerShell) — no bash needed:"
      echo '  $env:PIPELINE_BRIDGE_URL="https://<ngrok>.ngrok-free.app"; $env:PIPELINE_BRIDGE_TOKEN="<token>"'
      echo '  $body='\''{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"index_codebase","arguments":{"projectId":"admin"}}}'\'
      echo '  Invoke-RestMethod -Method Post -Uri "$env:PIPELINE_BRIDGE_URL/mcp" -Headers @{Authorization="Bearer $env:PIPELINE_BRIDGE_TOKEN"} -ContentType "application/json" -Body $body'
      exit 0
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$PROJECT_ID" ]; then
  echo "FATAL: --project <projectId> is required" >&2
  exit 2
fi

# ── token ────────────────────────────────────────────────────────────────
TOKEN="${PIPELINE_BRIDGE_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f /tmp/pipeline-bridge-token ]; then
  TOKEN="$(cat /tmp/pipeline-bridge-token)"
fi
MCP_URL="${BRIDGE%/}/mcp"
HEALTH_URL="${BRIDGE%/}/health"

echo "[index-via-bridge] project : $PROJECT_ID"
echo "[index-via-bridge] bridge  : $BRIDGE"

# ── detect REMOTE mode: not on the host (no sync-remote-mirror.sh host checkout) ─
# Remote has no pipeline-global/scripts/sync-remote-mirror.sh host path and the bridge
# is an ngrok URL. In that case skip mirror creation — the host's index_codebase
# refreshes the mirror from the sync block itself.
IS_REMOTE=0
if [ ! -f "$SCRIPT_DIR/sync-remote-mirror.sh" ]; then
  IS_REMOTE=1
elif [[ "$BRIDGE" == *"ngrok"* ]] && [ -n "${PIPELINE_BRIDGE_URL:-}" ]; then
  # Caller explicitly set a tunnel URL from env — treat as remote invocation even
  # when the script file exists (e.g. copied standalone).
  # Only force remote when the registry is absent (no host checkout copy).
  if [ ! -f "$PIPELINE_ROOT/config/projects.json" ]; then
    IS_REMOTE=1
  fi
fi
# Explicit override: URL implies host work; without it a remote just indexes.
if [ "$IS_REMOTE" -eq 1 ] && [ -n "$URL" ]; then
  echo "[index-via-bridge] remote mode: ignoring --url/--branch (mirror is host-managed)" >&2
  echo "  Register once on the HOST:" >&2
  echo "    GITHUB_TOKEN=<pat> bash scripts/index-via-bridge.sh --project $PROJECT_ID --url $URL --branch $BRANCH" >&2
  URL=""; BRANCH=""
fi

# ── 1. mirror (HOST only) ────────────────────────────────────────────────
if [ "$IS_REMOTE" -eq 1 ]; then
  echo "[index-via-bridge] remote mode — skipping mirror creation, will POST index_codebase to $BRIDGE"
elif [ -n "$URL" ] && [ -n "$BRANCH" ]; then
  # URL+branch supplied: clone/refresh mirror (path defaults to sibling ~/www/<id>)
  if [ -z "$MIRROR_PATH" ]; then
    MIRROR_PATH="$(cd "$PIPELINE_ROOT/.." && pwd)/$PROJECT_ID"
  fi
  SYNC_URL="$URL"
  if [[ "$SYNC_URL" == https://github.com/* ]] && [ -n "${GITHUB_TOKEN:-}" ] && [[ "$SYNC_URL" != *"@"* ]]; then
    SYNC_URL="${SYNC_URL/https:\/\/github.com\//https:\/\/oauth2:${GITHUB_TOKEN}@github.com/}"
  fi
  if ! bash "$SCRIPT_DIR/sync-remote-mirror.sh" --project "$PROJECT_ID" --url "$SYNC_URL" --branch "$BRANCH" --path "$MIRROR_PATH" --register 2>&1; then
    EC=$?
    echo "[index-via-bridge] mirror create failed (exit $EC)." >&2
    echo "  Private repo? Provide a host-readable URL:" >&2
    echo "    GITHUB_TOKEN=<pat> bash scripts/index-via-bridge.sh --project $PROJECT_ID --url https://github.com/KONEKTT/konektt-admin.git --branch development" >&2
    echo "  or use SSH if the host has a deploy key:" >&2
    echo "    bash scripts/index-via-bridge.sh --project $PROJECT_ID --url git@github.com:KONEKTT/konektt-admin.git --branch development" >&2
    exit $EC
  fi
elif [ -n "$URL" ] || [ -n "$BRANCH" ]; then
  echo "FATAL: --url and --branch must be given together" >&2; exit 2
elif [ -n "$MIRROR_PATH" ]; then
  # Existing checkout outside pipeline-global (no URL needed) — point hostPath there.
  if [ ! -d "$MIRROR_PATH/.git" ]; then
    echo "FATAL: --path $MIRROR_PATH does not exist or is not a git repo" >&2
    echo "  Clone it first, or pass --url/--branch to create a mirror." >&2
    exit 2
  fi
  echo "[index-via-bridge] using existing checkout at $MIRROR_PATH"
  python3 - "$PIPELINE_ROOT/config/projects.json" "$PROJECT_ID" "$MIRROR_PATH" <<'PY'
import json, sys, os
reg, pid, host_path = sys.argv[1:4]
with open(reg) as fh:
    raw=json.load(fh)
entry=raw.setdefault("projects", {}).setdefault(pid, {})
entry["hostPath"]=host_path
entry.setdefault("pgSchema", f"p_{pid.replace('-','_')}")
# keep existing sync block if any; do not overwrite url/branch when only --path was given
tmp=reg+".tmp"
with open(tmp,"w") as fh: json.dump(raw,fh,indent=2); fh.write("\n")
os.replace(tmp, reg)
print(f"[index-via-bridge] registered hostPath for '{pid}' -> {host_path}")
PY
else
  # no URL, no explicit path — just refresh if sync block exists; otherwise plain checkout
  if bash "$SCRIPT_DIR/sync-remote-mirror.sh" --project "$PROJECT_ID" 2>&1 | tee /tmp/index-via-bridge-sync.log; then
    cat /tmp/index-via-bridge-sync.log | head -20
  else
    if grep -q "no git url/branch" /tmp/index-via-bridge-sync.log 2>/dev/null; then
      echo "[index-via-bridge] no sync block for '$PROJECT_ID' — indexing local checkout directly"
    else
      cat /tmp/index-via-bridge-sync.log
      exit 1
    fi
  fi
fi

# ── bridge health ────────────────────────────────────────────────────────
if ! curl -fsS --max-time 5 "$HEALTH_URL" >/dev/null 2>&1; then
  echo "FATAL: bridge not reachable at $HEALTH_URL" >&2
  echo "       start it: PIPELINE_BRIDGE_TOKEN=\$TOKEN bash scripts/start-http-bridge.sh" >&2
  exit 1
fi
if [ -z "$TOKEN" ]; then
  echo "WARN: no PIPELINE_BRIDGE_TOKEN — bridge may reject /mcp with 401" >&2
fi

# ── 2. index_codebase + 3. poll index_status via MCP HTTP ─────────────────
python3 - "$PROJECT_ID" "$MCP_URL" "$TOKEN" "$PATHS_ARG" "$SKIP_VERIFY" <<'PY'
import json, sys, time, urllib.request, urllib.error

project_id, mcp_url, token, paths_arg, skip_verify = sys.argv[1:6]
skip_verify = skip_verify == "1"
paths = [p.strip() for p in paths_arg.split(",") if p.strip()] if paths_arg else None

def mcp_call(name, arguments):
    payload = json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name": name, "arguments": arguments}}).encode()
    req = urllib.request.Request(mcp_url, data=payload, method="POST")
    req.add_header("content-type", "application/json")
    req.add_header("accept", "application/json, text/event-stream")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            body = resp.read().decode()
    except urllib.error.HTTPError as e:
        print(f"FATAL: MCP {name} HTTP {e.code}: {e.read().decode()[:500]}", file=sys.stderr)
        sys.exit(1)
    # HTTP bridge returns SSE-ish; extract JSON payload
    # The body is typically: event: message\ndata: {...}\n\n  or plain JSON
    data = None
    for line in body.splitlines():
        line=line.strip()
        if line.startswith("data:"):
            line=line[5:].strip()
        if not line or line.startswith("event:"):
            continue
        try:
            data = json.loads(line)
            break
        except: pass
    if data is None:
        try: data = json.loads(body)
        except: pass
    if data is None:
        print(f"FATAL: unparseable MCP response for {name}: {body[:800]}", file=sys.stderr)
        sys.exit(1)
    # MCP tools/call wraps result in result.content[].text (JSON string) or result.structuredContent
    result = data.get("result") or {}
    # Try structuredContent first (new SDK), then content[].text
    if "structuredContent" in result:
        return result["structuredContent"]
    contents = result.get("content") or []
    for c in contents:
        t = c.get("text") if isinstance(c, dict) else None
        if t:
            try: return json.loads(t)
            except:
                # bridge may return YAML-ish text for index results
                if "status:" in t:
                    d={}
                    for line in t.splitlines():
                        if ":" in line and not line.strip().startswith("#"):
                            k,v=line.split(":",1)
                            d[k.strip()]=v.strip().strip('"')
                    if d: return d
                return {"raw": t}
    return result

print(f"[index-via-bridge] calling index_codebase projectId={project_id} paths={paths or 'FULL'}")
args = {"projectId": project_id}
if paths:
    args["paths"] = paths
res = mcp_call("index_codebase", args)
print(f"[index-via-bridge] index_codebase -> {json.dumps(res)[:800]}")
status = res.get("status") if isinstance(res, dict) else None

# Poll index_status while running (bounded ~120s)
if status == "running":
    deadline = time.time() + 120
    while time.time() < deadline:
        time.sleep(2)
        st = mcp_call("index_status", {"projectId": project_id})
        print(f"[index-via-bridge] index_status -> {json.dumps(st)[:600]}")
        s = st.get("status") if isinstance(st, dict) else None
        if s in ("done", "ok", "completed", "error", "failed"):
            res = st
            status = s
            break
        if s not in ("running", "indexing", None):
            break
    if status == "running":
        print("[index-via-bridge] still running after poll budget — check index_status later", file=sys.stderr)

if isinstance(res, dict) and res.get("status") in ("error","failed"):
    print(f"[index-via-bridge] index FAILED: {res.get('error')}", file=sys.stderr)
    sys.exit(1)
print(f"[index-via-bridge] index OK status={status or res.get('status','?')}")

if skip_verify:
    sys.exit(0)

# ── verify code_context ──────────────────────────────────────────────────
print(f"[index-via-bridge] verifying code_context projectId={project_id}")
cc = mcp_call("code_context", {"projectId": project_id, "query": "overview entrypoint", "top_k": 3})
hits = cc.get("results") or cc.get("hits") or []
# compact responses use results[]
total = cc.get("total_results", len(hits) if isinstance(hits, list) else 0)
print(f"[index-via-bridge] code_context hits={len(hits) if isinstance(hits, list) else '?'} total_results={total}")
if isinstance(hits, list) and hits:
    for h in hits[:3]:
        sid = h.get("source_id") or h.get("source") or "?"
        print(f"  - {sid}: {(h.get('content') or '')[:120].replace(chr(10),' ')}")
if not hits:
    print("[index-via-bridge] WARN: code_context returned 0 hits — corpus may be empty", file=sys.stderr)
PY

echo "[index-via-bridge] done — code_context({projectId:\"$PROJECT_ID\"}) should now return source."
