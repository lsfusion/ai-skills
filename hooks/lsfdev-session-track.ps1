# PostToolUse hook (matcher: PowerShell): records lsFusion dev instances started in this session.
#
# Reads the hook input JSON from stdin. When the executed command really (re)started an
# lsFusion dev instance, appends the invocation's absolute -ProjectDir to a per-session
# ledger in %TEMP% and removes that dir from other sessions' ledgers (whoever
# (re)started a project last owns it). The companion SessionEnd hook
# (lsfdev-session-stop.ps1) stops exactly the instances in the ledger, so parallel
# Claude sessions and servers started outside lsfdev (e.g. from the IDE) are never
# touched.
#
# Two layers keep false ownership out (a false claim would stop someone else's server):
# - Output gate: lsfdev.ps1 prints "Previous application server|Tomcat
#   stopped|was not running" (Stop-Tracked) at the exact point it starts touching the
#   project's processes; a command whose response lacks that marker never reached the
#   spawn phase (parameter binding error, not-set-up project, missing Java), so nothing
#   changed hands. If the marker wording or the tool_response schema ever drifts,
#   tracking silently disables - fail-open: servers then merely outlive the session.
# - AST layer: the command text is parsed with the PowerShell parser and only a real
#   `<...>lsfdev.ps1 start|start-server|start-web|restart` CommandAst with a constant
#   -ProjectDir argument counts - words inside strings/comments never match, and
#   quoting ('' escapes, & or ; inside quoted paths) is decoded by the parser, not by
#   regexes. Values that need evaluation ($vars, expandable strings) and paths that are
#   not drive-qualified/UNC-absolute (they would resolve against the tool's persistent
#   cwd or current drive, which this hook cannot see) are skipped on purpose.

using namespace System.Management.Automation.Language

# Claude Code writes the hook input as UTF-8; [Console]::In would decode it in the
# OEM code page and garble non-ASCII paths, so read the raw stream explicitly.
# TrimStart drops a BOM if the feeding pipe writes one (StreamReader keeps it).
$in = (New-Object IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)).ReadToEnd().TrimStart([char]0xFEFF) | ConvertFrom-Json
$c = [string]$in.tool_input.command
if (-not $c) { exit 0 }

$resp = [string]$in.tool_response.text
if (-not $resp -and $null -ne $in.tool_response) { $resp = [string](ConvertTo-Json $in.tool_response -Depth 10 -Compress) }
if ($resp -notmatch 'Previous (application server|Tomcat) (stopped|was not running)') { exit 0 }

$tokens = $null; $errors = $null
$ast = [Parser]::ParseInput($c, [ref]$tokens, [ref]$errors)
if ($errors.Count) { exit 0 }

$verbs = 'start', 'start-server', 'start-web', 'restart'
$ledger = Join-Path $env:TEMP ('claude-lsfdev-' + $in.session_id + '.txt')

foreach ($cmd in $ast.FindAll({ param($n) $n -is [CommandAst] }, $true)) {
    $elems = $cmd.CommandElements

    # The invocation shape: some element whose constant text ends in lsfdev.ps1
    # (direct call, & 'path', powershell -File path) followed by a start verb.
    $verbIdx = -1
    for ($i = 0; $i -lt $elems.Count - 1; $i++) {
        $t = $null
        if ($elems[$i] -is [StringConstantExpressionAst]) { $t = $elems[$i].Value }
        elseif ($elems[$i] -is [ExpandableStringExpressionAst]) { $t = $elems[$i].Value }
        if ($t -and $t -match '(?i)lsfdev\.ps1$' -and
            $elems[$i + 1] -is [StringConstantExpressionAst] -and
            $verbs -contains $elems[$i + 1].Value) { $verbIdx = $i + 1; break }
    }
    if ($verbIdx -lt 0) { continue }

    $dir = $null
    for ($i = $verbIdx + 1; $i -lt $elems.Count; $i++) {
        if ($elems[$i] -isnot [CommandParameterAst] -or $elems[$i].ParameterName -ne 'ProjectDir') { continue }
        $valAst = $elems[$i].Argument                                   # -ProjectDir:value form
        if (-not $valAst -and $i + 1 -lt $elems.Count) { $valAst = $elems[$i + 1] }
        if ($valAst -is [StringConstantExpressionAst]) { $dir = $valAst.Value }
        break
    }
    if (-not $dir -or $dir -notmatch '^([A-Za-z]:[\\/]|\\\\)') { continue }
    try { $dir = [IO.Path]::GetFullPath($dir) } catch { continue }
    $dir = $dir.TrimEnd('\', '/')                                       # one identity per project
    if ($dir -match '^[A-Za-z]:$') { $dir += '\' }

    Add-Content -LiteralPath $ledger -Value $dir -Encoding UTF8
    # Take-over: drop this dir from other sessions' ledgers. An unsynchronized rewrite
    # can lose a line another session appends in the same instant; two sessions
    # (re)starting the same project simultaneously is not worth file locking.
    Get-ChildItem -Path $env:TEMP -Filter 'claude-lsfdev-*.txt' |
        Where-Object { $_.FullName -ne $ledger } | ForEach-Object {
            try {
                $lines = @(Get-Content -LiteralPath $_.FullName -Encoding UTF8)
                $rest = @($lines -ne $dir)
                if ($rest.Count -eq $lines.Count) { return }
                if ($rest.Count) { Set-Content -LiteralPath $_.FullName -Value $rest -Encoding UTF8 }
                else { Remove-Item -LiteralPath $_.FullName -Force }
            } catch { }
        }
}
exit 0
