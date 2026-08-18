# PostToolUse hook (matcher: PowerShell): records lsFusion dev instances started in this session.
#
# Reads the hook input JSON from stdin. When the executed command really (re)started an
# lsFusion dev instance, appends the invocation's absolute -ProjectDir to a per-session
# ledger in %TEMP% and removes that dir from other sessions' ledgers (whoever
# (re)started a project last owns it). The companion SessionEnd hook
# (lsfdev-session-stop.ps1) turns the ledger into a deferred stop of exactly those
# instances - executed by lsfdev-session-gc.ps1 after a grace period unless the
# session is resumed (lsfdev-session-start.ps1) - so parallel Claude sessions and
# servers started outside lsfdev (e.g. from the IDE) are never touched, and a
# session whose CLI process was merely recycled keeps its servers.
#
# Three layers keep false ownership out (a false claim would stop someone else's server):
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
# - Ambiguity skip: the gate is per command, so the marker cannot be attributed to one
#   invocation. If the parse yields MORE THAN ONE distinct project dir (two starts
#   chained in one command, or an if/else whose dead branch starts another project),
#   nothing is recorded - fail-open again: those servers merely outlive the session.

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
$found = New-Object System.Collections.Generic.List[string]

function Get-ConstText($e) {
    if ($e -is [StringConstantExpressionAst]) { return $e.Value }
    if ($e -is [ExpandableStringExpressionAst]) { return $e.Value }
    return $null
}

foreach ($cmd in $ast.FindAll({ param($n) $n -is [CommandAst] }, $true)) {
    $elems = $cmd.CommandElements

    # The invocation shape: an element whose constant text ends in lsfdev.ps1 and is
    # the invocation TARGET - the command's first element (direct call, & 'path') or
    # the argument of a -File parameter of a PowerShell host (powershell/pwsh -File
    # path; -File after anything else is just that command's argument) - followed by
    # a start verb. lsfdev.ps1 as a mere argument (cmd /c echo ... lsfdev.ps1 start
    # ...) must not claim ownership. Only this canonical `<lsfdev.ps1> <verb>
    # -ProjectDir <value>` shape is recognized; binder tricks (parameters before the
    # verb, -Command start, abbreviated -Pro) are untracked on purpose - fail-open.
    $verbIdx = -1
    for ($i = 0; $i -lt $elems.Count - 1; $i++) {
        $t = Get-ConstText $elems[$i]
        if (-not $t -or $t -notmatch '(?i)lsfdev\.ps1$') { continue }
        if ($i -ne 0) {
            if (-not ($elems[$i - 1] -is [CommandParameterAst] -and $elems[$i - 1].ParameterName -eq 'File')) { continue }
            $exe = Get-ConstText $elems[0]
            if (-not $exe -or $exe -notmatch '(?i)(^|[\\/])(powershell|pwsh)(\.exe)?$') { continue }
            # -File must be the host's ACTIVE script target: after -Command or
            # -EncodedCommand the host treats the rest as command text, so a trailing
            # "-File ...lsfdev.ps1 start" never runs. powershell.exe accepts prefix
            # shorthands (-c, -ec), slash forms (/Command, /c - measured) and quoted
            # spellings ("-Command"), which parse as plain strings rather than
            # CommandParameterAst - so normalize ANY dash/slash-prefixed element and
            # prefix-match it. Over-rejection is fail-open (the start is merely
            # untracked). This guards against accidental shapes only - the hook is not
            # a security boundary: whoever authors the session's commands can stop any
            # server directly; the ledger merely keeps HONEST commands from
            # mis-claiming.
            $cmdParam = $false
            for ($j = 1; $j -lt $i - 1; $j++) {
                $n = $null
                if ($elems[$j] -is [CommandParameterAst]) { $n = $elems[$j].ParameterName }
                else {
                    $t2 = Get-ConstText $elems[$j]
                    if ($t2 -and $t2.Length -ge 2 -and ($t2[0] -eq '/' -or $t2[0] -eq '-')) { $n = $t2.Substring(1) }
                }
                if (-not $n) { continue }
                $n = $n.TrimStart('-', '/').Split(':')[0]
                # 'ec' is powershell.exe's documented EncodedCommand alias (measured),
                # NOT a prefix of it; pwsh additionally has -CommandWithArgs / -cwa.
                if ($n -and ($n -eq 'ec' -or $n -eq 'cwa' -or
                    'command'.StartsWith($n, [StringComparison]::OrdinalIgnoreCase) -or
                    'commandwithargs'.StartsWith($n, [StringComparison]::OrdinalIgnoreCase) -or
                    'encodedcommand'.StartsWith($n, [StringComparison]::OrdinalIgnoreCase))) { $cmdParam = $true; break }
            }
            if ($cmdParam) { continue }
        }
        if ($elems[$i + 1] -is [StringConstantExpressionAst] -and
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
    $found.Add($dir)
}

$uniq = @($found | Sort-Object -Unique)                                 # case-insensitive
if ($uniq.Count -ne 1) { exit 0 }                                       # none, or ambiguous - skip
$dir = $uniq[0]

# Ledger bookkeeping is shared with the SessionStart / SessionEnd / GC hooks
# (file formats and helpers in lsfdev-session-common.ps1). Fail-open if the
# helper file is missing: an untracked start merely outlives the session.
try { . (Join-Path $PSScriptRoot 'lsfdev-session-common.ps1') } catch { exit 0 }
$sid = [string]$in.session_id
$ledger = Get-LedgerPath $sid

# The live ledger carries '# cwd=<session cwd>' so that sibling sessions in
# the same folder (/clear, a second conversation on the project) can find and
# share the claim; Add-LedgerDirs writes the header when it creates the file.
Add-LedgerDirs $sid @($dir) ([string]$in.cwd)
Write-HookLog 'track' "session $sid (re)started $dir - owned by this session now"

# Take-over: drop this dir from other sessions' live ledgers AND pending stops
# (whoever (re)started a project last owns it; a due pending stop of an older
# session must not touch the newer session's server). An unsynchronized
# rewrite can lose a line another session appends in the same instant; two
# sessions (re)starting the same project simultaneously is not worth file
# locking.
foreach ($f in @(Get-LiveLedgers) + @(Get-PendingFiles)) {
    if ($f.FullName -ieq $ledger) { continue }
    if (Remove-DirFromLedgerFile $f.FullName $dir) {
        Write-HookLog 'track' "session $sid took $dir over from $($f.Name)"
    }
}
exit 0
