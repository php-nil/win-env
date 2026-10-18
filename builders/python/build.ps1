<#
.SYNOPSIS
    Build the Python (CPython, x64) one-click installer for Windows.

.DESCRIPTION
    - Resolves the newest final CPython release from the official install-manager
      index https://www.python.org/ftp/python/index-windows.json (no hardcoded
      patch versions). Optionally pinned to an exact version or a 3.x track.
    - Downloads the official python-<VER>-amd64.zip (the relocatable
      "pythoncore" layout used by the Python install manager) and verifies it
      against the sha256 published in that same index.
    - Stages the binary tree; the staged root equals C:\pf\python-<track> after
      install. The bundled Doc\ folder (offline HTML documentation, ~79 MB /
      ~58% of the payload) is trimmed by default; -KeepDoc keeps it.
    - Generates pip.cmd at the stage root: the zip ships pip inside
      Lib\site-packages but has no Scripts\ folder, so a bare `pip` command
      would not exist otherwise.
    - Runs mandatory smoke tests: staged python.exe must report the exact
      packaged version, sys.prefix must follow the staged location, tkinter
      (bundled Tcl/Tk) must initialise, the bundled pip must run and venv
      creation must produce a working interpreter.
    - Compiles an Inno Setup installer which installs to C:\pf\python-<track>
      by default and appends the install dir to the system PATH.

.PARAMETER PythonVersion
    Exact CPython version, e.g. 3.15.0. Empty = newest final 64-bit release in
    the official install-manager index.

.PARAMETER MajorTrack
    Major.minor track used by auto-discovery, e.g. 3.14. Empty = any track (the
    newest final release wins). Ignored when -PythonVersion is set.

.PARAMETER BuildDir
    Working directory for cache, staging and output. Default: <repo>\build.

.PARAMETER KeepDoc
    Keep the bundled Doc\ folder (official offline HTML documentation).

.PARAMETER SkipCompile
    Only resolve/download/assemble; do not invoke the Inno Setup compiler.
#>
[CmdletBinding()]
param(
    [string]$PythonVersion = '',
    [string]$MajorTrack    = '',
    [string]$BuildDir      = '',
    [switch]$KeepDoc,
    [switch]$SkipCompile
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
if (-not $BuildDir) { $BuildDir = Join-Path $RepoRoot 'build' }

$CacheDir = Join-Path $BuildDir 'cache'
$StageDir = Join-Path $BuildDir 'stage\python'
$OutDir   = Join-Path $BuildDir 'output'

$IndexUrl = 'https://www.python.org/ftp/python/index-windows.json'

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
# 1. Resolve version (official install-manager index; empty result = hard fail)
# ---------------------------------------------------------------------------
Write-Step 'Resolving CPython release from the official install-manager index'
# The document is an OBJECT, not a bare array: { "next": ..., "versions": [ ... ] }.
# Reading it as an array silently yields one item and every filter below misses
# (see doc/lessons.md 27).
$doc = Invoke-RestMethod -Uri $IndexUrl -ErrorAction Stop
$all = @($doc.versions)
if (-not $all) { throw "Empty versions array returned by $IndexUrl" }

# 64-bit GIL builds only. The free-threaded lines use ids like
# "pythoncore-3.15t-64" (the 't' sits before "-64"), so the anchored pattern
# below excludes them; pythonembed-* / pythontest-* entries are excluded by
# company+id as well. 'sort-version' must be a bare x.y.z: prerelease
# candidates (3.16.0a1, 3.15.0b3, ...) carry a suffix and are rejected.
$candidates = @($all | Where-Object {
    $_.company -eq 'PythonCore' -and
    $_.id -match '^pythoncore-\d+\.\d+-64$' -and
    $_.'sort-version' -match '^\d+\.\d+\.\d+$'
})
if ($candidates.Count -eq 0) { throw "No final 64-bit PythonCore release found in $IndexUrl" }

if ($PythonVersion) {
    if ($PythonVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid -PythonVersion: $PythonVersion" }
    $entry = @($candidates | Where-Object { $_.'sort-version' -eq $PythonVersion } | Select-Object -First 1)
    if (-not $entry) { throw "Python $PythonVersion (final, 64-bit, PythonCore) not found in $IndexUrl" }
}
else {
    if ($MajorTrack -and ($MajorTrack -notmatch '^\d+\.\d+$')) { throw "Invalid -MajorTrack: $MajorTrack" }
    $pool = $candidates
    if ($MajorTrack) {
        $pool = @($candidates | Where-Object { $_.id -eq "pythoncore-$MajorTrack-64" })
        if ($pool.Count -eq 0) { throw "No final 64-bit PythonCore release on track $MajorTrack in $IndexUrl" }
    }
    $entry = $pool | Sort-Object { [version]$_.'sort-version' } -Descending | Select-Object -First 1
}

$PythonVersion = [string]$entry.'sort-version'
$DisplayName   = [string]$entry.'display-name'
$Track         = (($PythonVersion -split '\.')[0..1] -join '.')
$DownloadUrl   = [string]$entry.url
$OfficialSha   = [string]$entry.hash.sha256

# The index is the authoritative source for both URL and checksum; never guess
# an URL. Guard the channel and the expected asset name before downloading.
if ($DownloadUrl -notmatch '^https://www\.python\.org/ftp/python/') {
    throw "Unexpected source URL (not the official python.org channel): $DownloadUrl"
}
$AssetFile = $DownloadUrl.Substring($DownloadUrl.LastIndexOf('/') + 1)
if ($AssetFile -ne "python-$PythonVersion-amd64.zip") {
    throw "Unexpected asset name in the index: $AssetFile (expected python-$PythonVersion-amd64.zip)"
}
if ($OfficialSha -notmatch '^[0-9a-f]{64}$') {
    throw "Missing or malformed sha256 for $PythonVersion in $IndexUrl"
}

Write-Host "  Python version : $PythonVersion  ($DisplayName)"
Write-Host "  Track          : $Track  ->  C:\pf\python-$Track"
Write-Host "  Package        : $AssetFile"
Write-Host "  Official sha256: $OfficialSha"

# ---------------------------------------------------------------------------
# 2. Download + verify + extract
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $OutDir | Out-Null
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

Write-Step 'Downloading Python package'
$zipFile = Join-Path $CacheDir $AssetFile
Download-File $DownloadUrl $zipFile

Write-Step 'Verifying the package against the official SHA-256'
$actualSha = (Get-FileHash -Algorithm SHA256 $zipFile).Hash.ToLower()
if ($actualSha -ne $OfficialSha.ToLower()) {
    throw "SHA-256 mismatch for $AssetFile`n  official: $OfficialSha`n  actual  : $actualSha"
}
Write-Host "  sha256 ok: $actualSha"

Write-Step 'Extracting Python package (zip)'
# tar.exe (ships with Windows 10+) extracts zips an order of magnitude faster
# than Expand-Archive on PS 5.1. Unlike the Node.js/PostgreSQL archives this zip
# has NO single wrapper folder: the executable sits at the archive root.
$tar = 'C:\Windows\System32\tar.exe'
if (Test-Path $tar) {
    & $tar -xf $zipFile -C $StageDir
    if ($LASTEXITCODE -ne 0) { throw "tar extraction failed with exit code $LASTEXITCODE" }
}
else {
    Expand-Archive -LiteralPath $zipFile -DestinationPath $StageDir -Force
}

# Layout gate: the relocatable pythoncore tree must be intact. A missing entry
# means the upstream asset layout changed and the build must not continue.
$layoutChecks = @(
    'python.exe',
    'pythonw.exe',
    'python3.dll',
    'vcruntime140.dll',
    'vcruntime140_1.dll',
    'DLLs\_tkinter.pyd',
    'DLLs\_ssl.pyd',
    'Lib\tkinter\__init__.py',
    'Lib\site-packages\pip\__init__.py',
    'include\Python.h',
    'libs\python3.lib',
    'build-details.json'
)
foreach ($rel in $layoutChecks) {
    if (-not (Test-Path (Join-Path $StageDir $rel))) {
        throw "Missing '$rel' in the extracted tree: official layout changed"
    }
}
# The embeddable distribution would carry python._pth and a zipped stdlib; it is
# a different asset and must never be staged by accident.
if (Test-Path (Join-Path $StageDir 'python._pth')) {
    throw 'python._pth found: the embeddable distribution was staged instead of pythoncore'
}

# Doc\ holds the offline HTML documentation (about 79 MB, ~58% of the payload).
# It is the single biggest lever and ships with every pythoncore zip, so the
# default build trims it; -KeepDoc opts out.
$docDir = Join-Path $StageDir 'Doc'
if (-not (Test-Path $docDir)) { throw 'Doc\ missing after extraction: official layout changed' }
if ($KeepDoc) {
    Write-Host '  keeping Doc\ (-KeepDoc)'
}
else {
    $docSize = (Get-ChildItem -LiteralPath $docDir -Recurse -Force -File |
        Measure-Object -Property Length -Sum).Sum
    Remove-Item -Recurse -Force $docDir
    Write-Host ("  trimmed Doc\ ({0:N1} MB of offline HTML docs)" -f ($docSize / 1MB))
}
if ((Test-Path $docDir) -ne [bool]$KeepDoc) { throw 'Doc\ trim assertion failed' }

# The tree we hand to ISCC must not contain reparse points: Inno Setup's [Files]
# scanner follows directory links and dies with an unnumbered error (see
# doc/lessons.md 14).
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
# 3. pip.cmd wrapper (the zip has no Scripts\ folder)
# ---------------------------------------------------------------------------
Write-Step 'Generating pip.cmd'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$pipCmd = @'
@echo off
"%~dp0python.exe" -m pip %*
'@
# cmd needs CRLF line endings; %~dp0 makes the wrapper independent of the
# caller's working directory (no PATH-relative surprises). A trailing CRLF is
# appended explicitly: a here-string drops the newline before the closing mark.
$pipCmd = (($pipCmd.TrimStart("`r", "`n")) -replace "`r?`n", "`r`n") + "`r`n"
$pipCmdPath = Join-Path $StageDir 'pip.cmd'
[IO.File]::WriteAllText($pipCmdPath, $pipCmd, $utf8NoBom)

# UTF-8 without BOM contract for the generated .cmd wrapper (see
# doc/lessons.md 1.2); cmd would miscount a leading BOM as part of the first
# command line.
$pipBytes = [IO.File]::ReadAllBytes($pipCmdPath)
if ($pipBytes.Length -ge 3 -and $pipBytes[0] -eq 0xEF -and $pipBytes[1] -eq 0xBB -and $pipBytes[2] -eq 0xBF) {
    throw 'pip.cmd must not carry a UTF-8 BOM'
}
$pipText = [IO.File]::ReadAllText($pipCmdPath, $utf8NoBom)
if ($pipText -notmatch "python\.exe`" -m pip %\*") { throw 'pip.cmd content assertion failed' }

# ---------------------------------------------------------------------------
# 4. Smoke test (mandatory: the staged tree must actually run)
# ---------------------------------------------------------------------------
Write-Step 'Smoke testing the staged interpreter'
$pyExe    = Join-Path $StageDir 'python.exe'
$venvDir  = Join-Path $CacheDir 'pysmoke-venv'
$prevEap  = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $verOut = (& $pyExe -V 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $verOut.Trim() -ne "Python $PythonVersion") {
        throw "Staged python.exe version mismatch (expected 'Python $PythonVersion'): $verOut"
    }
    Write-Host "  $($verOut.Trim())"

    # Relocatable layout: sys.prefix must follow the executable, not a
    # machine-wide registry entry. This is what makes C:\pf\python-<track> work.
    $prefixOut = (& $pyExe -c 'import sys; print(sys.prefix)' 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $prefixOut.Trim().TrimEnd('\') -ne $StageDir.TrimEnd('\')) {
        throw "sys.prefix does not follow the staged tree (expected '$StageDir'): $prefixOut"
    }

    # Single quotes inside the -c payload on purpose: PowerShell 5.1 strips
    # embedded double quotes when marshalling native command arguments, so
    # `eval("info patchlevel")` would reach Python mangled (see lessons 28).
    $tkOut = (& $pyExe -c "import tkinter; t = tkinter.Tcl(); print(t.eval('info patchlevel'))" 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $tkOut.Trim() -notmatch '^\d+\.\d+') {
        throw "tkinter smoke test failed (bundled Tcl/Tk): $tkOut"
    }
    Write-Host "  tkinter Tcl  : $($tkOut.Trim())"

    $pipOut = (& $pyExe -m pip -V 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $pipOut -notmatch '^pip \d') {
        throw "Bundled pip smoke test failed: $pipOut"
    }
    Write-Host "  $($pipOut.Trim())"

    $pipCmdOut = (& $pipCmdPath -V 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $pipCmdOut -notmatch '^pip \d') {
        throw "pip.cmd wrapper smoke test failed: $pipCmdOut"
    }
    Write-Host "  pip.cmd      : $($pipCmdOut.Trim())"

    # venv is the recommended way to install packages (the install dir itself
    # needs admin rights), so it must work out of the box.
    if (Test-Path $venvDir) { Remove-Item -Recurse -Force $venvDir }
    & $pyExe -m venv $venvDir
    if ($LASTEXITCODE -ne 0) { throw "python -m venv failed with exit code $LASTEXITCODE" }
    $venvPy = Join-Path $venvDir 'Scripts\python.exe'
    if (-not (Test-Path $venvPy)) { throw 'venv Scripts\python.exe missing' }
    $venvOut = (& $venvPy -V 2>&1) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $venvOut.Trim() -ne "Python $PythonVersion") {
        throw "venv interpreter version mismatch: $venvOut"
    }
    Write-Host "  venv         : $($venvOut.Trim())"
}
finally {
    $ErrorActionPreference = $prevEap
    if (Test-Path $venvDir) { Remove-Item -Recurse -Force $venvDir -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# 5. Compile installer
# ---------------------------------------------------------------------------
$SetupName = "python-$PythonVersion-setup-x64"
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
        "/DMyAppVersion=$PythonVersion" `
        "/DPyTrack=$Track" `
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
    package        = 'python'
    pythonVersion  = $PythonVersion
    displayName    = $DisplayName
    track          = $Track
    sourceAsset    = $AssetFile
    sourceUrl      = $DownloadUrl
    officialSha256 = $OfficialSha
    docTrimmed     = (-not $KeepDoc)
    defaultPath    = "C:\pf\python-$Track"
    pathEntries    = @("C:\pf\python-$Track")
    commands       = @('python', 'pythonw', 'pip')
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
    $docLine = if ($KeepDoc) {
        '- 保留官方 ``Doc\`` 离线 HTML 文档（``-KeepDoc`` 构建）'
    } else {
        '- 已裁剪官方 ``Doc\``（离线 HTML 文档，约 79 MB）；需要离线文档时用 ``-KeepDoc`` 重新构建'
    }
    $notes = @"
# Python $PythonVersion Windows x64 一键安装包

## 组件版本

| 组件 | 版本 / 来源 |
| --- | --- |
| CPython | $DisplayName（python.org 官方 install-manager 索引 ``index-windows.json`` 自动发现） |
| pip | 官方 zip 内置（``Lib\site-packages\pip``），另附 ``pip.cmd`` 包装器 |
| Tcl/Tk | 官方 zip 内置，``tkinter`` 可用 |
| VC++ 运行库 | 官方 zip 内置 app-local（``vcruntime140.dll`` / ``vcruntime140_1.dll``） |

## 默认行为

- 默认安装目录：``C:\pf\python-$Track``（安装向导中可修改）
- 安装后自动将安装目录加入系统 PATH，新开命令行可直接使用 ``python``、``pythonw``、``pip``
- ``pip`` 由构建期生成的 ``pip.cmd``（``"%~dp0python.exe" -m pip %*``）提供：官方 zip 没有 ``Scripts\`` 目录，
  且包装器不依赖调用方工作目录
- 安装内容即官方 ``$AssetFile`` 解压后的目录树（``python.exe``、``pythonw.exe``、``DLLs\``、``Lib\``、``include\``、``libs\`` 等），安装器只做原样释放，不在安装期下载或拼装任何内容
$docLine
- 安装/卸载对系统 PATH 均为幂等精确操作，不改动其他条目；卸载后文件与 PATH 条目全部清除

## 使用说明

- ``pip install`` 默认写入安装目录的 ``Lib\site-packages``（默认 ``C:\pf\python-$Track``），需要管理员终端；
  日常开发建议 ``python -m venv .venv`` 建虚拟环境后再装依赖（无需管理员）
- 不含 ``py`` 启动器（官方 Windows 安装器与 Store 版才有），多版本并存时 PATH 中先命中者生效
- 不写注册表运行时（``HKLM\SOFTWARE\Python``），不注册 ``.py`` 文件关联

## 校验

SHA-256（$SetupName.exe）：

``$hash``
"@
    # WriteAllText with UTF8(no BOM): Out-File -Encoding utf8 in PS 5.1 emits a
    # BOM, which GitHub renders as a stray character at the top of the body.
    [IO.File]::WriteAllText((Join-Path $OutDir 'release-notes.md'), $notes, $utf8NoBom)
}

if ($env:GITHUB_OUTPUT) {
    "python_version=$PythonVersion" | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
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
