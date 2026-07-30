<#
  lsfdev.ps1 - environment & runtime CLI for lsFusion development.
  Part of the "lsfusion-dev" skill. See ../SKILL.md for the workflow.

  Usage:
    powershell -ExecutionPolicy Bypass -File lsfdev.ps1 <command> [options]

  Commands: check setup start-server start-web start restart stop status
            log verify open api help
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Command = "help",
    [string]$ProjectDir = "",
    [string]$AppId = "",
    [string]$Version = "7",
    [string]$TomcatVersion = "",
    [string]$DbServer = "localhost",
    [string]$DbName = "lsfusion",
    [string]$DbUser = "postgres",
    [string]$DbPassword = "",
    [string]$AdminUser = "admin",
    [string]$AdminPassword = "",
    [string]$TopModule = "",
    [string]$Url = "",
    [string]$OpenScript = "",
    [string]$OpenScriptFile = "",
    [string]$OpenExpect = "",
    [string]$Click = "",
    [string]$DoubleClick = "",
    [string[]]$Do = @(),
    [switch]$Session,
    [switch]$EndSession,
    [switch]$Reload,
    [int]$CdpPort = 0,
    [int]$ViewportWidth = 1920,
    [int]$ViewportHeight = 1080,
    [string]$Locale = "",
    [string]$JvmArgs = "",
    [string]$TomcatOpts = "",
    [string]$Script = "",
    [string]$ScriptFile = "",
    [string[]]$Files = @(),
    [int]$RmiPort = 7652,
    [int]$HttpPort = 7651,
    [int]$WebSocketPort = 8887,
    [int]$WebPort = 8080,
    [int]$ShutdownPort = 8005,
    [int]$Lines = 80,
    [int]$Timeout = 180,
    [string]$GitUrl = "",
    [string]$Target = "",
    [string]$Branch = "",
    [switch]$Force,
    [switch]$NoWeb,
    [switch]$FullStart,
    [switch]$RefreshWar
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

# Emit UTF-8 on stdout so non-ASCII output (Action API responses, log tails with
# Cyrillic, etc.) survives. Without this, Write-Host re-encodes strings to the
# console's OEM code page and turns every non-ASCII character into '?' — even
# when the underlying data and the .NET string are perfectly correct.
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# Parameters the caller actually passed (captured at script scope for nested use).
$ScriptBound = $PSBoundParameters

if (-not $ProjectDir) { $ProjectDir = (Get-Location).Path }
$ProjectDir = (Resolve-Path $ProjectDir).Path
$StateDir   = Join-Path $ProjectDir ".lsfusion-dev"
$ConfigPath = Join-Path $StateDir "config.json"
$ServerOut  = Join-Path $StateDir "server.out.log"
$ServerErr  = Join-Path $StateDir "server.err.log"
$ServerPid  = Join-Path $StateDir "server.pid"
$TomcatOut  = Join-Path $StateDir "tomcat.out.log"
$TomcatPid  = Join-Path $StateDir "tomcat.pid"
$PwSessionPid = Join-Path $StateDir "pw-session.pid"   # persistent verify-session browser
$DownloadBase = "https://download.lsfusion.org/java"

# ---------------------------------------------------------------- helpers ---

function Head($text) {
    Write-Host ""
    Write-Host "=== $text ===" -ForegroundColor Cyan
}
function Ok($text)   { Write-Host "  [OK]   $text" -ForegroundColor Green }
function Warn($text) { Write-Host "  [WARN] $text" -ForegroundColor Yellow }
function Bad($text)  { Write-Host "  [FAIL] $text" -ForegroundColor Red }
function Info($text) { Write-Host "  $text" }

function Read-FileText([string]$path) {
    if (-not (Test-Path $path)) { return "" }
    try {
        $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $sr = New-Object IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
        $t = $sr.ReadToEnd()
        $sr.Dispose(); $fs.Dispose()
        return $t
    } catch { return "" }
}

function Tail-Text([string]$text, [int]$n) {
    if (-not $text) { return @() }
    $arr = $text -split "`r?`n"
    if ($arr.Count -le $n) { return $arr }
    return $arr[($arr.Count - $n)..($arr.Count - 1)]
}

# Read an integer key (e.g. rmi.port) from the project's settings.properties.
# Checks conf/settings.properties first (the file the server actually reads at
# runtime, and where Maven-mode overrides land) then the project-root file.
# Returns $null if the file or key is absent.
function Read-SettingsPort($key) {
    foreach ($sf in @((Join-Path $ProjectDir "conf\settings.properties"), (Join-Path $ProjectDir "settings.properties"))) {
        if (Test-Path $sf) {
            foreach ($line in (Get-Content $sf -Encoding UTF8)) {
                if ($line -match "^\s*$([regex]::Escape($key))\s*=\s*(\d+)\s*$") { return [int]$Matches[1] }
            }
        }
    }
    return $null
}

# Read a string-valued key from a .properties file ($null if file/key absent).
function Get-SettingsValue([string]$file, [string]$key) {
    if (-not (Test-Path $file)) { return $null }
    foreach ($line in (Get-Content $file -Encoding UTF8)) {
        if ($line -match "^\s*$([regex]::Escape($key))\s*=\s*(.*?)\s*$") { return $Matches[1] }
    }
    return $null
}

# Read a string-valued key from the project's settings.properties, checking
# conf/settings.properties first (the file the server actually reads at runtime —
# Spring `file:conf/settings.properties` in lsfusion.xml) then the project-root
# mirror. Returns $null if absent or blank. String sibling of Read-SettingsPort:
# it is what makes settings.properties the source of truth and config.json a mere
# cache for db.* (a hand-edit there wins, and survives a wiped .lsfusion-dev/).
function Read-SettingsString($key) {
    foreach ($sf in @((Join-Path $ProjectDir "conf\settings.properties"), (Join-Path $ProjectDir "settings.properties"))) {
        $v = Get-SettingsValue $sf $key
        if ($null -ne $v -and "$v".Trim() -ne "") { return $v }
    }
    return $null
}

# Write a .properties file as UTF-8 WITHOUT a BOM. PowerShell 5.1's
# Set-Content -Encoding UTF8 always emits a BOM, and Java's Properties loader
# does NOT strip it - the first key in the file silently becomes
# "﻿db.name", the server never sees db.name, and it falls back to the
# shared default database ("lsfusion"). Insidious because lsfdev's own
# readers (Get-Content) DO strip the BOM, so setup/status keep reporting the
# right name while the JVM disagrees. Re-writing through this helper also
# heals files damaged by earlier skill versions or BOM-adding editors.
function Write-PropertiesFile([string]$file, [string[]]$lines) {
    [IO.File]::WriteAllText($file, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
}

# Update an existing key in a .properties file, or append it if absent.
# Preserves every other line (and creates the file if missing).
function Set-SettingsProperty([string]$file, [string]$key, [string]$value) {
    $lines = @()
    if (Test-Path $file) { $lines = @(Get-Content $file -Encoding UTF8) }
    $pattern = "^\s*$([regex]::Escape($key))\s*="
    $replaced = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match $pattern) { $lines[$i] = "$key = $value"; $replaced = $true; break }
    }
    if (-not $replaced) { $lines += "$key = $value" }
    Write-PropertiesFile $file $lines
}

# Apply an install override into a settings file. An explicitly-passed flag
# always wins (warning if it clobbers a committed value); a non-explicit value
# is only filled in when the key is missing, so a repo's committed settings are
# never silently changed. Returns $true if the file was written.
function Apply-SettingsOverride([string]$file, [string]$key, [string]$value, [bool]$explicit) {
    $current = Get-SettingsValue $file $key
    if ($explicit) {
        if (($null -ne $current) -and ($current -ne "$value")) {
            Warn "conf/settings.properties: overriding committed $key ('$current' -> '$value')."
        }
        Set-SettingsProperty $file $key $value
        return $true
    }
    if ($null -eq $current) { Set-SettingsProperty $file $key $value; return $true }
    return $false
}

function Load-Config {
    if (Test-Path $ConfigPath) {
        $c = (Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        # settings.properties is the source of truth for the lsFusion-side ports
        # (rmi.port / http.port / webSocket.port), exactly like db.*. Reading them
        # back here means they survive a wiped .lsfusion-dev/ or a hand-edit of
        # settings.properties — config.json is only a cache/fallback. (webPort /
        # shutdownPort stay in config.json: those are Tomcat's, not lsFusion settings.)
        $sRmi  = Read-SettingsPort "rmi.port"
        $sHttp = Read-SettingsPort "http.port"
        $sWs   = Read-SettingsPort "webSocket.port"
        if ($sRmi)  { $c.rmiPort  = $sRmi }  elseif (-not $c.rmiPort)  { $c.rmiPort  = 7652 }
        if ($sHttp) { $c.httpPort = $sHttp } elseif (-not $c.httpPort) { $c.httpPort = 7651 }
        if ($sWs)   { $c | Add-Member -NotePropertyName webSocketPort -NotePropertyValue $sWs -Force }
        elseif (-not $c.webSocketPort) { $c | Add-Member -NotePropertyName webSocketPort -NotePropertyValue 8887 -Force }
        # db.* get the SAME treatment: settings.properties (conf/ first, then the
        # root mirror) is the source of truth; config.json is only the cache. This
        # is why a hand-edit of db.name in conf/settings.properties is honored by
        # start/restart/stop/api/status and is never reverted from config.json
        # (the bug this read-back closes), and why it survives a wiped .lsfusion-dev/.
        foreach ($pair in @(@('db.name','dbName'), @('db.server','dbServer'), @('db.user','dbUser'), @('db.password','dbPassword'))) {
            $sv = Read-SettingsString $pair[0]
            if ($null -ne $sv) { $c | Add-Member -NotePropertyName $pair[1] -NotePropertyValue $sv -Force }
        }
        return $c
    }
    return $null
}

function Get-ConfigOrFail {
    $c = Load-Config
    if (-not $c) {
        # Name the directory that was actually inspected: in practice this
        # error is almost never a missing setup - it is a missing -ProjectDir
        # (the shell's cwd resets between tool calls, so a bare call from the
        # wrong directory looks at the wrong .lsfusion-dev). Blaming setup
        # here sent agents down false trails (once even blamed on a live
        # verify -Session, which cannot cause this).
        $cwdNote = if ($ScriptBound.ContainsKey('ProjectDir')) { "" }
                   else { " (-ProjectDir not passed, so the current directory was used - it resets between tool calls; always pass -ProjectDir explicitly)" }
        throw ("Project is not set up: no .lsfusion-dev\config.json under '$ProjectDir'$cwdNote. " +
               "If this project IS set up, the path is simply wrong - re-run with -ProjectDir <project root>. " +
               "Only a genuinely new project needs:  lsfdev.ps1 setup -DbPassword <password>")
    }
    return $c
}

function Save-Config($cfg) {
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Find-Java {
    $exe = $null
    $cmd = Get-Command java -ErrorAction SilentlyContinue
    if ($cmd) { $exe = $cmd.Source }
    elseif ($env:JAVA_HOME -and (Test-Path (Join-Path $env:JAVA_HOME "bin\java.exe"))) {
        $exe = Join-Path $env:JAVA_HOME "bin\java.exe"
    }
    if (-not $exe) { return $null }
    # java prints -version to stderr; let cmd.exe merge the streams so the
    # lines are plain stdout text and not terminating PowerShell errors.
    $raw = cmd /c "`"$exe`" -version 2>&1"
    $out = ($raw -join "`n")
    $major = 0; $ver = "unknown"
    if ($out -match 'version "([^"]+)"') {
        $ver = $matches[1]
        if ($ver -match '^1\.(\d+)') { $major = [int]$matches[1] }
        elseif ($ver -match '^(\d+)') { $major = [int]$matches[1] }
    }
    return [pscustomobject]@{ Path = $exe; Version = $ver; Major = $major }
}

function Find-Git {
    $c = Get-Command git -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}

function Find-Maven {
    foreach ($n in @("mvn.cmd", "mvn")) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    foreach ($envName in @("MAVEN_HOME", "M2_HOME")) {
        $v = [Environment]::GetEnvironmentVariable($envName)
        if ($v -and (Test-Path (Join-Path $v "bin\mvn.cmd"))) {
            return (Join-Path $v "bin\mvn.cmd")
        }
    }
    return $null
}

function Test-MavenProject([string]$projectDir) {
    return (Test-Path (Join-Path $projectDir "pom.xml"))
}

# In a Maven project the lsFusion platform version is dictated by pom.xml (the
# server jar is resolved by Maven). The web-client war is NOT resolved by Maven
# — the skill downloads it — so it must follow the same version, or we'd ship a
# client that mismatches the server. Returns the platform version from pom.xml:
# the parent (lsfusion.platform.build) version, falling back to the project's
# own <version>. $null if pom.xml is absent or unparseable.
function Get-PomPlatformVersion([string]$projectDir) {
    $pom = Join-Path $projectDir "pom.xml"
    if (-not (Test-Path $pom)) { return $null }
    try {
        $xml = [xml](Get-Content $pom -Raw -Encoding UTF8)
        # PowerShell's XML adapter exposes child elements by local name even
        # under pom's default namespace, so dotted access works directly.
        $v = $null
        if ($xml.project.parent -and $xml.project.parent.version) { $v = "$($xml.project.parent.version)".Trim() }
        if (-not $v -and $xml.project.version) { $v = "$($xml.project.version)".Trim() }
        if ($v) { return $v }
    } catch { }
    return $null
}

function Test-ExistingProject([string]$projectDir) {
    # Markers that say "this directory already has its own lsFusion code and
    # config" - we should not scaffold settings.properties or a top module
    # over what the project ships.
    if (Test-Path (Join-Path $projectDir "pom.xml")) { return $true }
    if (Test-Path (Join-Path $projectDir "src\main\lsfusion")) { return $true }
    $found = Get-ChildItem $projectDir -Filter "lsfusion.properties" -File -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object -First 1
    return [bool]$found
}

function Find-Python {
    foreach ($n in @("python", "python3", "py")) {
        $c = Get-Command $n -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
    }
    return $null
}

# Escape an argument for a native process spawned by PowerShell 5.1, which
# builds the child command line WITHOUT escaping embedded double quotes - a
# -Do step like  eval:createElement("input")  otherwise reaches python as
# createElement(input). MSVCRT parsing rules: double every backslash run that
# sits immediately before a '"', then escape the '"' itself. (An argument
# ENDING in backslashes that also contains whitespace remains a known PS 5.1
# edge - avoid trailing backslashes in selectors/JS.)
function ConvertTo-NativeArg([string]$s) {
    return ($s -replace '(\\*)"', '$1$1\"')
}

function Test-PlaywrightInstalled([string]$pyExe) {
    # cmd /c suppresses python's ModuleNotFoundError stderr without tripping
    # PowerShell's stop-on-stderr handling.
    $null = cmd /c "`"$pyExe`" -c `"import playwright`" 2>nul"
    return ($LASTEXITCODE -eq 0)
}

function Ensure-Playwright([string]$pyExe) {
    if (Test-PlaywrightInstalled $pyExe) { return }
    Info "Installing Playwright (one-time; pip + Chromium ~120 MB)..."
    & $pyExe -m pip install --quiet --disable-pip-version-check playwright
    if ($LASTEXITCODE -ne 0) { throw "pip install playwright failed (exit $LASTEXITCODE)." }
    & $pyExe -m playwright install chromium
    if ($LASTEXITCODE -ne 0) { throw "playwright install chromium failed (exit $LASTEXITCODE)." }
    Ok "Playwright installed."
}

function Get-PortPids([int]$port) {
    try {
        $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
        return @($conns | Select-Object -ExpandProperty OwningProcess -Unique)
    } catch { return @() }
}

function Test-PortOpen([int]$port) {
    $c = New-Object Net.Sockets.TcpClient
    try { $c.Connect("127.0.0.1", $port); return $true }
    catch { return $false }
    finally { $c.Close() }
}

function Process-Alive([int]$procId) {
    if (-not $procId) { return $false }
    return [bool](Get-Process -Id $procId -ErrorAction SilentlyContinue)
}

# PIDs of the server / Tomcat instances this project itself launched, read from
# the tracked pid files. Used so a port-preflight doesn't flag our own running
# instance as a foreign conflict.
function Get-OwnPids {
    $own = @()
    foreach ($pf in @($ServerPid, $TomcatPid)) {
        if (Test-Path $pf) {
            $v = 0
            if (([int]::TryParse((Get-Content $pf -Raw -Encoding UTF8).Trim(), [ref]$v)) -and $v) { $own += $v }
        }
    }
    return $own
}

# True if $port is held by a LISTENING process that is not one of this project's
# own tracked instances. This catches a stray third-party service on the port
# (another Tomcat on 8080, something squatting the shutdown port, etc.).
function Test-PortBusyForeign([int]$port, [int[]]$ownPids) {
    $pids = @(Get-PortPids $port)
    if ($pids.Count -eq 0) { return $false }
    foreach ($p in $pids) { if ($ownPids -notcontains $p) { return $true } }
    return $false
}

# Warn about every port in $specs that a foreign process is already holding.
# $specs: array of @{ Name=...; Port=...; Flag=... }. Returns $true if any busy.
function Test-PortPreflight($specs) {
    $own = Get-OwnPids
    $any = $false
    foreach ($s in $specs) {
        if (Test-PortBusyForeign $s.Port $own) {
            $any = $true
            $hint = ""
            if ($s.Flag) { $hint = " - free it, or pick another with: setup $($s.Flag) <free port>" }
            Warn "Port $($s.Port) ($($s.Name)) is already in use by another process$hint."
        }
    }
    return $any
}

function Invoke-Download([string]$url, [string]$dest) {
    Info "Downloading $url"
    Info "        -> $dest"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        & curl.exe -L --fail --retry 3 --retry-delay 2 -C - --no-progress-meter -o $dest $url
        if ($LASTEXITCODE -eq 0 -and (Test-Path $dest)) { return }
        Warn "curl failed (exit $LASTEXITCODE); falling back to Invoke-WebRequest."
    }
    $oldProgress = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try {
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    } finally {
        $ProgressPreference = $oldProgress
    }
    if (-not (Test-Path $dest)) { throw "Download failed: $url" }
}

function Resolve-TomcatVersion {
    if ($TomcatVersion) { return $TomcatVersion }
    $cfg = Load-Config
    if ($cfg -and $cfg.tomcatVersion) { return $cfg.tomcatVersion }
    try {
        $html = (Invoke-WebRequest "https://dlcdn.apache.org/tomcat/tomcat-9/" -UseBasicParsing).Content
        $vs = [regex]::Matches($html, 'v(9\.0\.\d+)/') | ForEach-Object { $_.Groups[1].Value }
        if ($vs.Count -gt 0) {
            return ($vs | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
        }
    } catch { Warn "Could not query Apache mirror for the latest Tomcat 9; using pinned version." }
    return "9.0.107"
}

function Get-AvailableVersions {
    # Scrape the download server for every lsfusion-server-*.jar filename and
    # split into stable / snapshot / beta tracks. Returns fallback values on
    # network failure so the caller can still proceed.
    try {
        $html = (Invoke-WebRequest "$DownloadBase/" -UseBasicParsing -TimeoutSec 15).Content
        $raw = [regex]::Matches($html, 'lsfusion-server-([0-9][\w.-]*?)\.jar') |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -notmatch '-(sources|javadoc)$' } |
            Sort-Object -Unique
    } catch {
        return [pscustomobject]@{
            stable   = @("6.2"); snapshot = @("7.0-SNAPSHOT"); beta = @()
            error    = $_.Exception.Message
        }
    }
    return [pscustomobject]@{
        stable   = @($raw | Where-Object { $_ -notmatch 'SNAPSHOT|beta' })
        snapshot = @($raw | Where-Object { $_ -match 'SNAPSHOT' })
        beta     = @($raw | Where-Object { $_ -match 'beta' })
        error    = $null
    }
}

function Resolve-Version([string]$requested) {
    # Concrete tags (e.g. "6.2", "7.0-SNAPSHOT") pass through; the words below
    # are aliases for "the latest X in track Y". Defaults to the latest 7.x.
    if (-not $requested) { $requested = "7" }
    $lc = $requested.ToLowerInvariant()
    if ($lc -notin @("stable", "latest", "dev", "snapshot", "6", "7")) {
        return $requested
    }
    $av = Get-AvailableVersions
    $cmpStable = { try { [version]$_ } catch { [version]"0.0" } }
    $cmpSnap   = { try { [version]($_ -replace '-SNAPSHOT', '') } catch { [version]"0.0" } }
    switch ($lc) {
        { $_ -in "stable", "latest" } {
            $b = $av.stable | Sort-Object $cmpStable -Descending | Select-Object -First 1
            if ($b) { return $b } else { return "6.2" }
        }
        { $_ -in "dev", "snapshot" } {
            $b = $av.snapshot | Sort-Object $cmpSnap -Descending | Select-Object -First 1
            if ($b) { return $b } else { return "7.0-SNAPSHOT" }
        }
        "6" {
            $b = $av.stable | Where-Object { $_ -like "6.*" } | Sort-Object $cmpStable -Descending | Select-Object -First 1
            if ($b) { return $b } else { return "6.2" }
        }
        "7" {
            $b = (@($av.snapshot) + @($av.stable)) | Where-Object { $_ -like "7.*" } | Sort-Object $cmpSnap -Descending | Select-Object -First 1
            if ($b) { return $b } else { return "7.0-SNAPSHOT" }
        }
    }
}

function Get-ProjectPathHash([string]$projectDir, [int]$hexChars) {
    # Deterministic per-path hex tail: same path -> same value. Seeds the
    # derived app id (and the legacy db name, and the derived port set).
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $hashBytes = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($projectDir.ToLower()))
    $md5.Dispose()
    return ([BitConverter]::ToString($hashBytes) -replace '-', '').ToLower().Substring(0, $hexChars)
}

function New-AppId([string]$projectDir) {
    # Fallback app id when none was chosen at setup: sanitized folder leaf plus
    # a 4-hex path-hash tail, so two checkouts with the same folder name still
    # get distinct ids (and therefore distinct databases). Deterministic per
    # path. An explicit -AppId (a short, meaningful identifier chosen when the
    # application is created) is the intended path - this is only the safety net.
    $leaf = ((Split-Path $projectDir -Leaf).ToLower() -replace '[^a-z0-9]', '')
    if ($leaf.Length -gt 12) { $leaf = $leaf.Substring(0, 12) }
    if ($leaf -notmatch '^[a-z]') { $leaf = "app$leaf" }
    return "${leaf}_$(Get-ProjectPathHash $projectDir 4)"
}

function New-DbName([string]$projectDir) {
    # LEGACY per-project database name (pre-app-id skill versions). Kept only
    # so setup can recognize auto-generated names from older installs (the
    # repo-committed db.name check). New setups name the database after the
    # app id instead - see New-AppId and the resolution in Cmd-Setup.
    $leaf = ((Split-Path $projectDir -Leaf).ToLower() -replace '[^a-z0-9]', '_')
    if ($leaf.Length -gt 20) { $leaf = $leaf.Substring(0, 20) }
    return "lsfusion_${leaf}_$(Get-ProjectPathHash $projectDir 8)"
}

# True if $name can serve as a Tomcat war/context name: URL-path-safe chars
# only (lowercase - -cmatch, because PowerShell -match would wave through an
# expert -DbName like 'Foo' that the docs promise falls back to ROOT), and
# not one of the stock Tomcat webapps (deploying manager.war over the stock
# manager/ dir is undefined behavior).
function Test-ContextSafe([string]$name) {
    return ($name -cmatch '^[a-z][a-z0-9_]{0,29}$') -and ($name -notin @('root', 'docs', 'examples', 'manager'))
}

# The Tomcat context name for this project. db.name IS the app id, so the war
# is deployed as <db.name>.war and the UI lives at /<db.name>/ - no separate
# key to keep in sync. ROOT (context /) in two cases: db.name is not a safe
# context name (expert -DbName choices stay unrestricted), or the install
# still has a legacy ROOT.war deployment (pre-app-context skill versions) that
# the next setup will migrate.
function Get-AppContext($cfg) {
    $name = "$($cfg.dbName)"
    if (-not (Test-ContextSafe $name)) { return "ROOT" }
    $webapps = Join-Path $StateDir "tomcat\webapps"
    if ((Test-Path (Join-Path $webapps "ROOT.war")) -and -not (Test-Path (Join-Path $webapps "$name.war"))) { return "ROOT" }
    return $name
}

# The web UI base URL, context path included.
function Get-WebUrl($cfg) {
    $ctx = Get-AppContext $cfg
    if ($ctx -eq "ROOT") { return "http://localhost:$($cfg.webPort)/" }
    return "http://localhost:$($cfg.webPort)/$ctx/"
}

# The URL the SPA actually answers on. Current 7.0-SNAPSHOT wars 404 on the
# bare context root: web.xml still declares <welcome-file>main</welcome-file>,
# but Spring 5.3 resolves controllers by the full in-context path ("/"), which
# nothing serves - the SPA entry is mapped at /main only. Where the root DOES
# work it forwards to main anyway (main IS the welcome file), so probe the
# root first and fall back to <root>main. On an unreachable server, return
# the root unprobed - callers already handle a dead server.
# Returns @{ url; ok } - ok = $false when no URL answered below HTTP 400.
function Resolve-LandingUrl($cfg) {
    $base = Get-WebUrl $cfg
    foreach ($u in @($base, ($base + "main"))) {
        try {
            Invoke-WebRequest $u -UseBasicParsing -TimeoutSec 5 -MaximumRedirection 0 -ErrorAction Stop | Out-Null
            return @{ url = $u; ok = $true }
        } catch {
            $resp = $_.Exception.Response
            if (-not $resp) { return @{ url = $base; ok = $false } }
            $code = 0; try { $code = [int]$resp.StatusCode } catch { }
            # A 3xx (e.g. auth redirect to /login) proves the URL is routed.
            if ($code -ge 300 -and $code -lt 400) { return @{ url = $u; ok = $true } }
        }
    }
    return @{ url = $base; ok = $false }
}

# --- war <-> server build drift (SNAPSHOT versions) --------------------------
# Neither artifact carries a version stamp in its manifest, but the zip entry
# timestamps preserve the BUILD time - comparable across the two delivery
# channels (the war downloaded from download.lsfusion.org, the server jar
# resolved by Maven into the local repository or downloaded by setup).
# Returns the newest entry's timestamp, or $null when absent/unreadable.
function Get-ZipBuildDate([string]$path) {
    if (-not ($path -and (Test-Path $path))) { return $null }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        $zip = [System.IO.Compression.ZipFile]::OpenRead($path)
        try {
            $max = $null
            foreach ($e in $zip.Entries) {
                $t = $e.LastWriteTime.DateTime
                if ((-not $max) -or ($t -gt $max)) { $max = $t }
            }
            return $max
        } finally { $zip.Dispose() }
    } catch { return $null }
}

# The server jar actually in use: the Maven-resolved platform server artifact
# (from the cached dependency classpath) in a Maven project, else the
# lsfusion-server-<ver>.jar that setup downloaded. $null when not resolvable
# yet (e.g. Maven mode before the first start-server). The Maven branch is
# gated on the SAME condition Cmd-StartServer uses to pick the launch mode
# (pom.xml present AND mvn on PATH) - a leftover maven-classpath.txt from a
# past Maven-mode run must not shadow the jar the fallback mode actually
# launches.
function Get-ResolvedServerJar($cfg) {
    $cpFile = Join-Path $StateDir "maven-classpath.txt"
    if ((Test-Path $cpFile) -and (Test-MavenProject $ProjectDir) -and (Find-Maven)) {
        try {
            foreach ($e in ((Get-Content $cpFile -Raw -Encoding UTF8).Trim() -split ';')) {
                $e = $e.Trim()
                if ($e -match '[\\/]lsfusion[\\/]platform[\\/]server[\\/].*\.jar$' -and (Test-Path $e)) { return $e }
            }
        } catch { }
    }
    $jar = Join-Path $StateDir "lsfusion-server-$($cfg.version).jar"
    if (Test-Path $jar) { return $jar }
    return $null
}

# Warn when the deployed client war and the server jar come from different
# platform builds. The web client talks RMI to the app server with plain Java
# serialization, so mismatched builds of the same -SNAPSHOT version can fail
# on EVERY form open with "invalid stream header" (StreamCorruptedException /
# InvalidClassException). This drifts naturally in Maven projects: Maven
# re-resolves the -SNAPSHOT server over time (pom change, -U, snapshot update
# policy, a local platform build), while the war - downloaded by the skill,
# not Maven - stays whatever setup fetched. Same-build war+jar carry entry
# stamps minutes apart; >24 h apart means different builds. Serialization
# does not break on every build, hence warn, not fail.
function Test-WarServerBuildDrift($cfg) {
    $warPath = Join-Path $StateDir "tomcat\webapps\$(Get-AppContext $cfg).war"
    $jarPath = Get-ResolvedServerJar $cfg
    $warDate = Get-ZipBuildDate $warPath
    $jarDate = Get-ZipBuildDate $jarPath
    if (-not ($warDate -and $jarDate)) { return }
    if ([Math]::Abs(($jarDate - $warDate).TotalHours) -le 24) { return }
    Warn "Client war and server jar are from different platform builds: war built $($warDate.ToString('yyyy-MM-dd HH:mm')), server jar built $($jarDate.ToString('yyyy-MM-dd HH:mm'))."
    Warn "Mismatched $($cfg.version) builds can break RMI serialization - every form open then fails with 'invalid stream header'."
    if ($jarDate -gt $warDate) {
        Warn "The server is newer: refresh the war with 'setup -RefreshWar' (re-downloads lsfusion-client-$($cfg.version).war at the current build)."
    } elseif ($jarPath -eq (Join-Path $StateDir "lsfusion-server-$($cfg.version).jar")) {
        # The stale server jar is the skill's own download (non-Maven mode) -
        # a mvn command would be useless here.
        Warn "The war is newer: refresh the downloaded server jar - delete '$jarPath' and re-run setup (it refetches missing artifacts)."
    } else {
        Warn "The war is newer: update the Maven-resolved server to the current snapshot (mvn -U -DskipTests compile, then restart)."
    }
}

# psql is the skill's window into "which database is REALLY in use". It is
# often not on PATH on Windows, so after PATH we derive it from the installed
# PostgreSQL service's own binary path (works for any install location and
# naturally picks the running version), then fall back to the standard
# %ProgramFiles% locations. Resolved once per run (memoized).
$script:PsqlResolved = $false
$script:PsqlPath = $null
function Find-Psql {
    if ($script:PsqlResolved) { return $script:PsqlPath }
    $script:PsqlResolved = $true
    $c = Get-Command psql -ErrorAction SilentlyContinue
    if ($c) { $script:PsqlPath = $c.Source; return $script:PsqlPath }
    # The service's PathName is like:
    #   "C:\Program Files\PostgreSQL\18\bin\pg_ctl.exe" runservice -N "postgresql-x64-18" ...
    # - psql.exe sits in the same bin dir. Running services first.
    try {
        $svcs = @(Get-CimInstance Win32_Service -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "postgres*" -or $_.DisplayName -like "*postgreSQL*" } |
            Sort-Object { if ($_.State -eq 'Running') { 0 } else { 1 } })
        foreach ($s in $svcs) {
            $exe = if ("$($s.PathName)" -match '^\s*"([^"]+)"') { $Matches[1] } else { ("$($s.PathName)" -split '\s+')[0] }
            if (-not $exe) { continue }
            $cand = Join-Path (Split-Path $exe -Parent) "psql.exe"
            if (Test-Path $cand) { $script:PsqlPath = $cand; return $script:PsqlPath }
        }
    } catch { }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root) { continue }
        $cand = @(Get-ChildItem (Join-Path $root "PostgreSQL\*\bin\psql.exe") -ErrorAction SilentlyContinue |
            Sort-Object { try { [int](Split-Path (Split-Path (Split-Path $_.FullName -Parent) -Parent) -Leaf) } catch { 0 } } -Descending)
        if ($cand.Count) { $script:PsqlPath = $cand[0].FullName; return $script:PsqlPath }
    }
    return $null
}

# db.server may carry a non-default port as "host:port".
function Get-PgHostPort($cfg) {
    $h = "$($cfg.dbServer)"; $p = 5432
    if ($h -match '^(.+):(\d+)$') { $h = $Matches[1]; $p = [int]$Matches[2] }
    if (-not $h) { $h = "localhost" }
    return @{ Host = $h; Port = $p }
}

# Run one psql query (against $db, default the postgres maintenance DB) and
# return its -tAc output. $null means "could not inspect" (psql missing or the
# call failed); an EMPTY STRING means the query succeeded with zero rows - the
# distinction matters (e.g. "database not in pg_database" is a finding, not a
# failure). Never throws.
function Invoke-PgQuery($cfg, [string]$sql, [string]$db = "postgres") {
    $ErrorActionPreference = 'SilentlyContinue'
    $psql = Find-Psql
    if (-not $psql) { return $null }
    $hp = Get-PgHostPort $cfg
    $old = $env:PGPASSWORD
    $env:PGPASSWORD = $cfg.dbPassword
    try {
        $out = & $psql -U $cfg.dbUser -h $hp.Host -p $hp.Port -d $db -tAc $sql 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        if ($null -eq $out) { return "" }
        return $out
    } catch { return $null } finally { $env:PGPASSWORD = $old }
}

# After a successful start, verify which database the server is ACTUALLY on.
# This is the check that would have caught the real-world incident where a
# mis-parsed settings file (BOM'd first key) silently sent the server to the
# shared default DB "lsfusion" while every lsfdev report showed the right name.
# Exact method: the JVM's established TCP connections to PostgreSQL are paired
# with pg_stat_activity rows via client_port, so the answer is per-process, not
# per-name. Fallback: name-based connection count / pg_database existence.
# Returns @{ state = ok | ok-weak | mismatch | unverified; detail = <text> }.
function Test-DbBinding($cfg, [int]$serverPid) {
    $ErrorActionPreference = 'SilentlyContinue'
    if (-not (Find-Psql)) { return @{ state = 'unverified'; detail = 'psql not found (PATH and standard install dirs)' } }
    $hp = Get-PgHostPort $cfg
    $ports = @(Get-NetTCPConnection -OwningProcess $serverPid -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.RemotePort -eq $hp.Port } | ForEach-Object { "$($_.LocalPort)" })
    if ($ports.Count) {
        $rows = Invoke-PgQuery $cfg "SELECT datname || '|' || client_port FROM pg_stat_activity WHERE client_port IS NOT NULL AND datname IS NOT NULL"
        if ($null -ne $rows) {
            $actual = @($rows | ForEach-Object {
                $parts = "$_".Trim().Split('|')
                if ($parts.Count -eq 2 -and ($ports -contains $parts[1])) { $parts[0] }
            } | Where-Object { $_ } | Sort-Object -Unique)
            if ($actual.Count) {
                if ($actual.Count -eq 1 -and $actual[0] -eq $cfg.dbName) { return @{ state = 'ok'; detail = $actual[0] } }
                return @{ state = 'mismatch'; detail = ($actual -join ', ') }
            }
        }
    }
    $dbq = ($cfg.dbName -replace "'", "''")
    $exists = Invoke-PgQuery $cfg "SELECT 1 FROM pg_database WHERE datname='$dbq'"
    if ($null -eq $exists) { return @{ state = 'unverified'; detail = 'pg_database query failed' } }
    if ("$exists".Trim() -ne "1") { return @{ state = 'mismatch'; detail = "database '$($cfg.dbName)' does not exist on $($hp.Host):$($hp.Port)" } }
    $cnt = "$(Invoke-PgQuery $cfg "SELECT count(*) FROM pg_stat_activity WHERE datname='$dbq'")".Trim()
    if ($cnt -match '^\d+$' -and [int]$cnt -gt 0) { return @{ state = 'ok-weak'; detail = "'$($cfg.dbName)' exists and has $cnt connection(s) (attribution by name only)" } }
    return @{ state = 'unverified'; detail = "database exists but no connections visible" }
}

function Ensure-Database($cfg) {
    # native psql/createdb may write to stderr; keep redirects non-terminating.
    $ErrorActionPreference = 'SilentlyContinue'
    # Freshness signal for Sync-InitMarker: $true when the database was NOT
    # there and had to be (re)created - lightstart must not run against it
    # (no Reflection rows, no stats). Stays $false when psql is unavailable
    # or the pre-check failed (unknown is not evidence of freshness).
    $script:DbKnownFresh = $false
    $psql = Find-Psql
    if (-not $psql) {
        Info "psql not found - lsFusion will attempt to create the database itself."
        return
    }
    $hp = Get-PgHostPort $cfg
    # Probe THROUGH Invoke-PgQuery: it targets the maintenance DB (-d
    # postgres - a bare psql would try a database named after db.user) and
    # returns $null when psql itself failed (bad exit code / no connection).
    # A broken probe must NOT look like a missing database: claiming
    # freshness on it would clear the init marker and force a full start on
    # every restart for as long as psql is unreachable.
    $exists = Invoke-PgQuery $cfg "SELECT 1 FROM pg_database WHERE datname='$($cfg.dbName -replace "'", "''")'"
    if ($null -eq $exists) {
        Warn "Database pre-check skipped (psql probe failed) - lsFusion will attempt creation on startup."
        return
    }
    if ("$exists".Trim() -eq "1") {
        Info "Database '$($cfg.dbName)' already exists."
        return
    }
    # A successful probe found no row: the DB is missing, so whatever ends up
    # under this name is fresh either way - created here, or by lsFusion at
    # startup after a failed createdb.
    $script:DbKnownFresh = $true
    $old = $env:PGPASSWORD
    $env:PGPASSWORD = $cfg.dbPassword
    try {
        $createdb = Join-Path (Split-Path $psql -Parent) "createdb.exe"
        if (-not (Test-Path $createdb)) { $createdb = "createdb" }
        & $createdb -U $cfg.dbUser -h $hp.Host -p $hp.Port $cfg.dbName 2>$null
        if ($LASTEXITCODE -eq 0) { Ok "Created database '$($cfg.dbName)'." }
        else { Warn "Could not create database (lsFusion will try on startup)." }
    } catch {
        Warn "Database creation attempt failed: $_"
    } finally {
        $env:PGPASSWORD = $old
    }
}

# Lightstart must never run against a database the init marker does not
# actually certify. The marker's CONTENT is the db.name it was written for
# (empty on legacy installs). Clear it - forcing the next start to be a full
# one - when the database was just found missing and (re)created (external
# drop, wiped cluster), or when db.name now points at a different database
# than the marker certifies. Call right after Ensure-Database. Residual gap:
# a database dropped AND re-created externally between runs (never observed
# missing by us) keeps the marker - the flag cannot see that; use
# 'restart -FullStart' after restoring a database by hand.
function Sync-InitMarker($cfg) {
    $marker = Join-Path $StateDir "server-initialized.flag"
    if (-not (Test-Path $marker)) { return }
    $reason = $null
    if ($script:DbKnownFresh) {
        $reason = "database '$($cfg.dbName)' had to be created"
    } else {
        # ReadAllText mirrors the WriteAllText below (UTF-8, BOM tolerated),
        # where PS 5.1 Get-Content would decode a BOM-less file as ANSI and
        # mangle a non-ASCII db.name into a perpetual false repoint. -cne
        # because PostgreSQL database names are case-sensitive. An EMPTY
        # marker (legacy installs, or unreadable) is adopted as matching on
        # purpose: it was fully trusted before content existed, and failing
        # it would surprise every existing install with a full start.
        $initializedFor = ""
        try { $initializedFor = ("" + [IO.File]::ReadAllText($marker)).Trim().TrimStart([char]0xFEFF) } catch { }
        if ($initializedFor -and ($initializedFor -cne "$($cfg.dbName)")) {
            $reason = "db.name repointed ('$initializedFor' -> '$($cfg.dbName)')"
        }
    }
    if ($reason) {
        Remove-Item $marker -Force -ErrorAction SilentlyContinue
        Info "Init marker cleared ($reason) - next start will be a full one (initial schema, stats and Reflection sync)."
    }
}

function Add-Opens([int]$major) {
    # On Java 11+ frameworks need reflective access to JDK internals.
    # Every package below is real, so no "unknown package" warnings appear.
    if ($major -ge 11) {
        return @(
            "--add-opens=java.base/java.lang=ALL-UNNAMED",
            "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED",
            "--add-opens=java.base/java.util=ALL-UNNAMED",
            "--add-opens=java.base/java.util.concurrent=ALL-UNNAMED",
            "--add-opens=java.base/java.text=ALL-UNNAMED",
            "--add-opens=java.base/java.io=ALL-UNNAMED",
            "--add-opens=java.base/java.nio=ALL-UNNAMED",
            "--add-opens=java.base/java.time=ALL-UNNAMED",
            "--add-opens=java.base/java.math=ALL-UNNAMED",
            "--add-opens=java.desktop/java.awt.font=ALL-UNNAMED"
        )
    }
    return @()
}

function Stop-Tracked([string]$pidFile, [int[]]$ports, [string]$label) {
    $killed = $false
    if (Test-Path $pidFile) {
        $procId = 0; [int]::TryParse((Get-Content $pidFile -Raw -Encoding UTF8).Trim(), [ref]$procId) | Out-Null
        if (Process-Alive $procId) {
            Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
            $killed = $true
        }
        Remove-Item $pidFile -ErrorAction SilentlyContinue
    }
    foreach ($p in $ports) {
        foreach ($procId in (Get-PortPids $p)) {
            if (-not (Process-Alive $procId)) { continue }
            # Kill by port ONLY when the process provably belongs to THIS
            # project. Two parallel sessions on one box can drift onto the
            # same ports, and an unconditional port-kill shoots the other
            # session's server mid-schema-sync (empty stderr, log cut off
            # mid-line). Ownership signals on the command line: the
            # -Dlsfdev.project=<dir> marker every server JVM gets at launch,
            # or this project's .lsfusion-dev path (Tomcat carries it in
            # -Dcatalina.home). Anything else is reported, not killed.
            $cmdline = (Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction SilentlyContinue).CommandLine
            $isOurs = $cmdline -and (
                $cmdline.IndexOf("-Dlsfdev.project=$ProjectDir", [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                $cmdline.IndexOf($StateDir, [StringComparison]::OrdinalIgnoreCase) -ge 0)
            if ($isOurs) {
                Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
                $killed = $true
            } else {
                Warn "Port $p is held by PID $procId, which does not look like this project's process - NOT killing it. Stop it from its own project, or move this project to other ports (setup -RmiPort/-HttpPort/...)."
            }
        }
    }
    # Load-bearing wording: hooks/lsfdev-session-track.ps1 matches
    # "Previous application server|Tomcat stopped|was not running" in the tool
    # output as proof that a start/restart really touched this project's processes.
    if ($killed) { Ok "$label stopped." } else { Info "$label was not running." }
}

function Patch-TomcatPorts($tomcatHome, $webPort, $shutdownPort) {
    # Tomcat reads its HTTP and shutdown ports from conf/server.xml, so the
    # config value alone is not enough - rewrite the file. Matching is anchored
    # on the shutdown="SHUTDOWN" / protocol="HTTP/1.1" attributes, so it works
    # regardless of the port currently in the file (idempotent re-runs).
    $serverXml = Join-Path $tomcatHome "conf\server.xml"
    if (-not (Test-Path $serverXml)) { Warn "server.xml not found - Tomcat ports left at defaults."; return }
    $xml = Get-Content $serverXml -Raw -Encoding UTF8
    $xml = [regex]::Replace($xml, '(<Server\s+port=")\d+("\s+shutdown="SHUTDOWN")', ('${1}' + $shutdownPort + '${2}'))
    $xml = [regex]::Replace($xml, '(<Connector\s+port=")\d+("\s+protocol="HTTP/1\.1")', ('${1}' + $webPort + '${2}'))
    Set-Content -Path $serverXml -Value $xml -Encoding UTF8
    Ok "Tomcat ports set: HTTP $webPort, shutdown $shutdownPort."
}

# One-line heads-up when the host locale would silently pick the server's
# system-caption/message language. The JVM inherits the OS user locale, and
# nothing pins it unless setup persisted -Duser.language via -JvmArgs /
# -TomcatOpts. Both JVMs matter: the app server builds system captions (and
# they additionally get persisted into Reflection tables during the
# instance's first real use - switching the locale later does NOT rewrite
# those), the Tomcat JVM renders the web client's own pages. Verified on a
# pl-PL host: Polish web UI, Polish log dates and Polish system captions,
# with no hint anywhere.
function Show-LocaleAdvice($cfg, [switch]$Brief) {
    $tag = [System.Globalization.CultureInfo]::CurrentCulture.Name
    if (-not $tag) { $tag = [System.Globalization.CultureInfo]::CurrentUICulture.Name }
    $lang = "$(($tag -split '-')[0])".ToLowerInvariant()
    if ($lang -in @('', 'en')) { return }
    # Token-anchored and case-sensitive: JVM flags are case-sensitive, and a
    # -Duser.language.format=... alone would not set the base locale.
    $jvmPinned = "$($cfg.jvmArgs)" -cmatch '(^|\s)-Duser\.language='
    $tcPinned  = "$($cfg.tomcatOpts)" -cmatch '(^|\s)-Duser\.language='
    if ($jvmPinned -and $tcPinned) { return }
    # Name only the side(s) actually unpinned, and suggest only the missing
    # flag(s) - the two JVMs are configured independently. The suggested
    # value APPENDS to what is already stored: setup -JvmArgs replaces the
    # whole string, so a bare suggestion would silently drop an existing
    # -Xmx4g or similar.
    $sides = @(); $flags = @()
    if (-not $jvmPinned) { $sides += "app-server";          $flags += "-JvmArgs `"$(("$($cfg.jvmArgs) -Duser.language=en -Duser.country=US").Trim())`"" }
    if (-not $tcPinned)  { $sides += "web-client (Tomcat)"; $flags += "-TomcatOpts `"$(("$($cfg.tomcatOpts) -Duser.language=en -Duser.country=US").Trim())`"" }
    $jvmNoun = if ($sides.Count -gt 1) { "JVMs inherit" } else { "JVM inherits" }
    Warn "Host locale is $tag - the $($sides -join ' and ') $jvmNoun it silently: system captions, messages and logs will come out in '$lang'."
    if ($Brief) {
        Info "Pin it with: setup $($flags -join ' ') (any language tag works; details in 'check')."
        return
    }
    Info "If that is not what you want, pin the language once (en shown; any tag works):"
    Info "  setup $($flags -join ' ')   then restart."
    Info "System captions also get persisted into the database (Reflection tables) during the instance's first real use, and changing the locale later does NOT rewrite them - pin the locale before the first start if those matter."
}

# --------------------------------------------------------------- commands ---

function Cmd-Check {
    Head "Environment check"
    $java = Find-Java
    if ($java) {
        if ($java.Major -ge 11) { Ok "Java $($java.Version) (major $($java.Major)) - $($java.Path)" }
        elseif ($java.Major -eq 8) { Warn "Java $($java.Version) found. lsFusion runs on 8, but Java 11+ is recommended." }
        else { Warn "Java $($java.Version) found - version could not be confirmed as 8+." }
    } else {
        Bad "Java not found. Install a JDK 11+ (e.g. Temurin/OpenJDK) and re-run check."
    }

    Write-Host ""
    $psqlPath = Find-Psql
    if ($psqlPath) {
        $onPath = [bool](Get-Command psql -ErrorAction SilentlyContinue)
        $how = if ($onPath) { "" } else { " (not on PATH - located next to the PostgreSQL service/install; used automatically)" }
        Ok "psql found - $psqlPath$how"
        Info "Used to pre-create the database and to verify the server's actual DB binding after start."
    } else {
        Warn "psql not found (PATH, PostgreSQL service dir, standard install dirs) - the DB is still created by lsFusion itself, but the post-start database-binding verification will be skipped."
    }
    $svc = Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "postgres*" -or $_.DisplayName -like "*postgreSQL*" }
    if ($svc) {
        foreach ($s in $svc) {
            if ($s.Status -eq "Running") { Ok "PostgreSQL service '$($s.Name)' is running." }
            else { Warn "PostgreSQL service '$($s.Name)' exists but is '$($s.Status)'. Start it before running the server." }
        }
    }
    if (Test-PortOpen 5432) { Ok "A server is listening on PostgreSQL port 5432." }
    else { Bad "Nothing is listening on port 5432. PostgreSQL must be installed and running." }

    Write-Host ""
    $py = Find-Python
    if ($py) {
        Ok "Python for Playwright verification - $py"
        if (Test-PlaywrightInstalled $py) { Ok "Playwright is installed (Chromium bundled by Playwright)." }
        else { Info "Playwright will be installed on the first 'verify' run (~120 MB)." }
    } else {
        Warn "Python 3 not found - install Python to use the 'verify' command (it drives Playwright)."
    }

    Write-Host ""
    $git = Find-Git
    if ($git) { Ok "git found - $git (used by 'clone' to fetch existing projects)." }
    else { Info "git not on PATH - only needed for the 'clone' command. Install Git to clone an existing lsFusion repo." }

    Write-Host ""
    $mvn = Find-Maven
    if ($mvn) { Ok "Maven found - $mvn (used for projects with pom.xml; skips server jar download)." }
    else { Info "Maven not on PATH - only needed for Maven-based existing projects (pom.xml). The skill falls back to the downloaded server jar without it." }

    Write-Host ""
    $cfg = Load-Config
    if ($cfg) {
        Ok "Project is set up (lsFusion $($cfg.version), config in .lsfusion-dev/)."
        Show-LocaleAdvice $cfg
        if ((Test-MavenProject $ProjectDir) -and (Find-Maven)) {
            Ok "Maven project: lsfusion-server comes from Maven dependencies (no local jar needed)."
        } else {
            $jar = Join-Path $StateDir "lsfusion-server-$($cfg.version).jar"
            if (Test-Path $jar) { Ok "Server jar present." } else { Warn "Server jar missing - run setup again." }
        }
    } else {
        Info "Project not set up yet. Next step: lsfdev.ps1 setup -AppId <short id> -DbPassword <password>"
    }
    if ($script:StableShimPath) {
        Write-Host ""
        Ok "Stable CLI path (survives plugin updates - remember THIS one, never the versioned plugin-cache path): $script:StableShimPath"
    }
}

function Cmd-Setup {
    Head "Setup"
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

    $isExistingProject = Test-ExistingProject $ProjectDir
    if ($isExistingProject) {
        Info "Detected an existing lsFusion project (pom.xml / src/main/lsfusion / lsfusion.properties)."
        Info "The project's own lsfusion.properties stays in charge; settings.properties will only carry install-specific overrides."
    }

    $existing = Load-Config
    function Pick($key, $param, $fallback) {
        if ($ScriptBound.ContainsKey($param)) { return (Get-Variable $param -ValueOnly) }
        if ($existing -and ($existing.PSObject.Properties.Name -contains $key)) { return $existing.$key }
        return $fallback
    }
    $tomcatVer = Resolve-TomcatVersion
    $requestedVersion = (Pick "version" "Version" "7")
    # Maven projects pin the platform version in pom.xml, and Maven resolves the
    # server jar from it. The web-client war (which the skill downloads, not
    # Maven) MUST match, or a -Version default of '7' would ship a
    # mismatched client against the pom's server. So unless the user explicitly
    # passed -Version, follow the pom.
    $pomVersion = $null
    if (Test-MavenProject $ProjectDir) { $pomVersion = Get-PomPlatformVersion $ProjectDir }
    if ($pomVersion) {
        if ($ScriptBound.ContainsKey("Version")) {
            $resolvedReq = Resolve-Version $requestedVersion
            if ($resolvedReq -ne $pomVersion) {
                Warn "pom.xml pins platform $pomVersion, but -Version '$requestedVersion' resolves to $resolvedReq."
                Warn "Using $resolvedReq for the web client; the server still comes from pom.xml ($pomVersion). They should match - pass -Version $pomVersion."
            }
        } else {
            if ($requestedVersion -ne $pomVersion) {
                Info "Maven project: taking platform version $pomVersion from pom.xml (web client will match the server)."
            }
            $requestedVersion = $pomVersion
        }
    }
    $resolvedVersion = Resolve-Version $requestedVersion
    if ($resolvedVersion -ne $requestedVersion) {
        Info "Version: $resolvedVersion (resolved from '$requestedVersion')."
    }
    $cfg = [pscustomobject]@{
        version       = $resolvedVersion
        tomcatVersion = $tomcatVer
        dbServer      = (Pick "dbServer" "DbServer" "localhost")
        dbName        = (Pick "dbName" "DbName" "")
        dbUser        = (Pick "dbUser" "DbUser" "postgres")
        dbPassword    = (Pick "dbPassword" "DbPassword" "")
        adminUser     = (Pick "adminUser" "AdminUser" "admin")
        adminPassword = (Pick "adminPassword" "AdminPassword" "")
        topModule     = (Pick "topModule" "TopModule" "")
        jvmArgs       = (Pick "jvmArgs" "JvmArgs" "")
        tomcatOpts    = (Pick "tomcatOpts" "TomcatOpts" "")
        rmiPort       = (Pick "rmiPort" "RmiPort" 7652)
        httpPort      = (Pick "httpPort" "HttpPort" 7651)
        webSocketPort = (Pick "webSocketPort" "WebSocketPort" 8887)
        webPort       = (Pick "webPort" "WebPort" 8080)
        shutdownPort  = (Pick "shutdownPort" "ShutdownPort" 8005)
    }
    # --- App id resolution: db.name IS the app id -------------------------------
    # One short identifier, chosen when the application is created, covers both:
    # it is the PostgreSQL database name (db.name) AND the web context path (the
    # client war is deployed as <db.name>.war, so the UI lives at
    # http://localhost:<webPort>/<db.name>/). There is no separate key to keep in
    # sync: the context is derived from db.name wherever it is needed.
    # -AppId is the validated way to pick it; -DbName is the unrestricted expert
    # override (any name PostgreSQL accepts - if it is not context-safe, the war
    # simply deploys at the context root instead, see Test-ContextSafe).
    $dbExplicit = $ScriptBound.ContainsKey("DbName")
    if ($ScriptBound.ContainsKey("AppId")) {
        $aid = "$AppId".Trim().ToLowerInvariant()
        if ($aid -notmatch '^[a-z][a-z0-9_]{0,29}$') {
            throw "Invalid app id '$aid': 1-30 chars, a lowercase letter first, then only [a-z0-9_] - it names the PostgreSQL database and the web context path."
        }
        if ($aid -in @('postgres', 'template0', 'template1', 'root', 'docs', 'examples', 'manager')) {
            throw "App id '$aid' is reserved (PostgreSQL system database or stock Tomcat webapp) - pick another."
        }
        if ($dbExplicit -and ($cfg.dbName -ne $aid)) {
            throw "-AppId '$aid' and -DbName '$($cfg.dbName)' differ - the app id IS the database name; pass just one of them."
        }
        $persisted = Read-SettingsString "db.name"
        if ($persisted -and ($persisted -ne $aid)) {
            Info "App id changed: '$persisted' -> '$aid'. This repoints BOTH the database and the web context; data in '$persisted' is kept but no longer used - pass -DbName '$persisted' instead if you only meant to keep the old database."
        }
        $cfg.dbName = $aid
        $dbExplicit = $true
    }
    # Derived fallback for a genuinely fresh project (nothing persisted, nothing
    # passed): short folder-leaf + path-hash id - see New-AppId. A name already
    # persisted in settings.properties still wins (resolved just below).
    if (-not $cfg.dbName) {
        $cfg.dbName = New-AppId $ProjectDir
        Info "App id (database + web context): '$($cfg.dbName)' - derived from the folder name; pass -AppId <short id> to choose your own."
    }
    # --- Authoritative db.name resolution (before the first Save-Config) -------
    # db.name has NO safe implicit default: a missing db.name sends the server to
    # the shared platform-default database ("lsfusion"), silently orphaning this
    # project's data. The file the server actually reads is conf/settings.properties
    # (Spring `file:conf/settings.properties` in lsfusion.xml) in BOTH Maven and
    # non-Maven modes, with the project-root settings.properties as a legacy
    # mirror. So settings.properties — NOT config.json, NOT the per-project
    # auto-name — is the source of truth. Resolve strongest-first: an explicit
    # -DbName, else the name already persisted in settings.properties (preserved
    # VERBATIM), else whatever Pick produced (config.json cache, or the
    # deterministic per-path default for a genuinely fresh project). Doing this
    # BEFORE Save-Config means config.json is never even briefly written with the
    # auto-name when a real name exists — including when .lsfusion-dev/ was wiped
    # (then Load-Config returned $null and Pick fell through to the auto-name).
    if (-not $dbExplicit) {
        $confDbName = Get-SettingsValue (Join-Path $ProjectDir "conf\settings.properties") "db.name"
        $rootDbName = Get-SettingsValue (Join-Path $ProjectDir "settings.properties") "db.name"
        $persistedDbName = if ("$confDbName".Trim()) { $confDbName } elseif ("$rootDbName".Trim()) { $rootDbName } else { $null }
        if ($persistedDbName -and ($persistedDbName -ne $cfg.dbName)) {
            Info "Preserving app id / db.name '$persistedDbName' from settings.properties (pass -AppId or -DbName to change it)."
            $cfg.dbName = $persistedDbName
        }
        # A repo-committed db.name (conf/settings.properties shipped in the clone,
        # before this checkout ever had its own .lsfusion-dev/config.json) makes
        # every clone share one database. Flag it once, the first time we see it -
        # but only when it really looks committed: no config.json yet, a
        # non-default name, and no matching project-root mirror (lsfdev keeps root
        # and conf in sync, so a corroborating root file means we manage it and
        # the config cache was merely wiped, not a fresh clone).
        $rootCorroborates = ("$rootDbName".Trim() -ne "") -and ("$rootDbName".Trim() -eq "$confDbName".Trim())
        if ("$confDbName".Trim() -and (-not $existing) -and ($confDbName -ne (New-DbName $ProjectDir)) -and
            ($confDbName -ne (New-AppId $ProjectDir)) -and (-not $rootCorroborates)) {
            Warn "Project ships conf/settings.properties with db.name '$confDbName' - every clone of this repo shares that database. Pass 'setup -AppId <unique> -Force' if this instance needs its own DB."
        }
    }
    # When every port is still at its default, none was passed explicitly, and
    # a default is already taken by a foreign process (typical: a second agent
    # session on the same box), derive a deterministic per-project port set
    # from the same path hash that seeds the derived app id. Hash-derived ports land
    # parallel sessions on disjoint values instead of having every agent walk
    # the same "default+10" ladder and collide again.
    $portFlagsPassed = @("RmiPort", "HttpPort", "WebSocketPort", "WebPort", "ShutdownPort") |
        Where-Object { $ScriptBound.ContainsKey($_) }
    $portsAtDefault = ($cfg.rmiPort -eq 7652 -and $cfg.httpPort -eq 7651 -and $cfg.webSocketPort -eq 8887 -and
                       $cfg.webPort -eq 8080 -and $cfg.shutdownPort -eq 8005)
    if (-not $portFlagsPassed -and $portsAtDefault) {
        $ownPids = Get-OwnPids
        $defaultPorts = if ($NoWeb) { @(7652, 7651, 8887) } else { @(7652, 7651, 8887, 8080, 8005) }
        $busyDefaults = @($defaultPorts | Where-Object { Test-PortBusyForeign $_ $ownPids })
        if ($busyDefaults.Count) {
            $md5 = [System.Security.Cryptography.MD5]::Create()
            $hashBytes = $md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($ProjectDir.ToLower()))
            $md5.Dispose()
            $seed = [Math]::Abs([BitConverter]::ToInt32($hashBytes, 0))
            $derived = $false
            for ($i = 0; $i -lt 100 -and -not $derived; $i++) {
                # base in 20000..39990, step 10 - far from the well-known defaults
                $base = 20000 + (((($seed % 2000) + $i) * 10) % 20000)
                # NB: parentheses are load-bearing - PS's comma binds tighter
                # than '+', so @($base + 2, ...) would parse as int + array.
                $cand = @(($base + 2), ($base + 1), ($base + 7), $base, ($base + 5))   # rmi, http, ws, web, shutdown
                if (-not @($cand | Where-Object { Test-PortBusyForeign $_ $ownPids })) {
                    $cfg.rmiPort = $base + 2; $cfg.httpPort = $base + 1; $cfg.webSocketPort = $base + 7
                    $cfg.webPort = $base; $cfg.shutdownPort = $base + 5
                    $derived = $true
                }
            }
            if ($derived) {
                Info "Default port(s) $($busyDefaults -join ', ') are taken by another process - derived this project's ports from its path hash:"
                Info "  RMI $($cfg.rmiPort), Action API $($cfg.httpPort), WebSocket $($cfg.webSocketPort), web $($cfg.webPort), Tomcat shutdown $($cfg.shutdownPort)."
                Info "  (Deterministic for this path; pass -RmiPort/-HttpPort/... to choose your own.)"
            } else {
                Warn "Default port(s) busy and no free derived set found - pass explicit ports via setup flags."
            }
        }
    }
    Save-Config $cfg
    Ok "Config written (lsFusion $($cfg.version), Tomcat $($cfg.tomcatVersion))."
    Show-LocaleAdvice $cfg

    # Port preflight up front - BEFORE the ~400 MB of downloads - so a conflict
    # is reported immediately instead of after a long fetch. Covers every port
    # this install will bind, not just the web port; our own running instances
    # are excluded so a re-setup over a live server isn't a false positive.
    $preflight = @(
        @{ Name = "RMI (app server)";   Port = $cfg.rmiPort;       Flag = "-RmiPort" },
        @{ Name = "Action API";         Port = $cfg.httpPort;      Flag = "-HttpPort" },
        # The platform unconditionally binds a WebSocket server too (webSocket.port,
        # default 8887). A second instance on the same box hits BindException there
        # unless this port is shifted as well - it is the easy one to forget.
        @{ Name = "WebSocket (app server)"; Port = $cfg.webSocketPort; Flag = "-WebSocketPort" }
    )
    if (-not $NoWeb) {
        $preflight += @{ Name = "Tomcat HTTP (web)"; Port = $cfg.webPort;      Flag = "-WebPort" }
        $preflight += @{ Name = "Tomcat shutdown";   Port = $cfg.shutdownPort; Flag = "-ShutdownPort" }
    }
    Test-PortPreflight $preflight | Out-Null

    # When the platform version changes, drop the init marker so the next
    # start is a full one (fresh stats recalculation and Reflection sync for
    # the new platform's module set), and clear stale server jars to save disk.
    $platformVersionChanged = ($existing -and $existing.version -and ($existing.version -ne $cfg.version))
    if ($platformVersionChanged) {
        $marker = Join-Path $StateDir "server-initialized.flag"
        if (Test-Path $marker) {
            Remove-Item $marker -Force -ErrorAction SilentlyContinue
            Info "Version changed ($($existing.version) -> $($cfg.version)) - next start will be a full one (fresh stats + Reflection sync)."
        }
    }
    Get-ChildItem $StateDir -Filter "lsfusion-server-*.jar" -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne "lsfusion-server-$($cfg.version).jar" } |
        ForEach-Object {
            Remove-Item $_.FullName -Force
            Info "Removed stale jar: $($_.Name)"
        }

    # --- server jar (skipped for Maven projects: Maven resolves it itself) ---
    $mavenAvailable = (Test-MavenProject $ProjectDir) -and (Find-Maven)
    if ($mavenAvailable) {
        Info "Maven project + Maven on PATH: skipping server jar download. 'start-server' will use the Maven-resolved classpath (lsfusion-server comes from pom.xml)."
        # Clean up any leftover jar from earlier non-Maven setups - saves ~150 MB.
        Remove-Item (Join-Path $StateDir "lsfusion-server-*.jar") -Force -ErrorAction SilentlyContinue
    } else {
        # Version-driven only. The jar filename carries the version and the
        # stale-jar cleanup above removes other versions, so a missing jar means
        # "this version isn't fetched yet" — a fresh setup or a version bump.
        # -Force regenerates config/settings but does NOT re-download a jar that
        # is already the right version (delete the file to force a refetch).
        $jar = Join-Path $StateDir "lsfusion-server-$($cfg.version).jar"
        if (Test-Path $jar) { Ok "Server jar already present (lsFusion $($cfg.version))." }
        else { Invoke-Download "$DownloadBase/lsfusion-server-$($cfg.version).jar" $jar; Ok "Server jar downloaded." }
    }

    # --- Tomcat + client war ---
    if (-not $NoWeb) {
        # Drop any leftover war download (older skill versions kept it) - the
        # war only needs to exist as Tomcat's ROOT.war; a second ~250 MB copy
        # is pure waste.
        Remove-Item (Join-Path $StateDir "lsfusion-client-*.war") -Force -ErrorAction SilentlyContinue

        $tomcatHome = Join-Path $StateDir "tomcat"
        $webapps    = Join-Path $tomcatHome "webapps"
        # The war is deployed under the app id (= db.name), so Tomcat serves
        # the UI at the /<db.name> context path. A db.name that is not a valid
        # context name (expert -DbName choices are unrestricted) falls back to
        # the context root, i.e. the pre-app-id ROOT.war layout.
        $ctxName = $cfg.dbName
        if (-not (Test-ContextSafe $ctxName)) {
            Warn "db.name '$ctxName' is not usable as a Tomcat context/war name - deploying the web client at the context root (/) instead."
            $ctxName = "ROOT"
        }
        $ctxDisplay = if ($ctxName -eq "ROOT") { "/" } else { "/$ctxName" }
        $warName    = "$ctxName.war"
        $warPath    = Join-Path $webapps $warName

        # Re-download is version-driven, NOT -Force-driven:
        #  - Tomcat (the servlet container) is independent of the lsFusion
        #    version — a new client war runs fine on the already-installed
        #    Tomcat — so we fetch it ONLY when it is missing. To move to a
        #    different Tomcat build, delete .lsfusion-dev/tomcat and re-run setup.
        #  - the client war IS versioned with the platform, so we refetch it only
        #    when the platform version changed or the war is absent (a rename
        #    from a previous deployment name counts as present - see below), or
        #    when -RefreshWar explicitly asks for the current build of the SAME
        #    version: the escape hatch for -SNAPSHOT war<->server build drift
        #    (Maven updates the server, the war stays - see
        #    Test-WarServerBuildDrift).
        $needTomcat = -not (Test-Path (Join-Path $tomcatHome "bin\bootstrap.jar"))
        # Any *.war in webapps under another name is a previous lsfdev
        # deployment (stock Tomcat ships only exploded dirs, never wars): an
        # old ROOT.war, or a deployment under a previous app id.
        $staleWarsPre = @()
        if (Test-Path $webapps) {
            $staleWarsPre = @(Get-ChildItem $webapps -Filter *.war -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne $warName })
        }

        # Replacing Tomcat's files, the war, or the exploded app while Tomcat
        # is running fails ("bootstrap.jar is used by another process", or the
        # locked exploded directory). Stop a running Tomcat first whenever we
        # are about to touch any of them.
        if ($needTomcat -or $staleWarsPre -or (-not (Test-Path $warPath)) -or $platformVersionChanged -or $RefreshWar) {
            Stop-Tracked $TomcatPid @($cfg.webPort) "Running Tomcat (stopping before update)"
        }

        if ($needTomcat) {
            $zip = Join-Path $StateDir "tomcat.zip"
            $tv = $cfg.tomcatVersion
            try {
                Invoke-Download "https://dlcdn.apache.org/tomcat/tomcat-9/v$tv/bin/apache-tomcat-$tv.zip" $zip
            } catch {
                Warn "Primary mirror failed; trying the Apache archive."
                Invoke-Download "https://archive.apache.org/dist/tomcat/tomcat-9/v$tv/bin/apache-tomcat-$tv.zip" $zip
            }
            $tmp = Join-Path $StateDir "_tomcat_tmp"
            if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
            if (Test-Path $tomcatHome) { Remove-Item $tomcatHome -Recurse -Force }
            Expand-Archive -Path $zip -DestinationPath $tmp -Force
            $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1
            Move-Item $inner.FullName $tomcatHome
            Remove-Item $tmp -Recurse -Force
            Remove-Item $zip -Force
            Ok "Tomcat $tv installed."
        } else {
            Ok "Tomcat already installed (kept - independent of the lsFusion version)."
        }

        # Migrate deployments under any other name: it is the same ~250 MB
        # client war, so rename it to <db.name>.war instead of re-downloading,
        # and drop the old exploded dir + per-context descriptor. Recomputed
        # after the Tomcat install (a reinstall wipes webapps/).
        $staleWars = @()
        if (Test-Path $webapps) {
            $staleWars = @(Get-ChildItem $webapps -Filter *.war -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne $warName })
        }
        $deferredStaleWars = @()
        foreach ($sw in $staleWars) {
            $oldCtx = [IO.Path]::GetFileNameWithoutExtension($sw.Name)
            # Under a pure -RefreshWar the old-name war is the only deployable
            # copy until the refresh download has SUCCEEDED - a rename/AppId
            # switch combined with -RefreshWar must not consume it up front
            # (a failed download would leave the old context's settings
            # pointing at a war that no longer exists under that name). Defer
            # the cleanup to just after the successful deploy below.
            if ($RefreshWar -and (-not $platformVersionChanged)) {
                $deferredStaleWars += $sw
                continue
            }
            if ((-not $platformVersionChanged) -and (-not (Test-Path $warPath))) {
                Move-Item $sw.FullName $warPath -Force
                Info "Redeployed $($sw.Name) as $warName (same war, new web context $ctxDisplay)."
            } else {
                Remove-Item $sw.FullName -Force
            }
            Remove-Item (Join-Path $webapps $oldCtx) -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $tomcatHome "conf\Catalina\localhost\$oldCtx.xml") -Force -ErrorAction SilentlyContinue
        }
        $needWar = (-not (Test-Path $warPath)) -or $platformVersionChanged -or $RefreshWar

        # Deploy the client war as <db.name>.war. The ~250 MB war is downloaded
        # to a temp file and *moved* into place, so a separate copy is never kept.
        if ($needWar) {
            $warTmp = Join-Path $StateDir "lsfusion-client-download.war"
            Invoke-Download "$DownloadBase/lsfusion-client-$($cfg.version).war" $warTmp
            Remove-Item (Join-Path $webapps $ctxName) -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $warPath -Force -ErrorAction SilentlyContinue
            Move-Item $warTmp $warPath -Force
            Ok "Web client war deployed as $warName - web context $ctxDisplay (lsFusion $($cfg.version))."
            # The refresh succeeded - now the deferred stale deployments are
            # safe to drop (see the -RefreshWar deferral above).
            foreach ($sw in $deferredStaleWars) {
                $oldCtx = [IO.Path]::GetFileNameWithoutExtension($sw.Name)
                Remove-Item $sw.FullName -Force -ErrorAction SilentlyContinue
                Remove-Item (Join-Path $webapps $oldCtx) -Recurse -Force -ErrorAction SilentlyContinue
                Remove-Item (Join-Path $tomcatHome "conf\Catalina\localhost\$oldCtx.xml") -Force -ErrorAction SilentlyContinue
            }
            # Immediate verdict on -SNAPSHOT build drift (silent when aligned or
            # when the server jar is not resolvable yet - Maven mode before the
            # first start-server). A -RefreshWar that still warns here means the
            # SERVER side is the stale one; the warning names the remedy for
            # the jar's actual source (mvn -U vs delete + re-setup).
            Test-WarServerBuildDrift $cfg
        } else {
            Ok "Web client war up to date ($warName, web context $ctxDisplay, lsFusion $($cfg.version)) - not re-downloading."
            Test-WarServerBuildDrift $cfg
        }

        $rootDir = Join-Path $webapps "ROOT"
        if ($ctxName -eq "ROOT") {
            # The app itself owns the context root. A leftover redirect stub
            # from an earlier /<id> deployment (index.html, no WEB-INF) would
            # stop Tomcat from expanding ROOT.war - clear it.
            if ((Test-Path (Join-Path $rootDir "index.html")) -and -not (Test-Path (Join-Path $rootDir "WEB-INF"))) {
                Remove-Item $rootDir -Recurse -Force -ErrorAction SilentlyContinue
            }
        } else {
            # Keep the context root useful: replace Tomcat's stock welcome app
            # (or a leftover exploded ROOT) with a one-line redirect into the
            # app, so http://localhost:<webPort>/ still lands in it. Target
            # /<ctx>/main, not /<ctx>/: the bare context root 404s on current
            # 7.0-SNAPSHOT wars (see Resolve-LandingUrl), while /main answers
            # on every supported war - where the root works it forwards to
            # main anyway.
            if (Test-Path (Join-Path $rootDir "index.jsp")) {   # stock Tomcat welcome app
                Remove-Item $rootDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item -ItemType Directory -Force -Path $rootDir | Out-Null
            $redirect = '<!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=/' + $ctxName + '/main"><title>lsFusion</title></head>' +
                        '<body><a href="/' + $ctxName + '/main">/' + $ctxName + '/main</a></body></html>'
            Set-Content -Path (Join-Path $rootDir "index.html") -Value $redirect -Encoding UTF8
        }

        Patch-TomcatPorts $tomcatHome $cfg.webPort $cfg.shutdownPort
    }

    # --- settings.properties ---
    if ($mavenAvailable) {
        # In Maven mode start-server launches the JVM with cwd = project root,
        # which reads conf/settings.properties. The project-root settings.properties
        # is NOT on the Maven classpath and would be silently ignored - so install
        # overrides (db.password etc.) MUST land in conf/, not the root file.
        # Merge into whatever the repo already commits there, preserving its keys.
        $confDir = Join-Path $ProjectDir "conf"
        New-Item -ItemType Directory -Force -Path $confDir | Out-Null
        $confSettings = Join-Path $confDir "settings.properties"
        Apply-SettingsOverride $confSettings "db.password" $cfg.dbPassword ($ScriptBound.ContainsKey("DbPassword")) | Out-Null
        Apply-SettingsOverride $confSettings "db.user"     $cfg.dbUser     ($ScriptBound.ContainsKey("DbUser"))     | Out-Null
        Apply-SettingsOverride $confSettings "db.server"   $cfg.dbServer   ($ScriptBound.ContainsKey("DbServer"))   | Out-Null
        # db.name is resolved authoritatively (settings.properties first) before
        # the config was saved, so $cfg.dbName already holds the value to persist;
        # Apply-SettingsOverride leaves an existing conf/ db.name untouched and
        # fills it in only when absent (a fresh project / migration from the root
        # mirror). An explicit -DbName overwrites it.
        Apply-SettingsOverride $confSettings "db.name"     $cfg.dbName     $dbExplicit                              | Out-Null
        # Ports: written when explicitly passed OR when non-default (the
        # hash-derived set from the busy-defaults fallback must persist here
        # too - the server reads ports from this file). Defaults stay implicit.
        if ($ScriptBound.ContainsKey("RmiPort")       -or $cfg.rmiPort       -ne 7652) { Apply-SettingsOverride $confSettings "rmi.port"       $cfg.rmiPort       $true | Out-Null }
        if ($ScriptBound.ContainsKey("HttpPort")      -or $cfg.httpPort      -ne 7651) { Apply-SettingsOverride $confSettings "http.port"      $cfg.httpPort      $true | Out-Null }
        if ($ScriptBound.ContainsKey("WebSocketPort") -or $cfg.webSocketPort -ne 8887) { Apply-SettingsOverride $confSettings "webSocket.port" $cfg.webSocketPort $true | Out-Null }
        # A stale root settings.properties from an older skill run is dead weight
        # in Maven mode (never read) and only confuses - drop it, but only if we
        # generated it (carries our marker); never touch a hand-written root file.
        $rootSettings = Join-Path $ProjectDir "settings.properties"
        if ((Test-Path $rootSettings) -and ((Get-Content $rootSettings -Raw -Encoding UTF8) -match 'generated by lsfdev\.ps1')) {
            Remove-Item $rootSettings -Force -ErrorAction SilentlyContinue
            Info "Removed stale project-root settings.properties (ignored in Maven mode)."
        }
        Ok "conf/settings.properties updated (Maven project - this is the file the server reads)."
    } else {
    # Non-Maven layout. The file the server reads at RUNTIME is still
    # conf/settings.properties (Spring `file:conf/settings.properties`, relative
    # to the JVM cwd = project root); the project-root settings.properties is a
    # human-readable MIRROR that older lsfdev versions wrote. We keep the mirror
    # in sync here and assert the authoritative conf/ copy further below. db.name
    # was already resolved authoritatively (settings.properties first) before the
    # config was saved, so $cfg.dbName is the value to persist - written
    # UNCONDITIONALLY (it has no safe default).
    $settings = Join-Path $ProjectDir "settings.properties"
    if ((Test-Path $settings) -and -not $Force) {
        # Keep the mirror's comments / extra keys, but surgically apply the
        # resolved db.name plus any db.* the caller passed explicitly. This is
        # what stops a plain re-setup from dropping db.name AND makes
        # `setup -DbName <x>` (without -Force) update the file too, instead of
        # silently changing only config.json (the two used to drift apart here).
        Set-SettingsProperty $settings "db.name" $cfg.dbName
        if ($ScriptBound.ContainsKey("DbServer"))      { Set-SettingsProperty $settings "db.server"      $cfg.dbServer }
        if ($ScriptBound.ContainsKey("DbUser"))        { Set-SettingsProperty $settings "db.user"        $cfg.dbUser }
        if ($ScriptBound.ContainsKey("DbPassword"))    { Set-SettingsProperty $settings "db.password"    $cfg.dbPassword }
        if ($ScriptBound.ContainsKey("RmiPort"))       { Set-SettingsProperty $settings "rmi.port"       $cfg.rmiPort }
        if ($ScriptBound.ContainsKey("HttpPort"))      { Set-SettingsProperty $settings "http.port"      $cfg.httpPort }
        if ($ScriptBound.ContainsKey("WebSocketPort")) { Set-SettingsProperty $settings "webSocket.port" $cfg.webSocketPort }
        Ok "settings.properties present - db.name (and any explicitly passed db.* / ports) updated; use -Force to regenerate the whole file."
    } elseif ($isExistingProject) {
        # Minimal overrides only: the project's own lsfusion.properties drives
        # topModule, namespaces, etc. We inject install-specific database
        # credentials - including db.name UNCONDITIONALLY (see the resolver
        # above): omitting it is what repointed the server at the default DB.
        $lines = @(
            "# lsFusion install-specific overrides - generated by lsfdev.ps1.",
            "# The project's own lsfusion.properties is loaded first; only put",
            "# install-specific settings (DB credentials, port overrides) here.",
            "db.password = $($cfg.dbPassword)",
            "db.name = $($cfg.dbName)"
        )
        if ($ScriptBound.ContainsKey("DbUser")   -or $cfg.dbUser   -ne "postgres")  { $lines += "db.user = $($cfg.dbUser)" }
        if ($ScriptBound.ContainsKey("DbServer") -or $cfg.dbServer -ne "localhost") { $lines += "db.server = $($cfg.dbServer)" }
        # Ports live here too (same scheme as db.*): only emitted when non-default.
        if ($ScriptBound.ContainsKey("RmiPort")  -or $cfg.rmiPort  -ne 7652) { $lines += "rmi.port = $($cfg.rmiPort)" }
        if ($ScriptBound.ContainsKey("HttpPort") -or $cfg.httpPort -ne 7651) { $lines += "http.port = $($cfg.httpPort)" }
        if ($ScriptBound.ContainsKey("WebSocketPort") -or $cfg.webSocketPort -ne 8887) { $lines += "webSocket.port = $($cfg.webSocketPort)" }
        if ($ScriptBound.ContainsKey("TopModule") -and $cfg.topModule) { $lines += "logics.topModule = $($cfg.topModule)" }
        Write-PropertiesFile $settings $lines
        Ok "settings.properties written (minimal - existing project)."
    } else {
        $topLine = ""
        if ($cfg.topModule) { $topLine = "logics.topModule = $($cfg.topModule)`r`n" }
        # Non-default ports go in settings.properties (server reads them natively,
        # independent of how it is launched) — see the rmi.port / http.port /
        # webSocket.port note in SKILL.md. Default ports (7652 / 7651 / 8887)
        # are left implicit.
        $portLines = ""
        if ($cfg.rmiPort  -ne 7652) { $portLines += "rmi.port = $($cfg.rmiPort)`r`n" }
        if ($cfg.httpPort -ne 7651) { $portLines += "http.port = $($cfg.httpPort)`r`n" }
        if ($cfg.webSocketPort -ne 8887) { $portLines += "webSocket.port = $($cfg.webSocketPort)`r`n" }
        $content = @"
# lsFusion application server settings - generated by lsfdev.ps1
# This is a mirror; the server reads conf/settings.properties at runtime. Edit
# either (setup and start keep conf/ authoritative and in sync with this file).
db.server = $($cfg.dbServer)
db.name = $($cfg.dbName)
db.user = $($cfg.dbUser)
db.password = $($cfg.dbPassword)
$portLines$topLine
"@
        Write-PropertiesFile $settings @($content -split "`r?`n")
        Ok "settings.properties written."
    }

    # conf/settings.properties is the file the server actually reads at runtime,
    # so make it authoritative here regardless of -Force: surgically assert the
    # resolved db.name (unconditional - no safe default) plus the db.* / ports in
    # effect, preserving any other keys the user added. This is the other half of
    # the `setup -DbName <x>` fix - without it, only config.json and the root
    # mirror changed while the server kept reading the old conf/ db.name.
    $confDir = Join-Path $ProjectDir "conf"
    New-Item -ItemType Directory -Force -Path $confDir | Out-Null
    $confSettings = Join-Path $confDir "settings.properties"
    Set-SettingsProperty $confSettings "db.name" $cfg.dbName
    Apply-SettingsOverride $confSettings "db.password" $cfg.dbPassword ($ScriptBound.ContainsKey("DbPassword")) | Out-Null
    Apply-SettingsOverride $confSettings "db.user"     $cfg.dbUser     ($ScriptBound.ContainsKey("DbUser"))     | Out-Null
    Apply-SettingsOverride $confSettings "db.server"   $cfg.dbServer   ($ScriptBound.ContainsKey("DbServer"))   | Out-Null
    if ($ScriptBound.ContainsKey("RmiPort")       -or $cfg.rmiPort       -ne 7652) { Set-SettingsProperty $confSettings "rmi.port"       $cfg.rmiPort }
    if ($ScriptBound.ContainsKey("HttpPort")      -or $cfg.httpPort      -ne 7651) { Set-SettingsProperty $confSettings "http.port"      $cfg.httpPort }
    if ($ScriptBound.ContainsKey("WebSocketPort") -or $cfg.webSocketPort -ne 8887) { Set-SettingsProperty $confSettings "webSocket.port" $cfg.webSocketPort }
    Ok "conf/settings.properties updated (the file the server reads at runtime)."
    }

    # --- .gitignore ---
    $gi = Join-Path $ProjectDir ".gitignore"
    $giText = ""
    if (Test-Path $gi) { $giText = Get-Content $gi -Raw -Encoding UTF8 }
    if ($giText -notmatch '(?m)^\.lsfusion-dev/?\s*$') {
        Add-Content -Path $gi -Value ".lsfusion-dev/"
        Ok "Added .lsfusion-dev/ to .gitignore."
    }

    Ensure-Database $cfg
    Sync-InitMarker $cfg
    Write-Host ""
    if ($NoWeb) {
        Ok "App id / database '$($cfg.dbName)' (no web client: -NoWeb)."
    } else {
        Ok "App id '$($cfg.dbName)' - database '$($cfg.dbName)', web context $(Get-WebUrl $cfg)"
    }
    Ok "Setup complete. Put your .lsf modules in $ProjectDir, then run: lsfdev.ps1 start"
    if ($script:StableShimPath) {
        Ok "Stable CLI path (survives plugin updates - remember THIS one, never the versioned plugin-cache path): $script:StableShimPath"
    }
}

function Cmd-StartServer {
    Head "Start application server"
    $cfg = Get-ConfigOrFail
    $java = Find-Java
    if (-not $java) { throw "Java not found. Install a JDK 11+ first." }

    # Maven-aware path: if the project has pom.xml AND Maven is on PATH, let
    # Maven resolve dependencies (including lsfusion-server itself) and build
    # the classpath. Otherwise fall back to the downloaded server jar.
    $useMaven = $false
    $mvn = $null
    if (Test-MavenProject $ProjectDir) {
        $mvn = Find-Maven
        if ($mvn) {
            $useMaven = $true
            Info "Maven project detected; using Maven for dependencies and classpath."
        } else {
            Warn "pom.xml present but Maven not on PATH - falling back to the downloaded server jar."
        }
    }
    if (-not $useMaven) {
        $jar = Join-Path $StateDir "lsfusion-server-$($cfg.version).jar"
        if (-not (Test-Path $jar)) { throw "Server jar missing. Run setup again." }
    }

    Stop-Tracked $ServerPid @($cfg.rmiPort, $cfg.httpPort, $cfg.webSocketPort) "Previous application server"
    Ensure-Database $cfg
    Sync-InitMarker $cfg

    # settings.properties can live at the project root (scaffolded / non-Maven
    # projects) OR in conf/ (Maven projects, where the JVM reads conf/settings.properties
    # off the working dir). Only warn when neither exists.
    if (-not (Test-Path (Join-Path $ProjectDir "settings.properties")) -and
        -not (Test-Path (Join-Path $ProjectDir "conf\settings.properties"))) {
        Warn "settings.properties not found (looked in project root and conf/) - re-run setup."
    }
    # conf/settings.properties is what the JVM actually reads - make sure it
    # exists and carries the resolved db.name before EVERY launch, not only at
    # setup: db.name has no safe default (a missing key silently sends the
    # server to the shared 'lsfusion' database), and configs written by older
    # skill versions could keep the name only in config.json. Bootstrap the
    # file from the root mirror first so its other keys (db.password etc.)
    # survive. Idempotent when the file is already right (Load-Config read the
    # file's own value back into $cfg), and the rewrite also re-encodes a
    # BOM-damaged file that the JVM would otherwise mis-parse (see
    # Write-PropertiesFile).
    $confBootDir  = Join-Path $ProjectDir "conf"
    $confBoot     = Join-Path $confBootDir "settings.properties"
    $rootBoot     = Join-Path $ProjectDir "settings.properties"
    New-Item -ItemType Directory -Force -Path $confBootDir | Out-Null
    if (-not (Test-Path $confBoot) -and (Test-Path $rootBoot)) {
        Copy-Item -Path $rootBoot -Destination $confBoot -Force
    }
    Set-SettingsProperty $confBoot "db.name" $cfg.dbName
    # Count only modules that will actually be on the classpath, mirroring the
    # staging/classpath logic below: the Maven source roots when they exist,
    # else loose top-level .lsf (flat-project fallback). A recursive scan over
    # the whole project would also count Maven-staged copies in target/,
    # scratch/seed scripts in .lsfusion-dev/, and stray files in unrelated
    # subfolders - none of which load, making the number a misleading signal.
    $srcRoots = @(@("src\main\lsfusion", "src\main\resources") |
        ForEach-Object { Join-Path $ProjectDir $_ } | Where-Object { Test-Path $_ })
    if ($srcRoots.Count) {
        $lsf = @($srcRoots | ForEach-Object { Get-ChildItem $_ -Recurse -Filter *.lsf -ErrorAction SilentlyContinue })
        $lsfWhere = "under src/main"
    } else {
        $lsf = @(Get-ChildItem $ProjectDir -File -Filter *.lsf -ErrorAction SilentlyContinue)
        $lsfWhere = "at the project root"
    }
    if ($lsf.Count -eq 0) { Warn "No .lsf files found $lsfWhere - the server will start with system modules only." }
    else { Info "Found $($lsf.Count) .lsf file(s) to load ($lsfWhere)." }
    # Stray modules outside the loaded roots deserve a heads-up - a .lsf parked
    # in docs/, scripts/ or next to the sources will silently NOT load.
    $allLsf = @(Get-ChildItem $ProjectDir -Recurse -Filter *.lsf -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(target|\.lsfusion-dev|\.git)\\' })
    $strayCount = $allLsf.Count - $lsf.Count
    if ($strayCount -gt 0) {
        $verb = if ($strayCount -eq 1) { "is" } else { "are" }
        Info "($strayCount more .lsf elsewhere in the project $verb NOT on the classpath and will not load.)"
    }

    if ($useMaven) {
        # 'mvn compile' refreshes target/classes (Maven incremental, fast after
        # the first run). The dependency classpath is cached and only refreshed
        # when pom.xml changes - resolving deps is the slow part of Maven.
        $pomFile = Join-Path $ProjectDir "pom.xml"
        $cpFile  = Join-Path $StateDir "maven-classpath.txt"
        Info "mvn -B -q -DskipTests compile (first run pulls deps; later runs are incremental)..."
        & $mvn -B -q -DskipTests -f $pomFile compile
        if ($LASTEXITCODE -ne 0) { throw "mvn compile failed (exit $LASTEXITCODE)." }
        $needResolve = (-not (Test-Path $cpFile)) -or ((Get-Item $pomFile).LastWriteTimeUtc -gt (Get-Item $cpFile).LastWriteTimeUtc)
        if ($needResolve) {
            Info "Resolving Maven dependency classpath..."
            & $mvn -B -q -f $pomFile dependency:build-classpath "-Dmdep.outputFile=$cpFile" "-Dmdep.includeScope=runtime"
            if ($LASTEXITCODE -ne 0) { throw "mvn dependency:build-classpath failed (exit $LASTEXITCODE)." }
        } else {
            Info "Reusing cached Maven classpath (pom.xml unchanged)."
        }
        $mavenCp = (Get-Content $cpFile -Raw -Encoding UTF8).Trim()
        $depCount = (@($mavenCp -split ';' | Where-Object { $_.Trim() })).Count
        $cpParts = @("target\classes")
        foreach ($extra in @("src\main\resources", "src\main\lsfusion")) {
            if (Test-Path (Join-Path $ProjectDir $extra)) { $cpParts += $extra }
        }
        $cpParts += $mavenCp
        $cp = $cpParts -join ";"
        Info "Classpath: target\classes + sources + $depCount Maven dependencies."
    } else {
        # Build a Maven-style staging directory at target\classes and put ONLY
        # that (plus the server jar) on the classpath. Mixing the project root
        # with src/main/lsfusion as classpath roots makes lsFusion discover the
        # same .lsf file via two different relative paths and reject the second
        # registration with "module 'X' has already been added".
        $stageDir = Join-Path $ProjectDir "target\classes"
        Remove-Item $stageDir -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $stageDir -Force | Out-Null

        # The server reads conf/settings.properties at runtime (Spring
        # `file:conf/settings.properties` in lsfusion.xml, relative to the JVM
        # working directory = project root). That file is AUTHORITATIVE: the
        # pre-launch block above already bootstrapped it (from the root mirror
        # when needed) and asserted db.name into it. A copy is staged onto the
        # classpath too, always sourced from conf/ - never the reverse - so a
        # stale root-mirror value can never resurrect over a conf/ edit.
        $confSettings = Join-Path $ProjectDir "conf\settings.properties"
        if (Test-Path $confSettings) { Copy-Item -Path $confSettings -Destination $stageDir -Force }

        # Copy from the canonical Maven source roots first.
        $stagedFromMaven = $false
        foreach ($extra in @("src\main\resources", "src\main\lsfusion")) {
            $srcRoot = Join-Path $ProjectDir $extra
            if (Test-Path $srcRoot) {
                Copy-Item -Path (Join-Path $srcRoot '*') -Destination $stageDir -Recurse -Force -ErrorAction SilentlyContinue
                $stagedFromMaven = $true
            }
        }
        # Flat-project fallback: pick up loose .lsf and lsfusion.properties
        # files sitting at the project root.
        if (-not $stagedFromMaven) {
            $flatLsf  = @(Get-ChildItem $ProjectDir -File -Filter *.lsf -ErrorAction SilentlyContinue)
            $flatProp = @(Get-ChildItem $ProjectDir -File -Filter *.properties -ErrorAction SilentlyContinue |
                          Where-Object { $_.Name -ne 'settings.properties' })
            foreach ($f in @($flatLsf) + @($flatProp)) {
                Copy-Item -Path $f.FullName -Destination $stageDir -Force
            }
        }

        # Compile Java sources if present (rare, but lsFusion supports INTERNAL
        # bindings to Java action classes).
        $javaSrcRoot = Join-Path $ProjectDir "src\main\java"
        if (Test-Path $javaSrcRoot) {
            $javaFiles = @(Get-ChildItem $javaSrcRoot -Recurse -Filter *.java -ErrorAction SilentlyContinue)
            if ($javaFiles.Count -gt 0) {
                $javacExe = Join-Path (Split-Path $java.Path -Parent) "javac.exe"
                if (Test-Path $javacExe) {
                    Info "Compiling $($javaFiles.Count) Java source(s) to target\classes..."
                    $javacArgs = @("-d", $stageDir, "-cp", $jar) + ($javaFiles | ForEach-Object { $_.FullName })
                    & $javacExe @javacArgs
                    if ($LASTEXITCODE -ne 0) { throw "javac failed (exit $LASTEXITCODE)." }
                } else {
                    Warn "src\main\java present but javac not next to java.exe - Java sources not compiled."
                }
            }
        }

        $cp = "target\classes;$jar"
        Info "Classpath: target\classes (staged from src\main\* or project root) + server jar."
    }

    # Development JVM options. devmode is always on for local development.
    # lightstart makes restarts much faster; schema sync and business logic
    # still run under it. What it skips is the Reflection metadata sync and
    # the user-side prefs reload (runtime.md#lightstart), so it is dropped on
    # the first launch (fresh DB gets the full initial sync in one go) and
    # whenever -FullStart is passed (the fix when actions referenced by
    # canonical name - scheduler tasks etc. - were added since the last full
    # start).
    $initMarker = Join-Path $StateDir "server-initialized.flag"
    $firstStart = -not (Test-Path $initMarker)
    $lightStart = (-not $firstStart) -and (-not $FullStart)
    $devArgs = @("-Dlsfusion.server.devmode=true",
                 # In dev mode it is normal for the schema to shift between
                 # runs (platform upgrades, REQUIRE-graph changes, edited
                 # CLASS / DATA properties). Let the sync drop now-unused
                 # modules, tables, and properties instead of refusing to
                 # start; production deployments override these in their
                 # own settings.properties.
                 "-Ddb.denyDropModules=false",
                 "-Ddb.denyDropTables=false",
                 "-Ddb.denyDropProperties=false")
    if ($lightStart) {
        $devArgs += "-Dlsfusion.server.lightstart=true"
        Info "Dev mode ON, light start ON (fast restart)."
    } else {
        $reason = if ($firstStart) { "first launch" } else { "-FullStart requested" }
        Info "Dev mode ON, light start OFF ($reason - full start incl. Reflection/prefs sync)."
    }
    # db.* ALSO go on the command line as -D system properties, mirroring the
    # values just resolved from settings.properties. The file stays the source
    # of truth between runs (Load-Config reads it back, and the pre-launch
    # block re-asserts db.name into it), so the two layers cannot drift - the
    # -D is a same-value duplicate. -D outranks every file layer, which makes
    # the server provably run against the database reported here even when a
    # settings file layer is unreadable or mis-parsed: a BOM'd first key, a
    # staging/classpath quirk, a platform resolution regression - the
    # real-world incident was data landing in the shared default DB while
    # ports from the SAME file applied fine. Values with whitespace cannot
    # survive Start-Process argument joining and stay file-only.
    $dbArgs = @()
    foreach ($pair in @(@("db.name", $cfg.dbName), @("db.server", $cfg.dbServer), @("db.user", $cfg.dbUser), @("db.password", $cfg.dbPassword))) {
        $v = "$($pair[1])"
        if ($v -and $v -match '^\S+$') { $dbArgs += "-D$($pair[0])=$v" }
    }
    # Ports keep coming from settings.properties ONLY (rmi.port / http.port /
    # webSocket.port - the server reads them natively): they have safe
    # defaults and no silent-fallback failure mode, so a -D duplicate would
    # only re-introduce the "ports live in two places" split for no gain.
    # Extra user JVM args (setup -JvmArgs "..."), e.g. -Duser.language=ru or a
    # bigger -Xmx. Appended AFTER the defaults so a user -Xmx (or an explicit
    # user -Ddb.*) wins - for duplicated JVM flags the last occurrence takes
    # effect.
    $extraJvm = @()
    if ($cfg.PSObject.Properties.Name -contains 'jvmArgs' -and $cfg.jvmArgs) {
        $extraJvm = @("$($cfg.jvmArgs)" -split '\s+' | Where-Object { $_ })
        Info "Extra JVM args: $($extraJvm -join ' ')"
    }
    Show-LocaleAdvice $cfg -Brief
    $jvmArgs = @() + (Add-Opens $java.Major) + $devArgs + $dbArgs + @(
        "-Xmx2g", "-Dfile.encoding=UTF-8") + $extraJvm + @(
        # Ownership marker for stop/restart: lets Stop-Tracked tell this
        # project's JVM apart from another session's server on the same ports.
        "-Dlsfdev.project=$ProjectDir",
        "-cp", $cp,
        "lsfusion.server.logics.BusinessLogicsBootstrap"
    )
    # Do NOT echo the full java command line: the classpath alone can be ~30 KB,
    # which bloats agent transcripts and tempts callers into piping start/restart
    # through filters (| tail, | Select-String) - and a piped invocation is what
    # gets a foreground start reclassified as a background task. Keep stdout
    # compact; the full command line goes to a file for debugging.
    $launchCmdFile = Join-Path $StateDir "launch-cmd.txt"
    "$($java.Path) $($jvmArgs -join ' ')" | Set-Content -Path $launchCmdFile -Encoding UTF8
    Info "Launching java ($(($cp -split ';').Count) classpath entries; full command line: $launchCmdFile)"
    Remove-Item $ServerOut, $ServerErr -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $java.Path -ArgumentList $jvmArgs `
        -WorkingDirectory $ProjectDir -RedirectStandardOutput $ServerOut `
        -RedirectStandardError $ServerErr -NoNewWindow -PassThru
    $proc.Id | Set-Content $ServerPid
    Info "PID $($proc.Id). Waiting up to $Timeout s for startup..."

    $deadline = (Get-Date).AddSeconds($Timeout)
    $verdict = "inconclusive"
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $log = (Read-FileText $ServerOut) + "`n" + (Read-FileText $ServerErr)
        if ($log -match "Server has successfully started") { $verdict = "started"; break }
        if ($proc.HasExited) { $verdict = "failed"; break }
    }

    Write-Host ""
    $tailOut = Tail-Text (Read-FileText $ServerOut) $Lines
    $tailErr = Tail-Text (Read-FileText $ServerErr) 30
    if ($verdict -eq "started") {
        Ok "Application server started (RMI $($cfg.rmiPort), Action API $($cfg.httpPort), WebSocket $($cfg.webSocketPort))."
        # Trust, but verify: confirm which database this JVM is REALLY on.
        # settings.properties and the -Ddb.* launch args should make a mismatch
        # impossible - if one is reported anyway, treat it as stop-the-line.
        $bind = Test-DbBinding $cfg $proc.Id
        switch ($bind.state) {
            'ok'      { Ok "Database binding verified: this server is connected to '$($bind.detail)'." }
            'ok-weak' { Ok "Database binding: $($bind.detail)." }
            'mismatch' {
                Bad "DATABASE MISMATCH: configured db.name is '$($cfg.dbName)' but the server is actually on: $($bind.detail)."
                Info "Anything written now lands in the wrong database. Stop the server, inspect conf/settings.properties (encoding / first line - see runtime.md, 'silently ignores db.name') and the -Ddb.name in .lsfusion-dev/launch-cmd.txt, then restart."
            }
            default   { Info "(actual DB binding not verified: $($bind.detail). The -Ddb.name launch argument still pins the name at the strongest resolution layer.)" }
        }
        # Certify initialization ONLY when the run did not provably land on a
        # wrong database: on a mismatch the configured DB got no sync at all,
        # so writing "$($cfg.dbName)" would make the NEXT (corrected) start a
        # light one against an uninitialized database. An existing marker is
        # left untouched - a mismatch run changes nothing about what an
        # earlier run initialized. Content = the db.name this install
        # initialized; Sync-InitMarker compares it (BOM-less on purpose).
        if ($bind.state -ne 'mismatch') {
            [IO.File]::WriteAllText($initMarker, "$($cfg.dbName)")
        }
    } elseif ($verdict -eq "failed") {
        Bad "Application server process exited during startup. Last log lines:"
        $tailOut | ForEach-Object { Write-Host "    $_" }
        if (($tailErr -join "").Trim()) {
            Write-Host "  --- stderr ---"
            $tailErr | ForEach-Object { Write-Host "    $_" }
        }
        Write-Host ""
        Info "Diagnose with references/runtime.md, fix the cause, then: lsfdev.ps1 restart"
    } else {
        Warn "Startup not confirmed within $Timeout s. Server may still be initializing. Recent log:"
        $tailOut | ForEach-Object { Write-Host "    $_" }
        Info "Re-check with: lsfdev.ps1 log    (or start-server -Timeout 300)"
    }
}

function Cmd-StartWeb {
    Head "Start web client (Tomcat)"
    $cfg = Get-ConfigOrFail
    Show-LocaleAdvice $cfg -Brief
    $java = Find-Java
    if (-not $java) { throw "Java not found." }
    $tomcatHome = Join-Path $StateDir "tomcat"
    if (-not (Test-Path (Join-Path $tomcatHome "bin\bootstrap.jar"))) {
        throw "Tomcat is not installed. Run setup (without -NoWeb)."
    }
    Test-WarServerBuildDrift $cfg
    Stop-Tracked $TomcatPid @($cfg.webPort) "Previous Tomcat"

    # Preflight Tomcat's ports now that our own instance is stopped. The shutdown
    # port is the silent killer: if a foreign process holds it, Catalina aborts
    # at startup with a BindException that otherwise surfaces only as a vague
    # "web UI did not respond". Fail fast with an actionable message instead.
    $ownPids = Get-OwnPids
    if (Test-PortBusyForeign $cfg.shutdownPort $ownPids) {
        throw "Tomcat shutdown port $($cfg.shutdownPort) is held by another process - Catalina cannot start. Re-run: setup -ShutdownPort <free port>, then start-web."
    }
    if (Test-PortBusyForeign $cfg.webPort $ownPids) {
        Warn "Web port $($cfg.webPort) is held by another process; Tomcat may fail to bind it. Re-run: setup -WebPort <free port>."
    }

    # Point the web client at this instance's application server. The lsFusion
    # web client reads the app-server connection from Tomcat context parameters
    # `host` / `port` / `exportName`; `port` MUST equal the server's rmi.port.
    # We write conf/Catalina/localhost/<db.name>.xml (the per-context
    # descriptor, named after the deployed <db.name>.war; ROOT.xml on root
    # deployments - see Get-AppContext) so a non-default rmi.port is honored.
    # Without this the client always dials the built-in default 7652 and a
    # custom-port server is unreachable.
    $ctxName = Get-AppContext $cfg
    $ctxDir = Join-Path $tomcatHome "conf\Catalina\localhost"
    New-Item -ItemType Directory -Force -Path $ctxDir | Out-Null
    $ctxXml = Join-Path $ctxDir "$ctxName.xml"
    @(
        '<Context>',
        '    <Parameter name="host" value="localhost" override="false"/>',
        "    <Parameter name=`"port`" value=`"$($cfg.rmiPort)`" override=`"false`"/>",
        '</Context>'
    ) -join "`r`n" | Set-Content -Path $ctxXml -Encoding UTF8
    Info "Web client wired to application server RMI port $($cfg.rmiPort) (context /$(if ($ctxName -ne 'ROOT') { $ctxName }))."

    $tempDir = Join-Path $tomcatHome "temp"
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null
    # Extra user Tomcat JVM args (setup -TomcatOpts "..."), the CATALINA_OPTS
    # analog - e.g. -Duser.language=ru for the web client.
    $extraTomcat = @()
    if ($cfg.PSObject.Properties.Name -contains 'tomcatOpts' -and $cfg.tomcatOpts) {
        $extraTomcat = @("$($cfg.tomcatOpts)" -split '\s+' | Where-Object { $_ })
        Info "Extra Tomcat JVM args: $($extraTomcat -join ' ')"
    }
    $jvmArgs = @() + (Add-Opens $java.Major) + $extraTomcat + @(
        "-Dcatalina.home=$tomcatHome",
        "-Dcatalina.base=$tomcatHome",
        "-Djava.io.tmpdir=$tempDir",
        "-Djava.util.logging.config.file=$tomcatHome\conf\logging.properties",
        "-Djava.util.logging.manager=org.apache.juli.ClassLoaderLogManager",
        "-Dlsfdev.project=$ProjectDir",
        "-classpath", "$tomcatHome\bin\bootstrap.jar;$tomcatHome\bin\tomcat-juli.jar",
        "org.apache.catalina.startup.Bootstrap", "start"
    )
    Remove-Item $TomcatOut -ErrorAction SilentlyContinue
    $proc = Start-Process -FilePath $java.Path -ArgumentList $jvmArgs `
        -WorkingDirectory $tomcatHome -RedirectStandardOutput $TomcatOut `
        -RedirectStandardError (Join-Path $StateDir "tomcat.err.log") -NoNewWindow -PassThru
    $proc.Id | Set-Content $TomcatPid
    $webUrl = Get-WebUrl $cfg
    Info "PID $($proc.Id). Waiting for the web UI at $webUrl ..."

    $deadline = (Get-Date).AddSeconds([Math]::Min($Timeout, 120))
    $up = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if ($proc.HasExited) { break }
        try {
            Invoke-WebRequest $webUrl -UseBasicParsing -TimeoutSec 5 -MaximumRedirection 0 -ErrorAction Stop | Out-Null
            $up = $true; break
        } catch {
            if ($_.Exception.Response) { $up = $true; break }
        }
    }
    Write-Host ""
    if ($up) {
        # $up only proves Tomcat answers HTTP (a 404 counts) - resolve the URL
        # the app actually lives at before printing it.
        $landing = Resolve-LandingUrl $cfg
        Ok "Web client is up: $($landing.url)"
        if (-not $landing.ok) {
            Warn "Tomcat answers, but neither $webUrl nor ${webUrl}main returned a page below HTTP 400 - the war may still be deploying or is broken; re-check with 'status' in a moment."
        } elseif ($landing.url -ne $webUrl) {
            Info "The bare context root $webUrl returns 404 on this war (current 7.0-SNAPSHOT behavior) - the SPA entry is /main; open/verify/status use it automatically."
        }
        Info "Default login: user '$($cfg.adminUser)', empty password."
    } else {
        # Not up. Pull together the Tomcat logs and look for a bind failure - the
        # most common silent cause - before printing a generic message.
        $catalog = Get-ChildItem (Join-Path $tomcatHome "logs") -Filter "catalina*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $logText = (Read-FileText $TomcatOut) + "`n" + (Read-FileText (Join-Path $StateDir "tomcat.err.log"))
        if ($catalog) { $logText += "`n" + (Read-FileText $catalog.FullName) }

        $bindDiagnosed = $false
        if ($logText -match "Failed to create server shutdown socket.*?port \[(\d+)\]") {
            Bad "Tomcat could not bind its shutdown port $($Matches[1]) (already in use). Re-run: setup -ShutdownPort <free port>, then start-web."
            $bindDiagnosed = $true
        } elseif ($logText -match "(?im)address already in use") {
            Bad "Tomcat hit 'Address already in use' - web port $($cfg.webPort) or shutdown port $($cfg.shutdownPort) is taken. Pick free ports via setup -WebPort / -ShutdownPort."
            $bindDiagnosed = $true
        }

        if ($proc.HasExited) {
            if (-not $bindDiagnosed) { Bad "Tomcat exited during startup. Tomcat log tail:" }
            else { Info "Tomcat log tail:" }
        } elseif (-not $bindDiagnosed) {
            Warn "Web UI did not respond yet. Check 'lsfdev.ps1 status' shortly, or inspect .lsfusion-dev/tomcat/logs/."
        }
        Tail-Text (Read-FileText $TomcatOut) 40 | ForEach-Object { Write-Host "    $_" }
        if ($catalog) {
            Write-Host "  --- $($catalog.Name) ---"
            Tail-Text (Read-FileText $catalog.FullName) 40 | ForEach-Object { Write-Host "    $_" }
        }
    }
}

function Cmd-Status {
    Head "Status"
    $cfg = Load-Config
    if (-not $cfg) { Info "Not set up."; return }
    $rmi = $cfg.rmiPort; $http = $cfg.httpPort; $ws = $cfg.webSocketPort; $web = $cfg.webPort

    if (Test-PortOpen 5432) { Ok "PostgreSQL    : listening on 5432" }
    else { Bad "PostgreSQL    : not listening on 5432" }

    $sPid = 0
    if (Test-Path $ServerPid) { [int]::TryParse((Get-Content $ServerPid -Raw -Encoding UTF8).Trim(), [ref]$sPid) | Out-Null }
    if ((Process-Alive $sPid) -and (Test-PortOpen $rmi)) { Ok "App server    : running (PID $sPid, RMI $rmi, API $http, WebSocket $ws$(if (-not (Test-PortOpen $ws)) { ' [NOT BOUND - port clash? see runtime.md]' }))" }
    elseif (Test-PortOpen $rmi) { Warn "App server    : something is on RMI port $rmi (PID file stale)" }
    else { Info "App server    : stopped" }

    # Database line: the configured name plus what is actually observable via
    # pg_stat_activity - the count makes a silently-wrong binding visible at a
    # glance (0 connections under a running server is a red flag).
    $dbq = ("$($cfg.dbName)" -replace "'", "''")
    $cnt = "$(Invoke-PgQuery $cfg "SELECT count(*) FROM pg_stat_activity WHERE datname='$dbq'")".Trim()
    if ($cnt -match '^\d+$') {
        $exists = "$(Invoke-PgQuery $cfg "SELECT 1 FROM pg_database WHERE datname='$dbq'")".Trim()
        if ($exists -ne "1")   { Warn "Database      : $($cfg.dbName) (does not exist yet - created on first start)" }
        elseif ([int]$cnt -gt 0) { Ok "Database      : $($cfg.dbName) ($cnt connection(s))" }
        else                   { Info "Database      : $($cfg.dbName) (exists, no connections)" }
        if (Process-Alive $sPid) {
            $bind = Test-DbBinding $cfg $sPid
            if ($bind.state -eq 'mismatch') {
                Bad "DB MISMATCH   : server PID $sPid is actually on: $($bind.detail) (configured: '$($cfg.dbName)') - see runtime.md, 'silently ignores db.name'."
            }
        }
    } else {
        Info "Database      : $($cfg.dbName) (psql not available - cannot inspect connections)"
    }

    $tPid = 0
    if (Test-Path $TomcatPid) { [int]::TryParse((Get-Content $TomcatPid -Raw -Encoding UTF8).Trim(), [ref]$tPid) | Out-Null }
    if ((Process-Alive $tPid) -and (Test-PortOpen $web)) { Ok "Web client    : running (PID $tPid, $((Resolve-LandingUrl $cfg).url))" }
    elseif (Test-PortOpen $web) { Warn "Web client    : something is on web port $web (PID file stale)" }
    else { Info "Web client    : stopped" }

    # Silent when war/server build dates agree (the healthy case).
    Test-WarServerBuildDrift $cfg
}

function Cmd-Log {
    $out = Read-FileText $ServerOut
    $err = Read-FileText $ServerErr
    if (-not $out -and -not $err) { Info "No server log yet. Start the server first."; return }
    Head "Server log (last $Lines lines of stdout)"
    Tail-Text $out $Lines | ForEach-Object { Write-Host $_ }
    $errTail = (Tail-Text $err 40) -join "`n"
    if ($errTail.Trim()) {
        Head "stderr (last 40 lines)"
        Write-Host $errTail
    }
    Head "Verdict"
    $all = $out + "`n" + $err
    if ($all -match "Server has successfully started") { Ok "Log shows: Server has successfully started." }
    elseif ($all -match "(?im)error parsing|syntax error|expecting|module .* not found") {
        Bad "Log contains lsFusion parse/module errors - fix the .lsf code (use lsfusion_retrieve_docs)."
    } elseif ($all -match "(?im)could not.*connect|connection refused|FATAL|password authentication failed") {
        Bad "Log shows a database/connection problem - check PostgreSQL and settings.properties."
    } elseif ($all -match "(?im)exception|caused by") {
        Warn "Log contains an exception - read the lines above for the cause."
    } else {
        Info "No explicit success or error marker found - the server may still be starting."
    }
}

function Cmd-Verify {
    Head "Visual verification (Playwright)"
    $cfg = Get-ConfigOrFail
    if ($EndSession) {
        if (Test-Path $PwSessionPid) { Stop-Tracked $PwSessionPid @() "Persistent verify-session browser" }
        else { Info "No persistent verify session to end." }
        return
    }
    $target = $Url
    if (-not $target) {
        # Probe, don't assume: on wars whose bare context root 404s (current
        # 7.0-SNAPSHOT) a Get-WebUrl default would screenshot the Tomcat
        # error page and happily "verify" it.
        $target = (Resolve-LandingUrl $cfg).url
    }
    # Persistent session: a detached headless Chromium on a per-project CDP
    # port. The page (navigation, open form, JS state) survives between
    # verify calls, so multi-step scenarios skip the re-navigation cost.
    $sessionPort = 0
    if ($Session) {
        $sessionPort = if ($CdpPort) { $CdpPort } else { 40000 + ($cfg.webPort % 20000) }
        Info "Session: persistent browser on CDP port $sessionPort - page state survives between verify calls (end with 'verify -EndSession'; stop/restart also close it)."
        if ($Locale) { Warn "-Locale is ignored in session mode (the browser context already exists)." }
        if ($Reload) { Info "Reload : forced page reload - fresh JS/CSS, app reset to default state (open forms close; reopen via -OpenScript)." }
    } elseif ($Reload) {
        Info "-Reload has no effect without -Session (a fresh browser always loads the page anew)."
    }

    $py = Find-Python
    if (-not $py) { throw "Python 3 not found. Install Python 3 to use Playwright verification." }
    Ensure-Playwright $py

    # Run the helper from a copy in the state dir: when the skill is installed
    # as a Claude Code plugin, scripts/ lives on a virtualized filesystem that
    # this PowerShell process can read but spawned native processes cannot —
    # python.exe gets "[Errno 2] No such file or directory" on the same path
    # even though Test-Path returns true (lsfusion/ai-skills#2).
    $scriptSrc = Join-Path $PSScriptRoot "verify_playwright.py"
    if (-not (Test-Path $scriptSrc)) { throw "verify_playwright.py not found at $scriptSrc" }
    $scriptPath = Join-Path $StateDir "verify_playwright.py"
    Copy-Item -LiteralPath $scriptSrc -Destination $scriptPath -Force

    # Clean stale artefacts from earlier Chrome-based verify runs.
    Remove-Item (Join-Path $StateDir "verify.png"), (Join-Path $StateDir "chrome.err.log"),
                (Join-Path $StateDir "chrome.shot.log") -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $StateDir "chrome-shot"), (Join-Path $StateDir "chrome-dom") `
                -Recurse -Force -ErrorAction SilentlyContinue

    Info "Browser: Playwright Chromium (headless)"
    Info "Target : $target"
    Info "Login  : user '$($cfg.adminUser)', $(if ($cfg.adminPassword) { 'password from config' } else { 'empty password' })"

    # Resolve the direct-open script (mirrors api's -Script/-ScriptFile pair:
    # -OpenScriptFile is the robust channel for non-ASCII text). The text is
    # always materialized to a UTF-8 file in the state dir and handed to
    # python by path, so it never rides the argv boundary.
    $openScriptText = ""
    if ($OpenScriptFile) {
        if (-not (Test-Path $OpenScriptFile)) { throw "OpenScriptFile not found: $OpenScriptFile" }
        $openScriptText = Get-Content -Raw -Encoding UTF8 $OpenScriptFile
    } elseif ($OpenScript) {
        $openScriptText = $OpenScript
    }
    $openFileArg = ""
    if ($openScriptText.Trim()) {
        $openFileArg = Join-Path $StateDir "verify-open-script.lsf"
        [IO.File]::WriteAllText($openFileArg, $openScriptText, (New-Object Text.UTF8Encoding($false)))
        Info "Open   : $($openScriptText.Trim() -replace '\s+', ' ') (direct form open via /eval/action)"
        if ($OpenExpect) { Info "Expect : '$OpenExpect' (text to wait for on the opened form)" }
    }

    if ($Click) { Info "Click  : '$Click' (navigator click-through before the final screenshot)" }
    if ($DoubleClick) { Info "DblClick: '$DoubleClick' (double-click a grid row to open its edit card)" }
    if ($Do.Count) { Info "Do     : $($Do.Count) generic step(s) after navigation (click/dblclick/hover/drag/dnd/mouse/fill/type/edit/press/eval/wait by Playwright selector; first VISIBLE match)" }
    Info "View   : ${ViewportWidth}x${ViewportHeight}$(if ($Locale) { ", locale $Locale" })"

    # Use --name=value form so an empty password is preserved through
    # PowerShell's native-argument handling (without =, empty strings get
    # dropped and argparse sees the next flag as the value). Every free-text
    # value goes through ConvertTo-NativeArg - PS 5.1 does not escape embedded
    # double quotes on its own, and -Do steps (JS, attribute selectors) carry
    # them routinely.
    # -Do steps travel via a UTF-8 JSON file, NOT argv: PowerShell 5.1 wraps a
    # native argument in quotes only when it sees whitespace outside naively
    # paired quote characters, so JS / attribute-selector steps with certain
    # quote+space patterns (e.g. join(" | ")) get split apart no matter how
    # they are escaped. A file cannot be corrupted by argv quoting.
    $doArgs = @()
    $doSteps = @($Do | Where-Object { $_ })
    if ($doSteps.Count) {
        $doFile = Join-Path $StateDir "verify-do.json"
        [IO.File]::WriteAllText($doFile, (ConvertTo-Json -InputObject $doSteps -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
        $doArgs = @("--do-file=$doFile")
    }
    $reloadArgs = @()
    if ($Reload) { $reloadArgs = @("--reload") }
    $jsonText = (& $py $scriptPath --url $target --output-dir $StateDir `
        "--user=$(ConvertTo-NativeArg $cfg.adminUser)" "--password=$(ConvertTo-NativeArg $cfg.adminPassword)" `
        "--click=$(ConvertTo-NativeArg $Click)" "--double-click=$(ConvertTo-NativeArg $DoubleClick)" `
        "--open-script-file=$(ConvertTo-NativeArg $openFileArg)" "--open-expect=$(ConvertTo-NativeArg $OpenExpect)" `
        --viewport-width $ViewportWidth --viewport-height $ViewportHeight "--locale=$Locale" `
        --session-port $sessionPort `
        @reloadArgs @doArgs --timeout 30000) -join "`n"
    $pyExit = $LASTEXITCODE

    $r = $null
    try { $r = $jsonText | ConvertFrom-Json } catch { }
    if (-not $r) {
        Bad "verify_playwright.py did not return parseable JSON (exit $pyExit). Raw output:"
        Write-Host $jsonText
        return
    }

    Write-Host ""
    if ($r.session -and $r.session.requested) {
        $sessionNote = if ($r.session.navigated) { 'page (re)navigated to the target URL' }
        elseif ($r.open -and $r.open.requested) { 'continued the live page, then -OpenScript re-navigated it (fresh page, fresh JS/CSS)' }
        else { 'continued the live page - no reload, previous state (open form, JS/CSS as loaded) intact; add -Reload to pick up edited web resources' }
        Info "Session : $sessionNote"
    }
    if ($r.title) { Info "Page title : $($r.title)" }
    # An error landing must not sail through as [OK] screenshots. The status
    # comes from the navigation response; the title pattern (Tomcat's stock
    # error page) covers session continuations, where nothing navigates and
    # http_status stays null.
    $landedError = $false
    $landedStatus = 0
    if ($r.PSObject.Properties['http_status'] -and $r.http_status) { $landedStatus = [int]$r.http_status }
    if ($landedStatus -ge 400) {
        $landedError = $true
        Warn "Landing page returned HTTP $landedStatus - the screenshots below show an ERROR page, not the app."
    } elseif ("$($r.title)" -match '^HTTP Status \d{3}') {
        $landedError = $true
        Warn "Page title is a Tomcat error page - the screenshots below show an ERROR page, not the app."
    }
    if ($landedError -and ($landedStatus -eq 404 -or "$($r.title)" -match '\b404\b')) {
        Warn "A 404 here usually means the URL misses the SPA entry: current 7.0-SNAPSHOT wars serve nothing at the bare context root. Retry without -Url (the default target probes the root and falls back to /main), or point -Url at $(Get-WebUrl $cfg)main."
    }
    if (Test-Path $r.artifacts.login_screenshot) {
        $kb = [math]::Round((Get-Item $r.artifacts.login_screenshot).Length / 1KB, 1)
        if ($landedError) { Warn "Login screenshot (ERROR page) : $($r.artifacts.login_screenshot) ($kb KB)" }
        else { Ok "Login screenshot      : $($r.artifacts.login_screenshot) ($kb KB)" }
    }
    if (Test-Path $r.artifacts.app_screenshot) {
        $kb = [math]::Round((Get-Item $r.artifacts.app_screenshot).Length / 1KB, 1)
        $tag = if ($landedError) { "ERROR page" } elseif ($r.logged_in) { "authenticated UI" } else { "post-submit state" }
        if ($landedError) { Warn "App screenshot ($tag) : $($r.artifacts.app_screenshot) ($kb KB)" }
        else { Ok "App screenshot ($tag) : $($r.artifacts.app_screenshot) ($kb KB)" }
    }
    if ($r.open -and $r.open.requested) {
        if (Test-Path $r.artifacts.open_screenshot) {
            $kb = [math]::Round((Get-Item $r.artifacts.open_screenshot).Length / 1KB, 1)
            Ok "Open screenshot       : $($r.artifacts.open_screenshot) ($kb KB)"
        }
        if ($r.open.error) {
            Bad "Direct form open failed: $($r.open.error)"
        } else {
            $tag = if ($r.open.reloaded) { " (after one /push-notification reload)" } else { "" }
            Ok "Open script executed - landed on $($r.open.landed_url)$tag"
            if ($r.open.expect) {
                if ($r.open.expect_found) {
                    if ("$($r.open.expect_where)" -eq 'input-value') {
                        Ok "Expected text '$($r.open.expect)' found - as the VALUE of a visible input (a form field shows it; it is not a text node)."
                    } else {
                        Ok "Expected text '$($r.open.expect)' is visible on the opened form."
                    }
                }
                else { Warn "Expected text '$($r.open.expect)' NOT found - neither as visible text nor as any visible input's value. Check verify-open.png (caption may differ / form may be empty)." }
            }
        }
    }
    if ($r.click -and $r.click.requested) {
        if (Test-Path $r.artifacts.click_screenshot) {
            $kb = [math]::Round((Get-Item $r.artifacts.click_screenshot).Length / 1KB, 1)
            Ok "Click screenshot      : $($r.artifacts.click_screenshot) ($kb KB)"
        }
        if ($r.click.error) {
            # First line only: the rest of the Playwright message is the
            # actionability call log, which the classification below already
            # summarizes (the full text stays in the JSON on stdout).
            Warn "Click-through failed after [$($r.click.clicked -join ' > ')]: $(@($r.click.error -split "`r?`n")[0])"
            $seg = if ($r.click.failed_segment) { $r.click.failed_segment } else { $Click }
            switch ("$($r.click.reason)") {
                'not_found' {
                    Warn "No element with visible text '$seg' - the caption is simply different (captions are locale/data-dependent)."
                }
                'intercepted' {
                    Warn "Element '$seg' WAS found and visible, but another element intercepted every click: $($r.click.blocked_by)"
                    Warn "That is a loading overlay / sliding panel / hover popup on top - even a forced click did not land. Check verify-click.png for what was covering it; retry, or reach the target with -Do 'click:<css selector>'."
                }
                'not_visible' {
                    Warn "Element '$seg' exists in the DOM but its text is not visible (icon-only navigator entry or a collapsed panel) - text-based -Click cannot hit it. Click it via -Do 'click:<css selector>' (e.g. by lsfusion-container attribute from verify-dom.html)."
                }
                default {
                    # Unclassified actionability failure - the truncated first
                    # line is not enough here, so show Playwright's full log.
                    Warn "The element was found but never became clickable. Full Playwright log:"
                    @($r.click.error -split "`r?`n") | ForEach-Object { Write-Host "    $_" }
                }
            }
            if ($r.click.available) {
                if ($r.click.available.visible.Count) {
                    Info "Clickable navigator captions on this page: $($r.click.available.visible -join ' | ')"
                }
                if ($r.click.available.icon_only.Count) {
                    Info "Icon-only entries (text hidden - NOT clickable by text): $($r.click.available.icon_only -join ' | ')"
                }
                Info "(Full failure-time DOM: verify-dom.html)"
            }
        } elseif ($r.click.clicked.Count) {
            Ok "Clicked through: $($r.click.clicked -join ' > ')"
        }
        if ($r.click.forced.Count) {
            Warn "Segment(s) [$($r.click.forced -join ', ')] needed a FORCED click (an overlay was intercepting; hit-target check bypassed) - trust verify-click.png over this report for what actually opened."
        }
    }
    if ($r.double_click -and $r.double_click.requested) {
        if (Test-Path $r.artifacts.dblclick_screenshot) {
            $kb = [math]::Round((Get-Item $r.artifacts.dblclick_screenshot).Length / 1KB, 1)
            Ok "Double-click screenshot : $($r.artifacts.dblclick_screenshot) ($kb KB)"
        }
        if ($r.double_click.error) {
            Warn "Double-click failed: $(@($r.double_click.error -split "`r?`n")[0])"
            switch ("$($r.double_click.reason)") {
                'not_found'   { Warn "No cell with visible text '$DoubleClick' - row text is locale/data-dependent; check verify-dblclick.png for the actual grid text." }
                'intercepted' { Warn "Row found, but clicks were intercepted by: $($r.double_click.blocked_by) - likely a loading overlay; check verify-dblclick.png and retry." }
                'not_visible' { Warn "The matched text exists but is not visible (hidden column / virtualized row?) - check verify-dblclick.png; scroll or filter first via -Do." }
                default       { Warn "Row found but never became clickable - check verify-dblclick.png." }
            }
        } elseif ($r.double_click.target) {
            Ok "Double-clicked row '$($r.double_click.target)' - edit card in verify-dblclick.png"
        }
        if ($r.double_click.forced) {
            Warn "The double-click needed FORCE (an overlay was intercepting; hit-target check bypassed) - trust verify-dblclick.png for what actually opened."
        }
    }
    if ($r.do -and $r.do.requested) {
        foreach ($s in $r.do.steps) {
            if ($s.ok) { Ok "do: $($s.action)$(if ($s.detail) { "  ->  $($s.detail)" })" }
            else { Warn "do FAILED: $($s.action) - $($s.detail)" }
        }
        if ($r.do.error) { Warn "-Do chain stopped at the first failure; remaining steps were skipped." }
        if (Test-Path $r.artifacts.do_screenshot) {
            $kb = [math]::Round((Get-Item $r.artifacts.do_screenshot).Length / 1KB, 1)
            Ok "Do screenshot         : $($r.artifacts.do_screenshot) ($kb KB)"
        }
    }
    Info "Open the PNGs with the Read tool to see what was rendered."

    if ($r.login_attempted) {
        if ($r.logged_in) { Ok "Login flow succeeded - the authenticated screenshot shows the app." }
        else { Warn "Login was attempted but the password field is still visible - check credentials and the login screenshot." }
    } elseif ($landedError) {
        # No login form because there is no app on this page at all - the
        # devmode-auto-auth reading would be flatly wrong here.
        Warn "No login form - the landing is an error page (see the WARN above), so nothing app-related was verified."
    } else {
        Ok "No login form on the landing page - devmode auto-authenticated as '$($cfg.adminUser)', the screenshot shows the running app."
    }

    if ($r.console_errors -gt 0) {
        Warn "Browser console reported $($r.console_errors) error(s) - see $($r.artifacts.console)."
    }
    if ($r.error) { Bad "Playwright reported: $($r.error)" }
}

# Basic-auth headers for the /eval* endpoints. The header is attached ONLY
# when a non-empty password is configured: devmode lets a no-header request
# through as the anonymous user on every platform build, while Basic auth
# with an empty password was observed rejected by at least one snapshot-era
# build (see the fuller rationale in Cmd-Api).
function Get-EvalAuthHeaders($cfg) {
    $apiUser = if ($ScriptBound.ContainsKey("AdminUser"))     { $AdminUser }     else { $cfg.adminUser }
    $apiPass = if ($ScriptBound.ContainsKey("AdminPassword")) { $AdminPassword } else { $cfg.adminPassword }
    $headers = @{}
    if ($apiPass) {
        $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($apiUser):$($apiPass)"))
        $headers["Authorization"] = "Basic $auth"
    }
    return $headers
}

# The error-response body of a failed Invoke-WebRequest - for a 500 it carries
# the server's actual parse/name/type error, which is the whole diagnosis.
# PS 5.1: the cmdlet usually stashes the body in ErrorDetails; the raw stream
# is a fallback (rewound first - the cmdlet may have read it already).
function Get-ErrorResponseBody($err) {
    if ($err.ErrorDetails -and $err.ErrorDetails.Message) { return $err.ErrorDetails.Message }
    $errResp = $err.Exception.Response
    if ($errResp) {
        try {
            $stream = $errResp.GetResponseStream()
            if ($stream -and $stream.CanSeek) { $stream.Position = 0 }
            if ($stream) {
                $sr = New-Object IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                return $sr.ReadToEnd()
            }
        } catch { }
    }
    return $null
}

# One lexical pass over .lsf text producing a same-length "shadow": selected
# token classes become spaces, line breaks are kept, so LINE:COL positions
# always match the original. Token classes follow the platform lexer
# (LsfLogics.g), because naive quote-scanning misparses real literals:
#   - comments: // to EOL, /* */ (a '/*' inside a line comment or a string
#     must not open a phantom block);
#   - strings: '...' with backslash escapes AND ${ ... } interpolation blocks
#     (brace-nested, backslash escapes, bare quotes are LEGAL inside - a
#     quote-scanner would cut '${f('x')}' short);
#   - raw strings: r'...' / R'...' has NO escapes (r'C:\' is a complete
#     literal - treating \ as an escape swallows the closing quote and
#     derails everything after), and the delimited form r<S>'...'<S> (S = a
#     special char) whose content may hold quotes and newlines. r/R counts
#     as a raw prefix only when it STARTS the token: the char before it in
#     the ORIGINAL text must not be [A-Za-z0-9_#] (else foor'x' / ##r'x'
#     would misparse).
function Get-LsfMaskedText([string]$text, [bool]$blankComments, [bool]$blankStrings) {
    $chars = $text.ToCharArray()
    $n = $chars.Length
    $i = 0
    while ($i -lt $n) {
        $c = $chars[$i]
        # --- comments -------------------------------------------------------
        if ($c -eq '/' -and ($i + 1) -lt $n -and $chars[$i + 1] -eq '/') {
            while ($i -lt $n -and $chars[$i] -ne "`n" -and $chars[$i] -ne "`r") {
                if ($blankComments) { $chars[$i] = ' ' }
                $i++
            }
            continue
        }
        if ($c -eq '/' -and ($i + 1) -lt $n -and $chars[$i + 1] -eq '*') {
            if ($blankComments) { $chars[$i] = ' '; $chars[$i + 1] = ' ' }
            $i += 2
            while ($i -lt $n) {
                if ($chars[$i] -eq '*' -and ($i + 1) -lt $n -and $chars[$i + 1] -eq '/') {
                    if ($blankComments) { $chars[$i] = ' '; $chars[$i + 1] = ' ' }
                    $i += 2
                    break
                }
                if ($blankComments -and $chars[$i] -ne "`r" -and $chars[$i] -ne "`n") { $chars[$i] = ' ' }
                $i++
            }
            continue
        }
        # --- inline Java code literals <{ ... }> ----------------------------
        # CODE_LITERAL is a single token ending at the FIRST '}>' (ANTLR's
        # nongreedy .*). Its content is Java and is blanked in EVERY mode,
        # not just $blankStrings: shadow consumers regex the COMMENT shadow
        # too (run()-declaration safety skip, the declaredHere name harvest),
        # and visible Java would feed them phantoms - a 'run() {}' inside a
        # Java comment would false-trigger the skip, a 'ghost() = ...' line
        # would fake a cross-file declaration and downgrade a real name
        # error to inconclusive. Positions still match (spaces).
        if ($c -eq '<' -and ($i + 1) -lt $n -and $chars[$i + 1] -eq '{') {
            $chars[$i] = ' '; $chars[$i + 1] = ' '
            $i += 2
            while ($i -lt $n) {
                if ($chars[$i] -eq '}' -and ($i + 1) -lt $n -and $chars[$i + 1] -eq '>') {
                    $chars[$i] = ' '; $chars[$i + 1] = ' '
                    $i += 2
                    break
                }
                if ($chars[$i] -ne "`r" -and $chars[$i] -ne "`n") { $chars[$i] = ' ' }
                $i++
            }
            continue
        }
        # --- raw strings ----------------------------------------------------
        if (($c -eq 'r' -or $c -eq 'R') -and (($i -eq 0) -or ("$($text[$i - 1])" -cnotmatch '[A-Za-z0-9_#]'))) {
            # simple form: r'...' - ends at the FIRST quote, no escapes
            if (($i + 1) -lt $n -and $chars[$i + 1] -eq "'") {
                if ($blankStrings) { $chars[$i] = ' '; $chars[$i + 1] = ' ' }
                $i += 2
                while ($i -lt $n -and $chars[$i] -ne "'") {
                    if ($blankStrings -and $chars[$i] -ne "`r" -and $chars[$i] -ne "`n") { $chars[$i] = ' ' }
                    $i++
                }
                if ($i -lt $n) { if ($blankStrings) { $chars[$i] = ' ' }; $i++ }
                continue
            }
            # delimited form: r<S>'...'<S>, S = RAW_STR_SPECIAL_CHAR (not a
            # letter/digit/_/space/newline/quote and not one of +*,=<>()[]{}#)
            if (($i + 2) -lt $n -and $chars[$i + 2] -eq "'") {
                $s = $chars[$i + 1]
                $specialOk = (-not [char]::IsLetterOrDigit($s)) -and ($s -ne '_') -and
                             ($s -ne ' ') -and ($s -ne "`t") -and ($s -ne "`n") -and ($s -ne "`r") -and
                             ($s -ne "'") -and ('+*,=<>()[]{}#'.IndexOf($s) -lt 0)
                if ($specialOk) {
                    if ($blankStrings) { $chars[$i] = ' '; $chars[$i + 1] = ' '; $chars[$i + 2] = ' ' }
                    $i += 3
                    while ($i -lt $n) {
                        if ($chars[$i] -eq "'" -and ($i + 1) -lt $n -and $chars[$i + 1] -eq $s) {
                            if ($blankStrings) { $chars[$i] = ' '; $chars[$i + 1] = ' ' }
                            $i += 2
                            break
                        }
                        if ($blankStrings -and $chars[$i] -ne "`r" -and $chars[$i] -ne "`n") { $chars[$i] = ' ' }
                        $i++
                    }
                    continue
                }
            }
        }
        # --- ordinary strings (escapes + ${...} interpolation) --------------
        if ($c -eq "'") {
            if ($blankStrings) { $chars[$i] = ' ' }
            $i++
            while ($i -lt $n) {
                $sc = $chars[$i]
                if ($sc -eq '\') {
                    if ($blankStrings) { $chars[$i] = ' ' }
                    $i++
                    if ($i -lt $n) {
                        if ($blankStrings -and $chars[$i] -ne "`r" -and $chars[$i] -ne "`n") { $chars[$i] = ' ' }
                        $i++
                    }
                    continue
                }
                if ($sc -eq '$' -and ($i + 1) -lt $n -and $chars[$i + 1] -eq '{') {
                    if ($blankStrings) { $chars[$i] = ' '; $chars[$i + 1] = ' ' }
                    $i += 2
                    $depth = 1
                    while ($i -lt $n -and $depth -gt 0) {
                        $bc = $chars[$i]
                        if ($bc -eq '\') {
                            if ($blankStrings) { $chars[$i] = ' ' }
                            $i++
                            if ($i -lt $n) {
                                if ($blankStrings -and $chars[$i] -ne "`r" -and $chars[$i] -ne "`n") { $chars[$i] = ' ' }
                                $i++
                            }
                            continue
                        }
                        if ($bc -eq '{') { $depth++ } elseif ($bc -eq '}') { $depth-- }
                        if ($blankStrings -and $bc -ne "`r" -and $bc -ne "`n") { $chars[$i] = ' ' }
                        $i++
                    }
                    continue
                }
                if ($sc -eq "'") {
                    if ($blankStrings) { $chars[$i] = ' ' }
                    $i++
                    break
                }
                if ($blankStrings -and $sc -ne "`r" -and $sc -ne "`n") { $chars[$i] = ' ' }
                $i++
            }
            continue
        }
        $i++
    }
    return -join $chars
}

# Comment-blanked shadow: comments become spaces; string literals stay put
# (eval error positions must match the file). CODE_LITERAL <{...}> is the
# one non-comment token also blanked - in every mode, see Get-LsfMaskedText.
function Get-CommentBlankedShadow([string]$text) {
    return Get-LsfMaskedText $text $true $false
}

# Structural shadow: comments AND every string-literal form become spaces.
# Structural scans (bracket balance, META/END counting, statement extents)
# must not see a '(' or an END living inside a caption string. Input may be
# raw text or an already comment-blanked shadow - same result.
function Get-StructuralShadow([string]$shadow) {
    return Get-LsfMaskedText $shadow $true $true
}

# Blank every statement that starts at $startPattern and ends at the first ';'
# sitting at bracket depth 0 relative to the match start. Depth-aware because
# @-instantiation arguments and EXTEND FORM event blocks legitimately carry
# ';' inside (...) / {... }. A statement with no such terminator (unbalanced
# file) is left in place - callers treat leftovers conservatively.
function Remove-DepthStatements([string]$s, [string]$startPattern) {
    $sb = New-Object System.Text.StringBuilder $s
    foreach ($m in [regex]::Matches($s, $startPattern)) {
        $depth = 0
        for ($i = $m.Index; $i -lt $s.Length; $i++) {
            $c = $s[$i]
            if ($c -eq '(' -or $c -eq '{' -or $c -eq '[') { $depth++ }
            elseif ($c -eq ')' -or $c -eq '}' -or $c -eq ']') { $depth-- }
            elseif ($c -eq ';' -and $depth -le 0) {
                for ($j = $m.Index; $j -le $i; $j++) {
                    if ($sb[$j] -ne "`r" -and $sb[$j] -ne "`n") { $sb[$j] = ' ' }
                }
                break
            }
        }
    }
    return $sb.ToString()
}

# How much of a file can /eval actually check. Works on the STRUCTURAL shadow.
# Blanks module headers, META...END definition blocks, @-instantiation
# statements and EXTEND FORM statements; whatever remains is the surface eval
# genuinely compiles. Residual=$false + any construct flag => a "restart-only"
# file (the main-file shape that used to burn a cycle: all META + EXTEND FORM,
# where precheck could catch neither ambiguity nor a constraint error).
# Deliberately conservative: nested METAs / inline @usages / DESIGN leave
# residue, and the file then just takes the normal eval path.
function Get-EvalCoverage([string]$structShadow) {
    $s = $structShadow
    # Token-level, NOT line-anchored: lsFusion newlines are ordinary token
    # separators, so 'p() = 1; END' with END mid-line is a perfectly legal
    # META closer - a line-start-only count would flag a false unclosed-META
    # FAIL on it. [regex] static calls are case-sensitive, matching the
    # case-sensitive keywords. Trade-off: END is also a DESIGN alignment
    # literal (alignment = END), which can only INFLATE MetaEnd - that can
    # mask an unclosed META (missed detection) but never produce a false
    # unclosed-META FAIL; the surplus direction is reported as a mere Warn,
    # and only for files that declare META at all.
    $metaOpen  = [regex]::Matches($s, '\bMETA\b').Count
    $metaEnd   = [regex]::Matches($s, '\bEND\b').Count
    $hasExtend = [regex]::IsMatch($s, '\bEXTEND\s+FORM\b')
    $hasUsage  = [regex]::IsMatch($s, '@[A-Za-z_]')
    # Headers out first (structural variant: every occurrence, no
    # well-formedness gate - this is coverage math, not eval input).
    $s = [regex]::Replace($s, '\b(MODULE|REQUIRE|NAMESPACE|PRIORITY)\b[^;]*;', ' ')
    # META bodies: lazy to the first END token (flat definitions; nested ones
    # or an alignment END inside the body leave residue - conservative).
    $s = [regex]::Replace($s, '(?s)\bMETA\b.*?\bEND\b[ \t]*;?', ' ')
    $s = Remove-DepthStatements $s '@[A-Za-z_]'
    $s = Remove-DepthStatements $s '\bEXTEND\s+FORM\b'
    return @{
        MetaOpen  = $metaOpen
        MetaEnd   = $metaEnd
        HasMeta   = ($metaOpen -gt 0)
        HasUsage  = $hasUsage
        HasExtend = $hasExtend
        Residual  = ($s -match '\S')
    }
}

# Blank out top-level module-header statements (MODULE / REQUIRE / NAMESPACE /
# PRIORITY): eval compiles the text as a throwaway module that already depends
# on every loaded module, so headers are both forbidden ("missing EOF at
# 'MODULE'") and unnecessary. Every replaced character becomes a space, so the
# LINE:COL positions in eval's errors still match the original file. Header
# extents are located on the comment-blanked shadow, so a ';' inside a
# comment cannot cut a REQUIRE list short and leave residue behind.
function Strip-ModuleHeader([string]$text) {
    $shadow = Get-CommentBlankedShadow $text
    $chars = $text.ToCharArray()
    $blanked = @{}
    foreach ($m in [regex]::Matches($shadow, '(?m)^[ \t]*(MODULE|REQUIRE|NAMESPACE|PRIORITY)\b[^;]*;')) {
        # Blank only a WELL-FORMED header, and only the FIRST of each kind. A
        # malformed one (say, a REQUIRE missing its ';') makes [^;]*; swallow
        # the next declaration too, and a duplicate header is itself illegal -
        # blanking either would false-PASS a file the restart rejects. Left in
        # place they fail the eval parse loudly (the precheck FAIL branch
        # explains that hint). Full ORDER validation is deliberately not
        # attempted: a mis-remembered ordering rule here would produce false
        # FAILs, which cost more trust than the rare uncaught misorder.
        $kw = $m.Groups[1].Value
        if ($blanked.ContainsKey($kw)) { continue }
        $ident = '[A-Za-z_][A-Za-z0-9_]*'
        $bodyPattern = if ($kw -eq 'REQUIRE' -or $kw -eq 'PRIORITY') { "$ident(\s*,\s*$ident)*" } else { $ident }
        if ($m.Value -notmatch "^\s*$kw\s+$bodyPattern\s*;\s*$") { continue }
        $blanked[$kw] = $true
        for ($i = $m.Index; $i -lt $m.Index + $m.Length; $i++) {
            if ($chars[$i] -ne [char]"`r" -and $chars[$i] -ne [char]"`n") { $chars[$i] = [char]' ' }
        }
    }
    return -join $chars
}

# Uri.EscapeDataString on .NET Framework (PS 5.1) throws on inputs longer
# than ~65,519 characters - escape big scripts in slices. Escaping is
# per-character, so any split point is safe except the middle of a surrogate
# pair, which the slicer steps over.
function ConvertTo-EscapedData([string]$s) {
    $chunk = 60000
    if ($s.Length -le $chunk) { return [uri]::EscapeDataString($s) }
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $s.Length) {
        $len = [Math]::Min($chunk, $s.Length - $i)
        if (($i + $len) -lt $s.Length -and [char]::IsHighSurrogate($s[$i + $len - 1])) { $len++ }
        $null = $sb.Append([uri]::EscapeDataString($s.Substring($i, $len)))
        $i += $len
    }
    return $sb.ToString()
}

function Cmd-Precheck {
    Head "Pre-check .lsf via eval (syntax + names, no restart)"
    $cfg = Get-ConfigOrFail

    # Resolve the file set: explicit -Files (absolute or project-relative),
    # else every .lsf under the same roots start-server puts on the classpath.
    $targets = @()
    if ($Files.Count) {
        # powershell.exe -File hands "-Files 'a','b'" over as ONE literal
        # string - split elements on commas so both invocation styles work
        # (an .lsf path with a comma in it is not a case worth supporting).
        foreach ($f in @($Files | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
            $p = if ([IO.Path]::IsPathRooted($f)) { $f } else { Join-Path $ProjectDir $f }
            if (-not (Test-Path $p)) { throw "File not found: $p" }
            $targets += (Resolve-Path $p).Path
        }
    } else {
        $srcRoots = @(@("src\main\lsfusion", "src\main\resources") |
            ForEach-Object { Join-Path $ProjectDir $_ } | Where-Object { Test-Path $_ })
        if ($srcRoots.Count) {
            $targets = @($srcRoots | ForEach-Object {
                    Get-ChildItem $_ -Recurse -Filter *.lsf -ErrorAction SilentlyContinue
                } | ForEach-Object { $_.FullName })
        } else {
            $targets = @(Get-ChildItem $ProjectDir -File -Filter *.lsf -ErrorAction SilentlyContinue |
                ForEach-Object { $_.FullName })
        }
    }
    if (-not $targets.Count) { throw "No .lsf files to check. Pass them explicitly: precheck -Files 'src\main\lsfusion\MyModule.lsf'" }

    # The check IS a compile on the running server - without one there is
    # nothing to ask. (This also means names resolve against what that server
    # has LOADED: a REQUIRE added in this same edit session is fine - eval
    # depends on every loaded module - but a brand-new module's names exist
    # only after its first successful restart.)
    if (-not (Test-PortOpen $cfg.httpPort)) {
        throw "Nothing is listening on the Action API port $($cfg.httpPort). precheck compiles against the RUNNING dev server - start it first: lsfdev.ps1 start-server"
    }
    # An open port only proves SOMETHING listens. If it is not this project's
    # tracked server (parallel-session port drift, a manually started
    # instance), name checks reflect whatever schema THAT server loaded -
    # worth a warning, not a refusal (a manually started server is a
    # legitimate target, exactly as it is for 'api').
    $ownerOk = $false
    if (Test-Path $ServerPid) {
        $sPid = 0
        if ([int]::TryParse((Get-Content $ServerPid -Raw -Encoding UTF8).Trim(), [ref]$sPid) -and (Process-Alive $sPid)) {
            $ownCmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$sPid" -ErrorAction SilentlyContinue).CommandLine
            if ($ownCmd -and $ownCmd.IndexOf("-Dlsfdev.project=$ProjectDir", [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                # The marked PID must also actually OWN the port - an alive
                # tracked server plus a foreign listener is still foreign.
                $ownerOk = ($sPid -in @(Get-PortPids $cfg.httpPort))
            }
        }
    }
    if (-not $ownerOk) {
        Warn "The listener on port $($cfg.httpPort) is not this project's tracked dev server (started by hand, or another session?) - name results reflect THAT server's loaded schema."
    }

    $headers = Get-EvalAuthHeaders $cfg
    Info "POST http://localhost:$($cfg.httpPort)/eval (statements mode), $($targets.Count) file(s)."
    Info "Verifies syntax everywhere and names where eval reaches them (~30 ms/file); loading the schema still requires a restart."
    Write-Host ""
    # Top-level names declared anywhere in THIS selection (column-0
    # declarations and CLASSes, harvested off the comment-blanked shadow).
    # eval checks files one at a time, so file B legitimately cannot see file
    # A's new declaration - a not-found on such a name is a cross-file
    # reference, reported as inconclusive rather than FAIL.
    # Ordinal dictionary, NOT a PS hashtable: hashtable keys are
    # case-insensitive, and lsFusion identifiers are not - CLASS 'NewProp'
    # must not swallow a genuine error on 'newProp'.
    # Ownership maps each identifier to the SET of full paths declaring it -
    # overloads legitimately live in several files, and a single-owner map
    # would let the last writer shadow the others (a same-name declaration in
    # the current file must not hide a cross-file overload). Full paths, not
    # leaves: two selected files can share a basename; the leaf is display-only.
    $declaredHere = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]' ([System.StringComparer]::Ordinal)
    foreach ($t in $targets) {
        try {
            $sh = Get-CommentBlankedShadow ([IO.File]::ReadAllText($t))
            # Column-0 property/action declarations, plus keyworded top-level
            # declarations whose names travel cross-file: classes, forms,
            # groups, windows, tables, metacodes.
            $declMatches = @([regex]::Matches($sh, "(?m)^([a-z][A-Za-z0-9_]*)\s*(?:'(?:[^'\\]|\\.)*'\s*)?(?:\(|=)")) +
                           @([regex]::Matches($sh, '(?m)^(?:CLASS|FORM|GROUP|WINDOW|TABLE|META)\s+([A-Za-z_][A-Za-z0-9_]*)'))
            foreach ($dm in $declMatches) {
                $nm = $dm.Groups[1].Value
                if (-not $declaredHere.ContainsKey($nm)) {
                    $declaredHere[$nm] = New-Object 'System.Collections.Generic.List[string]'
                }
                if (-not $declaredHere[$nm].Contains($t)) { $declaredHere[$nm].Add($t) }
            }
        } catch { }
    }
    $failCount = 0
    $skipCount = 0
    foreach ($t in $targets) {
        $leaf = Split-Path $t -Leaf
        try {
            $raw = [IO.File]::ReadAllText($t)
            # /eval EXECUTES the script's run() action. Project modules never
            # declare one, but hand-written eval probes do - running their
            # body from a linter could mutate data, so such files are skipped
            # outright rather than linted. Matched against the comment-blanked
            # shadow, so a run() mentioned in a comment doesn't skip the file.
            # The pattern covers every declaration shape - run() {}, run {},
            # run 'Caption' {}, run 'Caption'() {} (all verified to execute
            # via /eval), plus property/override forms (run() = ..., += - a
            # same-name property would only produce a confusing "already
            # defined" against the appended stub) and INTERNAL bodies
            # (run() INTERNAL <{...}>; / INTERNAL 'class' - the body form
            # doesn't matter, /eval runs whatever run() is; skipping is the
            # safe direction even if eval would refuse INTERNAL). A call
            # site (run();) or a longer name (runTotals) does not match.
            $fileShadow = Get-CommentBlankedShadow $raw
            if ($fileShadow -cmatch '(?m)^[ \t]*run(?![A-Za-z0-9_])\s*(?:''(?:[^''\\]|\\.)*''\s*)?(?:\([^)]*\)\s*)?(?:\{|\+?=|INTERNAL\b)') {
                $skipCount++
                Warn "$leaf - skipped: it declares run(), and /eval EXECUTES run() - a linter must not run project actions. Rename the action (or lint the file without it)."
                continue
            }
            # Every .lsf module must open with a MODULE header - the restart
            # loader rejects a file without one, and header-stripping cannot
            # flag what is absent. Checked on the shadow (a leading license
            # comment is already blank there).
            if ($fileShadow -cnotmatch '^\s*MODULE\s+[A-Za-z_][A-Za-z0-9_]*\s*;') {
                $failCount++
                Bad "$leaf - FAIL: no valid leading 'MODULE <Name>;' header - the restart loader requires one (precheck strips headers, it cannot invent a missing one)."
                continue
            }
            # Structural checks + coverage classification, BEFORE eval - they
            # cover exactly what eval cannot see (META bodies compile only at
            # instantiation; EXTEND FORM / '() + {}' crash eval's compiler).
            $structShadow = Get-StructuralShadow $fileShadow
            $cov = Get-EvalCoverage $structShadow
            if ($cov.MetaOpen -gt $cov.MetaEnd) {
                $failCount++
                Bad "$leaf - FAIL: unclosed META ($($cov.MetaOpen) META vs $($cov.MetaEnd) END outside comments/strings) - an unclosed META swallows the rest of the file at restart."
                continue
            }
            if ($cov.MetaOpen -gt 0 -and $cov.MetaEnd -gt $cov.MetaOpen) {
                # Only a Warn, and only for META-declaring files: END is also
                # a DESIGN alignment literal (alignment = END), so a surplus
                # END is often legitimate - a false FAIL here would cost more
                # trust than the rare uncaught stray END.
                Warn "$leaf - $($cov.MetaEnd) END vs $($cov.MetaOpen) META: a genuinely stray END fails the restart parse (ignore if the extra END is a DESIGN alignment value)."
            }
            $balanceNotes = @()
            foreach ($pair in @(@('(', ')'), @('{', '}'), @('[', ']'))) {
                $opens  = [regex]::Matches($structShadow, [regex]::Escape($pair[0])).Count
                $closes = [regex]::Matches($structShadow, [regex]::Escape($pair[1])).Count
                if ($opens -ne $closes) { $balanceNotes += "$opens x '$($pair[0])' vs $closes x '$($pair[1])'" }
            }
            if ($balanceNotes.Count) {
                Warn "$leaf - brackets look unbalanced outside comments/strings ($($balanceNotes -join '; ')) - if the restart fails with a parse error, start here (META fragments can legitimately unbalance, so this alone is not a FAIL)."
            }
            if ((-not $cov.Residual) -and ($cov.HasMeta -or $cov.HasUsage -or $cov.HasExtend)) {
                # The main-file shape that used to burn a precheck cycle: all
                # META definitions / @-instantiations / EXTEND FORM. eval can
                # compile NONE of that, so posting it yields either a hollow
                # PASS or a misleading compiler-crash report - say the truth
                # upfront instead.
                $skipCount++
                Warn "$leaf - restart-only: the file is entirely META definitions / @-instantiations / EXTEND FORM. eval can check NONE of its content - ambiguity and constraint errors included - so only structure was verified (MODULE header, META/END balance, brackets). The restart IS the check for this file: budget the restart cycle, don't re-run precheck for it."
                continue
            }
            # NAMESPACE / PRIORITY steer how ambiguous names resolve; they are
            # stripped for the check, so a clean name pass can still resolve
            # differently at restart - the verdict carries that caveat.
            $nsCaveat = ""
            if ($fileShadow -cmatch '(?m)^[ \t]*(NAMESPACE|PRIORITY)\b') {
                $nsCaveat = " (NAMESPACE/PRIORITY stripped for the check - ambiguous names can resolve differently at restart)"
            }
            $metaCaveat = ""
            if ($cov.HasMeta) {
                $metaCaveat = " (declares META: bodies compile only at @-instantiation - a definition not instantiated in THIS file stays unchecked until restart)"
            }
            $scriptText = (Strip-ModuleHeader $raw) + "`r`nrun() {}"
            # Transport: small scripts ride the %XX query parameter (decodes
            # as UTF-8 on every platform build - same reason as Cmd-Api), but
            # System.Uri and the server's request line cap out around 64 KB,
            # so bigger payloads go as a form body with an explicit UTF-8
            # charset. Decided on the ENCODED length - escaping expands up to
            # 9x (Cyrillic chars become %XX%XX). (6.x-era builds decoded the
            # body in the platform charset, but they cannot take a >64 KB URI
            # either - there is no better channel for a big file on them.)
            $enc = ConvertTo-EscapedData $scriptText
            $uri = "http://localhost:$($cfg.httpPort)/eval"
            if ($enc.Length -le 60000) {
                $null = Invoke-WebRequest -Uri "$uri`?script=$enc" `
                    -Method Post -Headers $headers -UseBasicParsing -TimeoutSec 30
            } else {
                $null = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers `
                    -ContentType "application/x-www-form-urlencoded; charset=UTF-8" `
                    -Body ([Text.Encoding]::UTF8.GetBytes("script=$enc")) -UseBasicParsing -TimeoutSec 60
            }
            Ok "$leaf - PASS (eval compiled and loaded it clean)$nsCaveat$metaCaveat"
        } catch {
            $body = Get-ErrorResponseBody $_
            if (-not $body) {
                # No HTTP error body: an IO problem, a connection drop, or a
                # non-HTTP failure - report it per file and keep going.
                $failCount++
                Bad "$leaf - precheck error: $($_.Exception.Message)"
                continue
            }
            # Compiler verdicts live in HTTP 500 bodies only. Anything else
            # (401 auth, 404 no Eval module / wrong path, 413 ...) is an
            # endpoint problem, not a statement about the file.
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch { }
            if ($status -ne 0 -and $status -ne 500) {
                $failCount++
                Bad "$leaf - HTTP $status from the endpoint (auth / wrong path / a build without the Eval module?) - not a verdict on the file: $(@($body -split "`r?`n" | Where-Object { $_.Trim() })[0])"
                continue
            }
            # Some real-module constructs crash eval's compiler outright with
            # an internal 500 + Java stack instead of the polite restriction
            # error - measured on 7.0-SNAPSHOT with EXTEND FORM ("NF
            # COLLECTION RESTARTED") and '() + {' action overrides
            # (ClassCastException). Says nothing about the file's validity.
            if ($body -match 'RemoteInternalException|Internal Server Error:\s*java\.') {
                $skipCount++
                $first = "$(@($body -split "`r?`n" | Where-Object { $_.Trim() })[0])".Trim()
                if ($first.Length -gt 160) { $first = $first.Substring(0, 160) + " ..." }
                Warn "$leaf - cannot lint: eval's compiler crashed on a construct it does not support (typically EXTEND FORM or a '() + { }' override of an existing action). Only a restart checks this file."
                Info "    ($first)"
                continue
            }
            # Strip the "[error]:" preambles and the "Subsequent errors" note;
            # rebrand eval's throwaway module name (UNIQUEnNSNAME) to the file
            # so positions read naturally. Line:col match the original file -
            # Strip-ModuleHeader blanks headers in place instead of removing.
            $meat = @($body -split "`r?`n" | Where-Object { $_.Trim() } |
                Where-Object { $_ -notmatch '^\s*\[error\]:\s*$' -and $_ -notmatch '^Subsequent errors' } |
                ForEach-Object { ($_ -replace 'UNIQUE\d+NSNAME', ($leaf -replace '\.lsf$', '')).Trim() })
            $evalOnly = @($meat | Where-Object { $_ -match 'cannot be used in EVAL module' })
            if ($meat.Count -and ($evalOnly.Count -eq $meat.Count)) {
                # Load-only construct (CLASS, persistent DATA options, WHEN,
                # CONSTRAINT...). The restriction fires BEFORE name resolution
                # (measured: a name error on line 1 goes unreported when a
                # CLASS sits on line 2), so this outcome proves the syntax of
                # the whole file and nothing about its names.
                $where = if ($evalOnly[0] -match ':(\d+):\d+') { " at line $($Matches[1])" } else { "" }
                Ok "$leaf - syntax OK (whole file). Names NOT checked: a load-only construct$where stops eval before name resolution - names in this file surface only on restart.$metaCaveat"
            } else {
                # A not-found on a name that another file of THIS selection
                # declares is a cross-file reference eval cannot see, not a
                # real error - inconclusive, the restart is the actual check.
                $crossRefs = @()
                foreach ($line in $meat) {
                    # Any not-found kind counts: the server words them as
                    # "property or action 'x[...]' is not found", "class 'X'
                    # is not found", etc. - capture the bare identifier.
                    if ($line -cmatch "'([A-Za-z_][A-Za-z0-9_]*)[^']*' is not found") {
                        $nm = $Matches[1]
                        if ($declaredHere.ContainsKey($nm)) {
                            $others = @($declaredHere[$nm] | Where-Object { $_ -ne $t })
                            if ($others.Count) {
                                $names = @($others | ForEach-Object { Split-Path $_ -Leaf } | Select-Object -Unique)
                                $crossRefs += "$nm (declared in $($names -join ', '))"
                            }
                        }
                    }
                }
                if ($crossRefs.Count) {
                    $skipCount++
                    Warn "$leaf - inconclusive: uses $($crossRefs -join ', ') - eval checks files one at a time, so a name declared in another file of this same selection cannot resolve here. Cross-file references are checked by the restart."
                } else {
                    $failCount++
                    Bad "$leaf - FAIL:"
                    $meat | ForEach-Object { Write-Host "    $_" }
                    if (@($meat | Where-Object { $_ -cmatch "'(MODULE|REQUIRE|NAMESPACE|PRIORITY)'" }).Count) {
                        Info "    (a malformed or duplicated MODULE/REQUIRE/NAMESPACE/PRIORITY header was deliberately left in the text - headers are stripped only when well-formed and unique; fix the header itself, e.g. its terminating ';')"
                    }
                }
            }
        }
    }
    Write-Host ""
    if ($failCount) {
        Bad "$failCount of $($targets.Count) file(s) failed the pre-check."
        Info "Name errors surface ONE per call (parse errors come all at once) - fix, re-run precheck until clean, THEN restart."
        exit 1
    } elseif ($skipCount) {
        Warn "$skipCount of $($targets.Count) file(s) skipped (reasons above), the rest pass - the restart is the only check for the skipped ones."
    } else {
        Ok "All $($targets.Count) file(s) pass. This proves syntax (+ names where eval reached them) - the schema itself still loads on restart."
    }
}

function Cmd-Api {
    Head "Action API call"
    $cfg = Get-ConfigOrFail

    # Resolve the script text. -ScriptFile is the robust channel for any script
    # containing non-ASCII characters (Cyrillic, etc.): it is read straight from
    # disk as UTF-8, so the text never crosses the bash -> PowerShell argv
    # boundary where the Windows ANSI code page would mangle it into '?'.
    if ($ScriptFile) {
        if (-not (Test-Path $ScriptFile)) { throw "ScriptFile not found: $ScriptFile" }
        $scriptText = Get-Content -Raw -Encoding UTF8 $ScriptFile
    } elseif ($Script) {
        $scriptText = $Script
    } else {
        throw "Provide lsFusion action code via -Script `"<code>`" or -ScriptFile `"<path>`" (uses the EVAL ACTION endpoint). For any non-ASCII text prefer -ScriptFile, which is read as UTF-8 from disk."
    }

    # Authentication. The local dev server is ALWAYS launched in devmode (see
    # Cmd-StartServer), and devmode lets a request with NO Authorization header
    # through as the anonymous user. With an Authorization header present the
    # server runs a real credential check instead: current builds (verified on
    # 6.2 and 7.0-SNAPSHOT, 2026-06) accept Basic auth for 'admin' with an
    # EMPTY password too, but at least one snapshot-era build was observed
    # rejecting it with HTTP 401 - the no-header form has no such history, so
    # we attach the header ONLY when a non-empty password is actually
    # configured (admin password rotated, or a real account set up).
    # An explicitly-passed -AdminUser/-AdminPassword on the 'api' call
    # overrides whatever setup stored in config.json.
    $headers = Get-EvalAuthHeaders $cfg
    if ($headers.Count) {
        Info "Authenticating with Basic auth (password configured)."
    } else {
        Info "Calling anonymously (devmode auto-auth) - no admin password set, so no Basic header is sent (the form that works on every platform build)."
    }
    # The script travels as a percent-encoded query parameter (NOT a POST form
    # body): EscapeDataString emits the UTF-8 bytes as %XX, which the server
    # decodes as UTF-8 reliably on every platform version. (Current
    # 7.0-SNAPSHOT decodes a POST form body as UTF-8 too, but 6.x-era builds
    # used the platform default charset there and corrupted non-ASCII to '?' -
    # the query parameter is the channel that behaves the same everywhere.)
    # Exception: System.Uri and the server's request line cap out around
    # 64 KB, so an oversized ENCODED script falls back to a UTF-8 form body -
    # on a 6.x-era build a giant non-ASCII script may then land mangled, but
    # the query channel would not carry it at all.
    $enc = ConvertTo-EscapedData $scriptText
    $useBody = ($enc.Length -gt 60000)
    $uri = if ($useBody) { "http://localhost:$($cfg.httpPort)/eval/action" }
           else { "http://localhost:$($cfg.httpPort)/eval/action?script=$enc" }
    # Do NOT echo the encoded URI: EscapeDataString turns every non-ASCII char
    # into %XX%XX (a Cyrillic seed script inflates ~9x into kilobytes of %D0..
    # noise in the transcript). Print the endpoint, the source, and a short
    # plain-text preview instead.
    $src = if ($ScriptFile) { "file $ScriptFile" } else { "inline -Script" }
    Info "POST http://localhost:$($cfg.httpPort)/eval/action ($src, $($scriptText.Length) chars)"
    $preview = ($scriptText -replace '\s+', ' ').Trim()
    if ($preview.Length -gt 200) { $preview = $preview.Substring(0, 200) + " ..." }
    Info "Script : $preview"

    # Snapshot the server log length so MESSAGE output can be surfaced after
    # the call. Over HTTP a plain MESSAGE is swallowed entirely (empty 200, no
    # log line), but MESSAGE ... NOWAIT IS written to the server log as
    # "Server message: ..." - reading the log delta makes that visible here
    # instead of forcing a second round-trip through 'lsfdev.ps1 log'.
    $logLenBefore = 0
    if (Test-Path $ServerOut) { $logLenBefore = (Get-Item $ServerOut).Length }

    try {
        if ($useBody) {
            $resp = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers `
                -ContentType "application/x-www-form-urlencoded; charset=UTF-8" `
                -Body ([Text.Encoding]::UTF8.GetBytes("script=$enc")) -UseBasicParsing -TimeoutSec 60
        } else {
            $resp = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers `
                -UseBasicParsing -TimeoutSec 30
        }
        Ok "HTTP $($resp.StatusCode)"
        # Decode the response body explicitly as UTF-8 so non-ASCII output
        # (e.g. EXPORT FROM with Cyrillic values) prints correctly.
        $bytes = $resp.RawContentStream.ToArray()
        if ($bytes.Length) { Write-Host ([System.Text.Encoding]::UTF8.GetString($bytes)) }
        else {
            # The self-check recipe differs by platform version: RETURN is 7.0+
            # only (a parse error on 6.x), where EXPORT FROM carries the value.
            $recipe = if ("$($cfg.version)" -match '^6') {
                "APPLY; EXPORT FROM res = (OVERRIDE 'CANCELED: ' + applyMessage(), 'OK');"
            } else {
                "APPLY; IF canceled() THEN RETURN 'CANCELED: ' + (OVERRIDE applyMessage(), 'no message');"
            }
            # The full explanation is identical on every call, and a seeding
            # loop of a dozen api calls used to print all 9 lines a dozen
            # times. Print it once per session - marker file, refreshed on
            # every empty-body call, so "session" = a cluster of api activity
            # with no 6-hour gap - then compress to the actionable core.
            $hintMarker = Join-Path $StateDir "api-empty-hint.stamp"
            $explained = (Test-Path $hintMarker) -and
                (((Get-Date) - (Get-Item $hintMarker).LastWriteTime).TotalHours -lt 6)
            if ($explained) {
                Info "(empty response body - carries no proof, and a plain MESSAGE is invisible over HTTP."
                Info " For mutations, end the script with: $recipe)"
            } else {
                Info "(empty response body - normal for actions without RETURN/EXPORT, but carries no proof either:"
                Info " a plain MESSAGE (no NOWAIT) is visible NOWHERE over HTTP - not here and not in the server"
                Info " log, so the log tail below cannot surface it either; only MESSAGE ... NOWAIT leaves a log"
                Info " line. A constraint-canceled APPLY still answers 200."
                Info " Also: EXPORT must be at the TOP LEVEL - its result is a session-local property, so inside"
                Info " NEWSESSION{} it is discarded with the session and never reaches the HTTP response (RETURN is"
                Info " fine inside NEWSESSION - it propagates up the stack - but an /eval/action script already runs"
                Info " in its own session, so no NEWSESSION wrapper is needed anyway)."
                Info " For mutations, end the script with: $recipe)"
            }
            New-Item -ItemType File -Force -Path $hintMarker | Out-Null
        }
    } catch {
        $errResp = $_.Exception.Response
        $statusTag = ""
        if ($errResp) { try { $statusTag = " (HTTP $([int]$errResp.StatusCode))" } catch { } }
        Bad "API call failed$($statusTag): $($_.Exception.Message)"
        # The 500 body carries the actual parse/type error from the server -
        # the whole diagnosis.
        $errBody = Get-ErrorResponseBody $_
        if ($errBody) { Write-Host $errBody }
        else { Info "(the server sent no error body)" }
    }

    # Surface MESSAGE ... NOWAIT output ("Server message: ..." log lines)
    # produced by this call. Plain MESSAGE never reaches the log - nothing to
    # show for it (see the hint above).
    try {
        Start-Sleep -Milliseconds 300
        if (Test-Path $ServerOut) {
            $fs = [IO.File]::Open($ServerOut, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            try {
                if ($fs.Length -gt $logLenBefore) {
                    $fs.Seek($logLenBefore, [IO.SeekOrigin]::Begin) | Out-Null
                    $srLog = New-Object IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                    $delta = $srLog.ReadToEnd()
                    $msgs = @($delta -split "`r?`n" | Where-Object { $_ -match 'Server message:' })
                    if ($msgs.Count) {
                        # Covers MESSAGE ... NOWAIT *and* the constraint text a
                        # canceled APPLY logs - both arrive as "Server message:".
                        Info "Server messages (from the log):"
                        $msgs | ForEach-Object { Write-Host ("    " + ($_ -replace '^.*Server message:\s*', '')) }
                    }
                }
            } finally { $fs.Close() }
        }
    } catch { }
}

function Cmd-Open {
    $cfg = Get-ConfigOrFail
    $landing = Resolve-LandingUrl $cfg
    $u = $landing.url
    Start-Process $u
    Ok "Opened $u in the default browser."
    if (-not $landing.ok) {
        Warn "Neither $u nor ${u}main answered below HTTP 400 - the web client is down or broken; check 'status'."
    } elseif ($u -ne (Get-WebUrl $cfg)) {
        Info "The bare context root $(Get-WebUrl $cfg) returns 404 on this war (current 7.0-SNAPSHOT behavior) - opened the SPA entry /main instead."
    }
}

function Cmd-Versions {
    Head "lsFusion versions available on download.lsfusion.org"
    $av = Get-AvailableVersions
    if ($av.error) { Bad "Could not reach the download server: $($av.error)" }
    Info "Stable     : $($av.stable -join ', ')"
    Info "Snapshot   : $($av.snapshot -join ', ')"
    if ($av.beta) { Info "Beta       : $($av.beta -join ', ')" }
    Write-Host ""
    $cmpStable = { try { [version]$_ } catch { [version]"0.0" } }
    $cmpSnap   = { try { [version]($_ -replace '-SNAPSHOT', '') } catch { [version]"0.0" } }
    $latestStable = $av.stable | Sort-Object $cmpStable -Descending | Select-Object -First 1
    $latestSnap   = $av.snapshot | Sort-Object $cmpSnap -Descending | Select-Object -First 1
    $latest6      = $av.stable | Where-Object { $_ -like "6.*" } | Sort-Object $cmpStable -Descending | Select-Object -First 1
    $latest7      = (@($av.snapshot) + @($av.stable)) | Where-Object { $_ -like "7.*" } | Sort-Object $cmpSnap -Descending | Select-Object -First 1
    Head "Aliases for: setup -Version <X>"
    Info "stable / latest -> $latestStable"
    Info "dev / snapshot  -> $latestSnap"
    Info "6               -> $latest6"
    Info "7               -> $latest7"
    Info "<exact tag>     -> used as-is (e.g. 6.2, 7.0-SNAPSHOT)"
}

function Cmd-Clone {
    Head "Clone lsFusion project"
    if (-not $GitUrl) { throw "Provide -GitUrl <repository URL>." }
    $git = Find-Git
    if (-not $git) { throw "git not found on PATH. Install Git to use 'clone'." }

    # Resolve target: explicit -Target wins; otherwise derive from the URL.
    if ($Target) {
        if ([IO.Path]::IsPathRooted($Target)) { $resolved = $Target }
        else { $resolved = Join-Path (Get-Location) $Target }
    } else {
        $name = $GitUrl.TrimEnd('/').Split('/')[-1]
        if ($name.EndsWith(".git")) { $name = $name.Substring(0, $name.Length - 4) }
        $resolved = Join-Path (Get-Location) $name
    }

    if (Test-Path $resolved) {
        $items = @(Get-ChildItem $resolved -Force -ErrorAction SilentlyContinue)
        if ($items.Count -gt 0 -and -not $Force) {
            throw "Target '$resolved' is not empty. Pick a different -Target or pass -Force."
        }
    }

    $gitArgs = @("clone")
    if ($Branch) { $gitArgs += @("--branch", $Branch, "--single-branch") }
    $gitArgs += @($GitUrl, $resolved)

    Info "Cloning $GitUrl"
    Info "      to $resolved"
    & $git $gitArgs
    if ($LASTEXITCODE -ne 0) { throw "git clone failed (exit $LASTEXITCODE)." }
    Ok "Cloned to $resolved"

    if (Test-ExistingProject $resolved) {
        Ok "Layout looks like an lsFusion project."
        Info "Next step (pick a short -AppId: it names the database and the web context path):"
        Info "  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" setup -ProjectDir `"$resolved`" -AppId <short id> -DbPassword <pwd>"
    } else {
        Warn "Repository does not look like an lsFusion project (no pom.xml, src/main/lsfusion, or lsfusion.properties found)."
        Info "You can still try setup against it, but verify the project layout first."
    }
}

function Cmd-Help {
    Write-Host @"
lsfdev.ps1 - lsFusion development CLI

Stable path: every run refreshes a version-independent copy at
  %LOCALAPPDATA%\lsfusion-dev\lsfdev.ps1
Call THAT after the first run - the plugin-cache path embeds the plugin
version and dies on every plugin update.

  clone          Clone an existing lsFusion project from a Git repository.
  check          Detect Java, PostgreSQL, Python, git and Maven.
  setup          Download server jar, client war, Tomcat; write settings.properties.
  start-server   Start the application server and report a startup verdict.
  start-web      Start Tomcat with the web client.
  start          start-server then start-web.
  restart        stop then start (use after editing .lsf files).
  stop           Stop the application server and Tomcat.
  status         Show running processes and ports.
  log            Print the server log tail and a verdict.
  verify         Playwright (headless Chromium) screenshot + DOM dump of the web UI.
                 -OpenScript "SHOW <form> DOCKED;" opens a form directly (no
                 navigator clicking, parameterizable); -Click/-DoubleClick
                 click through the navigator like a user would.
  open           Open the web UI in the default browser.
  api            Call the Action API (-Script "<code>" or -ScriptFile "<path>").
                 Use -ScriptFile for any script with non-ASCII text (UTF-8 safe).
                 ACTION code only - to lint declarations use precheck.
  precheck       Sub-second syntax + name check of .lsf files against the
                 RUNNING dev server, before paying for a restart (which
                 reports name errors one at a time). -Files 'a.lsf','b.lsf'
                 (project-relative or absolute); default: every .lsf under
                 src/main. Strips MODULE/REQUIRE headers, posts to /eval.
                 Verdicts say what was proven: files with load-only
                 constructs (CLASS/WHEN/...) get syntax-only coverage, and
                 EXTEND FORM / '() + { }' files can't be linted at all. A
                 file that is ENTIRELY META definitions / @-usages / EXTEND
                 FORM is reported upfront as RESTART-ONLY (eval compiles none
                 of it - ambiguity/constraint errors included); precheck
                 still checks its structure (MODULE header, META/END balance,
                 bracket balance) but the restart is the real check - budget
                 it, don't re-run precheck on such files.
                 REQUIRE completeness is never checked (eval sees every
                 loaded module) - a missing REQUIRE surfaces only at restart.
  versions       List lsFusion versions on download.lsfusion.org and aliases.

Common options:
  -AppId <id>           Short app identifier, chosen when the application is
                        created. It IS the database name (db.name) and the web
                        context path: the war deploys as <id>.war and the UI
                        lives at http://localhost:<web port>/<id>/main (open/
                        verify/status probe the bare context root and fall back
                        to /main - current 7.0-SNAPSHOT wars 404 on the root;
                        / redirects into the app either way).
                        Lowercase letter first, then [a-z0-9_], max 30
                        chars; persisted as db.name in settings.properties;
                        derived from folder name + path hash when omitted.
                        A validated -DbName, in effect - pass one or the other.
  -DbPassword <pwd>     PostgreSQL password (needed for setup).
  -DbUser / -DbServer / -DbName
  -Version <ver>        lsFusion version: '7' (default), 'stable', 'dev', '6',
                        or exact (e.g. 6.2, 7.0-SNAPSHOT). See 'versions'.
  -TomcatVersion <ver>  Pin a Tomcat 9 version.
  -TopModule <name>     Top lsFusion module to load.
  -RmiPort <port>       App-server RMI port (default 7652). Set per project to
                        run several servers/configs at once.
  -HttpPort <port>      App-server HTTP / Action API port (default 7651).
  -WebSocketPort <port> App-server WebSocket port (default 8887). Shift it too
                        when running several servers - it is always bound.
  -WebPort <port>       Tomcat HTTP port (default 8080).
  -ShutdownPort <port>  Tomcat shutdown port (default 8005).
  -Timeout <seconds>    Startup wait (default 180).
  -JvmArgs "<args>"     Extra app-server JVM args, persisted at setup
                        (e.g. -JvmArgs "-Duser.language=ru -Xmx4g"; appended
                        after defaults, so a user -Xmx wins).
  -TomcatOpts "<args>"  Extra Tomcat JVM args (CATALINA_OPTS analog),
                        persisted at setup.
  -Url <url>            Target URL for 'verify'.
  -OpenScript <code>    'verify' only: open a form DIRECTLY by navigating to
                        /eval/action?script=<code> - no navigator clicking.
                        The code is an lsFusion action script, typically
                        SHOW <form> DOCKED; or
                        FOR <key> DO SHOW EDIT <Class> = o DOCKED;
                        (qualify names with the namespace; DOCKED renders the
                        form as a tab like in production - without it the
                        form opens as a small floating window). Output goes
                        to verify-open.png. ASCII-safe only; for non-ASCII
                        use -OpenScriptFile.
  -OpenScriptFile <path> 'verify': same as -OpenScript but read from a UTF-8
                        file (preferred for non-ASCII scripts).
  -OpenExpect <text>    'verify': with -OpenScript, wait for this text on the
                        opened form and report whether it appeared. Matches
                        visible text nodes AND the values of visible inputs
                        (a form field's content is an input VALUE, not text -
                        it used to false-negative); the report says which
                        kind matched.
  -Click <text>         'verify' only: click navigator entry(ies) by visible
                        text before the final screenshot; chain with '>'
                        (e.g. -Click "Master data > Items"). Output goes to
                        verify-click.png; first form open gets generous waits.
  -DoubleClick <text>   'verify' only: after -Click navigation, double-click a
                        grid row by visible cell text to open its edit card,
                        then screenshot it (e.g. -DoubleClick "Coffee beans").
                        Output goes to verify-dblclick.png.
  -Do <step>[,<step>]   'verify' only: generic interaction steps, run in order
                        AFTER the -Click/-DoubleClick navigation - the way to
                        reach buttons/inputs inside CUSTOM (React) components
                        that text-based -Click cannot hit. Each step is
                        verb:rest with any Playwright selector (css, text=...,
                        button:has-text(...)); click/dblclick/hover/drag/dnd
                        selectors accept an @x,y offset from the element's
                        top-left corner:
                          click:<sel>[@x,y]         dblclick:<sel>[@x,y]
                          hover:<sel>[@x,y]         drag:<sel>[@x,y]=><sel>[@x,y]
                          dnd:<sel>[@x,y]=><sel>[@x,y]
                          mouse:down[@x,y]  mouse:up[@x,y]  mouse:move@x,y[,steps]
                          fill:<sel>=><value>       type:<sel>=><value>
                          edit:<caption|sel>=><val> press:<key>  eval:<js>  wait:<ms>
                        'drag' is a raw mouse gesture (mousedown/mousemove/
                        mouseup - drag-to-draw UIs); 'dnd' speaks HTML5
                        drag-and-drop (DragEvents sharing one live
                        DataTransfer - kanban/sortable components listening
                        dragstart/drop). A component understands one protocol
                        or the other - if drag: visibly does nothing on a
                        draggable UI, use dnd:.
                        Selectors resolve to the FIRST VISIBLE match: the web
                        client keeps whole duplicate toolbars of inactive
                        docked tabs in the DOM, so a bare first-match click
                        used to hang on a hidden copy - hidden matches are now
                        skipped and reported ('3 matched, 1 visible - using
                        the first visible'); if every match is hidden the
                        step fails with that diagnosis. 'edit' drives the lsFusion IN-PLACE
                        editor (fill/type can't - the <input> exists only
                        after the cell is focused): it finds the panel cell by
                        its visible caption (or any selector, e.g. a grid
                        cell), double-clicks it, selects all, types the value
                        and presses Enter; on a caption miss it lists the
                        editable panel captions of the page. 'drag' performs a
                        real mousedown -> interpolated mousemoves -> mouseup
                        gesture (drag-to-draw UIs: Gantt links, resize
                        handles); 'mouse' gives raw viewport-coordinate
                        primitives (move glides in 12 interpolated steps by
                        default so busy pages still see the path); 'type'
                        presses real keys (React inputs that ignore fill);
                        eval returns its value into the report. Chain stops at
                        the first failed step. Screenshot goes to
                        verify-do.png. Example:
                          verify -Click "Schedule" -Do "edit:Comment=>Ivanov","drag:.task-a=>.task-b","click:text=Book"
  -Session              'verify' only: keep a persistent headless browser
                        (per-project CDP port) so the page - navigation, open
                        form, JS state - SURVIVES between verify calls:
                        navigate once with -OpenScript/-Click, then iterate
                        with -Do only. While the page is on the app it is
                        NEVER reloaded implicitly - so edited JS/CSS are NOT
                        picked up until -Reload (or a re-navigation such as
                        -OpenScript). Ended by 'verify -EndSession';
                        stop/restart also close it. -Locale has no effect on
                        an existing session.
  -Reload               'verify -Session' only: force a page reload before the
                        steps - the reloaded page fetches fresh JS/CSS (devmode
                        serves web resources no-store with a content-hash URL,
                        so an ordinary reload is always enough) but the app
                        resets to its default state: open forms close (reopen
                        in the same call via -OpenScript). Without -Session
                        every verify starts a fresh browser anyway.
  -EndSession           'verify' only: close the persistent session browser.
  -CdpPort <port>       'verify -Session' only: override the derived CDP port.
  -ViewportWidth/-ViewportHeight
                        'verify' browser viewport (default 1920x1080; narrow
                        viewports make dense forms look broken).
  -Locale <tag>         'verify' browser locale, e.g. ru-RU.
  -Script <code>        Inline lsFusion action code for 'api' (ASCII-safe only).
  -ScriptFile <path>    UTF-8 file with lsFusion action code for 'api'. Preferred
                        for non-ASCII scripts (read from disk, never via argv).
  -Files <p1>[,<p2>]    'precheck' only: .lsf files to lint (project-relative
                        or absolute). Default: every .lsf under src/main.
  PowerShell quoting    Wrap -Do/-Click/-Script values that contain double
                        quotes, brackets or commas in SINGLE quotes:
                        -Do 'click:[data-id="add"]'. Backslash-escaping
                        (\") splits the argument apart, and a comma in the
                        unquoted remainder aborts parsing ("Missing argument
                        in parameter list"). Several -Do steps = ONE array
                        argument: -Do 'step1','step2' (repeating -Do fails).
  -GitUrl <url>         Repository URL for 'clone'.
  -Target <dir>         Destination directory for 'clone' (default: subfolder named from the URL).
  -Branch <name>        Branch to check out for 'clone' (default: the repo's default branch).
  -Force                setup: regenerate config + settings.properties (does
                        NOT re-download binaries - downloads are version-driven);
                        clone: allow a non-empty target dir.
  -NoWeb                Skip the web client (server + Action API only).
  -FullStart            Disable light start for this run (a full start also
                        re-syncs the Reflection tables and user-side prefs;
                        schema sync runs either way). The fix when code added
                        since the last full start must be visible in the
                        Reflection tables (scheduler tasks pick actions via
                        actionCanonicalName) - one full restart, then back to
                        light starts.
  -RefreshWar           setup only: re-download the client war at the SAME
                        version (current -SNAPSHOT build). The fix when the war
                        and the server jar drift apart across snapshot builds
                        (Maven updated the server, the war stayed) and forms
                        fail with 'invalid stream header'; start-web/status
                        warn when they detect that drift.
"@
}

# ---------------------------------------------------- stable entry point ----
# When installed as a plugin, this script's real path carries the PLUGIN
# VERSION (...\plugins\cache\<marketplace>\lsfusion-ai-skills\<version>\
# skills\lsfusion-dev\scripts\lsfdev.ps1), so every plugin update kills any
# remembered absolute path (measured: a session memory pointing at 0.1.18
# failed after the cache moved to 0.1.20). Every run therefore maintains a
# tiny forwarder at a VERSION-INDEPENDENT path:
#
#   %LOCALAPPDATA%\lsfusion-dev\lsfdev.ps1
#
# which re-resolves the newest installed skill copy at call time and forwards
# all arguments (and the exit code) to it. That path is the one to remember,
# document, and put in session memories.
function Sync-StableShim {
    try {
        if (-not $env:LOCALAPPDATA) { return $null }
        $shimDir = Join-Path $env:LOCALAPPDATA "lsfusion-dev"
        # Degenerate install guard: if THIS script already runs from the shim
        # location, rewriting it would overwrite the running file with
        # forwarder text and orphan the next call.
        if ("$PSScriptRoot".TrimEnd('\') -ieq $shimDir.TrimEnd('\')) { return (Join-Path $shimDir "lsfdev.ps1") }
        $self = Join-Path $PSScriptRoot "lsfdev.ps1"
        # The cache root THIS copy is installed under (…\<root>\<marketplace>\
        # lsfusion-ai-skills\<version>\skills\lsfusion-dev\scripts). Embedded
        # into the shim as an extra search root, so nonstandard cache
        # locations (relocated config dirs, custom cache env vars) keep
        # working: a plugin update lands in the same root the current copy
        # runs from. Empty when the layout is not a versioned plugin cache
        # (e.g. a repo checkout) - the shim then relies on the other roots
        # and the literal fallback path.
        $cacheRoot = ""
        try {
            # scripts -> lsfusion-dev -> skills -> <version>; then the root is
            # THREE more levels up (<version> -> lsfusion-ai-skills ->
            # <marketplace> -> root), matching the shim's
            # <root>\*\lsfusion-ai-skills\*\skills\... glob shape. Both the
            # version-looking leaf and the plugin-dir name are asserted, so a
            # repo checkout (or any other layout) embeds nothing.
            $verDir = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
            if ($verDir -and ((Split-Path $verDir -Leaf) -match '^\d+(\.\d+)*([.-].+)?$')) {
                $pluginDir = Split-Path $verDir -Parent
                if ($pluginDir -and ((Split-Path $pluginDir -Leaf) -ieq 'lsfusion-ai-skills')) {
                    $cacheRoot = Split-Path (Split-Path $pluginDir -Parent) -Parent
                }
            }
        } catch { }
        $shimText = @'
# Auto-generated by the lsfusion-dev skill - STABLE entry point for lsfdev.ps1.
# The real script lives under the Claude plugin cache, whose path contains the
# plugin VERSION and changes on every plugin update; THIS path never changes.
# The shim re-resolves the newest installed copy on every call and forwards
# all arguments and the exit code. Remember this path, not the versioned one.
# Search roots: CLAUDE_CONFIG_DIR\plugins\cache (relocated config dir), the
# cache root the generating copy was installed under, and the default
# USERPROFILE\.claude\plugins\cache.
$roots = @()
if ($env:CLAUDE_CONFIG_DIR) { $roots += (Join-Path $env:CLAUDE_CONFIG_DIR 'plugins\cache') }
$roots += '__CACHEROOT__'
if ($env:USERPROFILE) { $roots += (Join-Path $env:USERPROFILE '.claude\plugins\cache') }
$cands = @()
foreach ($r in @($roots | Where-Object { $_ } | Select-Object -Unique)) {
    $cands += @(Get-ChildItem (Join-Path $r '*\lsfusion-ai-skills\*\skills\lsfusion-dev\scripts\lsfdev.ps1') -ErrorAction SilentlyContinue)
}
$cands = @($cands | Sort-Object -Property FullName -Unique)
$real = $null
if ($cands.Count) {
    $real = ($cands | Sort-Object -Property `
        @{Expression = { Test-Path (Join-Path $_.Directory.Parent.Parent.Parent.FullName '.in_use') }; Descending = $true},
        @{Expression = { try { [version]$_.Directory.Parent.Parent.Parent.Name } catch { [version]'0.0' } }; Descending = $true} |
        Select-Object -First 1).FullName
}
if (-not $real -and (Test-Path '__FALLBACK__')) { $real = '__FALLBACK__' }
if (-not $real) {
    Write-Host "[FAIL] No installed lsfusion-dev skill found: the plugin cache glob matched nothing and the copy that generated this shim is gone. Reinstall the lsfusion-ai-skills plugin (or call its skills\lsfusion-dev\scripts\lsfdev.ps1 directly)." -ForegroundColor Red
    exit 1
}
# An in-process caller reads $LASTEXITCODE afterwards; without this reset a
# stale nonzero value from an unrelated earlier native command would leak
# through when the real script completes without running one.
$global:LASTEXITCODE = 0
& $real @args
exit $LASTEXITCODE
'@
        # Apostrophes in paths (C:\Users\O'Brien\...) must be doubled - the
        # placeholders sit inside single-quoted literals in the shim text.
        $shimText = $shimText.Replace('__FALLBACK__', $self.Replace("'", "''"))
        $shimText = $shimText.Replace('__CACHEROOT__', "$cacheRoot".Replace("'", "''"))
        $shimPath = Join-Path $shimDir "lsfdev.ps1"
        $current = ""
        if (Test-Path $shimPath) { try { $current = [IO.File]::ReadAllText($shimPath) } catch { } }
        if ($current -ne $shimText) {
            New-Item -ItemType Directory -Force -Path $shimDir | Out-Null
            [IO.File]::WriteAllText($shimPath, $shimText, (New-Object System.Text.UTF8Encoding($false)))
        }
        return $shimPath
    } catch { return $null }
}

# ---------------------------------------------------------------- dispatch --

$script:StableShimPath = Sync-StableShim
try {
    switch ($Command.ToLower()) {
        "clone"           { Cmd-Clone }
        "check"           { Cmd-Check }
        "setup"           { Cmd-Setup }
        "start-server" { Cmd-StartServer }
        "start-web"    { Cmd-StartWeb }
        "start"        { Cmd-StartServer; Cmd-StartWeb }
        "restart" {
            Head "Restart"
            $cfg = Load-Config
            $srvPorts = @(7652, 7651, 8887); $webPorts = @(8080)
            if ($cfg) { $srvPorts = @($cfg.rmiPort, $cfg.httpPort, $cfg.webSocketPort); $webPorts = @($cfg.webPort) }
            Stop-Tracked $ServerPid $srvPorts "Application server"
            Stop-Tracked $TomcatPid $webPorts "Tomcat"
            # The session browser holds a page of the app being restarted -
            # a stale page after a schema change misleads more than it helps.
            if (Test-Path $PwSessionPid) { Stop-Tracked $PwSessionPid @() "Persistent verify-session browser" }
            Cmd-StartServer
            if (-not $NoWeb) { Cmd-StartWeb }
        }
        "stop" {
            Head "Stop"
            $cfg = Load-Config
            $srvPorts = @(7652, 7651, 8887); $webPorts = @(8080)
            if ($cfg) { $srvPorts = @($cfg.rmiPort, $cfg.httpPort, $cfg.webSocketPort); $webPorts = @($cfg.webPort) }
            Stop-Tracked $ServerPid $srvPorts "Application server"
            Stop-Tracked $TomcatPid $webPorts "Tomcat"
            if (Test-Path $PwSessionPid) { Stop-Tracked $PwSessionPid @() "Persistent verify-session browser" }
        }
        "status"       { Cmd-Status }
        "log"          { Cmd-Log }
        "verify"       { Cmd-Verify }
        "open"         { Cmd-Open }
        "api"          { Cmd-Api }
        "precheck"     { Cmd-Precheck }
        "versions"     { Cmd-Versions }
        default        { Cmd-Help }
    }
} catch {
    Bad $_.Exception.Message
    exit 1
}
