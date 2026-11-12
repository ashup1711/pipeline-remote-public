# scripts/reindex-remote.ps1 — push local checkout to host and reindex (no git, no zip/tar required).
# Runs on the REMOTE machine (Windows) via PowerShell. Host bridge must be live at PIPELINE_BRIDGE_URL.
#
# Usage (from remote):
#   $env:PIPELINE_BRIDGE_URL="https://<ngrok>.ngrok-free.app"
#   $env:PIPELINE_BRIDGE_TOKEN="<token>"
#   powershell -ExecutionPolicy Bypass -File scripts/reindex-remote.ps1 -ProjectId admin -LocalPath "C:\code\admin"
#   powershell -ExecutionPolicy Bypass -File scripts/reindex-remote.ps1 -ProjectId admin -LocalPath "C:\code\admin" -Query "auth controller"
#
# Opencode can run it anytime:
#   powershell -ExecutionPolicy Bypass -File scripts/reindex-remote.ps1 -ProjectId admin -LocalPath "C:\code\admin"

param(
  [string]$ProjectId = "admin",
  [string]$LocalPath = "C:\code\admin",
  [string]$BridgeUrl = $env:PIPELINE_BRIDGE_URL,
  [string]$BridgeToken = $env:PIPELINE_BRIDGE_TOKEN,
  [string]$Query = "admin"
)

$ErrorActionPreference = "Stop"
if (-not $BridgeUrl) { throw "PIPELINE_BRIDGE_URL not set" }
if (-not $BridgeToken) { throw "PIPELINE_BRIDGE_TOKEN not set" }
if (-not (Test-Path $LocalPath)) { throw "LocalPath not found: $LocalPath" }

Write-Host "[reindex] project: $ProjectId"
Write-Host "[reindex] local:   $LocalPath"
Write-Host "[reindex] bridge:  $BridgeUrl"

# Collect files as JSON (no archive) — host POST /upload handles application/json {files:[{path,content}]}
$files = Get-ChildItem -Path $LocalPath -Recurse -File | Where-Object {
  $_.FullName -notmatch '\\\.git\\' -and $_.FullName -notmatch '\\node_modules\\' -and $_.FullName -notmatch '\\dist\\' -and $_.FullName -notmatch '\\\.pipeline\\' -and $_.Length -lt 500KB -and $_.Name -notmatch '^\.DS_Store$'
} | ForEach-Object {
  try {
    $rel = $_.FullName.Substring($LocalPath.Length).TrimStart('\','/') -replace '\\','/'
    if (-not $rel) { return }
    @{ path = $rel; content = [IO.File]::ReadAllText($_.FullName) }
  } catch { Write-Warning "skip $($_.FullName): $($_.Exception.Message)" }
}
if (-not $files -or $files.Count -eq 0) { throw "No files collected from $LocalPath" }
Write-Host "[reindex] collected $($files.Count) files"

$payload = @{ files = $files } | ConvertTo-Json -Depth 4 -Compress
Write-Host "[reindex] uploading..."
$upload = Invoke-RestMethod -Method Post -Uri "$BridgeUrl/upload?projectId=$ProjectId" -Headers @{Authorization="Bearer $BridgeToken"} -ContentType "application/json" -Body $payload
$upload | ConvertTo-Json -Depth 3 | Write-Host

Write-Host "[reindex] indexing..."
$body = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"index_codebase","arguments":{"projectId":"' + $ProjectId + '"}}}'
$idx = Invoke-RestMethod -Method Post -Uri "$BridgeUrl/mcp" -Headers @{Authorization="Bearer $BridgeToken"} -ContentType "application/json" -Body $body
$idx.result.content[0].text | Write-Host

# Poll index_status briefly if still running
for ($i=0; $i -lt 6; $i++) {
  Start-Sleep -Seconds 2
  $stBody = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"index_status","arguments":{"projectId":"' + $ProjectId + '"}}}'
  $st = Invoke-RestMethod -Method Post -Uri "$BridgeUrl/mcp" -Headers @{Authorization="Bearer $BridgeToken"} -ContentType "application/json" -Body $stBody
  $txt = $st.result.content[0].text
  Write-Host "[reindex] status: $txt"
  if ($txt -match 'status:\s*done|status:\s*removed|index_version') { break }
}

Write-Host "[reindex] verifying code_context query=`"$Query`"..."
$verifyBody = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"code_context","arguments":{"projectId":"' + $ProjectId + '","query":"' + $Query + '","top_k":3}}}'
$verify = Invoke-RestMethod -Method Post -Uri "$BridgeUrl/mcp" -Headers @{Authorization="Bearer $BridgeToken"} -ContentType "application/json" -Body $verifyBody
$verify.result.content[0].text | Write-Host

Write-Host "[reindex] done — code_context({projectId:`"$ProjectId`"}) should now return source."
