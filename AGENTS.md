# 仓库总览与开发约定

> 本文件是仓库全局规范（L1），只记录跨环境通用规则；各打包环境的细节见 `doc/<name>.md`（L2）。同一信息仅在一处维护，其他位置用相对路径引用。

## 一、项目概述

* **项目名称**：win-env
* **核心定位**：自动打包 Windows 常用开发环境。GitHub Actions **手动触发**构建 → 自动发布 GitHub Release → 交付物为基于 Inno Setup 6 的**一键安装包（.exe）**。
* **当前环境**：PHP 8.5（NTS / VS17 / x64，含 Xdebug、APCu、cacert.pem、nilpack、Composer、app-local VC++ 运行库），详见 [doc/php-8.5.md](doc/php-8.5.md)；pnpm 12（standalone `pnpm.exe`，默认 `C:\pf\pnpm`），详见 [doc/pnpm.md](doc/pnpm.md)；Git v2.x.windows.y（PortableGit，默认 `C:\pf\Git`），详见 [doc/git.md](doc/git.md)；PowerShell 7（v7.6.x · x64，默认 `C:\pf\PowerShell7`，内置右键菜单与 Windows Terminal 配置档），详见 [doc/pwsh.md](doc/pwsh.md)；Node.js LTS（官方 dist zip，默认 `C:\pf\node`，内置 npm），详见 [doc/node.md](doc/node.md)；Rust MSVC（stable channel，x86_64-pc-windows-msvc，默认 `C:\pf\rust`，内置 LLD 链接器与 Windows SDK/CRT），详见 [doc/rust.md](doc/rust.md)；PostgreSQL（EDB 官方 binaries zip，x64，默认 `C:\pf\postgres-<major>`，含 `pg-start`/`pg-stop`/`pg-restart`/`pg-status` 管理脚本），详见 [doc/postgres.md](doc/postgres.md)；Chromium（ungoogled-chromium 官方便携包，x64，默认 `C:\pf\chromium`，含桌面快捷方式），详见 [doc/chromium.md](doc/chromium.md)。

## 二、仓库结构

| 路径 | 说明 |
| --- | --- |
| `.github/workflows/build-<name>.yml` | 各环境的构建工作流，一律 `workflow_dispatch` 手动触发，构建成功自动发 Release |
| `builders/<name>/build.ps1` | 构建脚本：版本发现 → 下载 → 暂存组装 → 冒烟测试 → 编译安装包 → 元数据/发布说明 |
| `builders/<name>/setup.iss` | Inno Setup 安装器脚本（含随仓库自带的 `Languages/ChineseSimplified.isl`） |
| `builders/opencv-shim/` | OpenCV shim 专用构建资产（无安装包）：便携 MinGW 引导 `setup-mingw.ps1`，`CMakeLists.txt` + `opencv_shim.cpp` + `build.ps1`（gnu 路线构建），由 `build-opencv-shim.yml` 调用；产物为裸 `opencv_shim.dll` artifact |
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
| 体积优化评估 | [doc/compression.md](doc/compression.md) | 安装包压缩参数与内容的实测评估：Inno 侧已到顶、可选杠杆与代价（仅评估，未落地） |
| 经验教训 | [doc/lessons.md](doc/lessons.md) | Windows / PowerShell / ISCC / Git 已验证的坑与规避规则 |

## 五、变更记录

> 仅保留最近 6 条；详细背景见对应文档与 git 历史。

| 日期 | 变更摘要 |
| --- | --- |
| 2026-10-18 | opencv-shim 代码层复核修复：`builders/opencv-shim/CMakeLists.txt` 补 `-static-libgcc -static-libstdc++`（GCC 默认动态链接 libstdc++/libgcc，会把 `libstdc++-6.dll`/`libgcc_s_seh-1.dll` 拖进交付，与"单文件自包含"契约及依赖闸门冲突）；`build-opencv-shim.yml` gnu 依赖闸门从"仅 `KERNEL32.dll` + `msvcrt.dll`"改为"`KERNEL32.dll` + OS CRT（`msvcrt.dll`，或 ucrt 工具链的 `ucrtbase.dll` + `api-ms-win-*`）"——`setup-mingw.ps1` 资产正则同时接受 msvcrt/ucrt，而当前 WinLibs `x86_64-posix-seh` 只发 ucrt 包，原白名单会误杀合法导入；gnu 路线补单导出闸门（`objdump -p` 断言导出名表仅 `shim_match_template`，与 msvc 的 `dumpbin /EXPORTS` 对齐）、CI 侧两步改为仓库惯例的 call 运算符 `&` 直调（`setup-mingw.ps1` 传 `-Mirror ''` 走官方直连；`powershell -File` 会丢空实参、参数绑定直接失败，见 [doc/lessons.md](doc/lessons.md) §4.6）；gnu 配置补 `-DWITH_PTHREADS_PF=OFF`（MinGW 的 pthreads 并行框架默认开启，会把 `libwinpthread-1.dll` 拖进 shim；而 msvc 用的 `OPENCV_DISABLE_THREAD_SUPPORT` 在 MinGW 上会 FATAL_ERROR）；`build.ps1` 的 `Find-OpenCvConfigDir` 找不到 `OpenCVModules.cmake` 时改为显式 throw（不再把 MSVC 专用 Windows Pack 配置交给 CMake）、msvc job 的静态库目录改为递归检索 `opencv_core*.lib` 定位并打印（不再写死 `<prefix>\lib`）；同步 workflow 头注释与 [doc/opencv-msvc-plan.md](doc/opencv-msvc-plan.md) |
| 2026-10-18 | 新增 Chromium (ungoogled) 一键安装包（`builders/chromium/` + `.github/workflows/build-chromium.yml` + [doc/chromium.md](doc/chromium.md)）：来源 `ungoogled-software/ungoogled-chromium-windows` Release 的便携 zip `ungoogled-chromium_<tag>_windows_x64.zip`（tag 形如 `155.0.8059.39-1.1` = Chromium 版本 + ungoogled 修订），版本默认取最新非草稿/非预发布且携带 x64 zip 的 Release（解析为空即报错），支持 `mirror_base`/`-MirrorBase` 切 USTC 镜像（镜像对直链资产有 JS Cookie 防爬，`Download-File` 解析页面内 `addr=` 值设 Cookie 后重取一次真实资产，官方端点无副作用）；zip 为单层包装目录 `ungoogled-chromium_<tag>_windows_x64\`，构建时拍平（顶层不唯一即报错），暂存树 420.5 MB；冒烟测试用 PE `FileVersion` 断言版本（`chrome.exe` 是 GUI 子系统程序，`--version` 无输出也无退出码）+ `--headless=new --dump-dom` 真实渲染带标记的 `data:` 页（证明 `chrome.dll`/`.pak`/V8 快照确实加载）+ 关键文件存在性断言；安装器默认 `C:\pf\chromium`、为所有用户创建桌面快捷方式 `Chromium`（指向 `{app}\chrome.exe`，卸载自动移除）、安装目录加入系统 PATH（幂等追加/卸载精确回收 + 广播 `WM_SETTINGCHANGE`）；`VersionInfoVersion` 用去 `-1.1` 修订后缀的纯数字版 `155.0.8059.39`（见 lessons §7）；安装器图标由 `chrome.exe` 的 PE 图标资源组提取（16/32/48/256 px 共 7 帧，官方二进制无独立 .ico 资产）；用户数据默认落 `%LOCALAPPDATA%\Chromium\User Data`，卸载不清理；本地完整构建通过，产物 131.9 MiB（155.0.8059.39-1.1） |
| 2026-10-17 | 新增 PostgreSQL 一键安装包（`builders/postgres/` + `.github/workflows/build-postgres.yml` + [doc/postgres.md](doc/postgres.md)）：二进制取 EDB 官方 `postgresql-<ver>-<rev>-windows-x64-binaries.zip`（版本走官方 `versions.json`，rev 1→3 探测 + minor 回退，下载前按主版本 ≥ 17 下限校验）；裁剪 `pgAdmin 4`（占官方压缩体积约 81%）、`StackBuilder`、`doc\src` 并做白名单断言，`include\` 用真实扁平布局 `include\server\postgres.h` 作哨兵；`bin\` 内 app-local 注入 7 个 vc_redist CRT DLL；构建脚本生成 `pg-start`/`pg-stop`/`pg-restart`/`pg-status` 四个管理脚本写入 `bin\`（UTF-8 无 BOM + CRLF + `chcp 65001`，带编码断言）；默认集群 `initdb` 用 PG 17+ 的 `--locale-provider=builtin --builtin-locale=C.UTF-8`、`Asia/Shanghai`、仅回环监听、scram-sha-256；安装器只把 `<app>\bin` 加入系统 PATH、不注册 Windows 服务、卸载保留运行期 `data\`；安装器图标取自 postgresql.org 官方 `elephant.png`（官方二进制无内嵌图标资源）；冒烟测试真实跑通 `initdb`→`pg_ctl start`→`psql select version()`→`pg_isready`→`pg_ctl stop` 闭环；管理脚本首启修复：`initdb -D` 要求目标目录"不存在或为空"，故口令临时文件放 `%TEMP%`、`data\logs\` 待 initdb 成功后再建（见 lessons §22）；安装/卸载闭环需 CI 或人工验收（本机跳过关闭测试），产物 27.45 MiB（PostgreSQL 18.6） |
| 2026-10-17 | `build-opencv-shim` workflow 按仓库惯例对齐：workflow 显示名改 `Build OpenCV Shim`、补 `permissions` 与各 step 的 `name`、`shell` 统一为 `powershell`、action 版本对齐其余 workflow（`checkout@v7`/`upload-artifact@v7`/`cache@v6`/`setup-python@v7`）；新增 `resolve` 前置 job 取代硬编码版本——`opencv_version` 留空时从 GitHub tags API 解析最新 4.x 纯版本 tag（5.x 与厂商后缀 tag 不参与，解析为空立即报错），解析结果经 job 输出同时驱动下载 URL 与缓存 key，gnu/msvc 两条路线共用同一份 OpenCV 源码缓存（原 `-gnu`/`-msvc` 双份）；`builders/opencv-shim/`（`setup-mingw.ps1` 便携 MinGW 引导 + `CMakeLists.txt` + `opencv_shim.cpp` + `build.ps1`，单导出 `shim_match_template`）并入本仓库并清洗为自包含：MinGW 引导只做便携工具链下载（删除 `.cargo` 配置生成、`default-manifest.o` 改名等外来依赖），构建脚本删除硬编码机器路径、cmake/ninja 改走 PATH、日志与状态文件由 `target\` 迁到构建目录（脚本按惯例改名 `build.ps1`，`$PSScriptRoot` 上溯两级取仓库根）；方案文档更名 [doc/opencv-msvc-plan.md](doc/opencv-msvc-plan.md)（对齐 `rust-msvc-plan.md` 命名）并剔除项目外交叉引用；`.ps1` 统一 UTF-8 with BOM + LF、`.md` 无 BOM + LF；`builders/opencv-shim/` 登记进 §二结构表、`.gitignore` 补 `/tools/` 等本地产物 |
| 2026-10-17 | 文档与代码注释一致性优化：修正 [doc/rust.md](doc/rust.md) 中 TOML 解析的笔误（`TLD`→`TOML`）与失效交叉引用；[doc/lessons.md](doc/lessons.md) 按编号重排章节（§4.4/§4.5 归位、§7/§8 移到 §6 之后），补记 Rust channel TOML 双括号数组表解析坑，并删除非"可复现出错"类的实现说明条目（原 §15「rustc 自带 rust-lld 的包装器行为」——其内容已由 [doc/rust.md](doc/rust.md) §6 设计约定与 `build.ps1` 注释承载），删除后编号顺延并同步全部交叉引用；`builders/pwsh/setup.iss` 暂存树体积注释校正（~280 MB → ~245 MB，与实测一致）；`builders/git/setup.iss`、`builders/rust/setup.iss` 补齐 AppId 与压缩字典说明注释并统一注释风格 |
| 2026-10-17 | Rust 包补齐 rustfmt / clippy 组件与用户级 PATH：`$components` 增加 channel 组件 `rustfmt-preview` / `clippy-preview`（归档文件名不带 `-preview`，故组件表分离 `Name` 与 `FileStem`），暂存树校验四个新二进制、冒烟测试增加 `rustfmt --version`、`cargo fmt --check` 与 clippy 真实 lint；安装器把 `%USERPROFILE%\.cargo\bin` 加入用户 PATH（`HKCU\Environment`，与官方 rustup 一致），卸载仅回收本安装器新增的条目 |
