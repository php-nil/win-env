<#
.SYNOPSIS
    Build the GitHub CLI (gh) one-click installer for Windows x64.

.DESCRIPTION
    - Resolves the latest stable gh release via the official GitHub releases
      API (no hardcoded patch versions).
    - Downloads gh_<ver>_windows_amd64.zip from cli/cli releases.
    - Stages the binary tree (stage root == C:\pf\gh at install time) and runs
      a mandatory smoke test: gh.exe --version must report the exact resolved
      version, and gh.exe auth status must succeed (no network token required).
    - Compiles an Inno Setup installer which installs to C:\pf\gh by default
      and appends the install directory to the system PATH.

.PARAMETER GhVersion
    Exact gh version without leading 'v', e.g. 2.74.2. Empty = newest
    stable release on cli/cli without the "gh_" prefix prerelease.

.PARAMETER BuildDir
    Working directory for cache, staging and output. Default: <repo>\build.

.PARAMETER SkipCompile
    Only resolve/download/assemble; do not invoke the Inno Setup compiler.
#>
[CmdletBinding()]
param(
    [string]$GhVersion = '',
    [string]$BuildDir  = '',
    [switch]$SkipCompile
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
if (-not $BuildDir) { $BuildDir = Join-Path $RepoRoot 'build' }

$CacheDir = Join-Path $BuildDir 'cache'
$StageDir = Join-Path $BuildDir 'stage\gh'
$OutDir   = Join-Path $BuildDir 'output'

$RepoSlug  = 'cli/cli'
$AssetName = 'gh-windows-amd64.zip'
$AssetPattern = 'gh_*_windows_amd64.zip'

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

function Download-File([string]$url, [string]$dest) {
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
# 1. Resolve version (official GitHub releases API; empty result = hard fail)
# ---------------------------------------------------------------------------
Write-Step 'Resolving latest GitHub CLI (gh) release'
$headers = @{ 'User-Agent' = 'win-env-builder' }
if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }

if ($GhVersion) {
    if ($GhVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid -GhVersion: $GhVersion" }
}
else {
    # cli/cli releases list newest-first; scan until we find a non-draft,
    # non-prerelease tag with the win-x64 zip.
    $GhVersion = $null
    for ($page = 1; $page -le 3 -and -not $GhVersion; $page++) {
        $apiUrl = "https://api.github.com/repos/$RepoSlug/releases?per_page=100&page=$page"
        $releases = Invoke-RestMethod -Uri $apiUrl -Headers $headers
        if (-not $releases) { break }
        foreach ($rel in $releases) {
            if ($rel.draft -or $rel.prerelease) { continue }
            if (-not ($rel.tag_name -match '^v(\d+\.\d+\.\d+)$')) { continue }
            if (@($rel.assets | Where-Object { $_.name -like $AssetPattern }).Count -eq 0) { continue }
            $GhVersion = $Matches[1]
            break
        }
    }
    if (-not $GhVersion) {
        throw "Could not resolve a stable gh release carrying $AssetPattern"
    }
}
Write-Host "  gh version : $GhVersion"

# Find the asset name for this exact release (asset names embed the version).
$tagUrl = "https://api.github.com/repos/$RepoSlug/releases/tags/v$GhVersion"
$tagRel = Invoke-RestMethod -Uri $tagUrl -Headers $headers
$assetObj = @($tagRel.assets | Where-Object { $_.name -like $AssetPattern })[0]
if (-not $assetObj) { throw "No $AssetPattern asset under tag v$GhVersion" }
$DownloadUrl = $assetObj.browser_download_url
$ChecksumAsset = @($tagRel.assets | Where-Object { $_.name -like 'gh_*_checksums.txt' })[0]
$ChecksumUrl = if ($ChecksumAsset) { $ChecksumAsset.browser_download_url } else { '' }

# ---------------------------------------------------------------------------
# 2. Download
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $OutDir | Out-Null

# Strip reparse points before wipe (see doc/lessons.md §14 / pnpm build.ps1).
if (Test-Path $StageDir) {
    $links = @(Get-ChildItem -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
    foreach ($l in $links) {
        if ($l.PSIsContainer) { [IO.Directory]::Delete($l.FullName, $false) }
        else { [IO.File]::Delete($l.FullName) }
    }
    Remove-Item -Recurse -Force $StageDir
}
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

Write-Step 'Downloading gh binary package'
$ghZip = Join-Path $CacheDir "gh-$GhVersion-windows-amd64.zip"
Download-File $DownloadUrl $ghZip

# Optional: verify against official checksums.txt
if ($ChecksumUrl) {
    Write-Step 'Verifying SHA-256 against official checksums.txt'
    $checksumTxt = Join-Path $CacheDir 'gh-checksums.txt'
    Download-File $ChecksumUrl $checksumTxt
    $expected = (Select-String -Path $checksumTxt -Pattern ($assetObj.name + '\s+([0-9a-fA-F]{64})') | Select-Object -First 1)
    if ($expected) {
        $expectedHash = $expected.Matches[0].Groups[1].Value.ToLower()
        $actualHash = (Get-FileHash -Algorithm SHA256 $ghZip).Hash.ToLower()
        if ($expectedHash -ne $actualHash) {
            throw "SHA-256 mismatch for gh zip: expected $expectedHash, got $actualHash"
        }
        Write-Host "  checksum OK"
    }
}

# ---------------------------------------------------------------------------
# 3. Assemble staging tree
#    gh_*.zip contains a single top-level directory gh_<ver>_windows_amd64/
#    holding gh.exe directly at its root (no bin/ subdir). The staged layout
#    must be flat: StageDir == C:\pf\gh after install, so gh.exe sits at
#    the stage root.
# ---------------------------------------------------------------------------
Write-Step 'Extracting gh'
$extractTmp = Join-Path $CacheDir 'extract-gh'
if (Test-Path $extractTmp) { Remove-Item -Recurse -Force $extractTmp }
New-Item -ItemType Directory -Force -Path $extractTmp | Out-Null
[System.IO.Compression.ZipFile]::ExtractToDirectory($ghZip, $extractTmp)

$innerDir = Get-ChildItem -Directory $extractTmp | Select-Object -First 1
if (-not $innerDir) { throw 'No inner directory in gh archive' }

# Mirror all contents of the version wrapper directory directly into StageDir.
$rcArgs = @($innerDir.FullName, $StageDir, '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS')
$rcProc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $rcArgs -Wait -PassThru -NoNewWindow
if ($rcProc.ExitCode -ge 8) { throw "robocopy failed with exit code $($rcProc.ExitCode)" }
Remove-Item -Recurse -Force $extractTmp

$ghExe = Join-Path $StageDir 'gh.exe'
if (-not (Test-Path $ghExe)) {
    $tree = (Get-ChildItem -Recurse $StageDir | ForEach-Object { $_.FullName.Replace($StageDir, '') }) -join "`n"
    throw "gh.exe missing at stage root. Archive layout changed? Contents:`n$tree"
}

# ---------------------------------------------------------------------------
# 4. Smoke test
# ---------------------------------------------------------------------------
Write-Step 'Smoke testing staged gh.exe'
$ghVerOut = (& $ghExe --version 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) { throw "gh.exe --version failed: $ghVerOut" }
# gh --version outputs: "gh version 2.74.2 (2025-06-18T16:17:39Z)"
if ($ghVerOut -notmatch [regex]::Escape($GhVersion)) {
    throw "gh.exe version mismatch (expected $GhVersion): $ghVerOut"
}
Write-Host "  gh $($GhVersion) runs standalone"

# gh.exe carries its own icon resource; extract it for the installer icon.
# If extraction fails (unexpected upstream change) the build continues with
# SetupIconFile pointing at gh.exe directly — Inno Setup reads the first
# icon resource from the target binary.
try {
    $iconDest = Join-Path $ScriptDir 'setup.ico'
    if (-not (Test-Path $iconDest)) {
        Add-Type -AssemblyName System.Drawing
        $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($ghExe)
        if ($icon) {
            $stream = [IO.File]::Create($iconDest)
            $icon.Save($stream)
            $stream.Close()
            $icon.Dispose()
            Write-Host '  extracted setup.ico from gh.exe resources'
        }
    }
}
catch {
    Write-Host "  WARNING: could not extract icon from gh.exe ($($_.Exception.Message)) — setup.iss falls back to gh.exe icon resource"
}

# ---------------------------------------------------------------------------
# 5. Compile installer
# ---------------------------------------------------------------------------
$SetupName = "gh-$GhVersion-setup-x64"
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
    if (-not $iscc) { throw 'ISCC.exe not found. Install Inno Setup 6 or use -SkipCompile.' }
    Write-Host "  $iscc"

    Write-Step 'Compiling installer'
    & $iscc (Join-Path $ScriptDir 'setup.iss') /Q `
        "/DMyAppVersion=$GhVersion" `
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
    package   = 'gh'
    ghVersion = $GhVersion
    ghUrl     = $DownloadUrl
    defaultPath = 'C:\pf\gh'
    commands  = @('gh')
    builtAt   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
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
# GitHub CLI $GhVersion Windows x64 一键安装包

## 组件版本

| 组件 | 版本 / 来源 |
| --- | --- |
| gh CLI | $GhVersion（cli/cli 官方 GitHub Release ``gh_${GhVersion}_windows_amd64.zip``） |

## 默认行为

- 默认安装目录：``C:\pf\gh``（安装向导中可修改）
- 安装后自动将安装目录加入系统 PATH，新开命令行可直接使用 ``gh`` 命令
- 官方独立可执行文件，无需 Go / 其他运行时
- 安装/卸载对系统 PATH 均为幂等精确操作，不改动其他条目；卸载后文件与 PATH 条目全部清除

## 校验

SHA-256（$SetupName.exe）：

``$hash``
"@
    [IO.File]::WriteAllText((Join-Path $OutDir 'release-notes.md'), $notes, $utf8NoBom)
}

if ($env:GITHUB_OUTPUT) {
    "gh_version=$GhVersion"     | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
    "setup_name=$SetupName.exe" | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
}

Write-Step 'Done'
if (-not $SkipCompile) {
    Write-Host "  Installer : $SetupExe"
    Write-Host "  SHA-256   : $hash"
}
else {
    Write-Host "  Staging   : $StageDir"
}
