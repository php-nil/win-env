<#
.SYNOPSIS
    Build the pnpm one-click installer for Windows x64 (standalone pnpm.exe).

.DESCRIPTION
    - Resolves the latest stable pnpm release on a fixed major track (v12)
      that ships pnpm-win32-x64.zip, via the official GitHub releases API
      (no hardcoded patch versions).
    - Downloads the official pnpm-win32-x64.zip archive. pnpm.exe is a
      standalone single-executable application with the Node.js runtime
      embedded, so no system Node.js is required at runtime.
    - Stages the binary tree (stage root == C:\pf\pnpm at install time) and
      runs a mandatory smoke test: pnpm.exe --version must report the exact
      resolved version.
    - Compiles an Inno Setup installer which installs to C:\pf\pnpm by
      default and appends the install directory to the system PATH.

.PARAMETER PnpmVersion
    Exact pnpm version without leading 'v', e.g. 12.11.2. Empty = newest
    stable v<MajorTrack>.x.y release carrying pnpm-win32-x64.zip.

.PARAMETER MajorTrack
    Major version track used by auto-discovery. Default: 12.

.PARAMETER BuildDir
    Working directory for cache, staging and output. Default: <repo>\build.

.PARAMETER SkipCompile
    Only resolve/download/assemble; do not invoke the Inno Setup compiler.
#>
[CmdletBinding()]
param(
    [string]$PnpmVersion = '',
    [string]$MajorTrack = '12',
    [string]$BuildDir = '',
    [switch]$SkipCompile
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
if (-not $BuildDir) { $BuildDir = Join-Path $RepoRoot 'build' }

$CacheDir = Join-Path $BuildDir 'cache'
$StageDir = Join-Path $BuildDir 'stage\pnpm'
$OutDir   = Join-Path $BuildDir 'output'

$RepoSlug  = 'pnpm/pnpm'
$AssetName = 'pnpm-win32-x64.zip'

# Accept a string from the workflow input (which may be empty); validate into
# a positive integer, defaulting an empty value back to track 12.
$trackNum = 0
if ([string]::IsNullOrWhiteSpace($MajorTrack)) { $trackNum = 12 }
elseif (-not [int]::TryParse($MajorTrack.Trim(), [ref]$trackNum) -or $trackNum -le 0) {
    throw "Invalid -MajorTrack: $MajorTrack"
}
$MajorTrack = $trackNum

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

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
# 1. Resolve version (official GitHub releases API; empty result = hard fail)
# ---------------------------------------------------------------------------
Write-Step "Resolving pnpm v$MajorTrack.x release"
if ($PnpmVersion) {
    if (-not (Test-VersionString $PnpmVersion)) { throw "Invalid -PnpmVersion: $PnpmVersion" }
}
else {
    # Releases are listed newest-first; scan the first few pages and keep the
    # highest stable v<major>.<minor>.<patch> tag that carries the win-x64 zip.
    $headers = @{ 'User-Agent' = 'win-env-builder' }
    # On GitHub Actions the injected GITHUB_TOKEN lifts the unauthenticated
    # 60 req/h shared-IP rate limit to 1000 req/h; locally the header is absent.
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
    $tagPattern = '^v' + $MajorTrack + '\.\d+\.\d+$'
    $PnpmVersion = $null
    for ($page = 1; $page -le 3 -and -not $PnpmVersion; $page++) {
        $apiUrl = "https://api.github.com/repos/$RepoSlug/releases?per_page=100&page=$page"
        $releases = Invoke-RestMethod -Uri $apiUrl -Headers $headers
        if (-not $releases) { break }
        $PnpmVersion = @($releases |
            Where-Object {
                (-not $_.prerelease) -and (-not $_.draft) -and
                ($_.tag_name -match $tagPattern) -and
                @($_.assets | Where-Object { $_.name -eq $AssetName }).Count -gt 0
            } |
            ForEach-Object { $_.tag_name.TrimStart('v') } |
            Sort-Object -Unique { [version]$_ } |
            Select-Object -Last 1)
    }
    if (-not $PnpmVersion) {
        throw "Could not resolve a stable pnpm v$MajorTrack.x release carrying $AssetName"
    }
}
$DownloadUrl = "https://github.com/$RepoSlug/releases/download/v$PnpmVersion/$AssetName"
Write-Host "  pnpm version : $PnpmVersion"
Write-Host "  pnpm asset   : $AssetName"

# ---------------------------------------------------------------------------
# 2. Download
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $OutDir | Out-Null
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

Write-Step 'Downloading pnpm binary package'
$pnpmZip = Join-Path $CacheDir "pnpm-win-x64-$PnpmVersion.zip"
Download-File $DownloadUrl $pnpmZip

# ---------------------------------------------------------------------------
# 3. Assemble staging tree (root of StageDir == C:\pf\pnpm at install time)
# ---------------------------------------------------------------------------
Write-Step 'Extracting pnpm'
[System.IO.Compression.ZipFile]::ExtractToDirectory($pnpmZip, $StageDir)

$pnpmExe = Join-Path $StageDir 'pnpm.exe'
if (-not (Test-Path $pnpmExe)) {
    $tree = (Get-ChildItem -Recurse $StageDir | ForEach-Object { $_.FullName }) -join "`n"
    throw "pnpm.exe missing at stage root. Archive contents:`n$tree"
}

# The official archive also ships dist\node-gyp-bin + dist\node_modules:
# pnpm spawns that bundled node-gyp when installing packages with native
# addons. --version alone would pass even if upstream changed this layout.
if (-not (Test-Path (Join-Path $StageDir 'dist\node-gyp-bin'))) {
    $tree = (Get-ChildItem -Recurse $StageDir | ForEach-Object { $_.FullName }) -join "`n"
    throw "Official layout changed: dist\node-gyp-bin missing. Archive contents:`n$tree"
}

# ---------------------------------------------------------------------------
# 4. Smoke test: the staged standalone executable must run and report the
#    exact packaged version (Node.js runtime is embedded).
# ---------------------------------------------------------------------------
Write-Step 'Smoke testing staged pnpm.exe'
$pnpmVerOut = (& $pnpmExe --version 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0 -or ($pnpmVerOut.Trim() -ne $PnpmVersion)) {
    throw "Staged pnpm.exe --version failed (expected $PnpmVersion): $pnpmVerOut"
}
Write-Host "  pnpm $($pnpmVerOut.Trim()) runs standalone"

# ---------------------------------------------------------------------------
# 5. Compile installer
# ---------------------------------------------------------------------------
$SetupName = "pnpm-$PnpmVersion-setup-x64"
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
        "/DMyAppVersion=$PnpmVersion" `
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
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$buildInfo = [ordered]@{
    package     = 'pnpm'
    pnpmVersion = $PnpmVersion
    pnpmAsset   = $AssetName
    pnpmUrl     = $DownloadUrl
    defaultPath = 'C:\pf\pnpm'
    commands    = @('pnpm')
    builtAt     = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
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
# pnpm $PnpmVersion Windows x64 一键安装包

## 组件版本

| 组件 | 版本 / 来源 |
| --- | --- |
| pnpm | $PnpmVersion（standalone ``pnpm.exe``，pnpm 官方 GitHub Release ``pnpm-win32-x64.zip``） |

## 默认行为

- 默认安装（解压）目录：``C:\pf\pnpm``（安装向导中可修改）
- 安装后自动将安装目录加入系统 PATH，新开命令行可直接使用 ``pnpm`` 命令
- ``pnpm.exe`` 为官方独立可执行文件（Node.js 运行时已内置），无需预装 Node.js
- 安装/卸载对系统 PATH 均为幂等精确操作，不改动其他条目；卸载后文件与 PATH 条目全部清除

## 校验

SHA-256（$SetupName.exe）：

``$hash``
"@
    # WriteAllText with UTF8(no BOM): Out-File -Encoding utf8 in PS 5.1 emits
    # a BOM, which GitHub renders as a stray character at the top of the body.
    [IO.File]::WriteAllText((Join-Path $OutDir 'release-notes.md'), $notes, $utf8NoBom)
}

if ($env:GITHUB_OUTPUT) {
    "pnpm_version=$PnpmVersion"   | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
    "setup_name=$SetupName.exe"   | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
}

Write-Step 'Done'
if (-not $SkipCompile) {
    Write-Host "  Installer : $SetupExe"
    Write-Host "  SHA-256   : $hash"
}
else {
    Write-Host "  Staging   : $StageDir"
}
