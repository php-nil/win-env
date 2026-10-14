<#
.SYNOPSIS
    Build the PHP 8.5 one-click installer for Windows (x64, NTS, VS17).

.DESCRIPTION
    - Resolves the latest PHP 8.5.x / compatible Xdebug release from the
      official windows.php.net listings (no hardcoded patch versions).
    - Downloads the official PHP binary zip, Xdebug zip and cacert.pem.
    - Stages a runtime tree: php.ini is generated from php.ini-development,
      common development extensions are enabled, Xdebug is registered and
      curl.cainfo / openssl.cafile point at the bundled cacert.pem via the
      __APP_DIR__ placeholder (replaced by the installer with the real dir).
    - Compiles an Inno Setup installer which installs to C:\pf\php-8.5
      by default.

.PARAMETER PhpVersion
    Exact PHP 8.5 patch version, e.g. 8.5.11. Empty = latest published 8.5.x.

.PARAMETER XdebugVersion
    Exact Xdebug version, e.g. 3.5.3. Empty = latest release that ships a
    PHP 8.5 / NTS / VS17 / x64 build.

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
    [string]$XdebugVersion = '',
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
$StageDir  = Join-Path $BuildDir 'stage'
$OutDir    = Join-Path $BuildDir 'output'

$PhpBaseUrl    = 'https://windows.php.net/downloads/releases'
$XdebugBaseUrl = 'https://windows.php.net/downloads/pecl/releases/xdebug'
$CaCertUrl     = 'https://curl.se/ca/cacert.pem'
$NilpackUrl    = "https://github.com/php-nil/nilpack/releases/download/v$NilpackVersion/nilpack.phar"

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

function Download-File([string]$url, [string]$dest) {
    # Reuse a previously downloaded, non-empty cache file.
    if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) {
        Write-Host "  cached: $dest"
        return
    }
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
    return $v -match '^\d+\.\d+\.\d+$'
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
    $PhpVersion = $hrefs |
        ForEach-Object {
            if ($_ -match 'php-(8\.5\.\d+)-nts-Win32-vs17-x64\.zip$') { $matches[1] }
        } |
        Sort-Object -Unique { [version]$_ } |
        Select-Object -Last 1
    if (-not $PhpVersion) { throw 'Could not resolve latest PHP 8.5.x from windows.php.net' }
}
$PhpZipName = "php-$PhpVersion-nts-Win32-vs17-x64.zip"
Write-Host "  PHP version : $PhpVersion"
Write-Host "  PHP package : $PhpZipName"

Write-Step 'Resolving Xdebug release'
if ($XdebugVersion) {
    if (-not (Test-VersionString $XdebugVersion)) { throw "Invalid -XdebugVersion: $XdebugVersion" }
    $xdHrefs = Get-LinkHrefs "$XdebugBaseUrl/$XdebugVersion/"
    $XdebugAsset = $xdHrefs |
        Where-Object { $_ -eq "php_xdebug-$XdebugVersion-8.5-nts-vs17-x64.zip" } |
        Select-Object -First 1
    if (-not $XdebugAsset) {
        throw "Xdebug $XdebugVersion does not provide a PHP 8.5 NTS VS17 x64 build"
    }
}
else {
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
}
Write-Host "  Xdebug version: $XdebugVersion"
Write-Host "  Xdebug asset  : $XdebugAsset"

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

Write-Step 'Downloading cacert.pem'
$caPem = Join-Path $CacheDir 'cacert.pem'
Download-File $CaCertUrl $caPem

Write-Step "Downloading nilpack v$NilpackVersion (nil command)"
$nilPharCache = Join-Path $CacheDir 'nilpack.phar'
Download-File $NilpackUrl $nilPharCache

# ---------------------------------------------------------------------------
# 3. Assemble staging tree (root of StageDir == C:\pf\php-8.5 at install time)
# ---------------------------------------------------------------------------
Write-Step 'Extracting PHP'
[System.IO.Compression.ZipFile]::ExtractToDirectory($phpZip, $StageDir)

Write-Step 'Installing php_xdebug.dll into ext\'
$extDir = Join-Path $StageDir 'ext'
$zip = [System.IO.Compression.ZipFile]::OpenRead($xdZip)
try {
    $entry = $zip.Entries | Where-Object { $_.FullName -eq 'php_xdebug.dll' } | Select-Object -First 1
    if (-not $entry) { throw 'php_xdebug.dll not found inside Xdebug archive' }
    $target = Join-Path $extDir 'php_xdebug.dll'
    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
}
finally { $zip.Dispose() }

Write-Step 'Installing cacert.pem'
Copy-Item -Force $caPem (Join-Path $StageDir 'cacert.pem')

Write-Step 'Installing nilpack.phar and the nil command shim'
$nilPhar = Join-Path $StageDir 'nilpack.phar'
Copy-Item -Force $nilPharCache $nilPhar
# nil.bat resolves php.exe / nilpack.phar next to itself (%~dp0), so the
# shim works regardless of the caller's working directory. Being in {app}
# (which is added to PATH at install time) makes the bare `nil` command work.
$nilBat = Join-Path $StageDir 'nil.bat'
$batLines = @(
    '@echo off',
    'rem nil - Nil Pack Tool launcher (generated by win-env)',
    '"%~dp0php.exe" "%~dp0nilpack.phar" %*'
)
[IO.File]::WriteAllText($nilBat, ($batLines -join "`r`n") + "`r`n",
    (New-Object System.Text.ASCIIEncoding))

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
$nilVerOut = (& $phpExe $nilPhar --version 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or $nilVerOut -notmatch 'Nil Pack Tool') {
    throw "nilpack.phar smoke test failed: $nilVerOut"
}
Write-Host "  $($nilVerOut.Split("`n")[0].Trim()) runs via php.exe"

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
    cacertUrl      = $CaCertUrl
    nilpackVersion = $NilpackVersion
    nilpackUrl     = $NilpackUrl
    defaultPath    = 'C:\pf\php-8.5'
    commands       = @('php', 'nil')
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
| nilpack | v$NilpackVersion（nilpack.phar，``nil`` 命令） |
| CA 证书 | curl.se 官方 cacert.pem |

## 默认行为

- 默认安装（解压）目录：``C:\pf\php-8.5``（安装向导中可修改）
- 安装后自动将安装目录加入系统 PATH，新开命令行可直接使用 ``php`` 与 ``nil`` 命令
- 配置文件：基于官方 ``php.ini-development`` 生成的 ``php.ini``
- 默认开启扩展：curl、fileinfo、exif、gd、intl、mbstring、openssl、pdo_pgsql、pdo_sqlite、sodium、sockets、sqlite3、zip
- 默认不启用 MySQL 相关扩展（mysqli、pdo_mysql，php.ini 中已显式注释，需要时取消注释即可）
- Xdebug：``zend_extension=xdebug``，``xdebug.mode=develop,debug,coverage``，监听 ``127.0.0.1:9003``
- ``curl.cainfo`` / ``openssl.cafile`` 指向包内 ``cacert.pem``（安装后按实际目录自动改写）
- ``nil`` 命令：由包内 ``nil.bat`` 包装器以同目录 ``php.exe`` 运行 ``nilpack.phar``，用法如 ``nil list``、``nil phar``、``nil composer``

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
