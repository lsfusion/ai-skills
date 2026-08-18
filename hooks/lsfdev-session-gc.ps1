# Detached GC runner: executes PENDING STOPS once their grace period is over.
#
# Armed by the SessionEnd hook (one runner per ended session, -Due = that
# session's due time) and re-armed by the SessionStart hook when it finds an
# overdue pending file whose runner is gone (killed, machine rebooted, ...).
# Runs hidden and detached from the Claude Code process tree. Sleeps until
# -Due, then processes EVERY overdue pending file, not just its own - runners
# are interchangeable, and a pending file is claimed by an atomic rename to
# .stopping so two runners never act on the same one.
#
# For each project dir of an overdue pending file:
#   - a LIVE session ledger claims it     -> left running (that session owns it now)
#   - the project has keepRunning set     -> left running ('lsfdev.ps1 keep-running')
#   - the project dir is gone             -> nothing to do
#   - otherwise                           -> lsfdev.ps1 stop -ProjectDir <dir>
# What was actually stopped goes into claude-lsfdev-<sid>.stopped, which the
# next SessionStart in that session/cwd reports to Claude (and deletes).
# Every decision is logged to claude-lsfdev-hooks.log.

param(
    [string]$Due = '',      # ISO-8601 UTC ('o' format); empty = now
    [string]$Why = ''
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
try { . (Join-Path $PSScriptRoot 'lsfdev-session-common.ps1') } catch { exit 0 }

$dueUtc = [DateTime]::UtcNow
if ($Due) { try { $dueUtc = [DateTime]::Parse($Due, $null, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { } }

# Sleep in short slices (wall-clock checked each time) so a suspended machine
# does not oversleep by the suspend duration and a far-future due still ends.
$maxWaitUntil = [DateTime]::UtcNow.AddHours(26)
if ($dueUtc -gt $maxWaitUntil) { $dueUtc = $maxWaitUntil }
while ([DateTime]::UtcNow -lt $dueUtc) {
    $left = ($dueUtc - [DateTime]::UtcNow).TotalSeconds
    if ($left -le 0) { break }
    Start-Sleep -Seconds ([Math]::Min(60, [Math]::Ceiling($left)))
}

$now = [DateTime]::UtcNow
$lsfdev = Resolve-LsfdevScript
$processed = 0
foreach ($f in Get-PendingFiles) {
    $meta = Read-PendingFile $f.FullName
    if (-not $meta.due -or $meta.due -gt $now) { continue }          # not yet due (someone else's later grace)
    $stopping = [IO.Path]::ChangeExtension($f.FullName, '.stopping')
    try { Move-Item -LiteralPath $f.FullName -Destination $stopping -ErrorAction Stop } catch { continue }   # another runner took it
    $processed++
    $sid = $meta.sid
    $stopped = New-Object System.Collections.Generic.List[string]
    foreach ($dir in $meta.dirs) {
        if (-not $dir) { continue }
        if (-not (Test-Path -LiteralPath $dir)) { Write-HookLog 'gc' "session $sid due: $dir no longer exists - skipped"; continue }
        if (Test-DirClaimedLive $dir) { Write-HookLog 'gc' "session $sid due: $dir kept - a live session claims it"; continue }
        if (Test-KeepRunning $dir)    { Write-HookLog 'gc' "session $sid due: $dir kept - keep-running is set (lsfdev.ps1 keep-running -Off to re-enable the auto-stop)"; continue }
        if (-not $lsfdev) { Write-HookLog 'gc' "session $sid due: $dir NOT stopped - lsfdev.ps1 not found (plugin removed?)"; continue }
        $tail = ''
        try {
            # *>&1: lsfdev reports via Write-Host (the information stream),
            # which a plain 2>&1 would not capture.
            $out = @(& $lsfdev stop -ProjectDir $dir *>&1 | ForEach-Object { "$_" })
            $tail = (($out | Where-Object { $_ -match '\[OK\]|\[FAIL\]|was not running|NOT killing' } | ForEach-Object { $_.Trim() }) -join ' | ')
        } catch { $tail = "error: $($_.Exception.Message)" }
        $stopped.Add($dir)
        Write-HookLog 'gc' ("session {0} due (ended {1}, {2}): stopped {3} - {4}" -f $sid, $meta.ended, $meta.reason, $dir, $tail)
    }
    if ($stopped.Count) {
        try {
            Write-PendingFile (Get-StoppedPath $sid) @{ cwd = $meta.cwd; reason = $meta.reason; ended = $meta.ended; due = $meta.due.ToString('o') } @($stopped)
        } catch { }
    }
    Remove-Item -LiteralPath $stopping -Force -ErrorAction SilentlyContinue
}
if ($processed -eq 0 -and $Why) { Write-HookLog 'gc' "runner woke for '$Why': nothing overdue (resumed/adopted or already handled)" }

# Housekeeping: .stopping files older than a day are leftovers of a killed
# runner - put them back as overdue pending files so the next runner retries;
# .stopped markers older than a day were never read - drop them.
foreach ($f in @(Get-ChildItem -Path $script:LsfTemp -Filter 'claude-lsfdev-*.stopping' -File -ErrorAction SilentlyContinue)) {
    if ($f.LastWriteTimeUtc -lt $now.AddDays(-1)) { try { Move-Item -LiteralPath $f.FullName -Destination ([IO.Path]::ChangeExtension($f.FullName, '.pending')) -Force } catch { } }
}
foreach ($f in @(Get-ChildItem -Path $script:LsfTemp -Filter 'claude-lsfdev-*.stopped' -File -ErrorAction SilentlyContinue)) {
    if ($f.LastWriteTimeUtc -lt $now.AddDays(-1)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
}
exit 0
