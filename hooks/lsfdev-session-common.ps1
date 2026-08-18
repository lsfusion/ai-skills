# Shared helpers for the lsfusion-dev session hooks (dot-sourced by
# lsfdev-session-track.ps1 / -stop.ps1 / -start.ps1 / -gc.ps1). Everything here
# is fail-open: a helper that cannot do its job returns $null/$false and never
# throws out of a hook - a broken hook must at worst leave a dev server
# running, never stop one that is in use.
#
# Files in %TEMP% (all keyed by the Claude session id):
#   claude-lsfdev-<sid>.txt      LIVE ledger: one absolute project dir per line -
#                                the projects this session (re)started last and
#                                therefore owns (written by the PostToolUse hook).
#   claude-lsfdev-<sid>.pending  PENDING STOP: the ledger of a session whose CLI
#                                process ended, with '# key=value' header lines
#                                (cwd, reason, ended, due) above the dirs. Its
#                                projects are stopped by the GC runner once
#                                'due' has passed - unless the session resumes
#                                (or another session in the same cwd starts)
#                                first, which turns it back into a live claim.
#   claude-lsfdev-<sid>.stopping GC runner took the pending file (transient).
#   claude-lsfdev-<sid>.stopped  What the GC runner actually stopped, for the
#                                next SessionStart in that session/cwd to
#                                explain (then deleted).
#   claude-lsfdev-hooks.log      Diagnostics: one line per hook decision. The
#                                first place to look when a dev server "died".
# The live-ledger glob 'claude-lsfdev-*.txt' deliberately does NOT match the
# other extensions, so a claim scan never mistakes a pending stop for ownership.

Set-StrictMode -Off

$script:LsfTemp = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath().TrimEnd('\') }
$script:LsfHookLog = Join-Path $script:LsfTemp 'claude-lsfdev-hooks.log'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Read-HookInput {
    # Claude Code writes the hook input as UTF-8; [Console]::In would decode it in
    # the OEM code page and garble non-ASCII paths, so read the raw stream
    # explicitly. TrimStart drops a BOM if the feeding pipe writes one.
    try {
        $raw = (New-Object IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)).ReadToEnd().TrimStart([char]0xFEFF)
        if (-not $raw.Trim()) { return $null }
        return ($raw | ConvertFrom-Json)
    } catch { return $null }
}

function Get-LedgerPath([string]$sid)  { Join-Path $script:LsfTemp ('claude-lsfdev-' + $sid + '.txt') }
function Get-PendingPath([string]$sid) { Join-Path $script:LsfTemp ('claude-lsfdev-' + $sid + '.pending') }
function Get-StoppedPath([string]$sid) { Join-Path $script:LsfTemp ('claude-lsfdev-' + $sid + '.stopped') }

function Get-SidFromLedgerName([string]$name) {
    if ($name -match '^claude-lsfdev-(.+?)\.(txt|pending|stopping|stopped)$') { return $Matches[1] }
    return $null
}

function Write-HookLog([string]$event, [string]$message) {
    # Append-only, trimmed to the newest ~256 KB once it passes 512 KB. Never
    # throws (logging must not break a hook).
    try {
        $line = ("{0:yyyy-MM-dd HH:mm:ss.fff} {1,-8} {2}" -f (Get-Date), $event, $message)
        [IO.File]::AppendAllText($script:LsfHookLog, $line + "`r`n", $script:Utf8NoBom)
        $fi = Get-Item -LiteralPath $script:LsfHookLog -ErrorAction SilentlyContinue
        if ($fi -and $fi.Length -gt 524288) {
            $text = [IO.File]::ReadAllText($script:LsfHookLog, [Text.Encoding]::UTF8)
            $cut = $text.IndexOf("`n", $text.Length - 262144)
            if ($cut -ge 0) { [IO.File]::WriteAllText($script:LsfHookLog, $text.Substring($cut + 1), $script:Utf8NoBom) }
        }
    } catch { }
}

function Get-GraceMinutes {
    # Grace between the CLI process ending and the auto-stop. The desktop app
    # shuts idle session processes down and resumes them on demand (measured:
    # ~15 min after the last turn), so 'session end' alone does not mean the
    # user is done - the grace lets a resume (or a fresh session in the same
    # folder) reclaim the servers first. 0 = stop immediately (old behaviour).
    $v = $env:LSFDEV_STOP_GRACE_MIN
    $n = 60
    if ($v -and [int]::TryParse($v.Trim(), [ref]$n)) { if ($n -lt 0) { $n = 0 } } else { $n = 60 }
    return $n
}

function Read-LedgerDirs([string]$path) {
    # Dirs of a live ledger OR of a pending/stopped file (header lines skipped).
    $out = New-Object System.Collections.Generic.List[string]
    try {
        foreach ($l in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
            $t = $l.Trim()
            if (-not $t -or $t.StartsWith('#')) { continue }
            $out.Add($t)
        }
    } catch { }
    return @($out | Select-Object -Unique)
}

function Read-PendingFile([string]$path) {
    # Returns @{ sid; cwd; reason; ended; due([datetime] UTC or $null); dirs }.
    $meta = @{ sid = (Get-SidFromLedgerName (Split-Path $path -Leaf)); cwd = ''; reason = ''; ended = ''; due = $null; dirs = @() }
    try {
        $dirs = New-Object System.Collections.Generic.List[string]
        foreach ($l in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
            $t = $l.Trim()
            if (-not $t) { continue }
            if ($t.StartsWith('#')) {
                if ($t -match '^#\s*(\w+)=(.*)$') {
                    $k = $Matches[1]; $v = $Matches[2].Trim()
                    switch ($k) {
                        'cwd'    { $meta.cwd = $v }
                        'reason' { $meta.reason = $v }
                        'ended'  { $meta.ended = $v }
                        'due'    { try { $meta.due = [DateTime]::Parse($v, $null, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { } }
                    }
                }
                continue
            }
            $dirs.Add($t)
        }
        $meta.dirs = @($dirs | Select-Object -Unique)
    } catch { }
    return $meta
}

function Write-PendingFile([string]$path, [hashtable]$meta, [string[]]$dirs) {
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# lsfdev pending stop - do not edit; see claude-lsfdev-hooks.log')
    foreach ($k in 'cwd', 'reason', 'ended', 'due') { if ($meta.ContainsKey($k) -and $null -ne $meta[$k]) { $lines.Add("# $k=$($meta[$k])") } }
    foreach ($d in @($dirs | Select-Object -Unique)) { if ($d) { $lines.Add($d) } }
    [IO.File]::WriteAllLines($path, $lines, $script:Utf8NoBom)
}

function Get-LedgerCwd([string]$path) {
    # The '# cwd=' header a live ledger carries since 0.1.34 (the session's
    # working directory - how sibling sessions in one folder find each other).
    try {
        foreach ($l in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
            $t = $l.Trim()
            if (-not $t) { continue }
            if (-not $t.StartsWith('#')) { break }
            if ($t -match '^#\s*cwd=(.*)$') { return $Matches[1].Trim() }
        }
    } catch { }
    return ''
}

function Add-LedgerDirs([string]$sid, [string[]]$dirs, [string]$cwd = '') {
    # Append dirs (unique, case-insensitive) to the session's live ledger,
    # creating it (with the '# cwd=' header) when absent.
    if (-not $dirs -or -not $dirs.Count) { return }
    $ledger = Get-LedgerPath $sid
    $have = @()
    $exists = Test-Path -LiteralPath $ledger
    if ($exists) { $have = @(Read-LedgerDirs $ledger) }
    $add = @($dirs | Where-Object { $d = $_; $d -and -not ($have | Where-Object { $_ -ieq $d }) } | Select-Object -Unique)
    if (-not $add.Count) { return }
    $text = ''
    if (-not $exists -and $cwd) { $text = "# cwd=$cwd`r`n" }
    $text += (($add -join "`r`n") + "`r`n")
    [IO.File]::AppendAllText($ledger, $text, $script:Utf8NoBom)
}

function Get-LiveLedgers {
    # Live ledgers only (the .txt glob does not match .pending/.stopping/.stopped).
    @(Get-ChildItem -Path $script:LsfTemp -Filter 'claude-lsfdev-*.txt' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^claude-lsfdev-.+\.txt$' })
}

function Get-PendingFiles {
    @(Get-ChildItem -Path $script:LsfTemp -Filter 'claude-lsfdev-*.pending' -File -ErrorAction SilentlyContinue)
}

function Test-DirClaimedLive([string]$dir, [string]$exceptSid = '') {
    # Is $dir owned by ANY live session ledger (other than $exceptSid)? An
    # unreadable ledger counts as a claim - skipping a stop is the safe side.
    foreach ($f in Get-LiveLedgers) {
        $sid = Get-SidFromLedgerName $f.Name
        if ($exceptSid -and $sid -ieq $exceptSid) { continue }
        try {
            # Case-insensitive: ledgers hold normalized paths, but a
            # different-cased hand-typed -ProjectDir must still count.
            foreach ($l in [IO.File]::ReadAllLines($f.FullName, [Text.Encoding]::UTF8)) { if ($l.Trim() -ieq $dir) { return $true } }
        } catch { return $true }
    }
    return $false
}

function Test-KeepRunning([string]$dir) {
    # 'lsfdev.ps1 keep-running' persists keepRunning=true in the project's
    # .lsfusion-dev\config.json: the session-end auto-stop then leaves that
    # project alone (an explicit 'lsfdev.ps1 stop' still stops it).
    try {
        $cfgPath = Join-Path (Join-Path $dir '.lsfusion-dev') 'config.json'
        if (-not (Test-Path -LiteralPath $cfgPath)) { return $false }
        $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [bool]($cfg.PSObject.Properties.Name -contains 'keepRunning' -and $cfg.keepRunning)
    } catch { return $false }
}

function Resolve-LsfdevScript {
    # The plugin copy next to these hooks; falls back to the stable shim
    # (%LOCALAPPDATA%\lsfusion-dev\lsfdev.ps1, maintained by every lsfdev run)
    # when the plugin cache this hook came from was pruned by an update while
    # a GC runner was still sleeping.
    $sibling = Join-Path $PSScriptRoot '..\skills\lsfusion-dev\scripts\lsfdev.ps1'
    try { if (Test-Path -LiteralPath $sibling) { return (Resolve-Path -LiteralPath $sibling).Path } } catch { }
    if ($env:LOCALAPPDATA) {
        $shim = Join-Path $env:LOCALAPPDATA 'lsfusion-dev\lsfdev.ps1'
        if (Test-Path -LiteralPath $shim) { return $shim }
    }
    return $null
}

function Start-GcRunner([datetime]$dueUtc, [string]$why) {
    # Spawn the detached GC runner (hidden window, no console output). It is a
    # child of THIS hook process, and the hook is a child of the CLI - but the
    # runner outlives both: the CLI's tree-kill on exit walks live parent links,
    # and this hook has exited long before the runner wakes up.
    $gc = Join-Path $PSScriptRoot 'lsfdev-session-gc.ps1'
    if (-not (Test-Path -LiteralPath $gc)) { Write-HookLog 'gc' "runner script missing: $gc"; return $null }
    try {
        $args = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                  '-File', ('"' + $gc + '"'), '-Due', $dueUtc.ToUniversalTime().ToString('o'), '-Why', ('"' + $why + '"'))
        $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $args -WindowStyle Hidden -PassThru
        Write-HookLog 'gc' ("runner pid {0} armed for {1:yyyy-MM-dd HH:mm:ss}Z ({2})" -f $p.Id, $dueUtc.ToUniversalTime(), $why)
        return $p.Id
    } catch {
        Write-HookLog 'gc' "runner spawn FAILED: $($_.Exception.Message) - pending stops will be re-armed by the next session start"
        return $null
    }
}

function Remove-DirFromLedgerFile([string]$path, [string]$dir) {
    # Take-over helper: drop $dir from a live ledger or pending file, keeping
    # header lines. Deletes the file when no dir remains. Returns $true when
    # something changed.
    try {
        $lines = @([IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8))
        $rest = @($lines | Where-Object { $_.Trim() -and -not ($_.Trim() -ieq $dir) })
        if ($rest.Count -eq $lines.Count) { return $false }
        $dirsLeft = @($rest | Where-Object { -not $_.Trim().StartsWith('#') })
        if ($dirsLeft.Count) { [IO.File]::WriteAllLines($path, $rest, $script:Utf8NoBom) }
        else { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
        return $true
    } catch { return $false }
}
