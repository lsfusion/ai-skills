# launch-jvm.ps1 - short-lived, hidden launcher ("trampoline") that starts a
# JVM for lsfdev.ps1 and exits at once.
#
# Why it exists. The agent's shell tool kills the WHOLE process tree of a shell
# it stops - a background task ended with TaskStop, a command aborted on
# timeout, a session torn down. A JVM started directly by lsfdev.ps1 is a live
# child of that shell and dies with it (measured 2026-08-17: a backgrounded
# 'restart' + 'verify' stopped via TaskStop took the app server and Tomcat down
# with it). Started through this trampoline, the JVM's parent is a process
# that exited milliseconds later; a tree walk from the tool shell no longer
# reaches it, and it survives the shell, the tool call and the CLI process
# (measured: taskkill /T /F on the launching shell leaves the JVM running).
#
# The launch is described by a JSON spec file (written by lsfdev.ps1, read
# here - no argument quoting across process boundaries):
#   { "exe": ..., "args": [...], "workDir": ..., "out": ..., "err": ...,
#     "pidFile": ..., "resultFile": ... }
# On success the JVM's PID goes to pidFile and "ok" to resultFile; on failure
# resultFile receives "error: <message>" (and lsfdev.ps1 falls back to a
# direct, in-tree launch). The redirected stdout/stderr files are held by the
# JVM itself, so this process can exit immediately; the JVM keeps the hidden
# console alive for as long as it runs.
param([Parameter(Mandatory = $true)][string]$Spec)

$ErrorActionPreference = 'Stop'
$resultFile = $null
try {
    $s = Get-Content -LiteralPath $Spec -Raw -Encoding UTF8 | ConvertFrom-Json
    $resultFile = [string]$s.resultFile
    $args = @()
    if ($s.args) { $args = @($s.args | ForEach-Object { [string]$_ }) }
    $sp = @{ FilePath = [string]$s.exe; PassThru = $true; NoNewWindow = $true }
    if ($args.Count) { $sp.ArgumentList = $args }
    if ($s.workDir) { $sp.WorkingDirectory = [string]$s.workDir }
    if ($s.out) { $sp.RedirectStandardOutput = [string]$s.out }
    if ($s.err) { $sp.RedirectStandardError = [string]$s.err }
    $p = Start-Process @sp
    [IO.File]::WriteAllText([string]$s.pidFile, "$($p.Id)", (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($resultFile, "ok", (New-Object System.Text.UTF8Encoding($false)))
    exit 0
} catch {
    try { if ($resultFile) { [IO.File]::WriteAllText($resultFile, "error: $($_.Exception.Message)", (New-Object System.Text.UTF8Encoding($false))) } } catch { }
    exit 1
}
