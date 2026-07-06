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
    [string]$Click = "",
    [string]$DoubleClick = "",
    [string[]]$Do = @(),
    [int]$ViewportWidth = 1920,
    [int]$ViewportHeight = 1080,
    [string]$Locale = "",
    [string]$JvmArgs = "",
    [string]$TomcatOpts = "",
    [string]$Script = "",
    [string]$ScriptFile = "",
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
    [switch]$FullStart
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
        $sr = New-Object IO.StreamReader($fs)
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
            foreach ($line in (Get-Content $sf)) {
                if ($line -match "^\s*$([regex]::Escape($key))\s*=\s*(\d+)\s*$") { return [int]$Matches[1] }
            }
        }
    }
    return $null
}

# Read a string-valued key from a .properties file ($null if file/key absent).
function Get-SettingsValue([string]$file, [string]$key) {
    if (-not (Test-Path $file)) { return $null }
    foreach ($line in (Get-Content $file)) {
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
    if (Test-Path $file) { $lines = @(Get-Content $file) }
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
        $c = (Get-Content $ConfigPath -Raw | ConvertFrom-Json)
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
        throw "Project is not set up. Run:  lsfdev.ps1 setup -DbPassword <password>"
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
        $xml = [xml](Get-Content $pom -Raw)
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
            if (([int]::TryParse((Get-Content $pf -Raw).Trim(), [ref]$v)) -and $v) { $own += $v }
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
# only, and not one of the stock Tomcat webapps (deploying manager.war over
# the stock manager/ dir is undefined behavior).
function Test-ContextSafe([string]$name) {
    return ($name -match '^[a-z][a-z0-9_]{0,29}$') -and ($name -notin @('root', 'docs', 'examples', 'manager'))
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
    $psql = Find-Psql
    if (-not $psql) {
        Info "psql not found - lsFusion will attempt to create the database itself."
        return
    }
    $hp = Get-PgHostPort $cfg
    $old = $env:PGPASSWORD
    $env:PGPASSWORD = $cfg.dbPassword
    try {
        $exists = (& $psql -U $cfg.dbUser -h $hp.Host -p $hp.Port -tAc "SELECT 1 FROM pg_database WHERE datname='$($cfg.dbName -replace "'", "''")'" 2>$null)
        if ("$exists".Trim() -eq "1") {
            Info "Database '$($cfg.dbName)' already exists."
        } else {
            $createdb = Join-Path (Split-Path $psql -Parent) "createdb.exe"
            if (-not (Test-Path $createdb)) { $createdb = "createdb" }
            & $createdb -U $cfg.dbUser -h $hp.Host -p $hp.Port $cfg.dbName 2>$null
            if ($LASTEXITCODE -eq 0) { Ok "Created database '$($cfg.dbName)'." }
            else { Warn "Could not create database (lsFusion will try on startup)." }
        }
    } catch {
        Warn "Database pre-check skipped: $_"
    } finally {
        $env:PGPASSWORD = $old
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
        $procId = 0; [int]::TryParse((Get-Content $pidFile -Raw).Trim(), [ref]$procId) | Out-Null
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
    if ($killed) { Ok "$label stopped." } else { Info "$label was not running." }
}

function Patch-TomcatPorts($tomcatHome, $webPort, $shutdownPort) {
    # Tomcat reads its HTTP and shutdown ports from conf/server.xml, so the
    # config value alone is not enough - rewrite the file. Matching is anchored
    # on the shutdown="SHUTDOWN" / protocol="HTTP/1.1" attributes, so it works
    # regardless of the port currently in the file (idempotent re-runs).
    $serverXml = Join-Path $tomcatHome "conf\server.xml"
    if (-not (Test-Path $serverXml)) { Warn "server.xml not found - Tomcat ports left at defaults."; return }
    $xml = Get-Content $serverXml -Raw
    $xml = [regex]::Replace($xml, '(<Server\s+port=")\d+("\s+shutdown="SHUTDOWN")', ('${1}' + $shutdownPort + '${2}'))
    $xml = [regex]::Replace($xml, '(<Connector\s+port=")\d+("\s+protocol="HTTP/1\.1")', ('${1}' + $webPort + '${2}'))
    Set-Content -Path $serverXml -Value $xml -Encoding UTF8
    Ok "Tomcat ports set: HTTP $webPort, shutdown $shutdownPort."
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
        if ((Test-MavenProject $ProjectDir) -and (Find-Maven)) {
            Ok "Maven project: lsfusion-server comes from Maven dependencies (no local jar needed)."
        } else {
            $jar = Join-Path $StateDir "lsfusion-server-$($cfg.version).jar"
            if (Test-Path $jar) { Ok "Server jar present." } else { Warn "Server jar missing - run setup again." }
        }
    } else {
        Info "Project not set up yet. Next step: lsfdev.ps1 setup -AppId <short id> -DbPassword <password>"
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
    # start does a full schema sync (major versions diverge enough that light
    # start would be unsafe), and clear out any stale server jar to save disk.
    $platformVersionChanged = ($existing -and $existing.version -and ($existing.version -ne $cfg.version))
    if ($platformVersionChanged) {
        $marker = Join-Path $StateDir "server-initialized.flag"
        if (Test-Path $marker) {
            Remove-Item $marker -Force -ErrorAction SilentlyContinue
            Info "Version changed ($($existing.version) -> $($cfg.version)) - next start will be a full schema sync."
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
        #    from a previous deployment name counts as present - see below).
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
        if ($needTomcat -or $staleWarsPre -or (-not (Test-Path $warPath)) -or $platformVersionChanged) {
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
        foreach ($sw in $staleWars) {
            $oldCtx = [IO.Path]::GetFileNameWithoutExtension($sw.Name)
            if ((-not $platformVersionChanged) -and (-not (Test-Path $warPath))) {
                Move-Item $sw.FullName $warPath -Force
                Info "Redeployed $($sw.Name) as $warName (same war, new web context $ctxDisplay)."
            } else {
                Remove-Item $sw.FullName -Force
            }
            Remove-Item (Join-Path $webapps $oldCtx) -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path $tomcatHome "conf\Catalina\localhost\$oldCtx.xml") -Force -ErrorAction SilentlyContinue
        }
        $needWar = (-not (Test-Path $warPath)) -or $platformVersionChanged

        # Deploy the client war as <db.name>.war. The ~250 MB war is downloaded
        # to a temp file and *moved* into place, so a separate copy is never kept.
        if ($needWar) {
            $warTmp = Join-Path $StateDir "lsfusion-client-download.war"
            Invoke-Download "$DownloadBase/lsfusion-client-$($cfg.version).war" $warTmp
            Remove-Item (Join-Path $webapps $ctxName) -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item $warPath -Force -ErrorAction SilentlyContinue
            Move-Item $warTmp $warPath -Force
            Ok "Web client war deployed as $warName - web context $ctxDisplay (lsFusion $($cfg.version))."
        } else {
            Ok "Web client war up to date ($warName, web context $ctxDisplay, lsFusion $($cfg.version)) - not re-downloading."
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
            # (or a leftover exploded ROOT) with a one-line redirect to the app
            # context, so http://localhost:<webPort>/ still lands in the app.
            if (Test-Path (Join-Path $rootDir "index.jsp")) {   # stock Tomcat welcome app
                Remove-Item $rootDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item -ItemType Directory -Force -Path $rootDir | Out-Null
            $redirect = '<!DOCTYPE html><html><head><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=/' + $ctxName + '/"><title>lsFusion</title></head>' +
                        '<body><a href="/' + $ctxName + '/">/' + $ctxName + '/</a></body></html>'
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
        if ((Test-Path $rootSettings) -and ((Get-Content $rootSettings -Raw) -match 'generated by lsfdev\.ps1')) {
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
    if (Test-Path $gi) { $giText = Get-Content $gi -Raw }
    if ($giText -notmatch '(?m)^\.lsfusion-dev/?\s*$') {
        Add-Content -Path $gi -Value ".lsfusion-dev/"
        Ok "Added .lsfusion-dev/ to .gitignore."
    }

    Ensure-Database $cfg
    Write-Host ""
    if ($NoWeb) {
        Ok "App id / database '$($cfg.dbName)' (no web client: -NoWeb)."
    } else {
        Ok "App id '$($cfg.dbName)' - database '$($cfg.dbName)', web context $(Get-WebUrl $cfg)"
    }
    Ok "Setup complete. Put your .lsf modules in $ProjectDir, then run: lsfdev.ps1 start"
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
        $mavenCp = (Get-Content $cpFile -Raw).Trim()
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
    # lightstart makes restarts much faster but is unsafe on the first launch
    # and after data-model changes (the DB schema must be fully synced), so it
    # is skipped on the first launch and whenever -FullStart is passed.
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
        Info "Dev mode ON, light start OFF ($reason - full schema sync)."
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
        New-Item -ItemType File -Force -Path $initMarker | Out-Null
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
    $java = Find-Java
    if (-not $java) { throw "Java not found." }
    $tomcatHome = Join-Path $StateDir "tomcat"
    if (-not (Test-Path (Join-Path $tomcatHome "bin\bootstrap.jar"))) {
        throw "Tomcat is not installed. Run setup (without -NoWeb)."
    }
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
        Ok "Web client is up: $webUrl"
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
    if (Test-Path $ServerPid) { [int]::TryParse((Get-Content $ServerPid -Raw).Trim(), [ref]$sPid) | Out-Null }
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
    if (Test-Path $TomcatPid) { [int]::TryParse((Get-Content $TomcatPid -Raw).Trim(), [ref]$tPid) | Out-Null }
    if ((Process-Alive $tPid) -and (Test-PortOpen $web)) { Ok "Web client    : running (PID $tPid, $(Get-WebUrl $cfg))" }
    elseif (Test-PortOpen $web) { Warn "Web client    : something is on web port $web (PID file stale)" }
    else { Info "Web client    : stopped" }
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
    $target = $Url
    if (-not $target) { $target = Get-WebUrl $cfg }

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

    if ($Click) { Info "Click  : '$Click' (navigator click-through before the final screenshot)" }
    if ($DoubleClick) { Info "DblClick: '$DoubleClick' (double-click a grid row to open its edit card)" }
    if ($Do.Count) { Info "Do     : $($Do.Count) generic step(s) after navigation (click/fill/type/press/eval/wait by Playwright selector)" }
    Info "View   : ${ViewportWidth}x${ViewportHeight}$(if ($Locale) { ", locale $Locale" })"

    # Use --name=value form so an empty password is preserved through
    # PowerShell's native-argument handling (without =, empty strings get
    # dropped and argparse sees the next flag as the value). Every free-text
    # value goes through ConvertTo-NativeArg - PS 5.1 does not escape embedded
    # double quotes on its own, and -Do steps (JS, attribute selectors) carry
    # them routinely.
    $doArgs = @($Do | Where-Object { $_ } | ForEach-Object { "--do=$(ConvertTo-NativeArg $_)" })
    $jsonText = (& $py $scriptPath --url $target --output-dir $StateDir `
        "--user=$(ConvertTo-NativeArg $cfg.adminUser)" "--password=$(ConvertTo-NativeArg $cfg.adminPassword)" `
        "--click=$(ConvertTo-NativeArg $Click)" "--double-click=$(ConvertTo-NativeArg $DoubleClick)" `
        --viewport-width $ViewportWidth --viewport-height $ViewportHeight "--locale=$Locale" `
        @doArgs --timeout 30000) -join "`n"
    $pyExit = $LASTEXITCODE

    $r = $null
    try { $r = $jsonText | ConvertFrom-Json } catch { }
    if (-not $r) {
        Bad "verify_playwright.py did not return parseable JSON (exit $pyExit). Raw output:"
        Write-Host $jsonText
        return
    }

    Write-Host ""
    if ($r.title) { Info "Page title : $($r.title)" }
    if (Test-Path $r.artifacts.login_screenshot) {
        $kb = [math]::Round((Get-Item $r.artifacts.login_screenshot).Length / 1KB, 1)
        Ok "Login screenshot      : $($r.artifacts.login_screenshot) ($kb KB)"
    }
    if (Test-Path $r.artifacts.app_screenshot) {
        $kb = [math]::Round((Get-Item $r.artifacts.app_screenshot).Length / 1KB, 1)
        $tag = if ($r.logged_in) { "authenticated UI" } else { "post-submit state" }
        Ok "App screenshot ($tag) : $($r.artifacts.app_screenshot) ($kb KB)"
    }
    if ($r.click -and $r.click.requested) {
        if (Test-Path $r.artifacts.click_screenshot) {
            $kb = [math]::Round((Get-Item $r.artifacts.click_screenshot).Length / 1KB, 1)
            Ok "Click screenshot      : $($r.artifacts.click_screenshot) ($kb KB)"
        }
        if ($r.click.error) {
            Warn "Click-through failed after [$($r.click.clicked -join ' > ')]: $($r.click.error)"
            Warn "Captions are locale-dependent - check verify-app.png for the actual navigator text."
        } elseif ($r.click.clicked.Count) {
            Ok "Clicked through: $($r.click.clicked -join ' > ')"
        }
    }
    if ($r.double_click -and $r.double_click.requested) {
        if (Test-Path $r.artifacts.dblclick_screenshot) {
            $kb = [math]::Round((Get-Item $r.artifacts.dblclick_screenshot).Length / 1KB, 1)
            Ok "Double-click screenshot : $($r.artifacts.dblclick_screenshot) ($kb KB)"
        }
        if ($r.double_click.error) {
            Warn "Double-click failed: $($r.double_click.error)"
            Warn "Row text is locale/data-dependent - check verify-click.png for the actual grid text."
        } elseif ($r.double_click.target) {
            Ok "Double-clicked row '$($r.double_click.target)' - edit card in verify-dblclick.png"
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
    } else {
        Ok "No login form on the landing page - devmode auto-authenticated as '$($cfg.adminUser)', the screenshot shows the running app."
    }

    if ($r.console_errors -gt 0) {
        Warn "Browser console reported $($r.console_errors) error(s) - see $($r.artifacts.console)."
    }
    if ($r.error) { Bad "Playwright reported: $($r.error)" }
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
    $apiUser = if ($ScriptBound.ContainsKey("AdminUser"))     { $AdminUser }     else { $cfg.adminUser }
    $apiPass = if ($ScriptBound.ContainsKey("AdminPassword")) { $AdminPassword } else { $cfg.adminPassword }
    $headers = @{}
    if ($apiPass) {
        $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($apiUser):$($apiPass)"))
        $headers["Authorization"] = "Basic $auth"
        Info "Authenticating as '$apiUser' (password configured)."
    } else {
        Info "Calling anonymously (devmode auto-auth) - no admin password set, so no Basic header is sent (the form that works on every platform build)."
    }
    # The script travels as a percent-encoded query parameter (NOT a POST form
    # body): EscapeDataString emits the UTF-8 bytes as %XX, which the server
    # decodes as UTF-8 reliably on every platform version. (Current
    # 7.0-SNAPSHOT decodes a POST form body as UTF-8 too, but 6.x-era builds
    # used the platform default charset there and corrupted non-ASCII to '?' -
    # the query parameter is the channel that behaves the same everywhere.)
    $enc = [uri]::EscapeDataString($scriptText)
    $uri = "http://localhost:$($cfg.httpPort)/eval/action?script=$enc"
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
        $resp = Invoke-WebRequest -Uri $uri -Method Post -Headers $headers `
            -UseBasicParsing -TimeoutSec 30
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
            Info "(empty response body - normal for actions without RETURN/EXPORT, but carries no proof either:"
            Info " a plain MESSAGE is not returned over HTTP, and a constraint-canceled APPLY still answers 200."
            Info " Also: EXPORT must be at the TOP LEVEL - its result is a session-local property, so inside"
            Info " NEWSESSION{} it is discarded with the session and never reaches the HTTP response (RETURN is"
            Info " fine inside NEWSESSION - it propagates up the stack - but an /eval/action script already runs"
            Info " in its own session, so no NEWSESSION wrapper is needed anyway)."
            Info " For mutations, end the script with: $recipe)"
        }
    } catch {
        $errResp = $_.Exception.Response
        $statusTag = ""
        if ($errResp) { try { $statusTag = " (HTTP $([int]$errResp.StatusCode))" } catch { } }
        Bad "API call failed$($statusTag): $($_.Exception.Message)"
        # Print the error response body - for a 500 it carries the actual
        # parse/type error from the server, which is the whole diagnosis.
        # PS 5.1: the cmdlet usually stashes the body in ErrorDetails; the
        # raw stream is a fallback (rewind it - the cmdlet may have read it).
        $errBody = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $errBody = $_.ErrorDetails.Message }
        elseif ($errResp) {
            try {
                $stream = $errResp.GetResponseStream()
                if ($stream -and $stream.CanSeek) { $stream.Position = 0 }
                if ($stream) {
                    $sr = New-Object IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
                    $errBody = $sr.ReadToEnd()
                }
            } catch { }
        }
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
    $u = Get-WebUrl $cfg
    Start-Process $u
    Ok "Opened $u in the default browser."
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
  open           Open the web UI in the default browser.
  api            Call the Action API (-Script "<code>" or -ScriptFile "<path>").
                 Use -ScriptFile for any script with non-ASCII text (UTF-8 safe).
  versions       List lsFusion versions on download.lsfusion.org and aliases.

Common options:
  -AppId <id>           Short app identifier, chosen when the application is
                        created. It IS the database name (db.name) and the web
                        context path: the war deploys as <id>.war and the UI
                        lives at http://localhost:<web port>/<id>/ (/ redirects
                        there). Lowercase letter first, then [a-z0-9_], max 30
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
                        button:has-text(...)):
                          click:<selector>          dblclick:<selector>
                          fill:<selector>=><value>  type:<selector>=><value>
                          press:<key>  eval:<js>  wait:<ms>
                        'type' presses real keys (React inputs that ignore
                        fill); eval returns its value into the report. Chain
                        stops at the first failed step. Screenshot goes to
                        verify-do.png. Example:
                          verify -Click "Schedule" -Do "fill:input.comment=>Ivanov","click:text=Book"
  -ViewportWidth/-ViewportHeight
                        'verify' browser viewport (default 1920x1080; narrow
                        viewports make dense forms look broken).
  -Locale <tag>         'verify' browser locale, e.g. ru-RU.
  -Script <code>        Inline lsFusion action code for 'api' (ASCII-safe only).
  -ScriptFile <path>    UTF-8 file with lsFusion action code for 'api'. Preferred
                        for non-ASCII scripts (read from disk, never via argv).
  -GitUrl <url>         Repository URL for 'clone'.
  -Target <dir>         Destination directory for 'clone' (default: subfolder named from the URL).
  -Branch <name>        Branch to check out for 'clone' (default: the repo's default branch).
  -Force                Re-download / overwrite on setup; allow clone into a non-empty dir.
  -NoWeb                Skip the web client (server + Action API only).
  -FullStart            Disable light start (full schema sync) for this run.
"@
}

# ---------------------------------------------------------------- dispatch --

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
        }
        "status"       { Cmd-Status }
        "log"          { Cmd-Log }
        "verify"       { Cmd-Verify }
        "open"         { Cmd-Open }
        "api"          { Cmd-Api }
        "versions"     { Cmd-Versions }
        default        { Cmd-Help }
    }
} catch {
    Bad $_.Exception.Message
    exit 1
}
