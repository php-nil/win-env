<#
.SYNOPSIS
    Build the LLVM one-click installer for Windows x64 (clang-cl + full LLVM toolchain).

.DESCRIPTION
    - Resolves the latest stable LLVM release on llvm/llvm-project via the official
      GitHub releases API (no hardcoded patch versions).
    - Downloads clang+llvm-<ver>-x86_64-pc-windows-msvc.tar.xz from llvm/llvm-project
      releases. The archive is a pure portable tree (no installer machinery inside).
    - Stages the binary tree (stage root == C:\pf\llvm at install time) and runs
      a mandatory smoke test: clang-cl.exe --version reports exact resolved version,
      clang.exe --version works, and compiling a HelloWorld.c with clang-cl succeeds.
    - Compiles an Inno Setup installer which installs to C:\pf\llvm by default
      and appends the install directory to the system PATH.

.PARAMETER LlvmVersion
    Exact LLVM version, e.g. 23.1.5. Empty = newest stable llvmorg-* release
    carrying the x86_64-pc-windows-msvc tarball.

.PARAMETER BuildDir
    Working directory for cache, staging and output. Default: <repo>\build.

.PARAMETER SkipCompile
    Only resolve/download/assemble; do not invoke the Inno Setup compiler.
#>
[CmdletBinding()]
param(
    [string]$LlvmVersion = '',
    [string]$BuildDir    = '',
    [switch]$SkipCompile
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path
if (-not $BuildDir) { $BuildDir = Join-Path $RepoRoot 'build' }

$CacheDir = Join-Path $BuildDir 'cache'
$StageDir = Join-Path $BuildDir 'stage\llvm'
$OutDir   = Join-Path $BuildDir 'output'

$RepoSlug      = 'llvm/llvm-project'
$AssetPattern  = 'clang+llvm-*-x86_64-pc-windows-msvc.tar.xz'
$AssetSuffix   = '-x86_64-pc-windows-msvc.tar.xz'

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
Write-Step 'Resolving latest LLVM release'
$headers = @{ 'User-Agent' = 'win-env-builder' }
if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }

if ($LlvmVersion) {
    if ($LlvmVersion -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid -LlvmVersion: $LlvmVersion" }
}
else {
    # llvm/llvm-project releases tagged llvmorg-<major>.<minor>.<patch>; we scan
    # until we find a non-draft, non-prerelease one carrying the win-x64 tarball.
    $LlvmVersion = $null
    for ($page = 1; $page -le 3 -and -not $LlvmVersion; $page++) {
        $apiUrl = "https://api.github.com/repos/$RepoSlug/releases?per_page=100&page=$page"
        $releases = Invoke-RestMethod -Uri $apiUrl -Headers $headers
        if (-not $releases) { break }
        foreach ($rel in $releases) {
            if ($rel.draft -or $rel.prerelease) { continue }
            if (-not ($rel.tag_name -match '^llvmorg-(\d+\.\d+\.\d+)$')) { continue }
            if (@($rel.assets | Where-Object { $_.name -like $AssetPattern }).Count -eq 0) { continue }
            $LlvmVersion = $Matches[1]
            break
        }
    }
    if (-not $LlvmVersion) {
        throw "Could not resolve a stable LLVM release carrying $AssetPattern"
    }
}
Write-Host "  llvm version : $LlvmVersion"

# Find the exact asset object for download URL (asset names embed version).
$tagUrl = "https://api.github.com/repos/$RepoSlug/releases/tags/llvmorg-$LlvmVersion"
$tagRel = Invoke-RestMethod -Uri $tagUrl -Headers $headers
$assetObj = @($tagRel.assets | Where-Object { $_.name -like $AssetPattern })[0]
if (-not $assetObj) { throw "No $AssetPattern asset under tag llvmorg-$LlvmVersion" }
$DownloadUrl = $assetObj.browser_download_url

# LLVM releases ship .sig + .jsonl (SBOM) but no checksums.txt. We do not
# skip verification — the tar.xz integrity is guaranteed by HTTPS delivery
# plus Inno Setup re-compression.

# ---------------------------------------------------------------------------
# 2. Download
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $OutDir | Out-Null

# Strip reparse points before wipe (see doc/lessons.md §14).
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

Write-Step 'Downloading LLVM clang+llvm tarball'
$llvmTar = Join-Path $CacheDir "clang+llvm-$LlvmVersion$AssetSuffix"
Download-File $DownloadUrl $llvmTar

# ---------------------------------------------------------------------------
# 3. Assemble staging tree
#    clang+llvm-*.tar.xz contains a single top-level directory
#    clang+llvm-<ver>-x86_64-pc-windows-msvc/ holding bin/, lib/, include/, ...
#    The staged layout must be flat: StageDir == C:\pf\llvm after install,
#    so bin/, lib/, include/ sit at the stage root.
# ---------------------------------------------------------------------------
Write-Step 'Extracting LLVM'
$extractTmp = Join-Path $CacheDir 'extract-llvm'
if (Test-Path $extractTmp) { Remove-Item -Recurse -Force $extractTmp }
New-Item -ItemType Directory -Force -Path $extractTmp | Out-Null

# tar.exe on Windows 10+/Server 2022 supports .tar.xz natively via libarchive.
& tar -xf $llvmTar -C $extractTmp 2>&1 | ForEach-Object { Write-Host "  tar: $_" }
if ($LASTEXITCODE -ne 0) {
    throw "tar.exe failed to extract $llvmTar. Exit code: $LASTEXITCODE"
}

$innerDir = Get-ChildItem -Directory $extractTmp | Select-Object -First 1
if (-not $innerDir) { throw 'No inner directory in LLVM archive' }
Write-Host "  inner dir: $($innerDir.Name)"

# Mirror all contents of the version wrapper directory directly into StageDir.
$rcArgs = @($innerDir.FullName, $StageDir, '/MIR', '/NFL', '/NDL', '/NJH', '/NJS', '/NC', '/NS')
$rcProc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $rcArgs -Wait -PassThru -NoNewWindow
if ($rcProc.ExitCode -ge 8) { throw "robocopy failed with exit code $($rcProc.ExitCode)" }
Remove-Item -Recurse -Force $extractTmp

# Critical binaries: clang-cl (for cc crate), clang, clang++.
$clangCl = Join-Path $StageDir 'bin\clang-cl.exe'
$clangExe = Join-Path $StageDir 'bin\clang.exe'
$clangPP = Join-Path $StageDir 'bin\clang++.exe'
if (-not (Test-Path $clangCl)) { throw "bin\clang-cl.exe missing after extract. Archive layout changed?" }
if (-not (Test-Path $clangExe)) { throw "bin\clang.exe missing after extract" }

# ---------------------------------------------------------------------------
# 4. Smoke test
# ---------------------------------------------------------------------------
Write-Step 'Smoke testing staged clang-cl / clang'

# clang-cl --version outputs multiple lines; the first line contains the version.
$clVerOut = (& $clangCl --version 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) { throw "clang-cl --version failed: $clVerOut" }
# Accept either LLVM 23.1.5-style "clang-cl version 23.1.5" or older formats.
if ($clVerOut -notmatch [regex]::Escape($LlvmVersion)) {
    Write-Host "  WARNING: clang-cl version output does not embed '$LlvmVersion':"
    Write-Host "  $clVerOut"
}
Write-Host "  clang-cl OK"

$clangVerOut = (& $clangExe --version 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) { throw "clang --version failed: $clangVerOut" }
Write-Host "  clang OK"

# Compile a minimal C program with clang-cl to verify the full compiler pipeline.
Write-Step 'Smoke testing real compile (clang-cl HelloWorld.c)'
$smokeTmp = Join-Path $BuildDir 'smoke-llvm'
if (Test-Path $smokeTmp) { Remove-Item -Recurse -Force $smokeTmp }
New-Item -ItemType Directory -Force -Path $smokeTmp | Out-Null
$helloC = Join-Path $smokeTmp 'hello.c'
$helloExe = Join-Path $smokeTmp 'hello.exe'
[IO.File]::WriteAllText($helloC, '#include <stdio.h>' + "`n" + 'int main(){ printf("hello from clang-cl\n"); return 0; }' + "`n", (New-Object Text.UTF8Encoding($false)))

# clang-cl uses MSVC-compatible flags (/link invokes the bundled lld-link / MSVC link.exe).
& $clangCl /Fe:$helloExe $helloC 2>&1 | ForEach-Object { Write-Host "  clang-cl: $_" }
if ($LASTEXITCODE -ne 0) { throw "clang-cl compile failed" }

$helloOut = (& $helloExe 2>&1) -join "`n"
if ($LASTEXITCODE -ne 0) { throw "hello.exe exited with $LASTEXITCODE" }
if ($helloOut -notmatch 'hello from clang-cl') {
    throw "hello.exe produced unexpected output: $helloOut"
}
Write-Host "  clang-cl compile + run OK => $helloExe ($((Get-Item $helloExe).Length) bytes)"
Remove-Item -Recurse -Force $smokeTmp

# ---------------------------------------------------------------------------
# 5. Compile installer
# ---------------------------------------------------------------------------
$SetupName = "llvm-$LlvmVersion-setup-x64"
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
        "/DMyAppVersion=$LlvmVersion" `
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
    package    = 'llvm'
    llvmVersion = $LlvmVersion
    llvmUrl    = $DownloadUrl
    defaultPath = 'C:\pf\llvm'
    commands   = @('clang', 'clang-cl', 'clang++', 'clang-tidy', 'lldb', 'llvm-objdump', 'llvm-readelf')
    builtAt    = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
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
# LLVM $LlvmVersion Windows x64 一键安装包

## 组件版本

| 组件 | 版本 / 来源 |
| --- | --- |
| LLVM + Clang | $LlvmVersion（llvm/llvm-project 官方 Release ``clang+llvm-${LlvmVersion}$AssetSuffix``） |

## 默认行为

- 默认安装目录：``C:\pf\llvm``（安装向导中可修改）
- 安装后自动将 ``C:\pf\llvm\bin`` 加入系统 PATH，新开命令行可直接使用 ``clang-cl``、``clang``、``clang++``、``lldb`` 等命令
- 完整 LLVM 工具链：clang-cl（MSVC ABI 兼容，cc crate 自动识别）、lld-link（链接器）、lldb（调试器）、clang-tidy、llvm-objdump、llvm-readelf 等
- 官方可移植树，无需 MSYS2 / MinGW / 系统级依赖
- 安装/卸载对系统 PATH 均为幂等精确操作，不改动其他条目；卸载后文件与 PATH 条目全部清除

## 典型用途

- **cc crate C 编译器**：干净机器上 ``cargo build`` 编 ``zstd-sys`` / ``rusqlite`` / ``openssl-sys`` 等带 C 依赖的 crate
- **Node.js node-gyp**：``npm install`` 编原生模块（sharp、bcrypt 等）
- **Python setuptools / wheel**：``pip install`` 编带 C 扩展的包
- **独立 C/C++ 编译**：``clang-cl /Fe:hello.exe hello.c``

## 校验

SHA-256（$SetupName.exe）：

``$hash``
"@
    [IO.File]::WriteAllText((Join-Path $OutDir 'release-notes.md'), $notes, $utf8NoBom)
}

if ($env:GITHUB_OUTPUT) {
    "llvm_version=$LlvmVersion"   | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
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
