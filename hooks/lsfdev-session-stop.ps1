# SessionEnd hook: stops every lsFusion dev instance this session started.
#
# Reads the per-session ledger written by lsfdev-session-track.ps1 and runs
# `lsfdev.ps1 stop -ProjectDir <dir>` for each unique project dir, then removes
# the ledger. Instances belonging to other sessions (their ledgers carry other
# session ids) and servers started outside lsfdev keep running.

$in = [Console]::In.ReadToEnd() | ConvertFrom-Json
$ledger = Join-Path $env:TEMP ('claude-lsfdev-' + $in.session_id + '.txt')
if (-not (Test-Path $ledger)) { exit 0 }

$lsfdev = Join-Path $PSScriptRoot '..\skills\lsfusion-dev\scripts\lsfdev.ps1'
Get-Content $ledger | Sort-Object -Unique | ForEach-Object {
    if (Test-Path $_) { & $lsfdev stop -ProjectDir $_ }
}
Remove-Item $ledger -Force
