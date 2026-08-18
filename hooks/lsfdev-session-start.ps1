# SessionStart hook: reclaims lsFusion dev servers for a session that comes
# back, and explains servers that were auto-stopped while it was away.
#
# Fires on every session start (startup / resume / clear / compact / fork) of
# every project on this machine, so it must be quick and silent unless it has
# something to say. Its stdout is added to Claude's context - that is the
# channel used to report an auto-stop, so nothing else may reach stdout.
#
#   1. A pending stop for THIS session id (the CLI process ended, the user came
#      back before the grace ran out) -> restored into the live ledger. The
#      auto-stop is cancelled; the session owns its servers again.
#   2. Sibling sessions = same cwd (/clear gives the folder a new session id; a
#      second conversation opened on the same project). Their pending stops are
#      adopted (turned into our live claim, the pending file removed), and their
#      LIVE ledgers are copied into ours: a shared claim, so the servers of a
#      folder stop only when NO live session in that folder claims them - a
#      session resuming after a sibling adopted its servers is covered too.
#   3. A .stopped marker for this session id / cwd -> printed as context (what
#      was stopped, when, why, how to start again, how to opt out), deleted.
#   4. Any overdue pending file (its runner died with a reboot or was killed)
#      -> a fresh GC runner is armed for it.

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
try { . (Join-Path $PSScriptRoot 'lsfdev-session-common.ps1') } catch { exit 0 }

$in = Read-HookInput
if (-not $in -or -not $in.session_id) { exit 0 }
$sid = [string]$in.session_id
$source = [string]$in.source
$cwd = [string]$in.cwd
$cwdNorm = $cwd.TrimEnd('\', '/')

$notes = New-Object System.Collections.Generic.List[string]
try {
    # 1. own pending stop -> live again
    $own = Get-PendingPath $sid
    if (Test-Path -LiteralPath $own) {
        $meta = Read-PendingFile $own
        Add-LedgerDirs $sid $meta.dirs $cwd
        Remove-Item -LiteralPath $own -Force -ErrorAction SilentlyContinue
        Write-HookLog 'start' ("session {0} source={1}: resumed - pending stop cancelled, {2} project(s) live again: {3}" -f $sid, $source, $meta.dirs.Count, ($meta.dirs -join '; '))
    }

    # 2. siblings (same cwd): adopt their pending stops, share their live claims
    if ($cwdNorm) {
        foreach ($f in Get-PendingFiles) {
            $meta = Read-PendingFile $f.FullName
            if ($meta.sid -ieq $sid) { continue }
            if (-not $meta.cwd -or -not ($meta.cwd.TrimEnd('\', '/') -ieq $cwdNorm)) { continue }
            Add-LedgerDirs $sid $meta.dirs $cwd
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            Write-HookLog 'start' ("session {0} source={1}: adopted the pending stop of session {2} (same cwd {3}), {4} project(s) live again: {5}" -f $sid, $source, $meta.sid, $cwd, $meta.dirs.Count, ($meta.dirs -join '; '))
        }
        foreach ($f in Get-LiveLedgers) {
            $osid = Get-SidFromLedgerName $f.Name
            if (-not $osid -or $osid -ieq $sid) { continue }
            $ocwd = Get-LedgerCwd $f.FullName
            if (-not $ocwd -or -not ($ocwd.TrimEnd('\', '/') -ieq $cwdNorm)) { continue }
            $d = @(Read-LedgerDirs $f.FullName)
            if (-not $d.Count) { continue }
            $before = @(); $mine = Get-LedgerPath $sid
            if (Test-Path -LiteralPath $mine) { $before = @(Read-LedgerDirs $mine) }
            $new = @($d | Where-Object { $x = $_; -not ($before | Where-Object { $_ -ieq $x }) })
            if ($new.Count) {
                Add-LedgerDirs $sid $new $cwd
                Write-HookLog 'start' ("session {0} source={1}: shares the live claim of session {2} (same cwd) on {3}" -f $sid, $source, $osid, ($new -join '; '))
            }
        }
    }

    # 3. explain what the GC runner stopped for this session / folder
    $markers = @()
    $ownStopped = Get-StoppedPath $sid
    if (Test-Path -LiteralPath $ownStopped) { $markers += Get-Item -LiteralPath $ownStopped }
    if ($cwdNorm) {
        foreach ($f in @(Get-ChildItem -Path $script:LsfTemp -Filter 'claude-lsfdev-*.stopped' -File -ErrorAction SilentlyContinue)) {
            if ($f.FullName -ieq $ownStopped) { continue }
            $m = Read-PendingFile $f.FullName
            if ($m.cwd -and ($m.cwd.TrimEnd('\', '/') -ieq $cwdNorm)) { $markers += $f }
        }
    }
    foreach ($f in $markers) {
        $m = Read-PendingFile $f.FullName
        if ($m.dirs.Count) {
            $when = if ($m.due) { $m.due.ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { 'earlier' }
            $why = if ($m.reason) { $m.reason } else { 'unknown' }
            $notes.Add(("lsfusion-dev: the lsFusion dev server(s) of {0} were auto-stopped at {1}: the Claude Code process of the session that started them had ended (reason: {2}) and no session was resumed or started in this folder within {3} min, so the plugin's session-end cleanup stopped them - this is not a crash. Start again when needed:  lsfdev.ps1 start -ProjectDir ""{4}""   (opt out per project: lsfdev.ps1 keep-running -ProjectDir ""{4}"" ; details: {5})" -f ($m.dirs -join ', '), $when, $why, (Get-GraceMinutes), $m.dirs[0], $script:LsfHookLog))
        }
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        Write-HookLog 'start' ("session {0} source={1}: reported the auto-stop of {2} (marker of session {3})" -f $sid, $source, ($m.dirs -join '; '), $m.sid)
    }

    # 4. overdue pending stops without a live runner -> re-arm
    $now = [DateTime]::UtcNow
    $overdue = @(Get-PendingFiles | Where-Object { $m = Read-PendingFile $_.FullName; $m.due -and $m.due -le $now })
    if ($overdue.Count) {
        $null = Start-GcRunner $now ("re-armed at session start of $sid for " + $overdue.Count + " overdue pending stop(s)")
    }
} catch {
    Write-HookLog 'start' "session $sid source=${source}: hook error $($_.Exception.Message)"
}

if ($notes.Count) {
    # UTF-8 on stdout: a project path with non-ASCII characters must reach
    # Claude intact, not as OEM-code-page mojibake.
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    foreach ($n in $notes) { [Console]::Out.WriteLine($n) }
}
exit 0
