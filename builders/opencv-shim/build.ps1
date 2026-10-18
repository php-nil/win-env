﻿# build.ps1
#
# Build a minimal OpenCV from source with MinGW + CMake, then build the shim
# against it.
#
# WHY THIS SCRIPT EXISTS
#   The "gnu" route of .github/workflows/build-opencv-shim.yml builds a minimal,
#   static OpenCV with the portable MinGW toolchain (setup-mingw.ps1, this dir) so
#   that opencv_shim.dll is self-contained: no ~70MB opencv_world*.dll and no
#   MSVC runtime DLLs have to be shipped. The shim only needs cv::matchTemplate,
#   so the build is restricted to the core / imgproc modules.
#
# OUTPUTS
#   <InstallDir>                      OpenCV install prefix (has OpenCVConfig.cmake)
#   <BuildDir>\shim\opencv_shim.dll   the compiled, self-contained shim
#   <BuildDir>\opencv-*.log           per-stage logs
#   <BuildDir>\build-status.txt       one-line OK/FAIL record
#
# USAGE
#   The workflow calls this with explicit absolute paths. A local run can rely
#   on the repo-relative defaults:
#   powershell -ExecutionPolicy Bypass -File builders\opencv-shim\build.ps1 -Stage configure
#   powershell -ExecutionPolicy Bypass -File builders\opencv-shim\build.ps1 -Stage build
#   powershell -ExecutionPolicy Bypass -File builders\opencv-shim\build.ps1 -Stage install
#   powershell -ExecutionPolicy Bypass -File builders\opencv-shim\build.ps1 -Stage shim
#   powershell -ExecutionPolicy Bypass -File builders\opencv-shim\build.ps1 -Stage all
#
# DESIGN NOTES
#   * BUILD_LIST keeps only core / imgproc.
#     Image find needs no codecs, no highgui, no videoio, no dnn; dropping them
#     cuts both build time and binary size substantially.
#   * All image codecs and 3rdparty deps are off (the shim feeds raw
#     row-contiguous grayscale buffers in and gets coordinates back out).
#   * CPU_DISPATCH is emptied to skip compiling a pile of SIMD variants; the
#     baseline is SSE4.2, which every x86-64 CPU since ~2008 supports.
#   * OpenCV is linked statically (BUILD_SHARED_LIBS=OFF), so the shim is
#     self-contained and nothing else has to ship alongside it.
#
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 reads .ps1 files using
# the ANSI code page unless there is a BOM, so non-ASCII comments get mangled
# and can break parsing.

param(
    [ValidateSet("configure", "build", "install", "shim", "all")]
    [string]$Stage = "all",

    [string]$OpenCvSrc  = "",
    [string]$BuildDir   = "",
    [string]$InstallDir = "",
    [string]$MinGwBin   = "",
    [int]$Jobs = 4
)

# NOTE: deliberately NOT "Stop". With ErrorActionPreference=Stop, PowerShell 5.1
# turns anything a native command writes to stderr into a terminating
# NativeCommandError -- and both CMake and Ninja write ordinary warnings (and
# progress output) to stderr. We check $LASTEXITCODE explicitly instead.
$ErrorActionPreference = "Continue"

# $PSScriptRoot is builders\opencv-shim; the repo root is two levels up.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# Repo-relative defaults so a local run needs no arguments; the workflow always
# passes explicit absolute paths.
if (-not $BuildDir)   { $BuildDir   = Join-Path $repoRoot "build-mingw" }
if (-not $InstallDir) { $InstallDir = Join-Path $repoRoot "mingw-install" }
if (-not $MinGwBin)   { $MinGwBin   = Join-Path $repoRoot "tools\mingw64\bin" }
if (-not $OpenCvSrc) {
    $cand = Get-ChildItem (Join-Path $repoRoot "opencv-src") -Directory -Filter "opencv-*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($cand) { $OpenCvSrc = $cand.FullName }
    else { throw "-OpenCvSrc not given and no extracted source found under <repo>\opencv-src" }
}

New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

# --- toolchain lookup -------------------------------------------------------
# cmake and ninja come from PATH: the workflow installs ninja via pip and uses
# the runner's cmake. No machine-specific hardcoded paths.
$cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
$ninja = (Get-Command ninja -ErrorAction SilentlyContinue).Source
if (-not $cmake) { throw "cmake not found on PATH. Install it (e.g. pip install cmake) or add it to PATH." }
if (-not $ninja) { throw "ninja not found on PATH. Install it (e.g. pip install ninja) or add it to PATH." }
if (-not (Test-Path (Join-Path $MinGwBin "g++.exe"))) { throw "g++ not found under $MinGwBin" }

$env:PATH = $MinGwBin + ";" + $env:PATH

$gcc = Join-Path $MinGwBin "gcc.exe"
$gxx = Join-Path $MinGwBin "g++.exe"

function Invoke-Configure {
    if (-not (Test-Path $OpenCvSrc)) { throw "OpenCV sources not found: $OpenCvSrc" }

    $cmakeArgs = @(
        "-S", $OpenCvSrc,
        "-B", $BuildDir,
        "-G", "Ninja",
        "-DCMAKE_MAKE_PROGRAM=$ninja",
        "-DCMAKE_C_COMPILER=$gcc",
        "-DCMAKE_CXX_COMPILER=$gxx",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DCMAKE_INSTALL_PREFIX=$InstallDir",
        # CMake 4.x rejects very old cmake_minimum_required; 3.5 is its floor.
        "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
        # only the modules image find actually needs
        "-DBUILD_LIST=core,imgproc",
        # static OpenCV -> self-contained shim
        "-DBUILD_SHARED_LIBS=OFF",
        # BUILD_LIST whitelists gapi off, but modules/gapi/cmake/init.cmake still
        # runs during configure and creates the "ade" target, and
        # ocv_install_target(... EXPORT OpenCVModules ...) exports it into the
        # installed OpenCVModules.cmake -- while libade.a is never built. The gnu
        # route consumes that very config via find_package, so the configure dies
        # with "the imported target ade references ... libade.a but this file does
        # not exist". WITH_ADE=OFF hits init.cmake's "if(NOT WITH_ADE) return()"
        # first, so the target is never created and never exported. It cannot
        # affect anything we build: gapi is already excluded above.
        "-DWITH_ADE=OFF",
        # MinGW ships posix threads, and OpenCV's pthreads parallel_for option is
        # default ON and visible on MinGW (root CMakeLists: VISIBLE_IF NOT WIN32
        # OR MINGW), while the MinGW branch pushes pthread into OPENCV_LINKER_LIBS.
        # Left alone, opencv_core compiles pthread code and drags
        # libwinpthread-1.dll into the delivery, breaking self-containment.
        # matchTemplate's CPU path is serial, so the parallel framework is pure
        # liability here. The stronger OPENCV_DISABLE_THREAD_SUPPORT=ON is NOT
        # usable on MinGW: HAVE_PTHREAD holds there and the root CMakeLists aborts
        # the configure with "Thread execution might be in use in some component."
        "-DWITH_PTHREADS_PF=OFF",
        # no build-time extras
        "-DBUILD_TESTS=OFF", "-DBUILD_PERF_TESTS=OFF", "-DBUILD_EXAMPLES=OFF",
        "-DBUILD_opencv_apps=OFF", "-DBUILD_DOCS=OFF", "-DBUILD_JAVA=OFF",
        "-DBUILD_opencv_python2=OFF", "-DBUILD_opencv_python3=OFF",
        "-DBUILD_opencv_java_bindings_generator=OFF",
        "-DBUILD_opencv_python_bindings_generator=OFF",
        "-DBUILD_opencv_js_bindings_generator=OFF",
        "-DBUILD_opencv_objc_bindings_generator=OFF",
        # no image codecs (input is a raw grayscale buffer) -> no 3rdparty deps
        "-DWITH_PNG=OFF", "-DWITH_JPEG=OFF", "-DWITH_TIFF=OFF", "-DWITH_WEBP=OFF",
        "-DWITH_OPENJPEG=OFF", "-DWITH_JASPER=OFF", "-DWITH_OPENEXR=OFF",
        "-DWITH_IMGCODEC_HDR=OFF", "-DWITH_IMGCODEC_SUNRASTER=OFF",
        "-DWITH_IMGCODEC_PXM=OFF", "-DWITH_IMGCODEC_PFM=OFF",
        # everything that would download or slow the build down
        "-DWITH_IPP=OFF", "-DWITH_ITT=OFF", "-DWITH_OPENCL=OFF",
        "-DWITH_OPENCLAMDBLAS=OFF", "-DWITH_OPENCLAMDFFT=OFF",
        "-DWITH_TBB=OFF", "-DWITH_EIGEN=OFF", "-DWITH_LAPACK=OFF",
        "-DWITH_FFMPEG=OFF", "-DWITH_1394=OFF", "-DWITH_DSHOW=OFF",
        "-DWITH_MSMF=OFF", "-DWITH_GSTREAMER=OFF", "-DWITH_QUIRC=OFF",
        "-DWITH_PROTOBUF=OFF", "-DBUILD_PROTOBUF=OFF",
        "-DWITH_OPENVX=OFF", "-DWITH_VA=OFF", "-DWITH_VA_INTEL=OFF",
        "-DWITH_OBSENSOR=OFF",
        # SSE4.2 baseline, no multi-version dispatch (much shorter build)
        "-DCPU_BASELINE=SSE4_2", "-DCPU_DISPATCH=",
        "-DOPENCV_GENERATE_PKGCONFIG=OFF",
        "-DOPENCV_GENERATE_SETUPVARS=OFF",
        "-DENABLE_CONFIG_VERIFICATION=OFF"
    )

    Write-Host "== configure =="
    & $cmake @cmakeArgs 2>&1 | Tee-Object -FilePath (Join-Path $BuildDir "opencv-configure.log")
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed (exit $LASTEXITCODE)" }
}

function Invoke-Build {
    Write-Host "== build =="
    & $cmake --build $BuildDir --parallel $Jobs 2>&1 |
        Tee-Object -FilePath (Join-Path $BuildDir "opencv-build.log")
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed (exit $LASTEXITCODE)" }
}

function Invoke-Install {
    Write-Host "== install =="
    & $cmake --install $BuildDir 2>&1 |
        Tee-Object -FilePath (Join-Path $BuildDir "opencv-install.log")
    if ($LASTEXITCODE -ne 0) { throw "cmake install failed (exit $LASTEXITCODE)" }
}

function Find-OpenCvConfigDir([string]$Root) {
    # The install prefix root contains an "OpenCV Windows Pack" OpenCVConfig.cmake
    # that only understands the MSVC layout (x64/vc16/lib), so it reports
    # "no binaries compatible with your configuration" for a MinGW static build.
    # The usable one is whichever directory also holds OpenCVModules.cmake. Without
    # it there is nothing find_package can consume, so fail here with a readable
    # message instead of handing the MSVC-only config to CMake.
    $modules = Get-ChildItem $Root -Recurse -Filter "OpenCVModules.cmake" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($modules) { return $modules.DirectoryName }
    throw "OpenCVModules.cmake not found under $Root - the install prefix only holds the 'Windows Pack' config, which cannot describe a MinGW static build"
}

function Invoke-Shim {
    Write-Host "== shim =="
    $shimBuild = Join-Path $BuildDir "shim"
    $ocvDir = Find-OpenCvConfigDir $InstallDir
    Write-Host "OpenCV_DIR = $ocvDir"

    # $PSScriptRoot is the builders\opencv-shim\ directory: it holds
    # CMakeLists.txt and opencv_shim.cpp, so it is the CMake source dir for
    # the shim.
    & $cmake -S $PSScriptRoot -B $shimBuild -G Ninja `
        "-DCMAKE_MAKE_PROGRAM=$ninja" `
        "-DCMAKE_C_COMPILER=$gcc" `
        "-DCMAKE_CXX_COMPILER=$gxx" `
        "-DCMAKE_BUILD_TYPE=Release" `
        "-DOpenCV_DIR=$ocvDir" `
        2>&1 | Tee-Object -FilePath (Join-Path $BuildDir "shim-configure.log")
    if ($LASTEXITCODE -ne 0) { throw "shim configure failed (exit $LASTEXITCODE)" }

    & $cmake --build $shimBuild --parallel $Jobs 2>&1 |
        Tee-Object -FilePath (Join-Path $BuildDir "shim-build.log")
    if ($LASTEXITCODE -ne 0) { throw "shim build failed (exit $LASTEXITCODE)" }
}

# Record the outcome in a durable status file. Callers may pipe this script's
# output in ways that swallow the exit code, and the per-stage logs are the only
# other record -- a single line here makes "did it work?" unambiguous.
$statusFile = Join-Path $BuildDir "build-status.txt"
$status = "OK"
try {
    switch ($Stage) {
        "configure" { Invoke-Configure }
        "build" { Invoke-Build }
        "install" { Invoke-Install }
        "shim" { Invoke-Shim }
        "all" { Invoke-Configure; Invoke-Build; Invoke-Install; Invoke-Shim }
    }
} catch {
    $status = "FAIL: $($_.Exception.Message)"
}

"$(Get-Date -Format o)  stage=$Stage  $status" |
    Out-File -FilePath $statusFile -Append -Encoding utf8

if ($status -ne "OK") {
    Write-Host $status
    exit 1
}
Write-Host "OK: stage=$Stage"
