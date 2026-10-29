<#
.SYNOPSIS
    Build the PHP 8.5 one-click installer for Windows (x64, NTS, VS17).

.DESCRIPTION
    - Resolves the latest PHP 8.5.x / compatible Xdebug and APCu releases
      from the official windows.php.net listings (no hardcoded patch
      versions).
    - Downloads the official PHP binary zip, the Xdebug and APCu PECL zips
      and cacert.pem.
    - Stages a runtime tree: php.ini is generated from php.ini-development,
      common development extensions are enabled, APCu and Xdebug are
      registered and curl.cainfo / openssl.cafile point at the bundled
      cacert.pem via the __APP_DIR__ placeholder (replaced by the installer
      with the real dir).
    - Compiles an Inno Setup installer which installs to C:\pf\php-8.5
      by default.

.PARAMETER PhpVersion
    Exact PHP 8.5 patch version, e.g. 8.5.11. Re-spin releases keep the
    upstream spelling, e.g. 8.5.12-1. Empty = latest published 8.5.x.

.PARAMETER BuildDir
    Working directory for cache, staging and output. Default: <repo>\build.

.PARAMETER SkipCompile
    Only resolve/download/assemble; do not invoke the Inno Setup compiler.

.PARAMETER NilpackVersion
    Release tag (without leading 'v') of php-nil/nilpack to bundle as the
    `nil` command. Default 0.2.
#>
[CmdletBinding()]
param(
    [string]$PhpVersion = '',
    [string]$BuildDir = '',
    [switch]$SkipCompile,
    [string]$NilpackVersion = '0.2'
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
if (-not $BuildDir) { $BuildDir = Join-Path $RepoRoot 'build' }

$CacheDir  = Join-Path $BuildDir 'cache'
$StageDir  = Join-Path $BuildDir 'stage\php'
$OutDir    = Join-Path $BuildDir 'output'

$PhpBaseUrl    = 'https://windows.php.net/downloads/releases'
$XdebugBaseUrl = 'https://windows.php.net/downloads/pecl/releases/xdebug'
$ApcuBaseUrl   = 'https://windows.php.net/downloads/pecl/releases/apcu'
$CaCertUrl     = 'https://curl.se/ca/cacert.pem'
$NilpackUrl    = "https://github.com/php-nil/nilpack/releases/download/v$NilpackVersion/nilpack.phar"
$VcRedistUrl   = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
$WixZipUrl     = 'https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip'
$ComposerBaseUrl = 'https://getcomposer.org'

# VC++ runtime DLLs deployed app-local into the install root (next to php.exe).
# This set covers every vcruntime140/msvcp140 import in the staged tree;
# concrt140/vccorlib140/vcamp140/vcomp140/vcruntime140_threads are unused.
$VcRuntimeDlls = @(
    'vcruntime140.dll', 'vcruntime140_1.dll',
    'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll',
    'msvcp140_atomic_wait.dll', 'msvcp140_codecvt_ids.dll'
)

# Extensions enabled by default in the packaged php.ini (development profile).
$EnabledExtensions = @(
    'curl', 'fileinfo', 'exif', 'gd', 'intl', 'mbstring',
    'openssl', 'pdo_pgsql', 'pdo_sqlite', 'sodium', 'sockets',
    'sqlite3', 'zip'
)

# Extensions that must stay off even if a future php.ini-development ships them active.
$DisabledExtensions = @('mysqli', 'pdo_mysql')

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

function Get-LinkHrefs([string]$url) {
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $url
    @($resp.Links | ForEach-Object { $_.href })
}

function Download-File([string]$url, [string]$dest, [switch]$NoCache) {
    # Reuse a previously downloaded, non-empty cache file. -NoCache forces a
    # fresh download (used for cacert.pem, which must not be pinned forever).
    if (-not $NoCache -and (Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) {
        Write-Host "  cached: $dest"
        return
    }
    if ($NoCache -and (Test-Path $dest)) { Remove-Item -Force $dest }
    $attempts = 3
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            Write-Host "  downloading ($i/$attempts): $url"
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $dest
            if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) { return }
            throw 'downloaded file is empty'
        }
        catch {
            if ($i -eq $attempts) { throw }
            Start-Sleep -Seconds (3 * $i)
        }
    }
}

function Test-VersionString([string]$v) {
    # PHP re-spins are published as e.g. 8.5.12-1 (security rebuild of the
    # same patch release), so a trailing -N suffix is a valid version.
    return $v -match '^\d+\.\d+\.\d+(-\d+)?$'
}

function Get-VersionSortKey([string]$v) {
    # [version] cannot parse the re-spin form; map 8.5.12-1 -> 8.5.12.1 so
    # both forms sort numerically and the newest re-spin wins.
    if ($v -match '^(\d+\.\d+\.\d+)-(\d+)$') {
        return [version]("$($matches[1]).$($matches[2])")
    }
    return [version]$v
}

function Install-ExtensionDll([string]$ZipPath, [string]$DllName, [string]$ExtDir) {
    # PECL release zips carry the DLL plus docs/PDB; only the DLL is needed.
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq $DllName } | Select-Object -First 1
        if (-not $entry) { throw "$DllName not found inside $ZipPath" }
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $ExtDir $DllName), $true)
    }
    finally { $zip.Dispose() }
}

# ---------------------------------------------------------------------------
# 1. Resolve versions
# ---------------------------------------------------------------------------
Write-Step 'Resolving PHP 8.5 release'
if ($PhpVersion) {
    if (-not (Test-VersionString $PhpVersion)) { throw "Invalid -PhpVersion: $PhpVersion" }
}
else {
    $hrefs = Get-LinkHrefs $PhpBaseUrl
    # Asset names may carry a re-spin suffix (php-8.5.12-1-nts-...zip).
    $PhpVersion = $hrefs |
        ForEach-Object {
            if ($_ -match '^php-(8\.5\.\d+(?:-\d+)?)-nts-Win32-vs17-x64\.zip$') { $matches[1] }
        } |
        Sort-Object -Unique { Get-VersionSortKey $_ } |
        Select-Object -Last 1
    if (-not $PhpVersion) { throw 'Could not resolve latest PHP 8.5.x from windows.php.net' }
}
$PhpZipName = "php-$PhpVersion-nts-Win32-vs17-x64.zip"
# Inno Setup's VersionInfoVersion only accepts up to four numeric components,
# so the re-spin form 8.5.12-1 is expressed as 8.5.12.1 there while every
# user-visible string keeps the upstream 8.5.12-1 spelling.
$PhpVersionInfo = if ($PhpVersion -match '^(\d+\.\d+\.\d+)-(\d+)$') {
    "$($matches[1]).$($matches[2])"
}
else { $PhpVersion }
Write-Host "  PHP version : $PhpVersion"
Write-Host "  PHP package : $PhpZipName"

Write-Step 'Resolving Xdebug release'
# Walk release directories from newest to oldest until one ships 8.5 NTS.
$versionDirs = Get-LinkHrefs $XdebugBaseUrl |
    ForEach-Object { if ($_ -match '^(\d+\.\d+\.\d+)/$') { $matches[1] } } |
    Sort-Object -Unique { [version]$_ } |
    Sort-Object -Descending { [version]$_ }

$XdebugAsset = $null
foreach ($v in $versionDirs) {
    $hrefs = Get-LinkHrefs "$XdebugBaseUrl/$v/"
    $asset = $hrefs |
        Where-Object { $_ -eq "php_xdebug-$v-8.5-nts-vs17-x64.zip" } |
        Select-Object -First 1
    if ($asset) { $XdebugVersion = $v; $XdebugAsset = $asset; break }
}
if (-not $XdebugAsset) { throw 'Could not resolve an Xdebug build for PHP 8.5 NTS VS17 x64' }
Write-Host "  Xdebug version: $XdebugVersion"
Write-Host "  Xdebug asset  : $XdebugAsset"

Write-Step 'Resolving APCu release'
# Walk release directories from newest to oldest until one ships 8.5 NTS.
$apcuVersionDirs = Get-LinkHrefs $ApcuBaseUrl |
    ForEach-Object { if ($_ -match '^(\d+\.\d+\.\d+)/$') { $matches[1] } } |
    Sort-Object -Unique { [version]$_ } |
    Sort-Object -Descending { [version]$_ }

$ApcuAsset = $null
foreach ($v in $apcuVersionDirs) {
    $hrefs = Get-LinkHrefs "$ApcuBaseUrl/$v/"
    $asset = $hrefs |
        Where-Object { $_ -eq "php_apcu-$v-8.5-nts-vs17-x64.zip" } |
        Select-Object -First 1
    if ($asset) { $ApcuVersion = $v; $ApcuAsset = $asset; break }
}
if (-not $ApcuAsset) { throw 'Could not resolve an APCu build for PHP 8.5 NTS VS17 x64' }
Write-Host "  APCu version  : $ApcuVersion"
Write-Host "  APCu asset    : $ApcuAsset"

# ---------------------------------------------------------------------------
# 2. Download
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $OutDir | Out-Null
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

Write-Step 'Downloading PHP binary package'
$phpZip = Join-Path $CacheDir $PhpZipName
Download-File "$PhpBaseUrl/$PhpZipName" $phpZip

Write-Step 'Downloading Xdebug'
$xdZip = Join-Path $CacheDir $XdebugAsset
Download-File "$XdebugBaseUrl/$XdebugVersion/$XdebugAsset" $xdZip

Write-Step 'Downloading APCu'
$apZip = Join-Path $CacheDir $ApcuAsset
Download-File "$ApcuBaseUrl/$ApcuVersion/$ApcuAsset" $apZip

Write-Step 'Downloading cacert.pem'
$caPem = Join-Path $CacheDir 'cacert.pem'
# CA bundle rotates regularly (~200 KB): always re-fetch so local rebuilds
# never ship an expired bundle from a stale cache.
Download-File $CaCertUrl $caPem -NoCache

Write-Step "Downloading nilpack v$NilpackVersion (nil command)"
# Cache name is versioned: switching -NilpackVersion must not reuse the
# previously cached phar of another version.
$nilPharCache = Join-Path $CacheDir "nilpack-$NilpackVersion.phar"
Download-File $NilpackUrl $nilPharCache

Write-Step 'Downloading VC++ runtime redist (vc_redist.x64.exe)'
# Always re-fetch: aka.ms/vs/17/release tracks the latest 14.x runtime, so a
# cache would silently pin an outdated CRT (same rationale as cacert.pem).
$vcRedistExe = Join-Path $CacheDir 'vc_redist.x64.exe'
Download-File $VcRedistUrl $vcRedistExe -NoCache
$VcRedistVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($vcRedistExe).FileVersion
Write-Host "  VC++ runtime : $VcRedistVersion"

Write-Step 'Downloading WiX 3.14 toolset (dark.exe, for redist extraction)'
# Pinned tool version, safe to cache.
$wixZip = Join-Path $CacheDir 'wix314-binaries.zip'
Download-File $WixZipUrl $wixZip

Write-Step 'Downloading Composer'
# Latest stable only (no version pinning): the file rotates upstream, so never
# reuse cache (same rationale as cacert.pem). The exact version is read back
# from `composer.phar --version` later and recorded in the metadata.
$composerPharCache = Join-Path $CacheDir 'composer-stable.phar'
Download-File "$ComposerBaseUrl/composer-stable.phar" $composerPharCache -NoCache

# ---------------------------------------------------------------------------
# 3. Assemble staging tree (root of StageDir == C:\pf\php-8.5 at install time)
# ---------------------------------------------------------------------------
Write-Step 'Extracting PHP'
[System.IO.Compression.ZipFile]::ExtractToDirectory($phpZip, $StageDir)

Write-Step 'Installing php_xdebug.dll into ext\'
$extDir = Join-Path $StageDir 'ext'
Install-ExtensionDll -ZipPath $xdZip -DllName 'php_xdebug.dll' -ExtDir $extDir

Write-Step 'Installing php_apcu.dll into ext\'
Install-ExtensionDll -ZipPath $apZip -DllName 'php_apcu.dll' -ExtDir $extDir

Write-Step 'Installing cacert.pem'
Copy-Item -Force $caPem (Join-Path $StageDir 'cacert.pem')

Write-Step 'Installing nilpack.phar and the nil command shim'
$nilPhar = Join-Path $StageDir 'nilpack.phar'
Copy-Item -Force $nilPharCache $nilPhar
# nil.bat resolves php.exe / nilpack.phar next to itself (%~dp0), so the
# shim works regardless of the caller's working directory. Being in {app}
# (which is added to PATH at install time) makes the bare `nil` command work.
$nilBat = Join-Path $StageDir 'nil.bat'
# phar.readonly is ON by default in PHP, which makes Phar write operations
# (nil phar, nil composer) fail with phar.readonly errors. The shim disables
# it for this CLI invocation only; the bundled php.ini is left untouched.
$batLines = @(
    '@echo off',
    'rem nil - Nil Pack Tool launcher (generated by win-env)',
    '"%~dp0php.exe" -d phar.readonly=0 "%~dp0nilpack.phar" %*'
)
[IO.File]::WriteAllText($nilBat, ($batLines -join "`r`n") + "`r`n",
    (New-Object System.Text.ASCIIEncoding))

Write-Step 'Installing composer.phar and the composer command shim'
$composerPhar = Join-Path $StageDir 'composer.phar'
Copy-Item -Force $composerPharCache $composerPhar
# Same self-locating pattern as nil.bat: works from any caller CWD, and {app}
# being on PATH makes the bare `composer` command work in a new shell.
$composerBat = Join-Path $StageDir 'composer.bat'
$composerBatLines = @(
    '@echo off',
    'rem composer - Dependency Manager for PHP (shim generated by win-env)',
    '"%~dp0php.exe" "%~dp0composer.phar" %*'
)
[IO.File]::WriteAllText($composerBat, ($composerBatLines -join "`r`n") + "`r`n",
    (New-Object System.Text.ASCIIEncoding))

Write-Step 'Extracting VC++ runtime DLLs (app-local deployment)'
$wixDir = Join-Path $CacheDir 'wix314'
if (-not (Test-Path (Join-Path $wixDir 'dark.exe'))) {
    if (Test-Path $wixDir) { Remove-Item -Recurse -Force $wixDir }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($wixZip, $wixDir)
}
# vc_redist.x64.exe is a WiX Burn bundle: 7-Zip cannot open it and its /layout
# mode needs elevation plus writes to C:\Windows\Temp. dark.exe decompiles the
# bundle offline into payload MSIs; msiexec /a then extracts the MSI payload.
$vcX = Join-Path $CacheDir 'vcredist-x'
if (Test-Path $vcX) { Remove-Item -Recurse -Force $vcX }
& (Join-Path $wixDir 'dark.exe') -nologo -x $vcX $vcRedistExe
if ($LASTEXITCODE -ne 0) { throw "dark.exe failed with exit code $LASTEXITCODE" }
$vcMsi = Join-Path $vcX 'AttachedContainer\packages\vcRuntimeMinimum_amd64\vc_runtimeMinimum_x64.msi'
if (-not (Test-Path $vcMsi)) { throw 'vc_runtimeMinimum_x64.msi not found in redist bundle' }
$vcOut = Join-Path $vcX 'out-min'
$msiProc = Start-Process -FilePath 'msiexec.exe' -Wait -PassThru `
    -ArgumentList @('/a', "`"$vcMsi`"", '/qn', "TARGETDIR=`"$vcOut`"")
if ($msiProc.ExitCode -ne 0) { throw "msiexec /a failed with exit code $($msiProc.ExitCode)" }
foreach ($dll in $VcRuntimeDlls) {
    $src = Join-Path $vcOut "System64\$dll"
    if (-not (Test-Path $src)) { throw "$dll not found in extracted VC++ runtime" }
    Copy-Item -Force $src (Join-Path $StageDir $dll)
    $fv = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $StageDir $dll)).FileVersion
    if ($fv -notmatch '^14\.') { throw "Unexpected VC++ runtime version for ${dll}: $fv" }
}
Write-Host "  $($VcRuntimeDlls.Count) CRT DLLs staged (app-local, runtime $VcRedistVersion)"

# ---------------------------------------------------------------------------
# 4. Generate php.ini from php.ini-development
# ---------------------------------------------------------------------------
Write-Step 'Generating php.ini from php.ini-development'
$iniPath    = Join-Path $StageDir 'php.ini'
$iniTplPath = Join-Path $StageDir 'php.ini-development'
if (-not (Test-Path $iniTplPath)) { throw 'php.ini-development missing from PHP package' }
$ini = [IO.File]::ReadAllText($iniTplPath)

# extension_dir = "ext"
if ($ini -match '(?m)^[ \t]*;[ \t]*extension_dir[ \t]*=') {
    $ini = [regex]::Replace($ini, '(?m)^[ \t]*;[ \t]*(extension_dir[ \t]*=[ \t]*"ext")', '$1')
}
elseif ($ini -notmatch '(?m)^[ \t]*extension_dir[ \t]*=') {
    $ini += "`r`nextension_dir = `"ext`"`r`n"
}

# Common development extensions
foreach ($ext in $EnabledExtensions) {
    # Already active in php.ini-development?
    $activePattern = '(?m)^[ \t]*extension[ \t]*=[ \t]*' + [regex]::Escape($ext) + '\b'
    if ([regex]::IsMatch($ini, $activePattern)) { continue }

    # NOTE: ini-development uses CRLF; anchor with \b instead of ([ \t]|$)
    # because $ sits after \r and would fail the group.
    $commentedPattern = '(?m)^[ \t]*;[ \t]*(extension[ \t]*=[ \t]*' + [regex]::Escape($ext) + '\b)'
    if ([regex]::IsMatch($ini, $commentedPattern)) {
        # Instance method: Replace(input, replacement, count) - only first hit.
        # (The static overload has no count parameter; an int would be coerced
        # to RegexOptions.IgnoreCase and uncomment every occurrence.)
        $ini = ([regex]$commentedPattern).Replace($ini, '$1', 1)
    }
    else {
        Write-Host "  WARNING: 'extension=$ext' is not present in php.ini-development"
    }
}

# Force-disable extensions that must stay off by default (MySQL drivers),
# covering the case where php.ini-development ships one of them enabled.
foreach ($ext in $DisabledExtensions) {
    $disablePattern = '(?m)^(?![ \t]*;)([ \t]*extension[ \t]*=[ \t]*' + [regex]::Escape($ext) + '\b[^\r\n]*)'
    if ([regex]::IsMatch($ini, $disablePattern)) {
        $ini = [regex]::Replace($ini, $disablePattern, ';$1  ; disabled by win-env (default)')
        Write-Host "  force-disabled extension: $ext"
    }
}

# Defensive: comment out accidental duplicate active extension/zend_extension lines.
$nl = if ($ini -match "`r`n") { "`r`n" } else { "`n" }
$seen = @{}
$iniLines = $ini -split [regex]::Escape($nl)
for ($i = 0; $i -lt $iniLines.Length; $i++) {
    if ($iniLines[$i] -match '^[ \t]*(zend_extension|extension)[ \t]*=[ \t]*([^\s;]+)') {
        $key = ($matches[1] + '=' + $matches[2]).ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            $iniLines[$i] = ';' + $iniLines[$i] + '  ; commented out by win-env (duplicate)'
        }
        else { $seen[$key] = $true }
    }
}
$ini = $iniLines -join $nl

# Bundle CA certificate: __APP_DIR__ is replaced with the actual install
# directory by the Inno Setup installer after extraction.
$caRel = '__APP_DIR__/cacert.pem'
if ($ini -match '(?m)^[ \t]*;?[ \t]*curl\.cainfo[ \t]*=') {
    $ini = [regex]::Replace($ini, '(?m)^[ \t]*;?[ \t]*(curl\.cainfo[ \t]*=)[^\r\n]*', "`$1 `"$caRel`"")
}
else { $ini += "`r`ncurl.cainfo = `"$caRel`"`r`n" }

if ($ini -match '(?m)^[ \t]*;?[ \t]*openssl\.cafile[ \t]*=') {
    $ini = [regex]::Replace($ini, '(?m)^[ \t]*;?[ \t]*(openssl\.cafile[ \t]*=)[^\r\n]*', "`$1 `"$caRel`"")
}
else { $ini += "`r`nopenssl.cafile = `"$caRel`"`r`n" }

# Default timezone: Asia/Shanghai (php.ini-development ships this commented out).
if ($ini -match '(?m)^[ \t]*;?[ \t]*date\.timezone[ \t]*=') {
    $ini = [regex]::Replace($ini, '(?m)^[ \t]*;?[ \t]*(date\.timezone[ \t]*=)[^\r\n]*', '$1 Asia/Shanghai')
}
else { $ini += "`r`ndate.timezone = Asia/Shanghai`r`n" }

# APCu (bundled PECL extension, enabled by default). Unlike the core
# extensions above it has no line in php.ini-development, so the entry is
# added explicitly. CLI usage stays off (apc.enable_cli=0, the upstream
# default): a CLI process would otherwise pay the shared-memory setup cost on
# every invocation; enable it per-run with -d apc.enable_cli=1 when needed.
$apcuBlock = @"

; >>> win-env bundled APCu $ApcuVersion >>>
[PHP]
extension=apcu
[apcu]
apc.enabled=1
apc.enable_cli=0
apc.shm_size=32M
; <<< win-env bundled APCu <<<
"@
$ini = $ini.TrimEnd("`r", "`n") + "`r`n" + $apcuBlock

# Xdebug (loaded from extension_dir, so the entry is path-independent)
$xdebugBlock = @"

; >>> win-env bundled Xdebug $XdebugVersion >>>
[xdebug]
zend_extension=xdebug
xdebug.mode=develop,debug,coverage
xdebug.client_host=127.0.0.1
xdebug.client_port=9003
; <<< win-env bundled Xdebug <<<
"@
$ini = $ini.TrimEnd("`r", "`n") + "`r`n" + $xdebugBlock

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($iniPath, $ini, $utf8NoBom)

# ---------------------------------------------------------------------------
# 4b. Smoke test: the staged runtime must start, see Xdebug, and the bundled
#     nilpack.phar must execute through php.exe.
# ---------------------------------------------------------------------------
Write-Step 'Smoke testing staged runtime'
$phpExe = Join-Path $StageDir 'php.exe'
$phpVerOut = (& $phpExe -v 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or $phpVerOut -notmatch 'PHP 8\.5') {
    throw "Staged php.exe -v failed: $phpVerOut"
}
if ($phpVerOut -notmatch 'Xdebug v') { throw 'Xdebug not loaded in staged runtime' }
# APCu must be loaded, and must stay off in CLI by default (apc.enable_cli=0).
$apcuOut = (& $phpExe -r "echo extension_loaded('apcu') ? 'LOADED' : 'MISSING', '/', (apcu_enabled() ? 'CLI-ON' : 'CLI-OFF');" 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or $apcuOut -notmatch 'LOADED/CLI-OFF') {
    throw "APCu not loaded (or unexpectedly enabled in CLI): $apcuOut"
}
# Explicitly enabling APCu for a CLI run must actually work, which proves the
# bundled php_apcu.dll is functional (store/fetch round-trip).
$apcuOnOut = (& $phpExe -d apc.enable_cli=1 -r "echo (apcu_store('k', 42) && apcu_fetch('k') === 42) ? 'APCU-OK' : 'APCU-FAIL';" 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or $apcuOnOut -notmatch 'APCU-OK') {
    throw "APCu failed to store/fetch when explicitly enabled: $apcuOnOut"
}
Write-Host "  APCu $ApcuVersion loaded (CLI off by default, works with -d apc.enable_cli=1)"
$tzOut = (& $phpExe -r "echo date_default_timezone_get();" 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or $tzOut -notmatch 'Asia/Shanghai') {
    throw "date.timezone not applied in staged runtime: $tzOut"
}
Write-Host '  date.timezone = Asia/Shanghai'
$nilVerOut = (& $phpExe $nilPhar --version 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or $nilVerOut -notmatch 'Nil Pack Tool') {
    throw "nilpack.phar smoke test failed: $nilVerOut"
}
Write-Host "  $($nilVerOut.Split("`n")[0].Trim()) runs via php.exe"
# Composer writes an informational "PHP version ..." line to stderr; under
# $ErrorActionPreference='Stop' PS 5.1 turns any native stderr output into a
# terminating NativeCommandError. Relax EAP just for this call.
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$composerVerOut = (& $phpExe $composerPhar --version --no-ansi 2>&1) -join "`n"
$composerExit = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($composerExit -ne 0 -or $composerVerOut -notmatch 'Composer version') {
    throw "composer.phar smoke test failed: $composerVerOut"
}
# The exact Composer version is only known after it ran.
if ($composerVerOut -match 'Composer version (\d+\.\d+\.\d+)') {
    $ComposerVersion = $matches[1]
}
Write-Host "  Composer $ComposerVersion runs via php.exe"

# ---------------------------------------------------------------------------
# 5. Compile installer
# ---------------------------------------------------------------------------
$SetupName = "php-$PhpVersion-setup-x64"
$SetupExe  = Join-Path $OutDir "$SetupName.exe"

if (-not $SkipCompile) {
    Write-Step 'Locating Inno Setup compiler (ISCC.exe)'
    $iscc = @(
        $(if ($env:ISCC) { $env:ISCC }),
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe'
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $iscc) {
        $cmd = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
        if ($cmd) { $iscc = $cmd.Source }
    }
    if (-not $iscc) { throw 'ISCC.exe not found. Install Inno Setup 6 (choco install innosetup) or use -SkipCompile.' }
    Write-Host "  $iscc"

    Write-Step 'Compiling installer'
    & $iscc (Join-Path $ScriptDir 'setup.iss') /Q `
        "/DMyAppVersion=$PhpVersion" `
        "/DMyAppVersionInfo=$PhpVersionInfo" `
        "/DXdebugVersion=$XdebugVersion" `
        "/DStageDir=$StageDir" `
        "/DOutputDir=$OutDir" `
        "/DOutputBaseFilename=$SetupName"
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }
}
else {
    Write-Step 'Skipping installer compilation (-SkipCompile)'
}

# ---------------------------------------------------------------------------
# 6. Metadata / release notes / GitHub outputs
# ---------------------------------------------------------------------------
$buildInfo = [ordered]@{
    package        = 'php'
    phpVersion     = $PhpVersion
    phpAsset       = $PhpZipName
    phpUrl         = "$PhpBaseUrl/$PhpZipName"
    xdebugVersion  = $XdebugVersion
    xdebugAsset    = $XdebugAsset
    xdebugUrl      = "$XdebugBaseUrl/$XdebugVersion/$XdebugAsset"
    apcuVersion    = $ApcuVersion
    apcuAsset      = $ApcuAsset
    apcuUrl        = "$ApcuBaseUrl/$ApcuVersion/$ApcuAsset"
    cacertUrl      = $CaCertUrl
    nilpackVersion = $NilpackVersion
    nilpackUrl     = $NilpackUrl
    composerVersion = $ComposerVersion
    composerUrl    = "$ComposerBaseUrl/composer-stable.phar"
    vcRedistVersion = $VcRedistVersion
    vcRedistUrl    = $VcRedistUrl
    vcRuntimeDlls  = $VcRuntimeDlls
    defaultPath    = 'C:\pf\php-8.5'
    commands       = @('php', 'composer', 'nil')
    builtAt        = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
if (-not $SkipCompile) {
    $hash = (Get-FileHash -Algorithm SHA256 $SetupExe).Hash.ToLower()
    $buildInfo['file'] = "$SetupName.exe"
    $buildInfo['size'] = (Get-Item $SetupExe).Length
    $buildInfo['sha256'] = $hash
    "$hash  $SetupName.exe" | Out-File -Encoding ascii (Join-Path $OutDir "$SetupName.exe.sha256.txt")
}
$buildInfo | ConvertTo-Json -Depth 4 |
    ForEach-Object { [IO.File]::WriteAllText((Join-Path $OutDir 'build-info.json'), $_, $utf8NoBom) }

if (-not $SkipCompile) {
    $notes = @"
# PHP $PhpVersion Windows x64 一键安装包

## 组件版本

| 组件 | 版本 / 来源 |
| --- | --- |
| PHP | $PhpVersion（NTS / VS17 / x64，windows.php.net 官方包） |
| Xdebug | $XdebugVersion（ext\php_xdebug.dll，PHP 8.5 NTS VS17 x64） |
| APCu | $ApcuVersion（ext\php_apcu.dll，PHP 8.5 NTS VS17 x64，默认开启） |
| nilpack | v$NilpackVersion（nilpack.phar，``nil`` 命令） |
| Composer | $ComposerVersion（composer.phar，``composer`` 命令，getcomposer.org 官方） |
| CA 证书 | curl.se 官方 cacert.pem |
| VC++ 运行库 | $VcRedistVersion（app-local：7 个 CRT DLL 源自官方 vc_redist.x64.exe，释放到安装目录） |

## 默认行为

- 默认安装（解压）目录：``C:\pf\php-8.5``（安装向导中可修改）
- 安装后自动将安装目录加入系统 PATH，新开命令行可直接使用 ``php`` 与 ``nil`` 命令
- 配置文件：基于官方 ``php.ini-development`` 生成的 ``php.ini``
- 默认开启扩展：curl、fileinfo、exif、gd、intl、mbstring、openssl、pdo_pgsql、pdo_sqlite、sodium、sockets、sqlite3、zip
- APCu：默认开启（``extension=apcu``，``apc.enabled=1``、``apc.shm_size=32M``）；``apc.enable_cli=0`` 保持上游默认，CLI 下 ``apcu_*`` 函数默认不生效，需要时用 ``-d apc.enable_cli=1`` 单次开启
- 默认时区：``date.timezone = Asia/Shanghai``
- 默认不启用 MySQL 相关扩展（mysqli、pdo_mysql，php.ini 中已显式注释，需要时取消注释即可）
- Xdebug：``zend_extension=xdebug``，``xdebug.mode=develop,debug,coverage``，监听 ``127.0.0.1:9003``
- ``curl.cainfo`` / ``openssl.cafile`` 指向包内 ``cacert.pem``（安装后按实际目录自动改写）
- ``nil`` 命令：由包内 ``nil.bat`` 包装器以同目录 ``php.exe`` 运行 ``nilpack.phar``，用法如 ``nil list``、``nil phar``、``nil composer``
- ``composer`` 命令：由包内 ``composer.bat`` 包装器以同目录 ``php.exe`` 运行 ``composer.phar``（getcomposer.org 官方最新稳定版），新开命令行直接可用
- 内置 VC++ 2015-2022 运行库（vcruntime140 / msvcp140 等 7 个 DLL，app-local 随包释放）：未安装系统级 VC 运行库的干净 Windows 10+ 机器上 ``php`` 也可直接运行

## 校验

SHA-256（$SetupName.exe）：

``$hash``
"@
    # WriteAllText with UTF8(no BOM): Out-File -Encoding utf8 in PS 5.1 emits
    # a BOM, which GitHub renders as a stray character at the top of the body.
    [IO.File]::WriteAllText((Join-Path $OutDir 'release-notes.md'), $notes, $utf8NoBom)
}

if ($env:GITHUB_OUTPUT) {
    "php_version=$PhpVersion"       | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
    "xdebug_version=$XdebugVersion" | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
    "apcu_version=$ApcuVersion"     | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
    "composer_version=$ComposerVersion" | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
    "setup_name=$SetupName.exe"     | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
}

Write-Step 'Done'
if (-not $SkipCompile) {
    Write-Host "  Installer : $SetupExe"
    Write-Host "  SHA-256   : $hash"
}
else {
    Write-Host "  Staging   : $StageDir"
}
