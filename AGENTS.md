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
| `scripts/publish-alias-release.ps1` | 常青别名发布器：`-Env/-Version/-AssetPath/-VersionedTag/-DisplayName`，把安装包另存为固定资产名 `<env>-setup-x64.exe`（并按该名生成 sha256）上传到固定 tag `<env>-latest`；已存在则 `gh release upload --clobber` + `gh release edit` 刷新说明，末尾断言资产确实存在（README 下载链接的稳定入口，见 §3.1） |
| `scripts/test-release-published.ps1` | 带版本号 Release 的存在性判据：`gh release view <tag> --json isDraft`，非草稿即 `published=true` 写入 `GITHUB_OUTPUT`，供 workflow 跳过重复发布（草稿不计入，便于转正） |
| `doc/` | 文档目录：各环境打包文档 `doc/<name>.md` 与 [经验教训](doc/lessons.md) |
| `build/` | 本地构建工作目录（cache/stage/output），已 gitignore，**禁止提交** |

> 新增环境 = 新增一组 `builders/<name>/` + workflow + `doc/<name>.md`，并在 README 打包清单登记一行。

## 三、全局约定

### 3.1 构建与交付

* **版本不硬编码**：补丁版本运行时从官方目录列表解析；解析为空立即终止报错，不猜测 URL。workflow 保留手动指定版本的输入框。
* **组件只走官方渠道**（PHP/Xdebug/APCu 走 windows.php.net，CA 走 curl.se，nilpack 走其 GitHub Release）；来源写入 `build-info.json` 与发布说明。
* **暂存目录即安装目录**：`build/stage/<env>` 根目录布局等于安装后的 `C:\pf\<env>`（各环境暂存树按目录隔离），安装器只做原样释放 + 少量改写（占位符替换、PATH），不在安装期做下载/拼装。
* **冒烟测试是强制门槛**：组装完成后必须在暂存树上真实执行（当前为 `php -v` 见 Xdebug、APCu 已加载且 CLI 下默认关闭（`-d apc.enable_cli=1` 时 store/fetch 正常）、`date.timezone` 为 Asia/Shanghai、`nilpack.phar --version`），失败即 throw，不产出坏包。
* **产物三件套**：安装包 exe、`*.sha256.txt`、`build-info.json`，外加 `release-notes.md`；全部上传**带版本号**的 Release 并保留同名 artifact。
* **每个环境两个 Release**：
  * 带版本号 `<env>-<version>`（如 `php-8.5.11`）：三件套 + release-notes，只在版本首次构建时发布；tag 已有公开（非草稿）Release 则跳过、不覆盖既有资产（草稿不计入，便于转正）。
  * **常青别名** `<env>-latest`：资产名固定 `<env>-setup-x64.exe` + 同名 sha256，每次构建 `gh release upload --clobber` 原地覆盖，标 `prerelease` 不抢仓库 "Latest" 指向；勾选 `draft_release` 的构建不更新别名（避免草稿产物进公开下载通道）。
  * README 的下载链接只指向常青别名，因此永不随版本号失效。别名发布由 [scripts/publish-alias-release.ps1](scripts/publish-alias-release.ps1) 完成；版本包的存在性判据由 [scripts/test-release-published.ps1](scripts/test-release-published.ps1) 输出 `published`，workflow 据此 `if: steps.rel.outputs.published != 'true'` 跳过重复发布。

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
* 新踩的坑（环境怪癖、工具链退出码、编码/引号问题等）只记录**已实际验证**的条目，并按"通用 vs 单场景"分流：
  * **跨环境通用**（任何打包链路都可能踩：PowerShell 5.1 编码/BOM、CRLF 行尾锚点、`cmd /c` 拼接、原生命令退出码与输出解析、GitHub API 限额、跨盘 rename、上游格式先拉样本验证等）→ 补入 [doc/lessons.md](doc/lessons.md)；
  * **只在某个环境成立**（如 PHP 的 php.ini/扩展与 re-spin、Python 的 `index-windows.json`、PostgreSQL 的版本发现/管理脚本/头文件布局、Rust 的 channel TOML 与组件命名、OpenCV shim 的导出面/链接依赖、VC 运行库解包细节等）→ 补入对应 `doc/<name>.md` 的"经验 / Rule / 坑"小节，**不写进 lessons.md**；同一坑不必两处重复，通用条目里用一行指针指向场景文档。
* `doc/lessons.md` 的条目标题编号是**对外引用标识**（AGENTS、workflow 注释、脚本、各环境文档都会写"见 lessons.md §N"）：删除/迁移通用条目前必须全仓库 `grep '§'` 更新引用；**不得随意重编号**，已迁走的编号在 lessons.md 文末"附录 A：已迁移条目索引"保留映射，新条目只能追加到最大编号之后。

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
| OpenCV shim 构建说明 | [doc/opencv-msvc.md](doc/opencv-msvc.md) | gnu（默认交付）/ msvc（备选）两条路线的技术依据、旗标、验证闸门与已验证的坑 |
| 体积优化评估 | [doc/compression.md](doc/compression.md) | 安装包压缩参数与内容的实测评估：Inno 侧已到顶、可选杠杆与代价（仅评估，未落地） |
| 经验教训（跨环境通用） | [doc/lessons.md](doc/lessons.md) | 只收跨环境通用条目（PowerShell 5.1 / ISCC / 原生命令 / 网络等）；单场景坑见对应环境文档，编号映射见文末"附录 A" |

## 五、变更记录

详细变更写入 `docs/changes/YYYY-MM-DD.md`