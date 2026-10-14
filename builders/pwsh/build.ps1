<#
.SYNOPSIS
    Build the PowerShell 7 one-click installer for Windows x64.

.DESCRIPTION
    - Resolves the latest stable PowerShell v7.6.x release that ships the
      win-x64 zip asset, via the official GitHub releases API (no hardcoded
      patch versions).
    - Downloads the official zip and stages the binary tree. The staged root
      equals C:\pf\PowerShell7 after install.
    - Runs a mandatory smoke test: staged pwsh.exe must report the exact
      packaged version.
    - Compiles an Inno Setup installer which installs to C:\pf\PowerShell7
      by default, appends the install dir to the system PATH, registers an
      "Open PowerShell 7 here" explorer context menu, and drops a Windows
      Terminal fragment so a "PowerShell 7" profile shows up automatically.

.PARAMETER PwshVersion
    Exact PowerShell version without the leading 'v', e.g. 7.6.6.
    Empty = newest stable v7.6.x release carrying PowerShell-*-win-x64.zip.

.PARAMETER BuildDir
    Working directory for cache, staging and output. Default: <repo>\build.

.PARAMETER SkipCompile
    Only resolve/download/assemble; do not invoke the Inno Setup compiler.
#>
[CmdletBinding()]
param(
    [string]$PwshVersion = '',
    [string]$BuildDir    = '',
    [switch]$SkipCompile
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
if (-not $BuildDir) { $BuildDir = Join-Path $RepoRoot 'build' }

$CacheDir = Join-Path $BuildDir 'cache'
$StageDir = Join-Path $BuildDir 'stage\pwsh'
$OutDir   = Join-Path $BuildDir 'output'

$RepoSlug   = 'PowerShell/PowerShell'
# Only the v7.6 LTS line; rc/preview tags carry suffixes and never match.
$TagPattern = '^v7\.6\.\d+$'
$AssetName  = 'PowerShell-<VER>-win-x64.zip'

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
Write-Step 'Resolving latest stable PowerShell v7.6.x release'
if ($PwshVersion) {
    if ($PwshVersion -notmatch '^7\.6\.\d+$') { throw "Invalid -PwshVersion: $PwshVersion (expected a 7.6.x version, e.g. 7.6.6)" }
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
                    # 403 = rate limit; honor X-RateLimit-Reset when present.
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
                @($_.assets | Where-Object { $_.name -like 'PowerShell-*-win-x64.zip' }).Count -gt 0
            } |
            Select-Object -First 1)
    }
    if (-not $candidate) {
        throw 'Could not resolve a stable PowerShell v7.6.x release carrying PowerShell-*-win-x64.zip'
    }
    $PwshVersion = $candidate.tag_name.TrimStart('v')
}

$AssetFile   = $AssetName -replace '<VER>', $PwshVersion
$Tag         = "v$PwshVersion"
$DownloadUrl = "https://github.com/$RepoSlug/releases/download/$Tag/$AssetFile"

Write-Host "  PowerShell version : $PwshVersion   (tag: $Tag)"
Write-Host "  Package            : $AssetFile"

# ---------------------------------------------------------------------------
# 2. Download + extract
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $OutDir | Out-Null
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

Write-Step 'Downloading PowerShell package'
$zipFile = Join-Path $CacheDir $AssetFile
Download-File $DownloadUrl $zipFile

Write-Step 'Extracting PowerShell package (zip)'
# Expand-Archive (PS 5.1) is extremely slow on ~100 MB zips with thousands of
# entries; the bsdtar shipping with Windows 10+ handles zip fine and is an
# order of magnitude faster. CI runners and any supported build host have it.
$tar = 'C:\Windows\System32\tar.exe'
if (Test-Path $tar) {
    Write-Host "  tar: $tar"
    & $tar -xf $zipFile -C $StageDir
    if ($LASTEXITCODE -ne 0) { throw "tar extraction failed with exit code $LASTEXITCODE" }
}
else {
    Write-Host '  tar.exe not found, falling back to Expand-Archive (slow)'
    Expand-Archive -LiteralPath $zipFile -DestinationPath $StageDir -Force
}

# The zip root IS the PowerShell tree (pwsh.exe at top level).
$pwshExe = Join-Path $StageDir 'pwsh.exe'
if (-not (Test-Path $pwshExe)) {
    $tree = (Get-ChildItem -Force $StageDir | ForEach-Object { $_.Name }) -join ', '
    throw "pwsh.exe missing after extraction. Top-level entries: $tree"
}

# ---------------------------------------------------------------------------
# 3. Smoke test
# ---------------------------------------------------------------------------
Write-Step 'Smoke testing staged pwsh.exe'
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$verOut = (& $pwshExe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>&1) -join "`n"
$code = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($code -ne 0 -or ($verOut.Trim() -ne $PwshVersion)) {
    throw "Staged pwsh.exe version mismatch (expected '$PwshVersion'): $verOut"
}
Write-Host "  PowerShell $($verOut.Trim())"

# ---------------------------------------------------------------------------
# 4. Compile installer
# ---------------------------------------------------------------------------
$SetupName      = "pwsh-$PwshVersion-setup-x64"
$SetupExe       = Join-Path $OutDir "$SetupName.exe"
$NumericVersion = "$PwshVersion.0"

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
        "/DMyAppVersion=$PwshVersion" `
        "/DMyAppNumericVersion=$NumericVersion" `
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
    package      = 'pwsh'
    pwshVersion  = $PwshVersion
    displayName  = "PowerShell $PwshVersion (x64)"
    sourceAsset  = $AssetFile
    releaseTag   = $Tag
    releaseUrl   = $DownloadUrl
    defaultPath  = 'C:\pf\PowerShell7'
    pathEntries  = @('C:\pf\PowerShell7')
    commands     = @('pwsh')
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
# PowerShell $PwshVersion 一键安装包

## 组件版本

| 组件 | 版本 / 来源 |
| --- | --- |
| PowerShell | $PwshVersion（``$AssetFile``，GitHub Release ``$Tag``） |

## 默认行为

- 默认安装目录：``C:\pf\PowerShell7``（安装向导中可修改）
- 安装后自动将安装目录加入系统 PATH，新开命令行可直接使用 ``pwsh`` 命令
- 资源管理器右键菜单新增**在此处打开 PowerShell 7**（目录上及目录空白处；Windows 11 位于“显示更多选项”内）
- Windows Terminal 自动出现 **PowerShell 7** 配置档（经 ProgramData Fragments 机制注册，不重开 Windows Terminal 不生效）
- 安装/卸载对系统 PATH 均为幂等精确操作，不改动其他条目；卸载后文件、PATH 条目、右键菜单与 Windows Terminal 配置档全部清除

## 校验

SHA-256（$SetupName.exe）：

``$hash``
"@
    [IO.File]::WriteAllText((Join-Path $OutDir 'release-notes.md'), $notes, $utf8NoBom)
}

if ($env:GITHUB_OUTPUT) {
    "pwsh_version=$PwshVersion" | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
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
