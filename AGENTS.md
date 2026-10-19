# 仓库总览与开发约定

> 本文件是仓库全局规范（L1），只记录跨环境通用规则；各打包环境的细节见 `doc/<name>.md`（L2）。同一信息仅在一处维护，其他位置用相对路径引用。

## 一、项目概述

* **项目名称**：win-env
* **核心定位**：自动打包 Windows 常用开发环境。GitHub Actions **手动触发**构建 → 自动发布 GitHub Release → 交付物为基于 Inno Setup 6 的**一键安装包（.exe）**。
* **当前环境**：PHP 8.5（NTS / VS17 / x64，含 Xdebug、APCu、cacert.pem、nilpack、Composer、app-local VC++ 运行库），详见 [doc/php-8.5.md](doc/php-8.5.md)；pnpm 12（standalone `pnpm.exe`，默认 `C:\pf\pnpm`），详见 [doc/pnpm.md](doc/pnpm.md)；Git v2.x.windows.y（PortableGit，默认 `C:\pf\Git`），详见 [doc/git.md](doc/git.md)；PowerShell 7（v7.6.x · x64，默认 `C:\pf\PowerShell7`，内置右键菜单与 Windows Terminal 配置档），详见 [doc/pwsh.md](doc/pwsh.md)；Node.js LTS（官方 dist zip，默认 `C:\pf\node`，内置 npm），详见 [doc/node.md](doc/node.md)；Rust MSVC（stable channel，x86_64-pc-windows-msvc，默认 `C:\pf\rust`，内置 LLD 链接器与 Windows SDK/CRT），详见 [doc/rust.md](doc/rust.md)；PostgreSQL（EDB 官方 binaries zip，x64，默认 `C:\pf\postgres-<major>`，含 `pg-start`/`pg-stop`/`pg-restart`/`pg-status` 管理脚本），详见 [doc/postgres.md](doc/postgres.md)；Chromium（ungoogled-chromium 官方便携包，x64，默认 `C:\pf\chromium`，含桌面快捷方式），详见 [doc/chromium.md](doc/chromium.md)；Python（python.org 官方 `python-<ver>-amd64.zip` pythoncore 可重定位布局，x64，默认 `C:\pf\python`，内置 pip/venv/tkinter，默认裁剪 `Doc\`），详见 [doc/python.md](doc/python.md)。

## 二、仓库结构

| 路径 | 说明 |
| --- | --- |
| `.github/workflows/build-<name>.yml` | 各环境的构建工作流，一律 `workflow_dispatch` 手动触发，构建成功自动发 Release |
| `builders/<name>/build.ps1` | 构建脚本：版本发现 → 下载 → 暂存组装 → 冒烟测试 → 编译安装包 → 元数据/发布说明 |
| `builders/<name>/setup.iss` | Inno Setup 安装器脚本（含随仓库自带的 `Languages/ChineseSimplified.isl`） |
| `builders/opencv-shim/` | OpenCV shim 专用构建资产（无安装包）：便携 MinGW 引导 `setup-mingw.ps1`，`CMakeLists.txt` + `opencv_shim.cpp` + `build.ps1`（gnu 路线构建），由 `build-opencv-shim.yml` 调用；产物为裸 `opencv_shim.dll` artifact |
| `.github/workflows/lint-ps1.yml` | PowerShell 守卫工作流：`push` / `pull_request` 触发，调用 `scripts/check-ps1.ps1` 校验全仓库 `.ps1` 的 BOM 与 PS 5.1 可解析性（非构建工作流，故不走 `workflow_dispatch` 手动触发） |
| `scripts/check-ps1.ps1` | 守卫脚本：`scripts/check-ps1.ps1`，仓库根为默认扫描根；对每个 `.ps1` 断言"BOM 不多于一个""含非 ASCII 必带单 BOM""`Parser::ParseFile` 零错误"，违规即列清单并 throw（本地可跑，CI 同源） |
| `scripts/get-pe-exports.ps1` | 产物判据工具：`Get-PeExportName -Path <pe>` 直读 PE 头部 `DataDirectory[0]` → `IMAGE_EXPORT_DIRECTORY` → `AddressOfNames` 返回导出名数组（PE32 / PE32+ 通吃，无外部工具、不加载目标 DLL）；供 `build-opencv-shim.yml` 的 gnu 单导出闸门替代脆弱的 `objdump -p` 文本解析（见 [doc/lessons.md](doc/lessons.md) §31） |
| `doc/` | 文档目录：各环境打包文档 `doc/<name>.md` 与 [经验教训](doc/lessons.md) |
| `build/` | 本地构建工作目录（cache/stage/output），已 gitignore，**禁止提交** |

> 新增环境 = 新增一组 `builders/<name>/` + workflow + `doc/<name>.md`，并在 README 打包清单登记一行。

## 三、全局约定

### 3.1 构建与交付

* **版本不硬编码**：补丁版本运行时从官方目录列表解析；解析为空立即终止报错，不猜测 URL。workflow 保留手动指定版本的输入框。
* **组件只走官方渠道**（PHP/Xdebug/APCu 走 windows.php.net，CA 走 curl.se，nilpack 走其 GitHub Release）；来源写入 `build-info.json` 与发布说明。
* **暂存目录即安装目录**：`build/stage/<env>` 根目录布局等于安装后的 `C:\pf\<env>`（各环境暂存树按目录隔离），安装器只做原样释放 + 少量改写（占位符替换、PATH），不在安装期做下载/拼装。
* **冒烟测试是强制门槛**：组装完成后必须在暂存树上真实执行（当前为 `php -v` 见 Xdebug、APCu 已加载且 CLI 下默认关闭（`-d apc.enable_cli=1` 时 store/fetch 正常）、`date.timezone` 为 Asia/Shanghai、`nilpack.phar --version`），失败即 throw，不产出坏包。
* **产物三件套**：安装包 exe、`*.sha256.txt`、`build-info.json`，外加 `release-notes.md`；全部上传 Release 并保留同名 artifact。
* **Release 标签**：`<env>-<version>`（如 `php-8.5.11`），同名重跑由 action 就地更新 Release。

### 3.2 安装器规则

* 默认目录 `C:\pf\<env>-<major.minor>`，向导可改；需要管理员权限（C 盘根目录 + 系统 PATH）。
* **PATH 必加、无安装选项**：安装目录写入**系统** PATH，幂等追加、卸载时精确移除该条目（不动其他条目），并广播 `WM_SETTINGCHANGE`；已打开的旧终端不生效，文档须提示"新开命令行"。
* 安装目录相关路径（证书等）使用 `__APP_DIR__` 占位符，安装器在 `ssPostInstall` 替换为真实目录，保证改目录不出错。
* 包内命令（如 `nil`）用安装根目录的 `.bat` 包装器（`%~dp0php.exe %~dp0xxx.phar %*`）实现，禁止依赖调用方工作目录。
* 固定 `AppId`，重复安装替换同一实例；卸载必须清干净文件与 PATH（每次改安装器都要实测静默安装→卸载闭环）。
* **安装器图标**：各安装包 exe 图标为对应软件的官方图标，以 `.ico` 随仓库保存在 `builders/<name>/setup.ico`，setup.iss 经 `SetupIconFile` 引用。优先从官方二进制资源提取（php/pwsh/git）；官方二进制无图标资源时（pnpm standalone）取官方 GitHub 组织头像生成。

### 3.3 PHP 打包策略

* 规格：NTS / VS17 / x64（CLI、IIS/FastCGI、Composer 场景的官方推荐）。
* `php.ini` 基于官方 `php.ini-development` **生成**而非直接使用；`extension_dir="ext"`。
* 默认扩展集在 build.ps1 的 `$EnabledExtensions` 单一清单维护（当前默认 pdo_pgsql，不含 mysqli/pdo_mysql）；`$DisabledExtensions` 强制注释禁用项，防止上游默认值变化破坏约定；重复生效行需去重。PECL 扩展（APCu）在 php.ini-development 中无对应行，由构建脚本直接追加 `extension=apcu` + `[apcu]` 配置块（`apc.enabled=1`、`apc.enable_cli=0`、`apc.shm_size=32M`），默认开启；`date.timezone` 固定写入 `Asia/Shanghai`。
* Xdebug、APCu、Composer 不提供版本选项（workflow 与 build.ps1 均无对应参数）：一律自动取各自官方渠道的最新可用版本。
* Xdebug 放 `ext/php_xdebug.dll`，以 `zend_extension=xdebug` 加载；cacert.pem 放安装根目录并配置 `curl.cainfo`/`openssl.cafile`。
* VC++ 运行库内置（app-local）：构建期从官方 `vc_redist.x64.exe`（dark.exe 解 Burn 包 + `msiexec /a` 解 MSI）提取 7 个 CRT DLL 放安装根目录，目标机器无需预装系统级运行库；版本取 aka.ms 最新并记入 `build-info.json`。

### 3.4 编码与脚本（Windows / PowerShell 5.1）

* **含非 ASCII 字符的 `.ps1` 必须保存为 UTF-8 with BOM**（否则 runner 按 ANSI 解析导致中文乱码）；详见 [doc/lessons.md](doc/lessons.md)。
* **`.ps1` 的 BOM 必须恰好一个**：多余 BOM 会让 PS 5.1 把第二个 U+FEFF 当正文首字符、报出一堆看着像真实语法错误的解析失败。编辑器和 AI 工具会悄悄增删 BOM，故本仓库设自动闸门——每次 `push`/`PR` 由 `.github/workflows/lint-ps1.yml` 调 `scripts/check-ps1.ps1` 校验（本地同源可跑），**禁止靠人眼复查文件头**；详见 [doc/lessons.md](doc/lessons.md) §1.3。
* 写 UTF-8 文本文件用 `[IO.File]::WriteAllText` + `UTF8Encoding($false)`，不用 `Out-File -Encoding utf8`（PS 5.1 会带 BOM）。
* workflow 步骤禁止用"退出码非 0 的自检命令"收尾（如 `iscc /?`）；PowerShell step 以 `$LASTEXITCODE` 收口。

### 3.5 文档与同步

* README 只放概览、打包清单与快速开始；细节全部归属 `doc/`，禁止两处重复维护。
* 代码/构建逻辑变更必须同步更新对应 `doc/<name>.md`，并在本文件第五节追加变更记录。
* 新踩的坑（环境怪癖、工具链退出码、编码/引号问题等）及时补入 [doc/lessons.md](doc/lessons.md)，只记录已实际验证的条目。

### 3.6 本地验证要求

* 仅组装：`build.ps1 -SkipCompile`（无需 Inno Setup）；检查一律用暂存树内 `php.exe` 的**绝对路径**，避免误用机器上其他 PHP。
* 完整构建：本机可用便携 ISCC（解压 choco 包到 `build/cache/`，不污染系统），以 `$env:ISCC` 指向。
* 安装闭环测试：静默安装到**非默认目录** → 用注册表 Machine+User PATH 拼出新进程环境验证裸命令（`php`、`nil`）→ 静默卸载 → 确认文件与 PATH 条目都消失。
* 临时测试文件放 `build/` 内并随构建目录清理，禁止在源码目录留 test/check 脚本。

## 四、文档索引

| 文档 | 路径 | 说明 |
| --- | --- | --- |
| PHP 8.5 打包文档 | [doc/php-8.5.md](doc/php-8.5.md) | 产物规格、workflow 参数、安装行为、组件来源、本地构建、设计约定 |
| pnpm 打包文档 | [doc/pnpm.md](doc/pnpm.md) | 产物规格、workflow 参数、安装行为、组件来源、本地构建、设计约定 |
| Git 打包文档 | [doc/git.md](doc/git.md) | 产物规格、workflow 参数、安装行为、组件来源、本地构建、设计约定 |
| PowerShell 7 打包文档 | [doc/pwsh.md](doc/pwsh.md) | 产物规格、workflow 参数、安装行为、组件来源、本地构建、设计约定 |
| Node.js 打包文档 | [doc/node.md](doc/node.md) | 产物规格、workflow 参数、安装行为、组件来源、本地构建、设计约定 |
| Rust MSVC 打包文档 | [doc/rust.md](doc/rust.md) | 产物规格、workflow 参数、安装行为、组件来源、本地构建、设计约定 |
| PostgreSQL 打包文档 | [doc/postgres.md](doc/postgres.md) | 产物规格、workflow 参数、安装行为（含管理脚本）、组件来源与裁剪、本地构建、设计约定 |
| Chromium 打包文档 | [doc/chromium.md](doc/chromium.md) | 产物规格、workflow 参数、安装行为（桌面快捷方式/PATH）、组件来源与镜像用法、本地构建、设计约定 |
| Python 打包文档 | [doc/python.md](doc/python.md) | 产物规格、workflow 参数、安装行为、组件来源与裁剪（默认裁 `Doc\`）、本地构建、设计约定 |
| 体积优化评估 | [doc/compression.md](doc/compression.md) | 安装包压缩参数与内容的实测评估：Inno 侧已到顶、可选杠杆与代价（仅评估，未落地） |
| 经验教训 | [doc/lessons.md](doc/lessons.md) | Windows / PowerShell / ISCC / Git 已验证的坑与规避规则 |

## 五、变更记录

> 仅保留最近 6 条；详细背景见对应文档与 git 历史。

| 日期 | 变更摘要 |
| --- | --- |
| 2026-10-19 | opencv-shim gnu 路线**单导出闸门断根**：`objdump -p` 的导出名文本解析连续第三轮在 CI 上返回空集合（前两轮为 `Select-String` 行号切片、显式索引定位表头收集；本轮为整段逐行按 `^\[\s*\d+\]\s+(\S+)$` 形状筛选），而**同一份输出、同一套捕获管线**在紧邻的导入表闸门里正常工作（`Select-String 'DLL Name:'` 有真实结果）——问题就在"导出表这段文本本身"：objdump 是否打印导出表、以及怎么排版，取决于 bfd 后端与该次 binutils 构建，不是稳定契约。改为**直读 PE**：新增 [scripts/get-pe-exports.ps1](scripts/get-pe-exports.ps1)（`Get-PeExportName -Path <pe>` 按 `DataDirectory[0]` → `IMAGE_EXPORT_DIRECTORY` → `AddressOfNames` 取导出名，PE32/PE32+ 通吃，无外部工具、不加载目标 DLL），gnu 单导出闸门 dot-source 它并断言 `$names` 恰为 `@('shim_match_template')`，判据不符时打印 PE 读到的清单并另 dump 整段 `objdump -p` 供事后比对。本机在真实系统 DLL 上覆盖两条 Optional Header 分支：`System32\kernel32.dll`（PE32+）1633 个导出含 `CreateFileW`/`LoadLibraryW`/`GetProcAddress`/`VirtualAlloc`、`SysWOW64\kernel32.dll`（PE32）1607 个含 `CreateFileW`、`ole32.dll` 546 个含 `CoCreateGuid`、`gdi32.dll` 973 个含 `BitBlt`；同步 [doc/opencv-msvc.md](doc/opencv-msvc.md) §3.4/§4 与 [doc/lessons.md](doc/lessons.md) §31，并在 lessons §1.1 补"缺 BOM 的中文 `.ps1` 是**解析失败**而非仅乱码"（本机实测：无 BOM 的中文脚本 `Parser::ParseFile` 报 `line 67: Unexpected token '}'`，补单 BOM 后 `parseErrors=0`） |
| 2026-10-19 | 新增 PowerShell 守卫闸门，终结 `.ps1` 文件头反复返工：`scripts/check-ps1.ps1`（默认扫描根为仓库根，排除 `.git`/`build`/`tools`）逐文件断言三点——BOM 不多于一个（多余 BOM 会让 PS 5.1 把第二个 U+FEFF 当正文首字符撞坏词法分析）、含非 ASCII 字符必须恰带单 BOM（否则 PS 5.1 按 ANSI 解析乱码）、`Parser::ParseFile` 零错误；违规即列清单（附 head 十六进制字节，直接指出该删还是该补）并 throw，本地与 CI 同一份脚本。`.github/workflows/lint-ps1.yml` 在每次 `push`/`pull_request` 调用它，问题在仓库门口挡下，不再依赖人工复查文件头。同时修复 `builders/opencv-shim/setup-mingw.ps1` 的双 BOM 复发：上一次"修多余前导字符"的提交方向做反，把合法单 BOM（`EF BB BF 3C 23`）又补成双 BOM——症状随双 BOM 后首个 token 变化，这次紧跟 `<#` 块注释、整个注释头被当代码解析，报的不再是 `InvalidLeftHandSide` 而是 `The 'from' keyword is not supported` / `The '<' operator is reserved` / `The ampersand (&) character is not allowed` / `Unexpected attribute 'CmdletBinding'`（首条错误推迟到行 7 的注释中部）；已字节级还原到坏提交父版本（blob 回到 `68db0bc`，本机 `Parser::ParseFile` 复现出与 CI 逐条一致的 5 条错误、修复后 `parseErrors=0`），全仓库体检确认 12 个 `.ps1` 均 `BOM=1`、零解析错误；守卫逻辑本身也经植入样本实测（双 BOM / 缺 BOM 的中文文件 / 真语法错误各命中且措辞准确，纯 ASCII 带 BOM 与正常文件不误伤）。[doc/lessons.md](doc/lessons.md) §1.3 补复发条目，[AGENTS.md](AGENTS.md) §3.4 与该结构表登记本闸门 |
| 2026-10-18 | 新增 Python 一键安装包（`builders/python/` + `.github/workflows/build-python.yml` + [doc/python.md](doc/python.md)）：来源 python.org 官方 `python-<version>-amd64.zip`（install manager 的 **pythoncore 可重定位**布局，无包装目录，解压即暂存根），版本默认从官方索引 `https://www.python.org/ftp/python/index-windows.json` 的 `versions` 数组解析最新正式版（筛 `company=PythonCore` + `id` 形如 `pythoncore-<major.minor>-64` + `sort-version` 为纯 `x.y.z`，排除 free-threaded `-64t`/`pythonembed*`/`pythontest*` 与 prerelease，解析为空即报错），支持 `python_version`/`major_track`（如 `3.14`）手动指定；下载后逐字节比对同索引发布的 `hash.sha256`（缓存命中同样校验）；**默认裁剪 `Doc\`**（离线 HTML 文档 78.7 MB，占解压树约 58%，`-KeepDoc` 可保留），暂存树 57.6 MB/1950 项；构建期生成 `pip.cmd`（`"%~dp0python.exe" -m pip %*`，UTF-8 无 BOM + CRLF，带编码/内容断言 —— 官方 zip 无 `Scripts\`，故裸 `pip` 命令必须自建包装器）；冒烟测试覆盖 `python -V` 逐字一致、`sys.prefix` 等于暂存目录（证明可重定位）、`tkinter` 真实初始化 Tcl 返回版本号、内置 `pip -m pip -V` 与 `pip.cmd` 可执行、`python -m venv` 建出的解释器版本一致，另断言 12 项官方布局哨兵并显式拒绝带 `python._pth` 的 embeddable 误装；安装器默认 `C:\pf\python`（目录不含版本号，与 node/chromium 一致；跨轨道更换建议先卸载旧版避免新旧 `Lib\` 混装）、只把安装根目录加入系统 PATH（幂等追加/卸载精确回收 + 广播 `WM_SETTINGCHANGE`）、固定 AppId `{{B3F6D8E5-2A94-4C71-8E5B-7D1A9F3C6B20}}`，安装器图标从官方 `python.exe` 的 PE 图标资源组提取（16–256 px，8bpp/32bpp 成对共 12 帧）；无需 vc_redist 提取链路（`vcruntime140.dll`/`vcruntime140_1.dll` 随官方 zip 自带 app-local）；本地完整构建通过，产物 17.79 MiB（Python 3.15.0），[doc/lessons.md](doc/lessons.md) 补 §27（`index-windows.json` 是对象、条目在 `.versions`）与 §28（PS 5.1 剥掉 `-c` 载荷内嵌双引号） |
| 2026-10-18 | 修复 `Build OpenCV Shim` workflow 两条路线的 CI 失败：gnu 路线 configure 阶段 `find_package` 报 "the imported target ade references … libade.a but this file does not exist"——`BUILD_LIST=core,imgproc` 虽已把 gapi 白名单剔除，但 `modules/gapi/cmake/init.cmake` 仍会在 configure 期创建 `ade` 目标，并由 `ocv_install_target(... EXPORT OpenCVModules ...)` 导出进安装出的 `OpenCVModules.cmake`，而 ade 静态库从不构建；两条路线的 OpenCV configure 均补 `-DWITH_ADE=OFF`（命中 `init.cmake` 的 `if(NOT WITH_ADE) return()` 短路，目标不创建即不导出，对已剔除的 gapi 无影响，msvc 路线本不走 `find_package`、加同一旗标只为两路线旗标集对齐）。msvc 路线报 "opencv4 include dir not found under msvc-install\include"——`cmake --install` 的头文件布局随 host 分支而变：Windows host 走 `OpenCVInstallLayout.cmake` 的 WIN32 分支（`OPENCV_INCLUDE_INSTALL_PATH=include`），头文件直接落 `<install>\include\opencv2\...`，**没有** `opencv4` 中间层（那是 UNIX 分支才有的），原按目录名 `opencv4` 检索必然落空；改为递归检索 `opencv_modules.hpp`（必在 `opencv2\` 内）取其上一级作为 `-I` 根，两种布局通吃并保留显式 throw；两条路线的 OpenCV build-tree 缓存 key 由 `-v1` 升至 `-v2`（configure 旗标变更，强制下次干净重配，避免复用带旧 `WITH_ADE:ON` 的缓存树）；第二轮 CI 复跑又暴露两处并已修复：(a) msvc 路线手写 cl 链接只列了 `opencv_core*.lib`/`opencv_imgproc*.lib`，漏掉静态 core/imgproc 的传递依赖，报 `LNK2019`（`__imp_CoCreateGuid` 需 `ole32.lib`、`gzopen/gzclose/gzgets/gzputs/gzrewind/gzeof` 需内置 `zlib.lib`）——改为按 glob 取 `zlib*.lib`（OpenCV 把内置 zlib 静态库装到与模块库同一 `x64/<rt>/staticlib` 目录）并显式补 `ole32.lib`；(b) gnu 路线 `setup-mingw.ps1` 解析 WinLibs release 时对 `api.github.com` 匿名查询 403（共享出口 IP 触及 60/h 限额）——workflow 侧经 `env:` 注入 `GITHUB_TOKEN`，脚本按"存在该变量才加 `Authorization: Bearer`"实现、本地匿名直连行为不变；第三轮 CI 复跑再暴露两处并已修复：(c) msvc 路线两条 `dumpbin` 门禁步骤把命令行**内联拼接**进 `cmd /c`（`cmd /c 'call "' + $vcvars + '" >nul && dumpbin ...'`），而 PowerShell 命令参数模式不做 `+` 拼接、碎片被当成独立实参交给 cmd，报 `'""' is not recognized as an internal or external command` 且门禁实际什么都没跑（本机 PS 5.1 已复现：内联形式退出码 1，`$cmd` 变量形式正常执行）——改为与 build/compile 步骤一致地先拼进 `$cmd` 再 `cmd /c $cmd`，依赖闸门另补 `if (-not $deps) { throw }` 断言"闸门确实跑过"，避免导入表为空时静默假通过；(d) gnu 路线 `setup-mingw.ps1` 末行 `& $Gxx --version | Select-Object -First 1` 把原生命令直接管进 `Select-Object -First`，PS 拿到首个对象即终止管道并 Kill 上游进程、把 `$LASTEXITCODE` 留成非 0，于是 `[setup] Done` 打印完步骤仍 exit 1（本机 PS 5.1 已复现被中断进程留下 `-1`）——改为先把整段输出收进 `$gxxVersion` 再取首行，并显式校验退出码；第四轮 CI 复跑再度暴露并已修复：(e) gnu 路线 `builders/opencv-shim/build.ps1` 在**解析阶段**即失败，5 条 `The assignment expression is not valid ...`（`FullyQualifiedErrorId: InvalidLeftHandSide`，行 45/47/48/49/50 全在 `param()` 块内）——文件头是**双 BOM**（`EF BB BF EF BB BF`），PS 5.1 只消化第一个、把第二个 U+FEFF 当正文首字符，`param(` 遂被解析成表达式、其内 `[string]$X = "..."` 逐一报错（本机 PS 5.1 用 `Parser::ParseFile` 复现出同样 5 条错误与行号、`BOM count=2`；去掉多余 BOM 后 `parseErrors=0`，正文零改动）——改为**单 BOM**（字节级重写，11646→11643 字节），并全仓库体检 12 个 `.ps1` 确认仅此一例；同步 [doc/opencv-msvc.md](doc/opencv-msvc.md) §4 的旗标、头文件布局、链接依赖与两条 dumpbin 闸门调用规则说明，[doc/lessons.md](doc/lessons.md) 补 §25/§26/§4.7/§4.8 与 §1.3（`.ps1` 双 BOM → PS 5.1 `InvalidLeftHandSide`）；第五轮 CI 复跑首次真正跑到 gnu 路线的 shim 导入表闸门，即拒绝 `libwinpthread-1.dll` 与 `ole32.dll` 并修复：(f) `builders/opencv-shim/CMakeLists.txt` 的 `-static-libgcc -static-libstdc++` 在 WinLibs `x86_64-posix-seh`（**POSIX 线程模型**）下不够——静态 libstdc++ 自身仍动态导入 `libwinpthread-1.dll`（这两个开关不含它），改用 `-static`（超集，一并静态链入 libgcc/libstdc++/libwinpthread）；`ole32.dll` 是 Windows OS 组件（core `modules/core/src/system.cpp` 的 `cv::tempfile` 用 `CoCreateGuid`），与 `KERNEL32.dll` 同类，计入 gnu 闸门白名单（`$allowed` 加 `ole32.dll`；msvc 闸门是黑名单 `VCRUNTIME|MSVCP|CONCRT|ucrtbase|opencv_`，ole32 本就不在内、无需改动）；gnu build-tree 缓存 key 由 `-v2` 升至 `-v3`（shim 的 CMake 缓存位于 `<BuildDir>\shim` 内，避免复用旧链接旗标）；同步 [doc/opencv-msvc.md](doc/opencv-msvc.md) §3.1/§3.2/§4，[doc/lessons.md](doc/lessons.md) 补 §29；文档命名（2026-10-19）：方案文档去掉 `-plan` 后缀，定名 [doc/opencv-msvc.md](doc/opencv-msvc.md)（原 `doc/opencv-msvc-plan.md`）与 [doc/rust-msvc.md](doc/rust-msvc.md)（原 `doc/rust-msvc-plan.md`），`.github/workflows/build-opencv-shim.yml` 头注释与 [doc/rust.md](doc/rust.md) 内引用同步更新；第六轮至第七轮 CI 复跑真正跑到 gnu 路线的**单导出闸门**（`objdump -p` 断言导出名恰有 `shim_match_template`）即连续失败：(g) 两轮均报 `exports: ` 为空、`expected exactly one export 'shim_match_template', got: `——第一轮用 `Select-String` 的 `.LineNumber` 去切 `& objdump.exe -p` 捕获进变量的数组（该行号映射不到数组下标），第二轮改为显式索引定位 `[Ordinal/Name Pointer] Table` 后逐行收集紧随条目，仍为空（新增诊断 dump 显示表头之后很快就是 `The Function Table (interpreted .pdata section contents)`，故"表头紧跟条目"的区段假设不成立）；最终**放弃一切表头/区段依赖**：先把整段输出收进 `$out` 并校验 `$LASTEXITCODE`/断言非空，再对整段逐行 `Trim()` 后按条目形状 `^\[\s*\d+\]\s+(\S+)$` 筛选（Export Address Table 的 `[   N] +base[   M] 1234 Export RVA` 含空格 token 故不误配），不符预期时 dump **整段**原始输出自诊断；本机用两份 mock（表头分别写作 `[Ordinal/Name Pointer] Table` / `[Name Pointer/Ordinal] Table`，各含一行 `[   0] shim_match_template` 与若干干扰行）验证均稳定提取恰一条；同步 [doc/opencv-msvc.md](doc/opencv-msvc.md) §4 与 [doc/lessons.md](doc/lessons.md) §30 |
| 2026-10-18 | opencv-shim 代码层复核修复：`builders/opencv-shim/CMakeLists.txt` 补 `-static-libgcc -static-libstdc++`（GCC 默认动态链接 libstdc++/libgcc，会把 `libstdc++-6.dll`/`libgcc_s_seh-1.dll` 拖进交付，与"单文件自包含"契约及依赖闸门冲突）；`build-opencv-shim.yml` gnu 依赖闸门从"仅 `KERNEL32.dll` + `msvcrt.dll`"改为"`KERNEL32.dll` + OS CRT（`msvcrt.dll`，或 ucrt 工具链的 `ucrtbase.dll` + `api-ms-win-*`）"——`setup-mingw.ps1` 资产正则同时接受 msvcrt/ucrt，而当前 WinLibs `x86_64-posix-seh` 只发 ucrt 包，原白名单会误杀合法导入；gnu 路线补单导出闸门（`objdump -p` 断言导出名表仅 `shim_match_template`，与 msvc 的 `dumpbin /EXPORTS` 对齐）、CI 侧两步改为仓库惯例的 call 运算符 `&` 直调（`setup-mingw.ps1` 传 `-Mirror ''` 走官方直连；`powershell -File` 会丢空实参、参数绑定直接失败，见 [doc/lessons.md](doc/lessons.md) §4.6）；gnu 配置补 `-DWITH_PTHREADS_PF=OFF`（MinGW 的 pthreads 并行框架默认开启，会把 `libwinpthread-1.dll` 拖进 shim；而 msvc 用的 `OPENCV_DISABLE_THREAD_SUPPORT` 在 MinGW 上会 FATAL_ERROR）；`build.ps1` 的 `Find-OpenCvConfigDir` 找不到 `OpenCVModules.cmake` 时改为显式 throw（不再把 MSVC 专用 Windows Pack 配置交给 CMake）、msvc job 的静态库目录改为递归检索 `opencv_core*.lib` 定位并打印（不再写死 `<prefix>\lib`）；同步 workflow 头注释与 [doc/opencv-msvc.md](doc/opencv-msvc.md) |
| 2026-10-18 | 新增 Chromium (ungoogled) 一键安装包（`builders/chromium/` + `.github/workflows/build-chromium.yml` + [doc/chromium.md](doc/chromium.md)）：来源 `ungoogled-software/ungoogled-chromium-windows` Release 的便携 zip `ungoogled-chromium_<tag>_windows_x64.zip`（tag 形如 `155.0.8059.39-1.1` = Chromium 版本 + ungoogled 修订），版本默认取最新非草稿/非预发布且携带 x64 zip 的 Release（解析为空即报错），支持 `mirror_base`/`-MirrorBase` 切 USTC 镜像（镜像对直链资产有 JS Cookie 防爬，`Download-File` 解析页面内 `addr=` 值设 Cookie 后重取一次真实资产，官方端点无副作用）；zip 为单层包装目录 `ungoogled-chromium_<tag>_windows_x64\`，构建时拍平（顶层不唯一即报错），暂存树 420.5 MB；冒烟测试用 PE `FileVersion` 断言版本（`chrome.exe` 是 GUI 子系统程序，`--version` 无输出也无退出码）+ `--headless=new --dump-dom` 真实渲染带标记的 `data:` 页（证明 `chrome.dll`/`.pak`/V8 快照确实加载）+ 关键文件存在性断言；安装器默认 `C:\pf\chromium`、为所有用户创建桌面快捷方式 `Chromium`（指向 `{app}\chrome.exe`，卸载自动移除）、安装目录加入系统 PATH（幂等追加/卸载精确回收 + 广播 `WM_SETTINGCHANGE`）；`VersionInfoVersion` 用去 `-1.1` 修订后缀的纯数字版 `155.0.8059.39`（见 lessons §7）；安装器图标由 `chrome.exe` 的 PE 图标资源组提取（16/32/48/256 px 共 7 帧，官方二进制无独立 .ico 资产）；用户数据默认落 `%LOCALAPPDATA%\Chromium\User Data`，卸载不清理；本地完整构建通过，产物 131.9 MiB（155.0.8059.39-1.1） |
