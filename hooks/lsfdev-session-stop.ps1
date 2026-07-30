# SessionEnd hook: stops every lsFusion dev instance this session started.
#
# Reads the per-session ledger written by lsfdev-session-track.ps1 and runs
# `lsfdev.ps1 stop -ProjectDir <dir>` for each unique project dir. The ledger is
# removed up front, so a failing stop cannot leave a stale ledger behind, and each
# stop runs in its own try/catch, so one broken project cannot keep the rest
# running. Instances belonging to other sessions (their ledgers carry other session
# ids) and servers started outside lsfdev keep running.
# Accepted micro-race: a start whose async tracker has not written the ledger by
# the time the session ends is not stopped - the server just stays up, which is no
# worse than not having this hook at all.

# Claude Code writes the hook input as UTF-8; [Console]::In would decode it in the
# OEM code page and garble non-ASCII session ids/paths, so read the raw stream explicitly.
# TrimStart drops a BOM if the feeding pipe writes one (StreamReader keeps it).
$in = (New-Object IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)).ReadToEnd().TrimStart([char]0xFEFF) | ConvertFrom-Json
$ledger = Join-Path $env:TEMP ('claude-lsfdev-' + $in.session_id + '.txt')
if (-not (Test-Path -LiteralPath $ledger)) { exit 0 }

$dirs = @(Get-Content -LiteralPath $ledger -Encoding UTF8 | Sort-Object -Unique)
Remove-Item -LiteralPath $ledger -Force

$lsfdev = Join-Path $PSScriptRoot '..\skills\lsfusion-dev\scripts\lsfdev.ps1'
foreach ($dir in $dirs) {
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
    try { & $lsfdev stop -ProjectDir $dir } catch { }
}
exit 0
