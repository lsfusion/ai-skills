# PostToolUse hook (PowerShell|Bash): records lsFusion dev instances started in this session.
#
# Reads the hook input JSON from stdin. When the executed shell command is an
# lsfdev.ps1 start / start-server / start-web / restart with an explicit
# -ProjectDir, appends that project dir to a per-session ledger file in %TEMP%.
# The companion SessionEnd hook (lsfdev-session-stop.ps1) reads the ledger and
# stops exactly these instances - so parallel Claude sessions and servers
# started outside the session (e.g. from the IDE) are never touched.

$in = [Console]::In.ReadToEnd() | ConvertFrom-Json
$c = [string]$in.tool_input.command
if ($c -match 'lsfdev\.ps1' -and $c -match '\b(start|restart)\b' -and $c -match '-ProjectDir\s+[\x22'']([^\x22'']+)') {
    Add-Content -LiteralPath (Join-Path $env:TEMP ('claude-lsfdev-' + $in.session_id + '.txt')) -Value $Matches[1]
}
