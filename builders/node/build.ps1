<#
.SYNOPSIS
    Build the Node.js LTS one-click installer for Windows x64.

.DESCRIPTION
    - Resolves the latest LTS release via the official nodejs.org/dist/index.json
      (no hardcoded patch versions). Optionally pinned to an exact version or a
      major track.
    - Downloads the official node-v<VER>-win-x64.zip and stages the binary tree.
      The staged root equals C:\pf\node after install.
    - Runs mandatory smoke tests: staged node.exe must report the exact packaged
      version, and the bundled npm must match the version recorded in the
      official dist index.
    - Compiles an Inno Setup installer which installs to C:\pf\node by default
      and appends the install dir to the system PATH.

.PARAMETER NodeVersion
    Exact Node.js version without the leading 'v', e.g. 22.20.0.
    Empty = newest LTS release in the official dist index.

.PARAMETER MajorTrack
    Major version track used by auto-discovery, e.g. 22. Empty = any LTS track
    (the newest published LTS release wins). Ignored when -NodeVersion is set.

.PARAMETER BuildDir
    Working directory for cache, staging and output. Default: <repo>\build.

.PARAMETER SkipCompile
    Only resolve/download/assemble; do not invoke the Inno Setup compiler.
#>
[CmdletBinding()]
param(
    [string]$NodeVersion = '',
    [string]$MajorTrack  = '',
    [string]$BuildDir    = '',
    [switch]$SkipCompile
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
if (-not $BuildDir) { $BuildDir = Join-Path $RepoRoot 'build' }

$CacheDir = Join-Path $BuildDir 'cache'
$StageDir = Join-Path $BuildDir 'stage\node'
$OutDir   = Join-Path $BuildDir 'output'

$DistIndexUrl = 'https://nodejs.org/dist/index.json'
$AssetTemplate = 'node-v<VER>-win-x64.zip'

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

# ---------------------------------------------------------------------------
# 1. Resolve version (official nodejs.org dist index; empty result = hard fail)
# ---------------------------------------------------------------------------
Write-Step 'Resolving Node.js release from the official dist index'
if ($NodeVersion) {
    if ($NodeVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid -NodeVersion: $NodeVersion" }
}
else {
    if ($MajorTrack -and ($MajorTrack -notmatch '^\d+$')) { throw "Invalid -MajorTrack: $MajorTrack" }
    $index = Invoke-RestMethod -Uri $DistIndexUrl -ErrorAction Stop
    if (-not $index) { throw "Empty dist index returned by $DistIndexUrl" }
    # Entries are sorted newest-first. lts is a codename string for LTS lines
    # and $false for Current lines, so truthiness selects LTS entries.
    $candidate = @($index | Where-Object {
        $_.lts -and (-not $MajorTrack -or $_.version -match ('^v' + $MajorTrack + '\.'))
    } | Select-Object -First 1)
    if (-not $candidate) {
        $trackNote = if ($MajorTrack) { " on major track v$MajorTrack" } else { '' }
        throw "Could not resolve an LTS release$trackNote from $DistIndexUrl"
    }
    $NodeVersion = $candidate.version.TrimStart('v')
}

$AssetFile = $AssetTemplate -replace '<VER>', $NodeVersion
$DownloadUrl = "https://nodejs.org/dist/v$NodeVersion/$AssetFile"

# The same index doubles as the metadata source: verify the pinned/auto version
# exists and capture the bundled npm version for the smoke assertion.
$entry = $null
try {
    $index = Invoke-RestMethod -Uri $DistIndexUrl -ErrorAction Stop
    $entry = @($index | Where-Object { $_.version -eq "v$NodeVersion" } | Select-Object -First 1)
} catch { }
if (-not $entry) { throw "Version v$NodeVersion not found in $DistIndexUrl" }
$LtsCodename = if ($entry.lts) { [string]$entry.lts } else { '' }
$NpmVersion  = [string]$entry.npm

Write-Host "  Node.js version : $NodeVersion$(if ($LtsCodename) { "  (LTS: $LtsCodename)" } else { '  (Current)' })"
Write-Host "  Bundled npm     : $NpmVersion"
Write-Host "  Package         : $AssetFile"

# ---------------------------------------------------------------------------
# 2. Download + extract
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $OutDir | Out-Null
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

Write-Step 'Downloading Node.js package'
$zipFile = Join-Path $CacheDir $AssetFile
Download-File $DownloadUrl $zipFile

Write-Step 'Extracting Node.js package (zip)'
# tar.exe (ships with Windows 10+) extracts zips an order of magnitude faster
# than Expand-Archive on PS 5.1.
$tar = 'C:\Windows\System32\tar.exe'
if (Test-Path $tar) {
    & $tar -xf $zipFile -C $StageDir
    if ($LASTEXITCODE -ne 0) { throw "tar extraction failed with exit code $LASTEXITCODE" }
}
else {
    Expand-Archive -LiteralPath $zipFile -DestinationPath $StageDir -Force
}

# The archive wraps everything in a single node-v<VER>-win-x64 root folder;
# flatten it so the stage root == install root.
$inner = Join-Path $StageDir "node-v$NodeVersion-win-x64"
if (-not (Test-Path $inner)) {
    $tree = (Get-ChildItem -Force $StageDir | ForEach-Object { $_.Name }) -join ', '
    throw "node-v$NodeVersion-win-x64 root folder missing after extraction. Top-level entries: $tree"
}
Get-ChildItem -Force -LiteralPath $inner | Move-Item -Destination $StageDir -Force
Remove-Item -Recurse -Force -LiteralPath $inner

$nodeExe = Join-Path $StageDir 'node.exe'
$npmCmd  = Join-Path $StageDir 'npm.cmd'
if (-not (Test-Path $nodeExe)) { throw "node.exe missing at stage root after extraction" }
if (-not (Test-Path $npmCmd))  { throw "npm.cmd missing at stage root after extraction" }
if (-not (Test-Path (Join-Path $StageDir 'node_modules\npm\bin\npm-cli.js'))) {
    throw 'Official layout changed: node_modules\npm\bin\npm-cli.js missing at stage root'
}

# ---------------------------------------------------------------------------
# 3. Smoke test (mandatory: staged tree must actually run)
# ---------------------------------------------------------------------------
Write-Step 'Smoke testing staged node.exe / npm.cmd'
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

$nodeOut = (& $nodeExe --version 2>&1) -join "`n"
$nodeCode = $LASTEXITCODE
if ($nodeCode -ne 0 -or ($nodeOut.Trim() -ne "v$NodeVersion")) {
    $ErrorActionPreference = $prevEap
    throw "Staged node.exe version mismatch (expected 'v$NodeVersion'): $nodeOut"
}

$npmOut = (& $npmCmd --version 2>&1) -join "`n"
$npmCode = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($npmCode -ne 0 -or ($npmOut.Trim() -ne $NpmVersion)) {
    throw "Staged npm version mismatch (expected '$NpmVersion' from dist index): $npmOut"
}
Write-Host "  node $($nodeOut.Trim())"
Write-Host "  npm   $($npmOut.Trim())"

# ---------------------------------------------------------------------------
# 4. Compile installer
# ---------------------------------------------------------------------------
$SetupName = "node-$NodeVersion-setup-x64"
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
        "/DMyAppVersion=$NodeVersion" `
        "/DStageDir=$StageDir" `
        "/DOutputDir=$OutDir" `
        "/DOutputBaseFilename=$SetupName"
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }
}
else {
    Write-Step 'Skipping installer compilation (-SkipCompile)'
}

# ---------------------------------------------------------------------------
# 5. Metadata / release notes / GitHub outputs
# ---------------------------------------------------------------------------
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$buildInfo = [ordered]@{
    package     = 'node'
    nodeVersion = $NodeVersion
    ltsCodename = $LtsCodename
    npmVersion  = $NpmVersion
    sourceAsset = $AssetFile
    releaseUrl  = $DownloadUrl
    defaultPath = 'C:\pf\node'
    pathEntries = @('C:\pf\node')
    commands    = @('node', 'npm', 'npx')
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
    $ltsLine = if ($LtsCodename) { "$NodeVersion（LTS ``$LtsCodename``，nodejs.org/dist 官方索引自动发现）" } else { "$NodeVersion（Current，nodejs.org/dist）" }
    $notes = @"
# Node.js $NodeVersion Windows x64 一键安装包

## 组件版本

| 组件 | 版本 / 来源 |
| --- | --- |
| Node.js | $ltsLine |
| npm | $NpmVersion（官方 zip 内置） |

## 默认行为

- 默认安装目录：``C:\pf\node``（安装向导中可修改，不带版本号后缀）
- 安装后自动将安装目录加入系统 PATH，新开命令行可直接使用 ``node``、``npm``、``npx`` 命令
- 安装内容即官方 ``$AssetFile`` 解压后的完整目录树，安装器只做原样释放，不在安装期下载或拼装任何内容
- 安装/卸载对系统 PATH 均为幂等精确操作，不改动其他条目；卸载后文件与 PATH 条目全部清除

## npm 全局数据说明

- ``npm install -g`` 的全局包默认位于 ``%APPDATA%\npm``（用户目录），不在安装目录、也不由本安装器配置 PATH；
  卸载本包不会清除这些用户数据，重装 Node.js 后仍可用。
- 包内自带 corepack；``corepack enable`` 需要写安装目录（默认 ``C:\pf\node``），需管理员终端执行。

## 校验

SHA-256（$SetupName.exe）：

``$hash``
"@
    [IO.File]::WriteAllText((Join-Path $OutDir 'release-notes.md'), $notes, $utf8NoBom)
}

if ($env:GITHUB_OUTPUT) {
    "node_version=$NodeVersion"   | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
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
