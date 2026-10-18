<#
.SYNOPSIS
    Build the ungoogled-chromium one-click installer for Windows x64.

.DESCRIPTION
    - Resolves the newest ungoogled-chromium-windows release (no hardcoded
      patch versions). The release tag carries both the upstream Chromium
      version and the ungoogled build revision, e.g. 155.0.8059.39-1.1.
    - Downloads the official portable archive
      ungoogled-chromium_<tag>_windows_x64.zip, flattens the single wrapper
      folder so the stage root == C:\pf\chromium at install time.
    - Asserts the files a runnable browser needs, then runs mandatory smoke
      tests: chrome.exe's PE version must match the resolved Chromium version,
      and a real headless launch (--dump-dom) must render a marker page -
      which proves chrome.dll and the resource payload actually load.
    - Compiles an Inno Setup installer which installs to C:\pf\chromium by
      default, puts the install dir on the system PATH and drops an
      all-users desktop shortcut.

.PARAMETER ChromiumVersion
    Exact release tag, e.g. 155.0.8059.39-1.1 (Chromium version + ungoogled
    build revision). Empty = the newest release carrying the x64 portable zip.

.PARAMETER MirrorBase
    Optional GitHub-release mirror base, used for both discovery and download.
    Local builds in mainland China should pass the USTC mirror:
      https://mirrors.ustc.edu.cn/github-release/ungoogled-software/ungoogled-chromium-windows
    Empty = the official GitHub release endpoint (the CI default).
    The mirror fronts direct asset links with a JS cookie challenge which
    Download-File solves transparently.

.PARAMETER BuildDir
    Working directory for cache, staging and output. Default: <repo>\build.

.PARAMETER SkipCompile
    Only resolve/download/assemble; do not invoke the Inno Setup compiler.
#>
[CmdletBinding()]
param(
    [string]$ChromiumVersion = '',
    [string]$MirrorBase      = '',
    [string]$BuildDir        = '',
    [switch]$SkipCompile
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
if (-not $BuildDir) { $BuildDir = Join-Path $RepoRoot 'build' }

$CacheDir = Join-Path $BuildDir 'cache'
$StageDir = Join-Path $BuildDir 'stage\chromium'
$OutDir   = Join-Path $BuildDir 'output'

$RepoSlug      = 'ungoogled-software/ungoogled-chromium-windows'
$AssetTemplate = 'ungoogled-chromium_<VER>_windows_x64.zip'
$GithubBase    = "https://github.com/$RepoSlug/releases/download"

# Must exist after assembly: a browser that lost any of these cannot start.
$RequiredFiles = @(
    'chrome.exe', 'chrome.dll', 'chrome_elf.dll',
    'chrome_100_percent.pak', 'chrome_200_percent.pak', 'resources.pak',
    'icudtl.dat', 'v8_context_snapshot.bin',
    'locales\en-US.pak', 'locales\zh-CN.pak',
    'IwaKeyDistribution\manifest.json'
)

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

function Download-File([string]$url, [string]$dest) {
    # Reuse a previously downloaded, non-empty cache file (the ~190 MB zip).
    if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) {
        Write-Host "  cached: $dest"
        return
    }
    $attempts = 3
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            Write-Host "  downloading ($i/$attempts): $url"
            $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
            $tmp = "$dest.part"
            if (Test-Path $tmp) { Remove-Item -Force $tmp }
            Invoke-WebRequest -UseBasicParsing -Uri $url -WebSession $session -OutFile $tmp
            # USTC (and similar) mirrors front direct asset links with a JS
            # cookie challenge: the first response is a tiny HTML page that
            # sets addr=<client-ip> and reloads. Replay that cookie and fetch
            # again - smaller than 64 KB and containing the challenge banner is
            # the reliable signal (the error page is always that small).
            $len = (Get-Item $tmp).Length
            if ($len -lt 65536) {
                $text = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($tmp))
                if ($text -match 'Verifying your browser') {
                    $m = [regex]::Match($text, 'addr=([0-9a-fA-F\.:]+)')
                    if (-not $m.Success) { throw 'mirror verification page did not expose an addr cookie' }
                    $session.Cookies.Add((New-Object System.Net.Cookie('addr', $m.Groups[1].Value, '/', ([Uri]$url).Host)))
                    Write-Host "  mirror cookie challenge solved (addr=$($m.Groups[1].Value))"
                    Remove-Item -Force $tmp
                    Invoke-WebRequest -UseBasicParsing -Uri $url -WebSession $session -OutFile $tmp
                }
            }
            if ((Test-Path $tmp) -and ((Get-Item $tmp).Length -gt 0)) {
                Move-Item -Force $tmp $dest
                return
            }
            throw 'downloaded file is empty'
        }
        catch {
            if ($i -eq $attempts) { throw }
            Start-Sleep -Seconds (3 * $i)
        }
    }
}

# ---------------------------------------------------------------------------
# 1. Resolve version (newest release; empty result = hard fail)
# ---------------------------------------------------------------------------
Write-Step 'Resolving ungoogled-chromium-windows release'
# Tag format: <chromium version>-<ungoogled revision>, e.g. 155.0.8059.39-1.1
$TagPattern = '^\d+\.\d+\.\d+\.\d+(-\d+(\.\d+)?)?$'
if ($ChromiumVersion) {
    if ($ChromiumVersion -notmatch $TagPattern) {
        throw "Invalid -ChromiumVersion: $ChromiumVersion (expected e.g. 155.0.8059.39-1.1)"
    }
    $indexNote = 'pinned by -ChromiumVersion'
}
elseif ($MirrorBase) {
    $mirrorRoot = $MirrorBase.TrimEnd('/')
    $listingUrl = "$mirrorRoot/LatestRelease/"
    Write-Host "  discovery via mirror listing: $listingUrl"
    $listing = Invoke-WebRequest -UseBasicParsing -Uri $listingUrl
    # The mirror's LatestRelease directory lists the same asset names as GitHub;
    # read the tag straight out of the x64 portable zip name.
    $m = [regex]::Match($listing.Content, 'ungoogled-chromium_([^"/]+)_windows_x64\.zip')
    if (-not $m.Success) { throw "No x64 portable zip listed at $listingUrl" }
    $ChromiumVersion = $m.Groups[1].Value
    if ($ChromiumVersion -notmatch $TagPattern) { throw "Unexpected version parsed from mirror: $ChromiumVersion" }
    $indexNote = "mirror LatestRelease listing: $ChromiumVersion"
}
else {
    $headers = @{ 'User-Agent' = 'win-env-builder' }
    # On GitHub Actions the injected GITHUB_TOKEN lifts the unauthenticated
    # 60 req/h shared-IP rate limit to 1000 req/h; locally the header is absent.
    if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }
    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/releases?per_page=30" -Headers $headers
    if (-not $releases) { throw "Empty release list returned by the GitHub API for $RepoSlug" }
    # Newest first: the first stable release that carries the x64 portable zip.
    $rel = @($releases | Where-Object {
        (-not $_.draft) -and (-not $_.prerelease) -and
        (@($_.assets | Where-Object { $_.name -like '*_windows_x64.zip' }).Count -gt 0)
    } | Select-Object -First 1)
    if (-not $rel) { throw "Could not resolve a stable $RepoSlug release carrying the x64 portable zip" }
    $ChromiumVersion = $rel.tag_name
    if ($ChromiumVersion -notmatch $TagPattern) { throw "Unexpected tag parsed from the API: $ChromiumVersion" }
    $indexNote = "GitHub releases API latest: $ChromiumVersion"
}

$AssetFile    = $AssetTemplate -replace '<VER>', $ChromiumVersion
# The Chromium version part drives the chrome.exe FileVersion assertion
# (ungoogled builds do not touch the embedded version).
$ChromiumCore = ($ChromiumVersion -split '-')[0]
if ($ChromiumCore -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    throw "Cannot derive a numeric version from tag $ChromiumVersion"
}
# VersionInfoVersion needs exactly four numeric parts; each must fit in 16 bit
# (see doc/lessons.md 7).
foreach ($part in $ChromiumCore.Split('.')) {
    if ([int]$part -gt 65535) { throw "Version component $part of $ChromiumVersion exceeds 65535" }
}

if ($MirrorBase) {
    $DownloadUrl = "$($MirrorBase.TrimEnd('/'))/$ChromiumVersion/$AssetFile"
}
else {
    $DownloadUrl = "$GithubBase/$ChromiumVersion/$AssetFile"
}

Write-Host "  release     : $ChromiumVersion"
Write-Host "  $indexNote"
Write-Host "  package     : $AssetFile"

# ---------------------------------------------------------------------------
# 2. Download + extract
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $OutDir | Out-Null
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

Write-Step 'Downloading ungoogled-chromium portable archive (~190 MB)'
$zipFile = Join-Path $CacheDir $AssetFile
Download-File $DownloadUrl $zipFile

Write-Step 'Extracting portable archive (zip)'
# tar.exe (ships with Windows 10+) extracts zips an order of magnitude faster
# than Expand-Archive on PS 5.1.
$tar = 'C:\Windows\System32\tar.exe'
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
if (Test-Path $tar) {
    & $tar -xf $zipFile -C $StageDir
    $tarCode = $LASTEXITCODE
}
else {
    $tarCode = 1
}
$ErrorActionPreference = $prevEap
if ($tarCode -ne 0) { throw "tar extraction failed with exit code $tarCode" }

# The archive wraps everything in one folder named
# ungoogled-chromium_<tag>_windows_x64; flatten it so the stage root == install
# root. Everything is a single top-level directory - anything else means the
# upstream layout changed.
$top = @(Get-ChildItem -Force $StageDir)
$inner = @($top | Where-Object { $_.PSIsContainer } | Select-Object -First 1)
if ($top.Count -ne 1 -or -not $inner) {
    $names = ($top | ForEach-Object { $_.Name }) -join ', '
    throw "Expected a single wrapper folder after extraction, got: $names"
}
Get-ChildItem -Force -LiteralPath $inner.FullName | Move-Item -Destination $StageDir -Force
Remove-Item -Recurse -Force -LiteralPath $inner.FullName

# ---------------------------------------------------------------------------
# 3. Content assertions + reparse point sweep
# ---------------------------------------------------------------------------
Write-Step 'Asserting the assembled payload'
foreach ($rel in $RequiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $StageDir $rel))) {
        throw "Required file missing after assembly: $rel (upstream layout changed - review the layout)"
    }
}
$totalMB = [math]::Round((Get-ChildItem $StageDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 1)
Write-Host "  staged tree: $totalMB MB"

# Stage trees must contain no reparse points: Inno Setup's [Files] scanner
# follows directory links and blows up with an unnumbered error (see
# doc/lessons.md 14). Directory links are deleted non-recursively so the
# target is never touched.
$links = @(Get-ChildItem -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
foreach ($l in $links) {
    if ($l.PSIsContainer) { [IO.Directory]::Delete($l.FullName, $false) }
    else { Remove-Item -Force -LiteralPath $l.FullName }
}
$linksLeft = @(Get-ChildItem -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })
if ($linksLeft.Count -ne 0) { throw "$($linksLeft.Count) reparse point(s) remain in the stage tree" }

# ---------------------------------------------------------------------------
# 4. Smoke test (mandatory: PE version + a real headless launch)
# ---------------------------------------------------------------------------
Write-Step 'Smoke testing staged chromium'
$chromeExe = Join-Path $StageDir 'chrome.exe'

# chrome.exe is a GUI-subsystem binary: a plain `chrome.exe --version` prints
# nothing and reports no exit code, so the embedded PE version is the
# authoritative check.
$fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($chromeExe).FileVersion
if ($fileVersion -ne $ChromiumCore) {
    throw "chrome.exe FileVersion $fileVersion does not match the packaged Chromium version $ChromiumCore"
}
Write-Host "  chrome.exe FileVersion : $fileVersion"

# A real launch proves chrome.dll, the .pak resources and the V8 snapshot
# actually load - a truncated or mismatched payload fails here instead of on
# the user's desktop.
$smokeDir = Join-Path $CacheDir 'chr-smoke'
$smokeOut = Join-Path $smokeDir 'dom.txt'
$smokeErr = Join-Path $smokeDir 'err.txt'
$smokeUdd = Join-Path $smokeDir 'profile'
$marker   = 'win-env-smoke-ok'
if (Test-Path $smokeDir) { Remove-Item -Recurse -Force $smokeDir }
New-Item -ItemType Directory -Force -Path $smokeDir | Out-Null
try {
    # --dump-dom renders synchronously and exits, which is the only reliable way
    # to get output out of the GUI-subsystem chrome.exe (redirected stdin/stdout).
    $chromeArgs = @(
        '--headless=new', '--disable-gpu', '--no-sandbox', '--no-first-run',
        '--disable-extensions', "--user-data-dir=$smokeUdd",
        '--dump-dom', "data:text/html,<h1>$marker</h1>"
    )
    Write-Host '  headless --dump-dom about a marker page'
    $proc = Start-Process -FilePath $chromeExe -ArgumentList $chromeArgs `
        -RedirectStandardOutput $smokeOut -RedirectStandardError $smokeErr -PassThru -NoNewWindow
    if (-not $proc.WaitForExit(90000)) {
        try { $proc.Kill() } catch { }
        throw 'headless chromium did not exit within 90 s'
    }
    $dom = if (Test-Path $smokeOut) { Get-Content -Raw $smokeOut } else { '' }
    if ($dom -notmatch $marker) {
        $err = if (Test-Path $smokeErr) { (Get-Content $smokeErr -Tail 20) -join "`n" } else { '(no stderr)' }
        throw "headless chromium did not render the marker page. stderr:`n$err"
    }
    Write-Host '  headless render OK'
}
finally {
    if (Test-Path $smokeDir) { Remove-Item -Recurse -Force $smokeDir -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# 5. Compile installer
# ---------------------------------------------------------------------------
$SetupName = "chromium-$ChromiumVersion-setup-x64"
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
        "/DMyAppVersion=$ChromiumVersion" `
        "/DMyAppNumericVersion=$ChromiumCore" `
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
    package         = 'chromium'
    chromiumVersion = $ChromiumVersion
    chromiumCore    = $ChromiumCore
    sourceAsset     = $AssetFile
    releaseUrl      = $DownloadUrl
    sourceRepo      = "https://github.com/$RepoSlug"
    releaseNote     = $indexNote
    mirrorBase      = $MirrorBase
    defaultPath     = 'C:\pf\chromium'
    pathEntries     = @('C:\pf\chromium')
    desktopShortcut = $true
    commands        = @('chrome')
    builtAt         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
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
    $srcLine = if ($MirrorBase) { "$ChromiumVersion（$MirrorBase 镜像，对应 GitHub Release）" } else { "$ChromiumVersion（ungoogled-chromium-windows 官方 GitHub Release）" }
    $notes = @"
# ungoogled-chromium $ChromiumVersion Windows x64 一键安装包

## 组件版本

| 组件 | 版本 / 来源 |
| --- | --- |
| ungoogled-chromium | $srcLine |
| 上游 Chromium | $ChromiumCore（嵌入 chrome.exe / chrome.dll 的 PE FileVersion） |
| 版本发现 | $indexNote |
| 上游仓库 | <https://github.com/$RepoSlug> |

## 默认行为

- 默认安装目录：``C:\pf\chromium``（安装向导中可修改，不带版本号后缀）
- 安装内容即官方 ``$AssetFile`` 解压后的完整目录树（``chrome.exe``、``chrome.dll``、``locales\``、``resources.pak`` 等），安装器只做原样释放，不在安装期下载或拼装任何内容
- **桌面快捷方式**：安装时为所有用户创建桌面快捷方式 ``Chromium``，指向 ``<安装目录>\chrome.exe``；卸载时一并移除
- 安装后自动将安装目录加入系统 PATH，新开命令行可直接使用 ``chrome`` 命令
- 安装/卸载对系统 PATH 均为幂等精确操作，不改动其他条目；卸载后文件与 PATH 条目全部清除

## 用户数据说明

- 浏览器配置与缓存默认保存在 ``%LOCALAPPDATA%\Chromium\User Data``（与官方 Chromium 一致，**不在安装目录内**），卸载本包不会清除这些用户数据
- 如需便携模式（配置随安装目录走），请自行给 ``chrome.exe`` 加 ``--user-data-dir`` 参数启动

## 校验

SHA-256（$SetupName.exe）：

``$hash``
"@
    # WriteAllText with UTF8(no BOM): Out-File -Encoding utf8 in PS 5.1 emits
    # a BOM, which GitHub renders as a stray character at the top of the body.
    [IO.File]::WriteAllText((Join-Path $OutDir 'release-notes.md'), $notes, $utf8NoBom)
}

if ($env:GITHUB_OUTPUT) {
    "chromium_version=$ChromiumVersion" | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
    "setup_name=$SetupName.exe"         | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
}

Write-Step 'Done'
if (-not $SkipCompile) {
    Write-Host "  Installer : $SetupExe"
    Write-Host "  SHA-256   : $hash"
}
else {
    Write-Host "  Staging   : $StageDir"
}
