#!/usr/bin/env bash
# scripts/reindex-remote.sh — push local checkout to host and reindex (bash, for Git Bash on Windows or host).
# No git URL, no tar/zip required when run from PowerShell via reindex-remote.ps1; this bash version
# still tars if you use it, but prefers the JSON path when curl + python3 are available.
#
# Usage:
#   PIPELINE_BRIDGE_URL=https://<ngrok>.ngrok-free.app PIPELINE_BRIDGE_TOKEN=<token> \
#     bash scripts/reindex-remote.sh --project admin --path "C:\code\admin"
#   # or on host (local checkout):
#   bash scripts/reindex-remote.sh --project admin --path /Users/ashutoshraval/www/admin
set -euo pipefail
PROJECT_ID="admin"
LOCAL_PATH=""
BRIDGE="${PIPELINE_BRIDGE_URL:-http://127.0.0.1:8003}"
while [ $# -gt 0 ]; do case "$1" in --project) PROJECT_ID="$2"; shift 2;; --project=*) PROJECT_ID="${1#--project=}"; shift;; --path) LOCAL_PATH="$2"; shift 2;; --path=*) LOCAL_PATH="${1#--path=}"; shift;; --bridge) BRIDGE="$2"; shift 2;; --bridge=*) BRIDGE="${1#--bridge=}"; shift;; *) echo "unknown arg $1" >&2; exit 2;; esac; done
[ -n "$LOCAL_PATH" ] || { echo "FATAL: --path <local checkout> required" >&2; exit 2; }
[ -d "$LOCAL_PATH" ] || { echo "FATAL: --path $LOCAL_PATH not found" >&2; exit 2; }
TOKEN="${PIPELINE_BRIDGE_TOKEN:-}"; [ -n "$TOKEN" ] || { [ -f /tmp/pipeline-bridge-token ] && TOKEN="$(cat /tmp/pipeline-bridge-token)" || true; }
[ -n "$TOKEN" ] || { echo "FATAL: PIPELINE_BRIDGE_TOKEN not set" >&2; exit 1; }
echo "[reindex] project:$PROJECT_ID local:$LOCAL_PATH bridge:$BRIDGE"
# Reuse index-via-bridge.sh remote upload path (it handles tar/JSON)
exec bash "$(dirname "$0")/index-via-bridge.sh" --project "$PROJECT_ID" --path "$LOCAL_PATH" --bridge "$BRIDGE"
