<#
.SYNOPSIS
    Build the Notepad3 one-click installer for Windows x64.

.DESCRIPTION
    - Resolves the newest rizonesoft/Notepad3 stable release (tags look like
      RELEASE_7.26.602.1, no "v" prefix, four numeric parts). Release
      candidates are filtered on draft/prerelease, so RC_*/RC2_* tags never
      win even though they carry the same asset names.
    - Downloads Notepad3_<version>_x64_Portable.zip and verifies it against the
      release asset's sha256 digest (GitHub publishes "sha256:<hex>"). A
      missing or malformed digest aborts the build instead of silently
      shipping an unverified binary.
    - Extracts straight into build/stage/notepad3 (the portable zip has no
      wrapper folder: the zip root is the install root at C:\pf\Notepad3).
    - Trims lng\ down to English (en-GB) and Simplified Chinese (zh-CN). The
      upstream language folders are ~12.46 MB of the ~21 MB payload and the
      other 23 locales are dead weight for this repo's users. lng\mplng.dll
      and lng\np3lng.dll (the MUI loaders, not per-locale data) are kept.
    - Mandatory smoke tests: layout sentinels, static-CRT import assertion
      (no vcruntime140 / msvcp140 / ucrtbase / api-ms-win-crt-* imports) and
      a PE FileVersion match against the resolved version. Notepad3.exe is a
      GUI app, so it is never launched during the build.
    - Compiles an Inno Setup installer which installs to C:\pf\Notepad3,
      puts the install dir on the system PATH, registers Notepad3 as an
      "Open with" candidate for the selected extensions (machine-wide) and
      offers a shortcut to the Windows Default Apps settings page.

.PARAMETER Notepad3Version
    Exact version, e.g. 7.26.602.1 (the part after RELEASE_). Empty = newest
    stable release carrying the x64 portable zip.

.PARAMETER BuildDir
    Working directory for cache, staging and output. Default: <repo>\build.

.PARAMETER SkipCompile
    Only resolve/download/assemble; do not invoke the Inno Setup compiler.
#>
[CmdletBinding()]
param(
    [string]$Notepad3Version = '',
    [string]$BuildDir        = '',
    [switch]$SkipCompile
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# PS 5.1 does not auto-load the zip assembly; [IO.Compression.ZipFile] fails
# with "type not found" otherwise.
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
if (-not $BuildDir) { $BuildDir = Join-Path $RepoRoot 'build' }

$CacheDir = Join-Path $BuildDir 'cache'
$StageDir = Join-Path $BuildDir 'stage\notepad3'
$OutDir   = Join-Path $BuildDir 'output'

$RepoSlug      = 'rizonesoft/Notepad3'
$AssetTemplate = 'Notepad3_<VER>_x64_Portable.zip'

# lng\ holds one folder per locale plus the shared loaders. Keep English and
# Simplified Chinese only; every other folder is deleted (see doc/notepad3.md).
$KeepLanguages = @('en-GB', 'zh-CN')

# Must exist after assembly (post-trim): the payload cannot be a working
# editor with any of these missing.
$RequiredFiles = @(
    'Notepad3.exe',
    'minipath.exe',
    'Notepad3.ini',
    'Docs\License.txt',
    'lng\mplng.dll',
    'lng\np3lng.dll',
    'lng\en-GB\mplng.dll.mui',
    'lng\en-GB\np3lng.dll.mui',
    'lng\zh-CN\mplng.dll.mui',
    'lng\zh-CN\np3lng.dll.mui'
)

# Notepad3 ships a static CRT; importing any of these would mean the payload
# needs a redistributable that this installer deliberately does not carry.
$ForbiddenImports = @('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll', 'ucrtbase.dll')

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

function Get-StageBytes {
    return [long](Get-ChildItem -LiteralPath $StageDir -Recurse -File |
        Measure-Object Length -Sum).Sum
}

function Download-File([string]$url, [string]$dest) {
    # Reuse a previously downloaded, non-empty cache file (a ~6.5 MB zip).
    if ((Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) {
        Write-Host "  cached: $dest"
        return
    }
    $attempts = 3
    for ($i = 1; $i -le $attempts; $i++) {
        try {
            Write-Host "  downloading ($i/$attempts): $url"
            $tmp = "$dest.part"
            if (Test-Path $tmp) { Remove-Item -Force $tmp }
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tmp
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

# Read the PE import directory and return the imported DLL names. Used as a
# layout/portability assertion only (no external tools, the image is never
# loaded).
function Get-PeImportDlls([string]$path) {
    $b = [IO.File]::ReadAllBytes($path)
    $peOff = [BitConverter]::ToInt32($b, 0x3C)
    if ([Text.Encoding]::ASCII.GetString($b, $peOff, 4) -ne "PE`0`0") {
        throw "$path is not a PE file"
    }
    $coffOff = $peOff + 4
    $numSections = [BitConverter]::ToUInt16($b, $coffOff + 2)
    $optSize = [BitConverter]::ToUInt16($b, $coffOff + 16)
    $optOff = $coffOff + 20
    $magic = [BitConverter]::ToUInt16($b, $optOff)
    $ddOff = if ($magic -eq 0x20b) { $optOff + 112 } else { $optOff + 96 }
    $impRva = [BitConverter]::ToUInt32($b, $ddOff + 8)
    if ($impRva -eq 0) { return @() }

    $sections = @()
    $secOff = $optOff + $optSize
    for ($i = 0; $i -lt $numSections; $i++) {
        $o = $secOff + $i * 40
        $sections += [pscustomobject]@{
            VA      = [BitConverter]::ToUInt32($b, $o + 12)
            VSize   = [BitConverter]::ToUInt32($b, $o + 8)
            RawSize = [BitConverter]::ToUInt32($b, $o + 16)
            RawPtr  = [BitConverter]::ToUInt32($b, $o + 20)
        }
    }
    $rvaToOff = {
        param([uint32]$rva)
        foreach ($s in $sections) {
            $span = [Math]::Max($s.VSize, $s.RawSize)
            if ($rva -ge $s.VA -and $rva -lt ($s.VA + $span)) {
                return [int]($rva - $s.VA + $s.RawPtr)
            }
        }
        throw "RVA 0x$('{0:X}' -f $rva) is not mapped to any section in $path"
    }

    $names = @()
    $off = & $rvaToOff $impRva
    for ($i = 0; $i -lt 4096; $i++) {
        $nameRva = [BitConverter]::ToUInt32($b, $off + 12)
        if ($nameRva -eq 0) { break }
        $p = & $rvaToOff $nameRva
        $sb = New-Object System.Text.StringBuilder
        while ($b[$p] -ne 0) { [void]$sb.Append([char]$b[$p]); $p++ }
        $names += $sb.ToString()
        $off += 20
    }
    return $names
}

function NormalizeVersion([string]$text) {
    $m = [regex]::Match($text, '(\d+)\.(\d+)\.(\d+)\.(\d+)')
    if (-not $m.Success) { throw "Cannot normalize a four-part version from '$text'" }
    return ($m.Groups[1..4] | ForEach-Object { [string][int]$_.Value }) -join '.'
}

# ---------------------------------------------------------------------------
# 1. Resolve version + release asset (newest stable; empty result = hard fail)
# ---------------------------------------------------------------------------
Write-Step 'Resolving Notepad3 release'
$VersionPattern = '^\d+\.\d+\.\d+\.\d+$'
$headers = @{ 'User-Agent' = 'win-env-builder' }
# On GitHub Actions the injected GITHUB_TOKEN lifts the unauthenticated
# 60 req/h shared-IP rate limit to 1000 req/h (see doc/lessons.md).
if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }

$rel = $null
if ($Notepad3Version) {
    if ($Notepad3Version -notmatch $VersionPattern) {
        throw "Invalid -Notepad3Version: $Notepad3Version (expected e.g. 7.26.602.1)"
    }
    Write-Host "  pinned by -Notepad3Version: $Notepad3Version"
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/releases/tags/RELEASE_$Notepad3Version" -Headers $headers
    }
    catch {
        throw "No release tagged RELEASE_$Notepad3Version in $RepoSlug ($($_.Exception.Message))"
    }
    if ($rel.draft -or $rel.prerelease) {
        throw "Release RELEASE_$Notepad3Version is a draft/prerelease; only stable releases are built"
    }
    $indexNote = "pinned by -Notepad3Version"
}
else {
    $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$RepoSlug/releases?per_page=30" -Headers $headers
    if (-not $releases) { throw "Empty release list returned by the GitHub API for $RepoSlug" }
    foreach ($r in $releases) {
        if ($r.draft -or $r.prerelease) { continue }
        $m = [regex]::Match([string]$r.tag_name, '^RELEASE_(\d+\.\d+\.\d+\.\d+)$')
        if (-not $m.Success) { continue }
        $candidate = $m.Groups[1].Value
        $portable = @($r.assets | Where-Object { $_.name -match '_x64_Portable\.zip$' })
        if ($portable.Count -eq 0) { continue }
        $exact = @($portable | Where-Object { $_.name -ceq ("Notepad3_" + $candidate + "_x64_Portable.zip") })
        if ($exact.Count -ne 1) {
            $names = ($portable | ForEach-Object { $_.name }) -join ', '
            throw "Release $($r.tag_name) carries x64 portable asset(s) that do not match the tag version: $names"
        }
        $rel = $r
        $Notepad3Version = $candidate
        break
    }
    if (-not $rel) { throw "Could not resolve a stable $RepoSlug release carrying Notepad3_<version>_x64_Portable.zip" }
    $indexNote = "GitHub releases API latest: $Notepad3Version"
}

# The tag and the asset filename must agree; a mismatch means upstream renamed
# something and our URL construction would be a guess.
$tagVersion = [regex]::Match([string]$rel.tag_name, '^RELEASE_(\d+\.\d+\.\d+\.\d+)$').Groups[1].Value
if ($tagVersion -ne $Notepad3Version) {
    throw "Release tag $($rel.tag_name) does not match the requested version $Notepad3Version"
}

$AssetFile = $AssetTemplate -replace '<VER>', $Notepad3Version
$asset = @($rel.assets | Where-Object { $_.name -ceq $AssetFile })
if ($asset.Count -ne 1) {
    $names = ($rel.assets | ForEach-Object { $_.name }) -join ', '
    throw "Asset $AssetFile not found in release $($rel.tag_name) (assets: $names)"
}
$asset = $asset[0]

# Mandatory integrity check: GitHub's release asset digest. Older releases
# predate this field; refuse to build rather than ship an unverified file.
$digest = [string]$asset.digest
$digestMatch = [regex]::Match($digest, '^sha256:([0-9a-fA-F]{64})$')
if (-not $digestMatch.Success) {
    throw "Release asset $AssetFile has no usable sha256 digest (got '$digest'); refusing to build unverified payload"
}
$ExpectedSha256 = $digestMatch.Groups[1].Value.ToLowerInvariant()

$DownloadUrl = [string]$asset.browser_download_url
if (-not $DownloadUrl) {
    throw "Release asset $AssetFile exposes no browser_download_url"
}

Write-Host "  release     : $($rel.tag_name)"
Write-Host "  $indexNote"
Write-Host "  package     : $AssetFile ($([math]::Round($asset.size / 1MB, 2)) MB)"
Write-Host "  sha256      : $ExpectedSha256"

# ---------------------------------------------------------------------------
# 2. Download + verify + extract
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $OutDir | Out-Null
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

Write-Step 'Downloading Notepad3 x64 portable archive'
$zipFile = Join-Path $CacheDir $AssetFile
Download-File $DownloadUrl $zipFile

Write-Step 'Verifying the downloaded archive against the release digest'
$actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipFile).Hash.ToLowerInvariant()
if ($actualSha256 -ne $ExpectedSha256) {
    Remove-Item -Force -LiteralPath $zipFile
    throw "SHA-256 mismatch for $AssetFile`n  expected: $ExpectedSha256`n  actual  : $actualSha256"
}
Write-Host '  digest OK'

Write-Step 'Extracting portable archive (zip root == install root)'
[IO.Compression.ZipFile]::ExtractToDirectory($zipFile, $StageDir)

# ---------------------------------------------------------------------------
# 3. Trim language packs (keep en-GB + zh-CN)
# ---------------------------------------------------------------------------
Write-Step 'Trimming language packs'
$LngDir = Join-Path $StageDir 'lng'
if (-not (Test-Path -LiteralPath $LngDir)) {
    throw 'lng\ is missing from the portable archive (upstream layout changed)'
}
$beforeBytes = Get-StageBytes
$beforeMB = [math]::Round($beforeBytes / 1MB, 2)
Write-Host "  staged tree before trim: $beforeMB MB"

$removedBytes = 0
$removedCount = 0
$removedNames = @()
foreach ($d in @(Get-ChildItem -LiteralPath $LngDir -Directory)) {
    if ($KeepLanguages -contains $d.Name) { continue }
    $bytes = [long](Get-ChildItem -LiteralPath $d.FullName -Recurse -File |
        Measure-Object Length -Sum).Sum
    Remove-Item -Recurse -Force -LiteralPath $d.FullName
    Write-Host ("  removed lng\{0,-7} {1,9:N0} bytes" -f $d.Name, $bytes)
    $removedBytes += $bytes
    $removedCount++
    $removedNames += $d.Name
}
if ($removedCount -eq 0) {
    throw "No language folder was trimmed; expected locales beyond $($KeepLanguages -join '/') (upstream layout changed)"
}

$afterBytes = Get-StageBytes
$afterMB = [math]::Round($afterBytes / 1MB, 2)
Write-Host ("  removed {0} locales, {1:N0} bytes ({2:N2} MB)" -f $removedCount, $removedBytes, ($removedBytes / 1MB))
Write-Host "  staged tree after trim : $afterMB MB"

# ---------------------------------------------------------------------------
# 4. Content assertions + reparse point sweep
# ---------------------------------------------------------------------------
Write-Step 'Asserting the assembled payload'
foreach ($requiredRel in $RequiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $StageDir $requiredRel))) {
        throw "Required file missing after assembly: $requiredRel (upstream layout changed - review the layout)"
    }
}
if (-not (Test-Path -LiteralPath (Join-Path $StageDir 'grepWin\LICENSE.txt'))) {
    throw 'grepWin\LICENSE.txt is missing; the bundled GPL-3.0 license must be shipped'
}
$themeCount = @(Get-ChildItem -LiteralPath (Join-Path $StageDir 'Themes') -File -Filter '*.ini').Count
if ($themeCount -lt 1) { throw 'Themes\ contains no theme ini files' }

$leftoverLocales = @(Get-ChildItem -LiteralPath $LngDir -Directory |
    Where-Object { $KeepLanguages -notcontains $_.Name } | ForEach-Object { $_.Name })
if ($leftoverLocales.Count -ne 0) {
    throw "Untrimmed language folder(s) remain: $($leftoverLocales -join ', ')"
}

# Stage trees must contain no reparse points: Inno Setup's [Files] scanner
# follows directory links and blows up with an unnumbered error (see
# doc/lessons.md).
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
# 5. Smoke test (mandatory: imports + PE version)
# ---------------------------------------------------------------------------
Write-Step 'Smoke testing staged Notepad3'
$np3Exe = Join-Path $StageDir 'Notepad3.exe'

foreach ($exe in @('Notepad3.exe', 'minipath.exe')) {
    $imports = Get-PeImportDlls (Join-Path $StageDir $exe)
    if ($imports.Count -eq 0) { throw "$exe exposes no import table" }
    $bad = @($imports | Where-Object { $ForbiddenImports -contains $_.ToLowerInvariant() })
    if ($bad.Count -ne 0) {
        throw "$exe imports CRT redistributable DLL(s) $($bad -join ', '); this installer carries no app-local runtime"
    }
    if (@($imports | Where-Object { $_ -like 'api-ms-win-crt-*' }).Count -ne 0) {
        throw "$exe imports the UCRT API set; a static-CRT build was expected"
    }
    Write-Host "  $exe imports : $($imports -join ', ')"
}

$declaredVersion = NormalizeVersion([Diagnostics.FileVersionInfo]::GetVersionInfo($np3Exe).FileVersion)
$expectedVersion = NormalizeVersion $Notepad3Version
if ($declaredVersion -ne $expectedVersion) {
    throw "Notepad3.exe FileVersion $declaredVersion does not match the packaged version $expectedVersion"
}
Write-Host "  Notepad3.exe FileVersion : $declaredVersion"
# Notepad3.exe is a GUI app: no `/?`, no `/v`, no silent launch-and-kill here.

# ---------------------------------------------------------------------------
# 6. Compile installer
# ---------------------------------------------------------------------------
$SetupName = "notepad3-$Notepad3Version-setup-x64"
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
        "/DMyAppVersion=$Notepad3Version" `
        "/DMyAppNumericVersion=$Notepad3Version" `
        "/DStageDir=$StageDir" `
        "/DOutputDir=$OutDir" `
        "/DOutputBaseFilename=$SetupName"
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }
}
else {
    Write-Step 'Skipping installer compilation (-SkipCompile)'
}

# ---------------------------------------------------------------------------
# 7. Metadata / release notes / GitHub outputs
# ---------------------------------------------------------------------------
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$buildInfo = [ordered]@{
    package          = 'notepad3'
    notepad3Version  = $Notepad3Version
    sourceAsset      = $AssetFile
    sourceDigest     = $digest
    releaseUrl       = $DownloadUrl
    sourceRepo       = "https://github.com/$RepoSlug"
    releaseNote      = $indexNote
    keptLanguages    = $KeepLanguages
    removedLanguages = $removedNames
    trimmedBytes     = $removedBytes
    stageBytes       = $afterBytes
    defaultPath      = 'C:\pf\Notepad3'
    pathEntries      = @('C:\pf\Notepad3')
    commands         = @('Notepad3')
    builtAt          = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}
if (-not $SkipCompile) {
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SetupExe).Hash.ToLower()
    $buildInfo['file'] = "$SetupName.exe"
    $buildInfo['size'] = (Get-Item -LiteralPath $SetupExe).Length
    $buildInfo['sha256'] = $hash
    "$hash  $SetupName.exe" | Out-File -Encoding ascii (Join-Path $OutDir "$SetupName.exe.sha256.txt")
}
$buildInfo | ConvertTo-Json -Depth 4 |
    ForEach-Object { [IO.File]::WriteAllText((Join-Path $OutDir 'build-info.json'), $_, $utf8NoBom) }

if (-not $SkipCompile) {
    $removedList = ($removedNames -join '、')
    $notes = @"
# Notepad3 $Notepad3Version Windows x64 一键安装包

## 组件版本

| 组件 | 版本 / 来源 |
| --- | --- |
| Notepad3 | $Notepad3Version（rizonesoft/Notepad3 官方 GitHub Release，tag RELEASE_$Notepad3Version） |
| 上游资产 | ``$AssetFile``（sha256 ``$ExpectedSha256``，构建时强制校验） |
| 版本发现 | $indexNote |
| 上游仓库 | <https://github.com/$RepoSlug> |
| 语言包 | 仅保留 English（``en-GB``）与简体中文（``zh-CN``），删除 $removedCount 套（$removedList） |

## 默认行为

- 默认安装目录：``C:\pf\Notepad3``（安装向导中可修改，不带版本号后缀）
- 安装内容即官方 x64 便携包解压后的目录树（``Notepad3.exe``、``minipath.exe``、``np3encrypt.exe``、``Themes\``、``lng\``、``Docs\``、``grepWin\``），安装器只做原样释放，不在安装期下载或拼装任何内容
- 安装目录加入系统 PATH；新开命令行可直接运行 ``Notepad3``
- 开始菜单快捷方式默认创建，桌面快捷方式为可选任务
- 配置沿用上游便携约定：``Notepad3.ini`` 位于安装目录（不重定向到 ``%APPDATA%``）；升级/重装不会覆盖已有 ``Notepad3.ini``，卸载也不会删除它

## 文件关联（仅注册为候选，不改默认）

- 安装向导中可选：纯文本类（``.txt .log .ini .md .json .xml .yml .yaml .csv``）默认勾选；``.bat`` / ``.cmd``、``.ps1`` 默认不勾选
- 勾选后仅把 Notepad3 注册进对应扩展名的「打开方式」候选列表（``OpenWithProgids`` + ``RegisteredApplications`` 能力声明），**不会**修改系统默认程序、``UserChoice``、``.txt`` 默认 ProgID 或 ``notepad.exe``
- Windows 10/11 的默认程序由 ``UserChoice`` 哈希保护（Win11 另有 UCPD 驱动拦截），任何第三方安装器都无法可靠地静默设默认，因此本包只做"注册为候选 + 安装完成后跳转系统「默认应用」设置页"，由用户手动确认一次
- 卸载时只删除本包写入的注册项；原本指向 Notepad3 的扩展名会悬空，系统会提示重新选择默认程序——这是 Windows 的机制，安装器无法还原卸载前的默认程序

## 校验

SHA-256（$SetupName.exe）：

``$hash``
"@
    # WriteAllText with UTF8(no BOM): Out-File -Encoding utf8 in PS 5.1 emits
    # a BOM, which GitHub renders as a stray character at the top of the body.
    [IO.File]::WriteAllText((Join-Path $OutDir 'release-notes.md'), $notes, $utf8NoBom)
}

if ($env:GITHUB_OUTPUT) {
    "notepad3_version=$Notepad3Version" | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
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
