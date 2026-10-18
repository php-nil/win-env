# OpenCV shim · MSVC 备选路线（设计说明）

> **状态**：备选路线，已实现于 [build-opencv-shim.yml](../.github/workflows/build-opencv-shim.yml)
> 的 `msvc` job。默认交付仍是 MinGW 自包含路线
> （[build.ps1](../builders/opencv-shim/build.ps1)：导入表只剩
> `KERNEL32.dll` + OS CRT（`msvcrt.dll`；ucrt 版工具链为 `ucrtbase.dll` +
> `api-ms-win-*.dll`）的单文件 `opencv_shim.dll`，C++ 运行库由
> `-static-libgcc -static-libstdc++` 静态链入、并关掉 pthreads 并行框架
> （`-DWITH_PTHREADS_PF=OFF`，见 §3.1）以免拖出 `libwinpthread-1.dll`、同时关掉
> 未被构建却被导出进安装 config 的 ade 目标（`-DWITH_ADE=OFF`，见 §4 第 2 步））。本文件保留 MSVC
> 路线的技术依据与旗标，供需要 MSVC 调试链（PDB / ASan / VS）时对照。
> 两条路线共用同一份 `builders/opencv-shim/opencv_shim.cpp`。

---

## 1. 方案

**静态 OpenCV `core,imgproc`（/MT + 关线程支持）+ cl /MT 直编 shim →
单文件 `opencv_shim.dll`**：交付形态与 MinGW 路线完全一致（1 文件、零运行时
依赖、零 UCRT 约束），额外获得 MSVC 调试链（PDB / ASan / VS）。shim 源码
**零改动**。

## 2. 现场事实

| 项 | 实测 |
| --- | --- |
| MSVC | VS 2022 Community，v143 工具集 14.44.35112；`VC\Auxiliary\Build\vcvars64.bat` 在 |
| CMake/Ninja | 需补：VS Installer 勾「CMake tools for C++」，或 `pip install cmake ninja` |

workflow 的 `msvc` job 用 `vswhere` 定位 `vcvars64.bat`，不写死 VS 安装路径。

## 3. 依据

### 3.1 `cv::matchTemplate` 本就串行 ⇒ 关线程支持零损失

OpenCV 4.10.0 `modules/imgproc/src/templmatch.cpp` 全文核验：无
`parallel_for_`/`thread`/`nstripes`，CPU 路径为结果矩阵分块单循环。
`OPENCV_DISABLE_THREAD_SUPPORT=ON` 是官方选项（根 `CMakeLists.txt` 消费之），
对本 shim 唯一调用路径无性能代价。

同一条结论也用于 gnu 路线，但只能换用弱一档的开关：MinGW 自带 posix 线程，
OpenCV 的 pthreads 并行框架 `WITH_PTHREADS_PF` **默认 ON 且在 MinGW 上可见**
（根 `CMakeLists.txt`：`VISIBLE_IF NOT WIN32 OR MINGW`、`VERIFY HAVE_PTHREADS_PF`），
且 MinGW 分支会把 `pthread` 加进 `OPENCV_LINKER_LIBS`——不关掉的话，`opencv_core`
会编译 pthread 代码并把 `libwinpthread-1.dll` 拖进交付，破坏"单文件自包含"。
故 gnu 路线显式 `-DWITH_PTHREADS_PF=OFF`。注意 msvc 路线用的
`OPENCV_DISABLE_THREAD_SUPPORT=ON` 在 MinGW 上**不可用**：MinGW 下 `HAVE_PTHREAD`
成立，根 `CMakeLists.txt` 在配置末尾以
`FATAL_ERROR "Thread execution might be in use in some component."` 中止。

### 3.2 CRT/UCRT 全静态，零运行时依赖

/MT 下 `libucrt.lib` 静态链入 UCRT（无伴随 DLL），编译器层 CRT 亦静态；
`BUILD_WITH_STATIC_CRT=ON` 官方即为静态构建设计（静态构建默认 ON）。
**一致性要求**：shim 与 OpenCV 静态库必须同一 CRT——本方案两侧均 /MT。
静态 OpenCV 链入自研 DLL 是通行做法（vcpkg `x64-windows-static` triplet 即此形态）。

### 3.3 shim 只用 C API：5 个符号，闸门 + 后备

shim 仅依赖 `cvInitMatHeader`/`cvCreateMat`/`cvReleaseMat`/`cvMatchTemplate`/`cvMinMaxLoc`。
OpenCV 4 移除的是 persistence/photo/video/imgcodecs/videoio 的 C API；
`cvMatchTemplate` 的 C API 在 4.x 仍在（文档树 `ocv:cfunction`，头文件 `CVAPI` 声明）。

最小 core+imgproc ≠ world 全模块，以实测收口：**构建后 `dumpbin /EXPORTS` 五个符号
缺一即不过闸**；任一缺失则 shim 内部改调 C++ `cv::matchTemplate`（同 cl 工具集，
ABI 一致；STL 不出 shim 边界），导出面不变。链接期本身也是闸门：符号缺失直接
链接失败。

### 3.4 导出面：单导出 `shim_match_template`

shim 为**单导出**，按 §5 规则 R1–R5 审计全部合规。该断言在两条路线都作为产物闸门
执行（gnu 路线 `objdump -p` 断言导出名表只有一个 `shim_match_template`，msvc 路线
`dumpbin /EXPORTS` 断言该符号存在）。

## 4. 构建步骤（已落地于 workflow 的 `msvc` job）

1. workflow 装 ninja；cmake 用 runner 预装的即可。
2. configure：裁剪集与 mingw 版逐项相同（关全部 codec/3rdparty/IPP/OpenCL/TBB、
   `CPU_BASELINE=SSE4_2`、`CPU_DISPATCH=` 空），增量旗标：

   ```
   -DBUILD_LIST=core,imgproc -DBUILD_SHARED_LIBS=OFF -DOPENCV_DISABLE_THREAD_SUPPORT=ON
   -DWITH_ADE=OFF
   ```

   （`BUILD_WITH_STATIC_CRT` 静态构建默认 ON，无需显式；**不要**加
   `-DWITH_PTHREADS_PF=ON`——MSVC 上 `HAVE_PTHREAD` 不成立，是空操作）

   `-DWITH_ADE=OFF` 两条路线都加。`BUILD_LIST` 已把 gapi 白名单剔除，但
   `modules/gapi/cmake/init.cmake` 在 configure 期仍会创建 `ade` 目标，并由
   `ocv_install_target(... EXPORT OpenCVModules ...)` 写进安装出的
   `OpenCVModules.cmake`——而 `libade.a`（gnu）/ `ade.lib`（msvc）从不构建。
   gnu 路线用 `find_package` 消费该 config，会因 "the imported target ade
   references … libade.a but this file does not exist" 直接 configure 失败；
   `WITH_ADE=OFF` 在 `init.cmake` 的 `if(NOT WITH_ADE) return()` 处短路，目标彻底
   消失，对已剔除的 gapi 无任何影响。msvc 路线不走 `find_package`（cl 直编），本不受
   影响，加同一旗标仅为让两条路线的旗标集保持一致。
3. shim 直编（不走 CMake；源文件自带 `__declspec(dllexport)`）：

   ```
   cl /nologo /O2 /MT /EHsc /std:c++17 /LD builders\opencv-shim\opencv_shim.cpp /I<install include root> ^
      /link /LIBPATH:<install lib dir> opencv_core<ver>.lib opencv_imgproc<ver>.lib ^
      /OUT:out-msvc\opencv_shim.dll
   ```

   lib 目录与文件名的版本后缀（`opencv_core4100.lib` → `...4110.lib` …）均由 job 内
   glob 递归检索 `opencv_core*.lib` 后取得，不写死路径也不硬编码。
   `-I` 指向**包含 `opencv2\` 的目录**（shim 用 `#include <opencv2/...>`）：
   `cmake --install` 的头文件布局随 host 分支而变——Windows host 走
   `OpenCVInstallLayout.cmake` 的 WIN32 分支，`OPENCV_INCLUDE_INSTALL_PATH=include`，
   头文件直接落在 `<install>\include\opencv2\...`（**没有** `opencv4` 中间层，那是
   UNIX 分支才有的）；UNIX host 才是 `<install>\include\opencv4\opencv2\...`。job 内
   由递归检索到的 `opencv_modules.hpp`（必在 `opencv2\` 内）取其上一级目录作为
   include 根，两种布局通吃，不再假设单一布局。
4. 产物落 `out-msvc\opencv_shim.dll`，作为 `opencv_shim-msvc` artifact 上传。
5. 验证闸门（job 内强制，全过才允许上传）：

   | 检查 | 期望 |
   | --- | --- |
   | `dumpbin /DEPENDENTS opencv_shim.dll` | 仅 KERNEL32（± `api-ms-win-core-*` 基础），**无任何 CRT / UCRT / concrt / opencv 依赖** |
   | `dumpbin /EXPORTS opencv_shim.dll` | 含 `shim_match_template` |
   | 链接期 | 五个 C API 符号全部可解析（缺一即链接失败） |

## 5. FFI 内存边界规则（固化条款）

适用于 shim 及其未来任何新导出；调用方（任何语言）对称遵守。

| # | 规则 |
| --- | --- |
| R1 | 入参指针调用方拥有；DLL 只读、不持有、不释放 |
| R2 | 出参由调用方分配（POD 指针） |
| R3 | DLL 内部分配必须同函数内释放，不得逃逸出边界（`cvCreateMat`→`cvReleaseMat` 同函数成对） |
| R4 | 未来新导出若返回缓冲区：必须配套 `shim_free_*` 导出，调用方只许调它释放；**调用方永不 free shim 返回的指针** |
| R5 | 边界只过 POD；CRT/STL 对象、`FILE*`、句柄不出边界（`cv::Mat` 仅 shim 内部） |

## 6. 代价与并存

| 项 | 评估 |
| --- | --- |
| 交付面/部署约束 | 与 MinGW 路线持平（1 文件、零运行时依赖） |
| 残余代价 | 一次性构建 + 第二份路线维护面；VS 工具集升级时需重编验证 |
| 残余风险 | C API 导出（§3.3 闸门 + 链接期双保险）；GCC→MSVC 代码生成差异（score 末位） |
| 功能收益 | **无**（同一份 `cv::matchTemplate`）；收益只在 MSVC 调试链（PDB/ASan/VS） |

并存策略：**默认交付不变**（MinGW）；两条路线共用同一份 `builders/opencv-shim/opencv_shim.cpp`
（C API 子集对 g++/cl 通吃）。

## 7. 核验来源（2026-10-15）

| 论断 | 来源 |
| --- | --- |
| `cv::matchTemplate` 4.10.0 CPU 路径串行（全文无 `parallel_for_`/`thread`/`nstripes`） | `modules/imgproc/src/templmatch.cpp` 全文核验（Debian Sources raw） |
| `OPENCV_DISABLE_THREAD_SUPPORT` 官方选项，根 CMakeLists 消费（REMOVE_ITEM pthread） | OpenCV 根 `CMakeLists.txt`；OpenCV 配置选项参考（docs.opencv.ac.cn） |
| `libucrt.lib` 静态链入 UCRT（/MT，无伴随 DLL） | Microsoft Learn「CRT and C++ standard library (STL) lib files」（Associated DLL: None） |
| `BUILD_WITH_STATIC_CRT`：`ON IF MSVC`，"for statically linked OpenCV" | OpenCV 4.10.0 根 `CMakeLists.txt`（Software Heritage 存档） |
| 静态 OpenCV + /MT 链入自研模块为通行形态 | vcpkg `x64-windows-static` triplet；多方静态构建实践记录 |
| OpenCV 4 移除的是 persistence/photo/video/imgcodecs/videoio 的 C API；`cvMatchTemplate` C API 仍在 | opencv.org OpenCV 4.0 release notes；4.x `object_detection.rst`（`ocv:cfunction cvMatchTemplate`） |
