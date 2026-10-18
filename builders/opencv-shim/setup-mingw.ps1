<#
.SYNOPSIS
    Download a portable WinLibs MinGW-w64 toolchain into tools\mingw64.

.DESCRIPTION
    Resolves the latest plain-GCC WinLibs MinGW-w64 release (posix threads, SEH)
    from its official GitHub Release, extracts it to <repo>\tools\mingw64 and
    verifies the g++ binary. No admin rights, no system installer and nothing
    else on the machine is touched: this only supplies the gcc/g++ that the "gnu"
    route of .github/workflows/build-opencv-shim.yml uses to build the static
    OpenCV and the self-contained opencv_shim.dll.

    Idempotent: re-running keeps the existing toolchain; pass -Force to
    re-download and re-extract.

    GitHub 访问慢时默认走镜像（https://gh-proxy.com/）。换镜像或直连：
        builders\opencv-shim\setup-mingw.ps1 -Mirror "https://ghfast.top/"
        builders\opencv-shim\setup-mingw.ps1 -Mirror ""        # 直连 GitHub
    镜像不可用时自动回退直连，不会卡死。

    以上写法要在当前 PowerShell 会话内调用（workflow 用 call 运算符 & 直调）。
    别用 `powershell -File ... -Mirror ""` 外起进程：PS 5.1 会把空字符串实参
    丢掉，直接报 Missing an argument for parameter 'Mirror'（见 doc/lessons.md §4.6）。
#>

[CmdletBinding()]
param(
    # Force re-download/re-extract even if a toolchain is already present.
    [switch]$Force,

    # GitHub 加速镜像前缀，拼接在原始 URL 前。留空 = 直连 GitHub。
    [string]$Mirror = "https://gh-proxy.com/"
)

# 把 GitHub URL 套上镜像前缀（未配置镜像时原样返回）。
function Get-MirrorUrl {
    param([Parameter(Mandatory)][string]$Url)
    if ([string]::IsNullOrWhiteSpace($Mirror)) { return $Url }
    return ($Mirror.TrimEnd('/') + '/' + $Url)
}

# 依次尝试各候选 URL；curl.exe 优先（比 Invoke-WebRequest 快得多），
# 全部失败才抛错。返回的临时文件由调用方负责清理。
function Invoke-Download {
    param(
        [Parameter(Mandatory)][string[]]$Urls,
        [Parameter(Mandatory)][string]$OutFile,
        [hashtable]$Headers
    )
    $hasCurl = [bool](Get-Command curl.exe -ErrorAction SilentlyContinue)
    foreach ($u in $Urls) {
        if (Test-Path $OutFile) { Remove-Item -Force $OutFile -ErrorAction SilentlyContinue }
        try {
            Write-Host "[setup] Downloading $u ..."
            if ($hasCurl) {
                # curl 的进度条/报错都走 stderr；PS5.1 会把原生命令 stderr 变成 ErrorRecord，
                # 无论 EAP 是 Stop（终止）还是 Continue（刷红屏）都不干净 ⇒
                # 用 -sS 静默 + stderr 重定向到文件（文件重定向不产生 ErrorRecord），
                # 只在失败时把内容以 Warning 打出来。
                $errLog = "$OutFile.curl-err.log"
                if (Test-Path $errLog) { Remove-Item -Force $errLog -ErrorAction SilentlyContinue }
                & curl.exe -sS -L --fail --retry 2 --connect-timeout 15 -o $OutFile $u 2>$errLog
                if ($LASTEXITCODE -ne 0) {
                    if (Test-Path $errLog) {
                        Get-Content $errLog | ForEach-Object { Write-Warning "curl: $_" }
                    }
                    throw "curl.exe exited with $LASTEXITCODE"
                }
            } else {
                $ProgressPreference = "SilentlyContinue"
                Invoke-WebRequest -Uri $u -OutFile $OutFile -Headers $Headers
            }
            if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) {
                return $u
            }
            throw "download produced an empty file"
        }
        catch {
            Write-Warning "[setup] 下载失败，尝试下一个源：$($_.Exception.Message)"
        }
    }
    throw "下载失败：所有候选源均不可用（镜像 + 直连）。可换镜像重试：builders\opencv-shim\setup-mingw.ps1 -Mirror <前缀>"
}

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# $PSScriptRoot is builders\opencv-shim; the repo root is two levels up.
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$MingwDir = Join-Path $RepoRoot "tools\mingw64"
$Gxx      = Join-Path $MingwDir "bin\g++.exe"

if (-not $Force -and (Test-Path $Gxx)) {
    Write-Host "[setup] MinGW already present at $MingwDir - skipping download."
} else {
    Write-Host "[setup] Resolving latest WinLibs MinGW-w64 release ..."
    $headers = @{ "User-Agent" = "win-env-setup-mingw" }
    # CI 里带 GITHUB_TOKEN：匿名访问 api.github.com 仅 60 次/小时（按出口 IP 计，
    # runner 共享 IP 极易 403 限流），认证后 1000 次/小时。本地无该变量时保持匿名直连。
    if ($env:GITHUB_TOKEN) { $headers["Authorization"] = "Bearer $env:GITHUB_TOKEN" }
    $apiUrl  = "https://api.github.com/repos/brechtsanders/winlibs_mingw/releases/latest"
    $apiUrls = @()
    if (-not [string]::IsNullOrWhiteSpace($Mirror)) { $apiUrls += (Get-MirrorUrl $apiUrl) }
    $apiUrls += $apiUrl

    $release = $null
    foreach ($u in $apiUrls) {
        try {
            $release = Invoke-RestMethod -Uri $u -Headers $headers
            if ($release) { break }
        }
        catch {
            Write-Warning "[setup] 查询 release 失败，尝试下一个源：$($_.Exception.Message)"
        }
    }
    if (-not $release) {
        throw "查询 WinLibs release 失败：镜像与直连均不可用。可换镜像重试：builders\opencv-shim\setup-mingw.ps1 -Mirror <前缀>"
    }

    # Plain GCC release (no LLVM build), posix threads, SEH; msvcrt or ucrt.
    $asset = $release.assets | Where-Object {
        $_.name -match '^winlibs-x86_64-posix-seh-gcc-[\d.]+-mingw-w64(?:msvcrt|ucrt)-[\d.]+-r\d+\.zip$'
    } | Select-Object -First 1

    if (-not $asset) {
        throw "Could not find a suitable WinLibs zip asset in release $($release.tag_name)."
    }

    Write-Host "[setup] Downloading $($asset.name) ($([math]::Round($asset.size / 1MB)) MB) ..."
    Write-Host "[setup] (curl 静默模式，下载期间无进度输出；镜像约 1-2 分钟，直连可能很久)"
    $tmpRoot = Join-Path $env:TEMP ("win-env-mingw-setup-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
    $zipPath = Join-Path $tmpRoot "mingw.zip"
    try {
        $urls = @()
        if (-not [string]::IsNullOrWhiteSpace($Mirror)) { $urls += (Get-MirrorUrl $asset.browser_download_url) }
        $urls += $asset.browser_download_url
        Invoke-Download -Urls $urls -OutFile $zipPath -Headers $headers

        Write-Host "[setup] Extracting ..."
        Expand-Archive -Path $zipPath -DestinationPath $tmpRoot\extract

        $extracted = Join-Path $tmpRoot "extract\mingw64"
        if (-not (Test-Path $extracted)) {
            throw "Unexpected archive layout: mingw64 folder not found after extraction."
        }

        if (Test-Path $MingwDir) {
            Remove-Item -Recurse -Force $MingwDir
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $MingwDir) | Out-Null
        Move-Item -Path $extracted -Destination $MingwDir
    }
    finally {
        if (Test-Path $tmpRoot) { Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue }
    }

    if (-not (Test-Path $Gxx)) {
        throw "Setup failed: $Gxx not found after extraction."
    }
    Write-Host "[setup] MinGW installed at $MingwDir"
}

& $Gxx --version | Select-Object -First 1
Write-Host "[setup] Done: tools\mingw64 is ready (gcc / g++)."
