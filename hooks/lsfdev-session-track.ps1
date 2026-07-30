# PostToolUse hook (matcher: PowerShell): records lsFusion dev instances started in this session.
#
# Reads the hook input JSON from stdin. For every `lsfdev.ps1 start / start-server /
# start-web / restart` invocation in the executed command, appends the invocation's
# absolute -ProjectDir to a per-session ledger in %TEMP% and removes that dir from
# other sessions' ledgers (whoever (re)started a project last owns it). The companion
# SessionEnd hook (lsfdev-session-stop.ps1) stops exactly the instances in the ledger,
# so parallel Claude sessions and servers started outside lsfdev (e.g. from the IDE)
# are never touched. Untrackable values are skipped on purpose: a -ProjectDir with $
# or a backtick needs PowerShell evaluation, and a relative or omitted -ProjectDir
# resolves against the PowerShell tool's persistent cwd, which this hook cannot see.

# Claude Code writes the hook input as UTF-8; [Console]::In would decode it in the
# OEM code page and garble non-ASCII paths, so read the raw stream explicitly.
# TrimStart drops a BOM if the feeding pipe writes one (StreamReader keeps it).
$in = (New-Object IO.StreamReader([Console]::OpenStandardInput(), [Text.Encoding]::UTF8)).ReadToEnd().TrimStart([char]0xFEFF) | ConvertFrom-Json
$c = [string]$in.tool_input.command
$ledger = Join-Path $env:TEMP ('claude-lsfdev-' + $in.session_id + '.txt')

foreach ($call in [regex]::Matches($c, '(?i)lsfdev\.ps1[''"]?\s+(?:start(?:-server|-web)?|restart)\b(?<tail>[^;|&\r\n]*)')) {
    $m = [regex]::Match($call.Groups['tail'].Value, '(?i)-ProjectDir[:\s]\s*(?:"([^"]+)"|''([^'']+)''|([^\s"'']+))')
    if (-not $m.Success) { continue }
    $dir = @($m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value) -ne '' | Select-Object -First 1
    if ($dir -match '[$`]') { continue }
    if (-not [IO.Path]::IsPathRooted($dir)) { continue }
    try { $dir = [IO.Path]::GetFullPath($dir) } catch { continue }

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
