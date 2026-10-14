<#
.SYNOPSIS
    Build the Git for Windows one-click installer for Windows x64.

.DESCRIPTION
    - Resolves the latest stable Git for Windows 2.x release that ships
      a 64-bit archive, via the official GitHub releases API (no hardcoded
      patch versions).
    - Downloads the official self-extracting archive and stages the binary
      tree. The staged root equals C:\pf\Git after install.
    - Runs a mandatory smoke test: cmd\git.exe --version must report
      the exact packaged Git version.
    - Compiles an Inno Setup installer which installs to C:\pf\Git by
      default and appends <install>\cmd to the system PATH.

.PARAMETER GitVersion
    Exact Git tag name without the leading 'v', e.g. 2.56.0.windows.2.
    Empty = newest stable v2.x.windows.y release carrying the 64-bit
    archive asset.

.PARAMETER BuildDir
    Working directory for cache, staging and output. Default: <repo>\build.

.PARAMETER SkipCompile
    Only resolve/download/assemble; do not invoke the Inno Setup compiler.
#>
[CmdletBinding()]
param(
    [string]$GitVersion = '',
    [string]$BuildDir   = '',
    [switch]$SkipCompile
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
if (-not $BuildDir) { $BuildDir = Join-Path $RepoRoot 'build' }

$CacheDir = Join-Path $BuildDir 'cache'
$StageDir = Join-Path $BuildDir 'stage\git'
$OutDir   = Join-Path $BuildDir 'output'

$RepoSlug  = 'git-for-windows/git'
# GitHub tag format: v2.56.0.windows.2   ("v" + MAJOR.MINOR.PATCH.windows.BUILD)
$TagPattern = '^v2\.\d+\.\d+\.windows\.\d+$'
# Asset format uses numeric-only segments: PortableGit-2.56.0.2-64-bit.7z.exe
# i.e. strip the literal ".windows." token from the tag body.
$AssetName = 'PortableGit-<VER>-64-bit.7z.exe'

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

function Test-VersionString([string]$v) {
    return $v -match '^\d+\.\d+\.\d+\.windows\.\d+$'
}

function Convert-TagVersionToAssetVersion([string]$tagVer) {
    # tagVer: 2.56.0.windows.2  ->  assetVer: 2.56.0.2
    return ($tagVer -replace '\.windows\.', '.')
}

# ---------------------------------------------------------------------------
# 1. Resolve version (official GitHub releases API; empty result = hard fail)
# ---------------------------------------------------------------------------
Write-Step 'Resolving latest Git for Windows v2.x.windows.y release'
if ($GitVersion) {
    if (-not (Test-VersionString $GitVersion)) { throw "Invalid -GitVersion: $GitVersion (expected e.g. 2.56.0.windows.2)" }
}
else {
    $headers = @{ 'User-Agent' = 'win-env-builder' }
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }

    $candidate = $null
    for ($page = 1; $page -le 3 -and -not $candidate; $page++) {
        $apiUrl = "https://api.github.com/repos/$RepoSlug/releases?per_page=100&page=$page"
        $attempts = 3
        $releases = $null
        for ($a = 1; $a -le $attempts; $a++) {
            try {
                $releases = Invoke-RestMethod -Uri $apiUrl -Headers $headers -ErrorAction Stop
                break
            }
            catch {
                $resp = $_.Exception.Response
                if ($resp -and $resp.StatusCode -eq [System.Net.HttpStatusCode]::Forbidden) {
                    # 403 = rate limit。就算带了 token，同一 runner IP 之前匿名限流
                    # 可能还在窗口内；读 X-RateLimit-Reset 头算等待秒数。
                    $resetHeader = $resp.Headers['X-RateLimit-Reset']
                    $waitSec = 30
                    if ($resetHeader) {
                        try {
                            $resetEpoch = [int64]$resetHeader
                            $epoch = [DateTimeOffset]::new(1970,1,1,[TimeSpan]::Zero,[DateTimeKind]::Utc)
                            $nowEpoch = [int64](([DateTimeOffset]::UtcNow - $epoch).TotalSeconds)
                            $waitSec  = [Math]::Max($waitSec, ($resetEpoch - $nowEpoch))
                        } catch { }
                    }
                    Write-Warning "GitHub API rate-limited (403); waiting ${waitSec}s then retry ($a/$attempts)."
                    Start-Sleep -Seconds $waitSec
                    if ($a -lt $attempts) { continue }
                }
                throw
            }
        }
        if (-not $releases) { break }
        $candidate = @($releases |
            Where-Object {
                (-not $_.prerelease) -and (-not $_.draft) -and
                ($_.tag_name -match $TagPattern) -and
                @($_.assets | Where-Object { $_.name -like 'PortableGit-*-64-bit.7z.exe' }).Count -gt 0
            } |
            Select-Object -First 1)
    }
    if (-not $candidate) {
        throw 'Could not resolve a stable Git for Windows v2.x.windows.y release carrying PortableGit-*-64-bit.7z.exe'
    }
    $GitVersion = $candidate.tag_name.TrimStart('v')
}

$AssetVersion = Convert-TagVersionToAssetVersion $GitVersion
# 真实 GitHub asset 文件名（用于下载 URL 与缓存路径）
$AssetFile    = $AssetName -replace '<VER>', $AssetVersion
# 对外显示名（去掉 "Portable" / ".7z.exe"，build-info / release-notes / 日志 都用这个）
$AssetDisplay = "Git-$AssetVersion-64-bit"
$Tag          = "v$GitVersion"
$DownloadUrl  = "https://github.com/$RepoSlug/releases/download/$Tag/$AssetFile"

Write-Host "  Git version : $GitVersion   (tag: $Tag)"
Write-Host "  Package     : $AssetDisplay"

# ---------------------------------------------------------------------------
# 2. Download + extract
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $OutDir | Out-Null
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

Write-Step 'Downloading Git package'
$gitExe = Join-Path $CacheDir $AssetFile
Download-File $DownloadUrl $gitExe

Write-Step 'Extracting Git package (7z)'
# PortableGit 的 .7z.exe 是 GUI 模块的 7-Zip SFX，直接调用不会返回
# 控制台退出码。用 7z.exe 把它当作普通 .7z 归档解包（7z 同样能读 SFX）。
$sevenZ = @(
    $(if ($env:7Z) { $env:7Z }),
    'C:\Program Files\7-Zip\7z.exe'
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $sevenZ) {
    $cmd = Get-Command '7z.exe' -ErrorAction SilentlyContinue
    if ($cmd) { $sevenZ = $cmd.Source }
}
if (-not $sevenZ) { throw '7z.exe not found. Install 7-Zip (choco install 7zip) or set $env:7Z.' }
Write-Host "  7z: $sevenZ"

& $sevenZ x $gitExe "-o$StageDir" '-y' '-bb0'
if ($LASTEXITCODE -ne 0) {
    throw "7z extraction failed with exit code $LASTEXITCODE"
}

# The archive root IS the Git tree (no top-level subdir like mingw64/).
# Verify key expected paths.
$cmdGit = Join-Path $StageDir 'cmd\git.exe'
$binGit = Join-Path $StageDir 'bin\git.exe'
if (-not ((Test-Path $cmdGit) -or (Test-Path $binGit))) {
    $tree = (Get-ChildItem -Force $StageDir | ForEach-Object { $_.Name }) -join ', '
    throw "git.exe missing after extraction. Top-level entries: $tree"
}

# ---------------------------------------------------------------------------
# 3. Smoke test
# ---------------------------------------------------------------------------
Write-Step 'Smoke testing staged git.exe'
$gitBin = if (Test-Path $cmdGit) { $cmdGit } else { $binGit }
$gitVerOut = (& $gitBin --version 2>&1) -join "`n"
$expected  = "git version $GitVersion"
if ($LASTEXITCODE -ne 0 -or ($gitVerOut.Trim() -ne $expected)) {
    throw "Staged git.exe --version mismatch (expected '$expected'): $gitVerOut"
}
Write-Host "  $($gitVerOut.Trim())"

# ---------------------------------------------------------------------------
# 4. Compile installer
# ---------------------------------------------------------------------------
$SetupName = "Git-$GitVersion-setup-x64"
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
        "/DMyAppVersion=$GitVersion" `
        "/DMyAppNumericVersion=$AssetVersion" `
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
    package      = 'git'
    gitVersion   = $GitVersion
    displayName  = $AssetDisplay
    sourceAsset  = $AssetFile
    gitTag       = $Tag
    gitUrl       = $DownloadUrl
    defaultPath  = 'C:\pf\Git'
    pathEntries  = @('C:\pf\Git\cmd')
    commands     = @('git')
    builtAt      = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
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
# Git for Windows $GitVersion 一键安装包

## 组件版本

| 组件 | 版本 / 来源 |
| --- | --- |
| Git | $GitVersion（``$AssetDisplay``，GitHub Release ``$Tag``） |

## 默认行为

- 默认安装（解压）目录：``C:\pf\Git``（安装向导中可修改）
- 安装后自动将 ``<安装目录>\cmd`` 加入系统 PATH，新开命令行可直接使用 ``git`` 命令
- 本包为完整的 Git for Windows 发行版，包含 ``git-bash``、``ssh``、``bash`` 等附加工具
- 安装/卸载对系统 PATH 均为幂等精确操作，不改动其他条目；卸载后文件与 PATH 条目全部清除

## 校验

SHA-256（$SetupName.exe）：

``$hash``
"@
    [IO.File]::WriteAllText((Join-Path $OutDir 'release-notes.md'), $notes, $utf8NoBom)
}

if ($env:GITHUB_OUTPUT) {
    "git_version=$GitVersion"   | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
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
