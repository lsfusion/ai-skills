# SessionEnd hook: schedules the stop of every lsFusion dev instance this
# session started - and NO LONGER stops them on the spot.
#
# Why deferred. "SessionEnd" fires whenever the Claude Code CLI process ends,
# and the process ends far more often than the user's work does: the desktop
# app shuts an idle session's process down (~15 min after the last turn,
# measured) and starts a new one - same session id, same transcript - when the
# user comes back; the CLI is also restarted on app updates, /clear (new id,
# same folder), crashes. The pre-0.1.34 hook ran 'lsfdev.ps1 stop' right here,
# so a coffee break killed the server the next prompt still needed (measured
# 2026-08-17: a server stopped 15 min after the session's last message while
# its Tomcat kept running - the stop was even cut short by the SessionEnd time
# budget). SDK/desktop exits report reason 'other' for BOTH the idle shutdown
# and a real close (measured), so the reason cannot tell them apart.
#
# What happens now:
#   reason 'resume'   -> the session pauses to be resumed (/resume switch);
#                        the ledger stays live, nothing is scheduled.
#   anything else     -> the live ledger becomes a PENDING STOP due in
#                        LSFDEV_STOP_GRACE_MIN minutes (default 60), and a
#                        detached GC runner (lsfdev-session-gc.ps1) is armed
#                        for that moment. If the session is resumed - or a new
#                        session starts in the same folder - before the runner
#                        fires, the SessionStart hook turns the pending stop
#                        back into a live claim and nothing is stopped. Otherwise
#                        the runner stops exactly the ledger's projects (skipping
#                        any that a live session claims by then, and projects
#                        marked 'lsfdev.ps1 keep-running'), and leaves a
#                        .stopped marker so the next session start in that
#                        folder learns what happened and why.
#   LSFDEV_STOP_GRACE_MIN=0 restores the immediate stop (respecting the same
#   claims/keep-running rules).
# The ledger file is renamed first, so a failure past that point can only
# leave a server running - never a stale live claim, and never a stop the
# session did not schedule.

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
try { . (Join-Path $PSScriptRoot 'lsfdev-session-common.ps1') } catch { exit 0 }

$in = Read-HookInput
if (-not $in -or -not $in.session_id) { exit 0 }
$sid = [string]$in.session_id
$reason = [string]$in.reason
$cwd = [string]$in.cwd
$ledger = Get-LedgerPath $sid

if (-not (Test-Path -LiteralPath $ledger)) {
    # Nothing owned by this session. (Do not log - most sessions never touch
    # lsFusion, and every one of them ends.)
    exit 0
}

if ($reason -ieq 'resume') {
    Write-HookLog 'end' "session $sid reason=resume: pausing, ledger kept live (no stop scheduled)"
    exit 0
}

$dirs = @(Read-LedgerDirs $ledger)
if (-not $dirs.Count) { Remove-Item -LiteralPath $ledger -Force -ErrorAction SilentlyContinue; exit 0 }

$grace = Get-GraceMinutes
$now = [DateTime]::UtcNow

if ($grace -le 0) {
    # Immediate mode (opt-in): the old behaviour, minus its two blind spots.
    Remove-Item -LiteralPath $ledger -Force -ErrorAction SilentlyContinue
    $lsfdev = Resolve-LsfdevScript
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        if (Test-DirClaimedLive $dir $sid) { Write-HookLog 'end' "session $sid reason=${reason}: $dir kept - claimed by another live session"; continue }
        if (Test-KeepRunning $dir)        { Write-HookLog 'end' "session $sid reason=${reason}: $dir kept - keep-running is set"; continue }
        if (-not $lsfdev) { Write-HookLog 'end' "session $sid reason=${reason}: $dir NOT stopped - lsfdev.ps1 not found"; continue }
        try { & $lsfdev stop -ProjectDir $dir *> $null } catch { }
        Write-HookLog 'end' "session $sid reason=${reason}: stopped $dir immediately (LSFDEV_STOP_GRACE_MIN=0)"
    }
    exit 0
}

# Deferred mode. Merge into an existing pending file for this sid (a resume that
# never wrote a tool call would have restored it, but be safe).
$due = $now.AddMinutes($grace)
$pending = Get-PendingPath $sid
$merged = New-Object System.Collections.Generic.List[string]
if (Test-Path -LiteralPath $pending) { foreach ($d in (Read-PendingFile $pending).dirs) { $merged.Add($d) } }
foreach ($d in $dirs) { $merged.Add($d) }
try {
    Write-PendingFile $pending @{ cwd = $cwd; reason = $reason; ended = $now.ToString('o'); due = $due.ToString('o') } @($merged)
    Remove-Item -LiteralPath $ledger -Force -ErrorAction Stop
} catch {
    Write-HookLog 'end' "session $sid reason=${reason}: could not write the pending stop ($($_.Exception.Message)) - ledger left as is"
    exit 0
}
Write-HookLog 'end' ("session {0} reason={1} cwd={2}: {3} project(s) -> pending stop due {4:yyyy-MM-dd HH:mm:ss}Z (grace {5} min): {6}" -f $sid, $reason, $cwd, $merged.Count, $due, $grace, ($merged -join '; '))
$null = Start-GcRunner $due "session $sid ended ($reason)"
exit 0
