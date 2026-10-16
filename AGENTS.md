# 仓库总览与开发约定

> 本文件是仓库全局规范（L1），只记录跨环境通用规则；各打包环境的细节见 `doc/<name>.md`（L2）。同一信息仅在一处维护，其他位置用相对路径引用。

## 一、项目概述

* **项目名称**：win-env
* **核心定位**：自动打包 Windows 常用开发环境。GitHub Actions **手动触发**构建 → 自动发布 GitHub Release → 交付物为基于 Inno Setup 6 的**一键安装包（.exe）**。
* **当前环境**：PHP 8.5（NTS / VS17 / x64，含 Xdebug、APCu、cacert.pem、nilpack、Composer、app-local VC++ 运行库），详见 [doc/php-8.5.md](doc/php-8.5.md)；pnpm 12（standalone `pnpm.exe`，默认 `C:\pf\pnpm`），详见 [doc/pnpm.md](doc/pnpm.md)；Git v2.x.windows.y（PortableGit，默认 `C:\pf\Git`），详见 [doc/git.md](doc/git.md)；PowerShell 7（v7.6.x · x64，默认 `C:\pf\PowerShell7`，内置右键菜单与 Windows Terminal 配置档），详见 [doc/pwsh.md](doc/pwsh.md)；Node.js LTS（官方 dist zip，默认 `C:\pf\node`，内置 npm），详见 [doc/node.md](doc/node.md)；Rust MSVC（stable channel，x86_64-pc-windows-msvc，默认 `C:\pf\rust`，内置 LLD 链接器与 Windows SDK/CRT），详见 [doc/rust.md](doc/rust.md)。

## 二、仓库结构

| 路径 | 说明 |
| --- | --- |
| `.github/workflows/build-<name>.yml` | 各环境的构建工作流，一律 `workflow_dispatch` 手动触发，构建成功自动发 Release |
| `builders/<name>/build.ps1` | 构建脚本：版本发现 → 下载 → 暂存组装 → 冒烟测试 → 编译安装包 → 元数据/发布说明 |
| `builders/<name>/setup.iss` | Inno Setup 安装器脚本（含随仓库自带的 `Languages/ChineseSimplified.isl`） |
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
| 体积优化评估 | [doc/compression.md](doc/compression.md) | 安装包压缩参数与内容的实测评估：Inno 侧已到顶、可选杠杆与代价（仅评估，未落地） |
| 经验教训 | [doc/lessons.md](doc/lessons.md) | Windows / PowerShell / ISCC / Git 已验证的坑与规避规则 |

## 五、变更记录

> 仅保留最近 6 条；详细背景见对应文档与 git 历史。

| 日期 | 变更摘要 |
| --- | --- |
| 2026-10-16 | PHP 包调整 php.ini 默认值：`apc.enable_cli=0`（CLI 下 APCu 默认不生效）、`date.timezone = Asia/Shanghai`；移除 Xdebug/APCu/Composer 版本选项（workflow 与 build.ps1 参数），一律取官方最新可用版本；冒烟测试同步校验时区与 APCu 行为 |
| 2026-10-16 | 新增 Rust MSVC 一键打包链路（stable channel 自动发现版本，默认 `C:\pf\rust`；内置 LLD 链接器 + xwin 提取的 Windows SDK/CRT，免 Visual Studio；构建含真实 `cargo new` + `cargo build --release` 冒烟测试；安装器写 `%USERPROFILE%\.cargo\config.toml` 并做段级合并） |
| 2026-10-16 | PHP 包新增 APCu（官方 PECL `php_apcu.dll`，放入 `ext\`）并在 php.ini 中默认开启（`apc.enabled=1`、`apc.enable_cli=1`、`apc.shm_size=32M`）；workflow 新增 `apcu_version` 输入，冒烟测试增加 APCu 校验 |
| 2026-10-14 | 新增 Node.js LTS 一键打包链路（官方 dist 索引自动发现最新 LTS，默认 `C:\pf\node`，PATH 必加；安装包 25.44 MiB） |
| 2026-10-14 | 全部安装包 exe 图标改为对应软件官方图标（`SetupIconFile` + `builders/<name>/setup.ico`；php/pwsh/git 提取自官方二进制，pnpm 取自官方 GitHub 组织头像） |
| 2026-10-14 | 新增 PowerShell 7 v7.6.x 一键打包链路（官方 win-x64 zip，默认 `C:\pf\PowerShell7`，PATH 必加 + 右键菜单「在此处打开 PowerShell 7」+ Windows Terminal fragment 配置档） |
