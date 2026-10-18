<#
.SYNOPSIS
    Build the PostgreSQL one-click installer for Windows x64.

.DESCRIPTION
    - Resolves the release from the official postgresql.org versions.json
      (no hardcoded patch versions). Optionally pinned to an exact version or
      a major track.
    - Downloads the official EDB "binaries" zip, flattens the single pgsql/
      root, trims the parts this package does not ship (pgAdmin 4,
      StackBuilder, SGML doc sources) and asserts the whitelist of files a
      usable command-line environment needs.
    - Deploys the VC++ runtime app-local into bin\ (the EDB zip has no CRT).
    - Generates the management scripts (pg-start / pg-stop / pg-restart /
      pg-status) into bin\, so they are on PATH after install.
    - Runs mandatory smoke tests: staged initdb must create a cluster, pg_ctl
      must start it on a scratch port, psql must report the packaged version,
      pg_isready must succeed and pg_ctl must stop it again.
    - Compiles an Inno Setup installer which installs to C:\pf\postgres-<major>
      by default and appends <app>\bin to the system PATH.

.PARAMETER PgVersion
    Exact PostgreSQL version as <major>.<minor>, e.g. 18.6. Empty = latest
    supported major from the official versions.json.

.PARAMETER PgMajor
    Major version track used by auto-discovery, e.g. 17. Empty = the highest
    supported major. Ignored when -PgVersion is set.

.PARAMETER BuildDir
    Working directory for cache, staging and output. Default: <repo>\build.

.PARAMETER SkipCompile
    Only resolve/download/assemble; do not invoke the Inno Setup compiler.
#>
[CmdletBinding()]
param(
    [string]$PgVersion = '',
    [string]$PgMajor   = '',
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
$StageDir = Join-Path $BuildDir 'stage\postgres'
$OutDir   = Join-Path $BuildDir 'output'

$VersionsUrl = 'https://www.postgresql.org/versions.json'
$EdbBaseUrl  = 'https://get.enterprisedb.com/postgresql'
# EDB publishes the same minor under a build revision (rev) suffix. rev starts
# at 1 and is probed upwards because older minors may have higher revs.
$EdbMaxRev   = 3
# versions.json tracks the PostgreSQL project, EDB publishes the Windows
# binaries slightly later: when a new minor has no zip yet, walk back a few
# minors instead of failing. All candidates exhausted = hard error.
$EdbMinorFallback = 3

$VcRedistUrl = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
$WixZipUrl   = 'https://github.com/wixtoolset/wix3/releases/download/wix3141rtm/wix314-binaries.zip'

# The cluster defaults (deterministic UTF-8 collation independent of the host
# locale) rely on the "builtin" locale provider, which PostgreSQL introduced in
# 17 (verified: the PG 16 initdb docs list only libc/icu). Older majors would
# silently produce host-locale-dependent clusters on Chinese Windows, so they
# are rejected up front instead of shipping a differently-behaving package.
$MinSupportedMajor = 17

# VC++ runtime DLLs deployed app-local into bin\: the EDB zip ships no CRT at
# all, so postgres.exe / psql.exe would fail on a clean Windows without them.
# This set covers every vcruntime140/msvcp140 import in the staged tree.
$VcRuntimeDlls = @(
    'vcruntime140.dll', 'vcruntime140_1.dll',
    'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll',
    'msvcp140_atomic_wait.dll', 'msvcp140_codecvt_ids.dll'
)

# Subtrees (relative to the flattened stage root) dropped from the package.
$TrimmedSubtrees = @(
    'pgAdmin 4',      # 274 MB of the packed archive; a separate desktop GUI, not a CLI env
    'StackBuilder',   # EDB GUI installer component
    'doc\src'         # SGML sources (includes a 12.8 MB postgres-full.xml); doc\html is kept
)
# Individual files / file patterns dropped from bin\ (StackBuilder GUI + wxWidgets
# libs it is the only consumer of, plus upstream self-test binaries).
$TrimmedExeFiles = @('stackbuilder.exe', 'test_cloexec.exe', 'testplug.dll')
$TrimmedGlobs    = @('wx*_vc_x64_custom.dll')

# Must exist after trimming: any upstream layout change that removes one of
# these would produce a package without the documented feature set.
$RequiredFiles = @(
    'bin\postgres.exe', 'bin\initdb.exe', 'bin\pg_ctl.exe', 'bin\psql.exe',
    'bin\pg_dump.exe', 'bin\pg_restore.exe', 'bin\pg_isready.exe', 'bin\pg_config.exe',
    'bin\createdb.exe', 'bin\libpq.dll',
    'share\postgresql.conf.sample', 'share\pg_hba.conf.sample',
    'share\timezone\Asia\Shanghai',
    # The EDB Windows binaries lay the headers out flat (include\server\...),
    # not as include\postgresql\server\... like a Unix make-install.
    'include\server\postgres.h'
)

# Integration defaults (kept identical in the management scripts).
$SmokePort     = 55432
$SmokeHost     = '127.0.0.1'
$SmokePassword = 'postgres'
$DefaultPort   = 5432
$DefaultListen = '127.0.0.1'

function Write-Step([string]$msg) { Write-Host "==> $msg" -ForegroundColor Cyan }

function Download-File([string]$url, [string]$dest, [switch]$NoCache) {
    # Reuse a previously downloaded, non-empty cache file (the 340 MB EDB zip
    # in particular). -NoCache forces a fresh download for files that rotate
    # upstream (vc_redist).
    if (-not $NoCache -and (Test-Path $dest) -and ((Get-Item $dest).Length -gt 0)) {
        Write-Host "  cached: $dest"
        return
    }
    if ($NoCache -and (Test-Path $dest)) { Remove-Item -Force $dest }
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

function Test-EdbAsset([string]$version, [int]$rev) {
    $name = "postgresql-$version-$rev-windows-x64-binaries.zip"
    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Method Head -Uri "$EdbBaseUrl/$name" -ErrorAction Stop
        if ($resp.StatusCode -eq 200) { return $name }
    }
    catch { }
    return $null
}

function ConvertTo-MajorVersion([string]$major) {
    # versions.json majors are bare numbers from 10 on ("14", "18") but
    # dotted below 10 ("6.3", "7.4"). System.Version rejects a bare "14"
    # ("version string portion was too short"), so pad to major.0.
    $parts = @($major -split '\.')
    while ($parts.Count -lt 2) { $parts += '0' }
    return [version]($parts -join '.')
}

# ---------------------------------------------------------------------------
# 1. Resolve version (official versions.json; empty result = hard fail)
# ---------------------------------------------------------------------------
Write-Step 'Resolving PostgreSQL release from the official versions.json'
if ($PgVersion) {
    if ($PgVersion -notmatch '^\d+\.\d+$') { throw "Invalid -PgVersion: $PgVersion (expected <major>.<minor>, e.g. 18.6)" }
    $candidates = @($PgVersion)
    $indexNote  = 'pinned by -PgVersion'
}
else {
    if ($PgMajor -and ($PgMajor -notmatch '^\d+$')) { throw "Invalid -PgMajor: $PgMajor" }
    $rows = Invoke-RestMethod -Uri $VersionsUrl -ErrorAction Stop
    $supported = @($rows | Where-Object { $_.supported })
    if (-not $supported) { throw "No supported releases in $VersionsUrl" }

    if ($PgMajor) {
        $row = @($supported | Where-Object { $_.major -eq $PgMajor } | Select-Object -First 1)
        if (-not $row) {
            $majors = @($supported | ForEach-Object { $_.major }) -join ', '
            throw "PostgreSQL major $PgMajor is not supported (supported majors: $majors)"
        }
    }
    else {
        # numeric sort of the major strings ("18" must beat "9.6")
        $row = @($supported | Sort-Object { ConvertTo-MajorVersion $_.major } | Select-Object -Last 1)
    }

    $indexLatest = "$($row.major).$($row.latestMinor)"
    $indexNote   = "versions.json latest supported: $indexLatest (current=$($row.current))"
    # Walk back a few minors in case EDB has not published this minor yet.
    $candidates = @()
    for ($d = 0; $d -le $EdbMinorFallback; $d++) {
        $m = [int]$row.latestMinor - $d
        if ($m -lt 0) { break }
        $candidates += "$($row.major).$m"
    }
}

$AssetFile = $null
$EdbRev    = 0
foreach ($v in $candidates) {
    for ($r = 1; $r -le $EdbMaxRev; $r++) {
        $name = Test-EdbAsset $v $r
        if ($name) { $PgVersion = $v; $EdbRev = $r; $AssetFile = $name; break }
    }
    if ($AssetFile) { break }
}
if (-not $AssetFile) {
    throw "No EDB Windows binaries found for candidate(s): $($candidates -join ', ') (rev 1..$EdbMaxRev all failed)"
}
if ($candidates.Count -gt 1 -and $PgVersion -ne $candidates[0]) {
    Write-Host "  NOTE: $($candidates[0]) has no EDB binaries yet, fell back to $PgVersion" -ForegroundColor Yellow
}

$PgMajorResolved = ($PgVersion -split '\.')[0]
if ([int]$PgMajorResolved -lt $MinSupportedMajor) {
    throw "PostgreSQL $PgVersion is not supported by this package (requires major >= $MinSupportedMajor): the deterministic UTF-8/builtin-locale cluster defaults need the builtin locale provider added in PostgreSQL 17. Use pg_major/pg_version to select a newer major."
}
$DownloadUrl     = "$EdbBaseUrl/$AssetFile"
Write-Host "  PostgreSQL  : $PgVersion (major track $PgMajorResolved)"
Write-Host "  $indexNote"
Write-Host "  Package     : $AssetFile (EDB rev $EdbRev)"

# ---------------------------------------------------------------------------
# 2. Download + extract
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $CacheDir, $OutDir | Out-Null
if (Test-Path $StageDir) { Remove-Item -Recurse -Force $StageDir }
New-Item -ItemType Directory -Force -Path $StageDir | Out-Null

Write-Step 'Downloading PostgreSQL binaries (EDB, ~340 MB)'
$zipFile = Join-Path $CacheDir $AssetFile
Download-File $DownloadUrl $zipFile

Write-Step 'Extracting PostgreSQL binaries (zip)'
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

# The archive wraps everything in a single pgsql/ root folder; flatten it so
# the stage root == install root.
$inner = Join-Path $StageDir 'pgsql'
if (-not (Test-Path $inner)) {
    $tree = (Get-ChildItem -Force $StageDir | ForEach-Object { $_.Name }) -join ', '
    throw "pgsql root folder missing after extraction. Top-level entries: $tree"
}
Get-ChildItem -Force -LiteralPath $inner | Move-Item -Destination $StageDir -Force
Remove-Item -Recurse -Force -LiteralPath $inner

# ---------------------------------------------------------------------------
# 3. Trim (documented feature set) + whitelist assertions
# ---------------------------------------------------------------------------
Write-Step 'Trimming package content (pgAdmin 4 / StackBuilder / SGML doc sources)'
foreach ($rel in $TrimmedSubtrees) {
    $p = Join-Path $StageDir $rel
    if (Test-Path -LiteralPath $p) {
        Write-Host "  removing $rel"
        Remove-Item -Recurse -Force -LiteralPath $p
    }
    else {
        Write-Host "  NOTE: $rel not present in this release (skipped)" -ForegroundColor Yellow
    }
}
$binDir = Join-Path $StageDir 'bin'
foreach ($f in $TrimmedExeFiles) {
    $p = Join-Path $binDir $f
    if (Test-Path -LiteralPath $p) { Remove-Item -Force -LiteralPath $p }
}
foreach ($g in $TrimmedGlobs) {
    Get-ChildItem -LiteralPath $binDir -Filter $g -File | Remove-Item -Force
}

Write-Step 'Asserting required files are still present after trimming'
foreach ($rel in $RequiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $StageDir $rel))) {
        throw "Required file missing after trimming: $rel (upstream layout changed - review the trim list)"
    }
}
# ICU library names carry the ICU major version (icuuc77/icudt77 for PG 18,
# icuuc72 for PG 16...), so assert by pattern instead of hardcoding.
foreach ($pat in @('icuuc*.dll', 'icudt*.dll', 'icuin*.dll')) {
    $hit = @(Get-ChildItem -LiteralPath $binDir -Filter $pat -File)
    if (-not $hit) { throw "ICU library $pat missing from bin\ after trimming" }
}

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
# 4. VC++ runtime DLLs, app-local into bin\
# ---------------------------------------------------------------------------
Write-Step 'Downloading VC++ runtime redist (vc_redist.x64.exe)'
# Always re-fetch: aka.ms/vs/17/release tracks the latest 14.x runtime, so a
# cache would silently pin an outdated CRT (same rationale as php/build.ps1).
$vcRedistExe = Join-Path $CacheDir 'vc_redist.x64.exe'
Download-File $VcRedistUrl $vcRedistExe -NoCache
$VcRedistVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($vcRedistExe).FileVersion
Write-Host "  VC++ runtime : $VcRedistVersion"

Write-Step 'Downloading WiX 3.14 toolset (dark.exe, for redist extraction)'
# Pinned tool version, safe to cache.
$wixZip = Join-Path $CacheDir 'wix314-binaries.zip'
Download-File $WixZipUrl $wixZip

Write-Step 'Extracting VC++ runtime DLLs (app-local deployment)'
$wixDir = Join-Path $CacheDir 'wix314'
if (-not (Test-Path (Join-Path $wixDir 'dark.exe'))) {
    if (Test-Path $wixDir) { Remove-Item -Recurse -Force $wixDir }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($wixZip, $wixDir)
}
# vc_redist.x64.exe is a WiX Burn bundle: 7-Zip cannot open it and its /layout
# mode needs elevation plus writes to C:\Windows\Temp. dark.exe decompiles the
# bundle offline into payload MSIs; msiexec /a then extracts the MSI payload.
$vcX = Join-Path $CacheDir 'vcredist-x'
if (Test-Path $vcX) { Remove-Item -Recurse -Force $vcX }
& (Join-Path $wixDir 'dark.exe') -nologo -x $vcX $vcRedistExe
if ($LASTEXITCODE -ne 0) { throw "dark.exe failed with exit code $LASTEXITCODE" }
$vcMsi = Join-Path $vcX 'AttachedContainer\packages\vcRuntimeMinimum_amd64\vc_runtimeMinimum_x64.msi'
if (-not (Test-Path $vcMsi)) { throw 'vc_runtimeMinimum_x64.msi not found in redist bundle' }
$vcOut = Join-Path $vcX 'out-min'
$msiProc = Start-Process -FilePath 'msiexec.exe' -Wait -PassThru `
    -ArgumentList @('/a', "`"$vcMsi`"", '/qn', "TARGETDIR=`"$vcOut`"")
if ($msiProc.ExitCode -ne 0) { throw "msiexec /a failed with exit code $($msiProc.ExitCode)" }
foreach ($dll in $VcRuntimeDlls) {
    $src = Join-Path $vcOut "System64\$dll"
    if (-not (Test-Path $src)) { throw "$dll not found in extracted VC++ runtime" }
    Copy-Item -Force $src (Join-Path $binDir $dll)
    $fv = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $binDir $dll)).FileVersion
    if ($fv -notmatch '^14\.') { throw "Unexpected VC++ runtime version for ${dll}: $fv" }
}
Write-Host "  $($VcRuntimeDlls.Count) CRT DLLs staged into bin\ (app-local, runtime $VcRedistVersion)"

# ---------------------------------------------------------------------------
# 5. Management scripts (generated into bin\, on PATH after install)
# ---------------------------------------------------------------------------
$initdbExe  = Join-Path $binDir 'initdb.exe'
$pgCtlExe   = Join-Path $binDir 'pg_ctl.exe'
$psqlExe    = Join-Path $binDir 'psql.exe'
$readyExe   = Join-Path $binDir 'pg_isready.exe'

Write-Step 'Verifying the staged initdb supports the builtin locale provider'
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$initdbHelp = (& $initdbExe --help 2>&1) -join "`n"
$ErrorActionPreference = $prevEap
if ($initdbHelp -notmatch '--builtin-locale') {
    throw "Staged initdb does not support --builtin-locale (builtin locale provider, PG 17+): the EDB build differs from the PostgreSQL docs. Refusing to ship host-locale-dependent cluster defaults."
}
# C.UTF-8 via the builtin provider: deterministic UTF8 collation independent
# of the host locale (Chinese Windows libc locales would derive GBK-ish
# encodings and unstable sort orders). ICU stays bundled for per-database
# zh-CN collations (CREATE DATABASE ... LOCALE_PROVIDER icu ICU_LOCALE 'zh-CN').
$LocaleArgs      = '--locale-provider=builtin --builtin-locale=C.UTF-8'
$LocaleArgsArray = @('--locale-provider=builtin', '--builtin-locale=C.UTF-8')
Write-Host "  initdb locale args: $LocaleArgs"

Write-Step 'Generating management scripts into bin\'

$startBat = @'
@echo off
rem pg-start - start the bundled PostgreSQL server (generated by win-env)
chcp 65001 >nul
setlocal EnableExtensions
set "BIN=%~dp0"
for %%I in ("%~dp0..") do set "APPDIR=%%~fI"
set "DATA=%APPDIR%\data"
set "LOG=%DATA%\logs\server.log"
set "PORT=__DEFAULT_PORT__"
set "LISTEN=__DEFAULT_LISTEN__"
set "PASSWORD=__DEFAULT_PASSWORD__"
set "PG_LOCALE_ARGS=__LOCALE_ARGS__"

rem Reuse the port / listen address of the previous run.
if exist "%DATA%\win-env.env" for /f "usebackq tokens=1,2 delims==" %%A in ("%DATA%\win-env.env") do (
  if /i "%%A"=="PORT" set "PORT=%%B"
  if /i "%%A"=="LISTEN" set "LISTEN=%%B"
)

:parse
if "%~1"=="" goto parsed
if /i "%~1"=="--port" ( set "PORT=%~2" & shift & shift & goto parse )
if /i "%~1"=="--listen" ( set "LISTEN=%~2" & shift & shift & goto parse )
if /i "%~1"=="--password" ( set "PASSWORD=%~2" & shift & shift & goto parse )
if /i "%~1"=="-h" goto usage
if /i "%~1"=="--help" goto usage
echo [pg-start] 未知参数: %~1
goto usage
:parsed

if exist "%DATA%\PG_VERSION" goto running_check

echo [pg-start] 首次启动：正在初始化数据目录（约 10-30 秒，请稍候）...
echo [pg-start]   %DATA%
rem initdb 要求目标目录"不存在或为空"：所以口令临时文件不能放进 data，
rem logs 也要等 initdb 成功后再建（先建会让 data 非空，initdb 直接失败）。
if not exist "%DATA%" mkdir "%DATA%"
set "PWFILE=%TEMP%\pg-start-win-env.pw.tmp"
> "%PWFILE%" echo %PASSWORD%
"%BIN%initdb.exe" -D "%DATA%" -U postgres -E UTF8 %PG_LOCALE_ARGS% --auth-host=scram-sha-256 --pwfile="%PWFILE%" -c listen_addresses=%LISTEN% -c port=%PORT% -c timezone=Asia/Shanghai -c log_timezone=Asia/Shanghai
set "RC=%ERRORLEVEL%"
del /f /q "%PWFILE%" >nul 2>&1
if not "%RC%"=="0" (
  echo [pg-start] initdb 初始化失败（退出码 %RC%），详见上方输出
  exit /b %RC%
)
echo [pg-start] 数据目录初始化完成
if not exist "%DATA%\logs" mkdir "%DATA%\logs"

:running_check
set "CHECKHOST=%LISTEN%"
if "%CHECKHOST%"=="0.0.0.0" set "CHECKHOST=127.0.0.1"
if "%CHECKHOST%"=="*" set "CHECKHOST=127.0.0.1"
"%BIN%pg_isready.exe" -h %CHECKHOST% -p %PORT% -q -t 3
if "%ERRORLEVEL%"=="0" (
  echo [pg-start] PostgreSQL 已在运行，端口 %PORT%（如需重启请用 pg-restart）
  exit /b 0
)

echo [pg-start] 正在启动 PostgreSQL（端口 %PORT%）...
"%BIN%pg_ctl.exe" start -D "%DATA%" -l "%LOG%" -w -t 60 -o "-p %PORT% -h %LISTEN%"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo [pg-start] 启动失败（退出码 %RC%），日志：%LOG%
  echo [pg-start] 端口被占用时可换端口：pg-start --port 5433
  exit /b %RC%
)

> "%DATA%\win-env.env" echo PORT=%PORT%
>> "%DATA%\win-env.env" echo LISTEN=%LISTEN%

"%BIN%pg_isready.exe" -h %CHECKHOST% -p %PORT% -t 10
if not "%ERRORLEVEL%"=="0" (
  echo [pg-start] 警告：服务进程已启动但 pg_isready 未能确认可用
  exit /b 0
)

echo [pg-start]  PostgreSQL 已启动
echo [pg-start]    端口     : %PORT%
echo [pg-start]    监听     : %LISTEN%
echo [pg-start]    数据目录 : %DATA%
echo [pg-start]    日志     : %LOG%
echo [pg-start]    连接示例 : set PGPASSWORD=口令  然后 psql -U postgres -h %CHECKHOST% -p %PORT% -d postgres
echo [pg-start]    停止     : pg-stop
exit /b 0

:usage
echo 用法: pg-start [--port 5432] [--listen 127.0.0.1] [--password postgres]
echo.
echo   首次执行会自动初始化数据目录（initdb，超级用户 postgres）。
echo   --port / --listen 会写入 data\win-env.env，pg-restart 沿用最近一次的取值。
echo   口令通过 %%TEMP%% 下的临时文件传给 initdb，初始化后立即删除，不写入配置文件。
echo   口令请避免使用批处理特殊字符（例如 ^& ^| ^< ^> ^^）。
exit /b 1
'@

$stopBat = @'
@echo off
rem pg-stop - stop the bundled PostgreSQL server (generated by win-env)
chcp 65001 >nul
setlocal EnableExtensions
set "BIN=%~dp0"
for %%I in ("%~dp0..") do set "APPDIR=%%~fI"
set "DATA=%APPDIR%\data"
set "MODE=fast"

:parse
if "%~1"=="" goto parsed
if /i "%~1"=="-m" ( set "MODE=%~2" & shift & shift & goto parse )
if /i "%~1"=="--mode" ( set "MODE=%~2" & shift & shift & goto parse )
if /i "%~1"=="-h" goto usage
if /i "%~1"=="--help" goto usage
echo [pg-stop] 未知参数: %~1
goto usage
:parsed

if not exist "%DATA%\PG_VERSION" (
  echo [pg-stop] 数据目录尚未初始化，PostgreSQL 未启动
  exit /b 0
)
"%BIN%pg_ctl.exe" status -D "%DATA%" >nul 2>&1
if not "%ERRORLEVEL%"=="0" (
  echo [pg-stop] PostgreSQL 未启动
  exit /b 0
)

echo [pg-stop] 正在停止 PostgreSQL（模式 %MODE%）...
"%BIN%pg_ctl.exe" stop -D "%DATA%" -m %MODE% -w -t 60
if not "%ERRORLEVEL%"=="0" (
  echo [pg-stop] 停止失败，详见上方输出
  echo [pg-stop] 无响应时可用强制模式：pg-stop -m immediate
  exit /b 1
)
echo [pg-stop] PostgreSQL 已停止
exit /b 0

:usage
echo 用法: pg-stop [-m fast^|smart^|immediate]   （默认 fast）
exit /b 1
'@

$restartBat = @'
@echo off
rem pg-restart - restart the bundled PostgreSQL server (generated by win-env)
chcp 65001 >nul
setlocal EnableExtensions
echo [pg-restart] 停止...
call "%~dp0pg-stop.bat"
echo [pg-restart] 启动...
call "%~dp0pg-start.bat" %*
'@

$statusBat = @'
@echo off
rem pg-status - report the state of the bundled PostgreSQL server (generated by win-env)
chcp 65001 >nul
setlocal EnableExtensions
set "BIN=%~dp0"
for %%I in ("%~dp0..") do set "APPDIR=%%~fI"
set "DATA=%APPDIR%\data"
set "PORT=__DEFAULT_PORT__"
if exist "%DATA%\win-env.env" for /f "usebackq tokens=1,2 delims==" %%A in ("%DATA%\win-env.env") do if /i "%%A"=="PORT" set "PORT=%%B"

echo [pg-status] 安装目录 : %APPDIR%
echo [pg-status] 数据目录 : %DATA%
echo [pg-status] 端口     : %PORT%
echo [pg-status] 日志     : %DATA%\logs\server.log
echo.

if not exist "%DATA%\PG_VERSION" (
  echo [pg-status] 数据目录尚未初始化，首次执行 pg-start 会自动初始化
  echo [pg-status] 状态: 未初始化
  exit /b 3
)

"%BIN%pg_ctl.exe" status -D "%DATA%"
set "RC=%ERRORLEVEL%"
echo.
"%BIN%pg_isready.exe" -h 127.0.0.1 -p %PORT% -t 5
echo.
if not "%RC%"=="0" (
  echo [pg-status] 状态: 未运行
  exit /b 3
)
echo [pg-status] 状态: 运行中
exit /b 0
'@

$scriptMap = @{
    'pg-start.bat'   = $startBat
    'pg-stop.bat'    = $stopBat
    'pg-restart.bat' = $restartBat
    'pg-status.bat'  = $statusBat
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
foreach ($name in $scriptMap.Keys) {
    $body = $scriptMap[$name]
    $body = $body -replace '__LOCALE_ARGS__', $LocaleArgs
    $body = $body -replace '__DEFAULT_PORT__', $DefaultPort
    $body = $body -replace '__DEFAULT_LISTEN__', $DefaultListen
    $body = $body -replace '__DEFAULT_PASSWORD__', $SmokePassword
    # cmd re-reads/decodes the batch text per line, so chcp 65001 at the top
    # makes the UTF-8 (no BOM) Chinese messages render correctly; the scripts
    # are written with WriteAllText + UTF8Encoding($false), never Out-File.
    # Line endings are forced to CRLF: cmd's goto/label bookkeeping is
    # unreliable in LF-only .bat files and these scripts use goto parse/usage.
    $body = ($body.TrimStart("`r", "`n")) -replace "`r?`n", "`r`n"
    [IO.File]::WriteAllText((Join-Path $binDir $name), $body, $utf8NoBom)
}
Write-Host "  4 management scripts staged into bin\"

# The scripts must be valid UTF-8 without BOM (cmd + chcp 65001 contract).
foreach ($name in $scriptMap.Keys) {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $binDir $name))
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "$name must not carry a BOM (cmd would print stray bytes)"
    }
    # Byte-level proof that the Chinese messages survived as UTF-8: had the file
    # been written as ANSI (Out-File -Encoding utf8/Default) this decode would
    # yield mojibake and no CJK codepoint would appear.
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if ($text -notmatch '[\u4e00-\u9fff]') {
        throw "$name is not valid UTF-8 (Chinese messages unreadable after decode)"
    }
}

# ---------------------------------------------------------------------------
# 6. Smoke test (mandatory: staged tree must initdb, start, answer, stop)
# ---------------------------------------------------------------------------
Write-Step 'Smoke testing staged PostgreSQL (initdb / pg_ctl start / psql / pg_isready / pg_ctl stop)'
$smokeData = Join-Path $CacheDir 'pgsmoke'
$smokeLog  = Join-Path $CacheDir 'pgsmoke.log'
$pwFile    = Join-Path $CacheDir 'pgsmoke.pw.tmp'
$prevEap   = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    if (Test-Path $smokeData) { Remove-Item -Recurse -Force $smokeData }
    if (Test-Path $smokeLog) { Remove-Item -Force $smokeLog }
    # initdb reads the superuser password from --pwfile; deleted right after.
    [IO.File]::WriteAllText($pwFile, $SmokePassword, (New-Object System.Text.ASCIIEncoding))

    Write-Host "  initdb -> $smokeData (port $SmokePort)"
    & $initdbExe -D $smokeData -U postgres -E UTF8 @LocaleArgsArray `
        --auth-host=scram-sha-256 "--pwfile=$pwFile" `
        -c "listen_addresses=$SmokeHost" -c "port=$SmokePort" `
        -c 'timezone=Asia/Shanghai' -c 'log_timezone=Asia/Shanghai'
    if ($LASTEXITCODE -ne 0) { throw "initdb failed with exit code $LASTEXITCODE" }
    Remove-Item -Force $pwFile -ErrorAction SilentlyContinue

    Write-Host '  pg_ctl start -w'
    # pg_ctl (like initdb) re-executes the postmaster with a restricted token,
    # so an elevated terminal / CI admin token works as well.
    & $pgCtlExe start -D $smokeData -l $smokeLog -w -t 60
    if ($LASTEXITCODE -ne 0) {
        $tail = if (Test-Path $smokeLog) { (Get-Content $smokeLog -Tail 40) -join "`n" } else { '(no server log)' }
        throw "pg_ctl start failed with exit code $LASTEXITCODE. Server log:`n$tail"
    }

    $env:PGPASSWORD = $SmokePassword
    Write-Host '  psql -tAc "select version()"'
    $psqlOut = (& $psqlExe -U postgres -h $SmokeHost -p $SmokePort -d postgres -tAc 'select version()' 2>&1) -join "`n"
    $psqlCode = $LASTEXITCODE
    if ($psqlCode -ne 0 -or $psqlOut -notmatch [regex]::Escape("PostgreSQL $PgVersion")) {
        throw "psql smoke test failed (exit $psqlCode): $psqlOut"
    }
    Write-Host "  $($psqlOut.Trim())"

    Write-Host '  pg_isready'
    $readyOut = (& $readyExe -h $SmokeHost -p $SmokePort -t 10 2>&1) -join "`n"
    $readyCode = $LASTEXITCODE
    if ($readyCode -ne 0) { throw "pg_isready failed (exit $readyCode): $readyOut" }
    Write-Host "  $($readyOut.Trim())"

    Write-Host '  pg_ctl stop -m fast -w'
    & $pgCtlExe stop -D $smokeData -m fast -w -t 60
    if ($LASTEXITCODE -ne 0) { throw "pg_ctl stop failed with exit code $LASTEXITCODE" }
}
finally {
    # Never leave a scratch postmaster running: a stray one would hold the
    # data directory open and break the next build.
    if (Test-Path (Join-Path $smokeData 'postmaster.pid')) {
        & $pgCtlExe stop -D $smokeData -m immediate -w -t 30 2>&1 | Out-Null
    }
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    Remove-Item -Force $pwFile -ErrorAction SilentlyContinue
    Remove-Item -Force $smokeLog -ErrorAction SilentlyContinue
    if (Test-Path $smokeData) { Remove-Item -Recurse -Force $smokeData -ErrorAction SilentlyContinue }
    $ErrorActionPreference = $prevEap
}
Write-Host '  initdb -> start -> psql -> pg_isready -> stop cycle OK'

# ---------------------------------------------------------------------------
# 7. Compile installer
# ---------------------------------------------------------------------------
$SetupName = "postgres-$PgVersion-setup-x64"
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
        "/DMyAppVersion=$PgVersion" `
        "/DPgMajor=$PgMajorResolved" `
        "/DStageDir=$StageDir" `
        "/DOutputDir=$OutDir" `
        "/DOutputBaseFilename=$SetupName"
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }
}
else {
    Write-Step 'Skipping installer compilation (-SkipCompile)'
}

# ---------------------------------------------------------------------------
# 8. Metadata / release notes / GitHub outputs
# ---------------------------------------------------------------------------
$trimmedList = @($TrimmedSubtrees) + @($TrimmedExeFiles) + @($TrimmedGlobs)

$buildInfo = [ordered]@{
    package         = 'postgres'
    pgVersion       = $PgVersion
    pgMajor         = $PgMajorResolved
    edbRev          = $EdbRev
    sourceAsset     = $AssetFile
    releaseUrl      = $DownloadUrl
    versionsIndexUrl = $VersionsUrl
    releaseNote     = $indexNote
    vcRedistVersion = $VcRedistVersion
    vcRedistUrl     = $VcRedistUrl
    vcRuntimeDlls   = $VcRuntimeDlls
    trimmed         = $trimmedList
    defaultPath     = "C:\pf\postgres-$PgMajorResolved"
    pathEntries     = @("C:\pf\postgres-$PgMajorResolved\bin")
    commands        = @('psql', 'pg_ctl', 'initdb', 'pg_dump', 'pg_restore', 'createdb',
                        'pg-start', 'pg-stop', 'pg-restart', 'pg-status')
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
    $notes = @"
# PostgreSQL $PgVersion Windows x64 一键安装包

## 组件版本

| 组件 | 版本 / 来源 |
| --- | --- |
| PostgreSQL | $PgVersion（EDB 官方 binaries zip，构建修订 $EdbRev，x64） |
| 版本发现 | postgresql.org 官方 versions.json（$indexNote） |
| VC++ 运行库 | $VcRedistVersion（app-local：$($VcRuntimeDlls.Count) 个 CRT DLL 源自官方 vc_redist.x64.exe，释放到 ``bin``） |

## 默认行为

- 默认安装目录：``C:\pf\postgres-$PgMajorResolved``（安装向导中可修改，**仅带主版本号后缀**）
- 安装后自动将 ``<安装目录>\bin`` 加入系统 PATH，新开命令行可直接使用 ``psql``、``pg_ctl``、``pg_dump`` 等命令
- 安装内容为官方 binaries zip 解压树（已扁平化 ``pgsql\`` 根目录），安装器只做原样释放，不在安装期下载或拼装任何内容
- 已裁剪（不随包提供）：pgAdmin 4（独立桌面工具）、StackBuilder（EDB GUI 安装器组件）、``doc\src`` SGML 源码文档；``doc\html`` 离线文档保留
- 安装器**不注册 Windows 服务、不创建数据目录**，可反复安装/卸载；安装/卸载对系统 PATH 均为幂等精确操作

## 管理脚本（随包装入 ``bin``，裸命令可用）

| 命令 | 说明 |
| --- | --- |
| ``pg-start [--port 5432] [--listen 127.0.0.1] [--password postgres]`` | 首次执行自动 ``initdb`` 初始化数据目录（超级用户 ``postgres``），随后 ``pg_ctl start -w`` 启动并复核；已在运行时直接提示 |
| ``pg-stop [-m fast^|smart^|immediate]`` | ``pg_ctl stop -w``；未运行时提示“未启动”而非报错 |
| ``pg-restart`` | 先停后启，沿用最近一次 ``--port`` / ``--listen`` |
| ``pg-status`` | 打印安装目录、数据目录、端口、日志路径与运行状态 |

- 数据目录：``<安装目录>\data``（**首次 ``pg-start`` 时由 initdb 创建**，不在安装期创建），端口 / 监听地址记于 ``data\win-env.env``
- 默认凭据：``postgres`` / ``postgres``（scram-sha-256，仅监听回环地址），连接串 ``postgres://postgres:postgres@127.0.0.1:5432/postgres``
- 编码与时区：``UTF8`` + 确定性排序（``--locale-provider=builtin --builtin-locale=C.UTF-8``，PG 17+；更早版本用 ``--locale=C``），``timezone`` / ``log_timezone`` 均为 ``Asia/Shanghai``
- 管理员终端可直接使用：``initdb`` / ``pg_ctl`` 会以受限令牌重新执行 ``postgres.exe``（PostgreSQL 明确禁止以管理员令牌直接运行 postgres），因此**不要**手工直接调用 ``postgres.exe``
- **卸载保留 ``data`` 目录**（用户数据不在安装器的文件清单内，不会被删除）；不需要时请手动删除
- 需要 pgAdmin 图形客户端时请另行安装官方 pgAdmin（不在本包范围内）

## 校验

SHA-256（$SetupName.exe）：

``$hash``
"@
    # WriteAllText with UTF8(no BOM): Out-File -Encoding utf8 in PS 5.1 emits
    # a BOM, which GitHub renders as a stray character at the top of the body.
    [IO.File]::WriteAllText((Join-Path $OutDir 'release-notes.md'), $notes, $utf8NoBom)
}

if ($env:GITHUB_OUTPUT) {
    "pg_version=$PgVersion"       | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
    "pg_major=$PgMajorResolved"   | Out-File -Encoding ascii -Append $env:GITHUB_OUTPUT
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
