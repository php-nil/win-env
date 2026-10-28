# Node.js Windows 一键安装包 · 打包文档

本文档是 Node.js 打包链路的唯一权威说明。构建配置位于 [builders/node](../builders/node)：

| 文件 | 作用 |
| --- | --- |
| `build.ps1` | 构建脚本：版本发现 → 下载 → 组装暂存目录 → 冒烟测试 → 编译安装包 → 输出元数据与发布说明 |
| `setup.iss` | Inno Setup 6 安装器脚本 |
| `Languages/ChineseSimplified.isl` | 安装向导简体中文语言包（官方 Inno Setup 安装包不含此文件，必须随仓库携带） |
| `setup.ico` | 安装器图标（从官方 `node.exe` 图标资源提取，含 16–256 px 共 6 帧） |

## 1. 产物规格

| 项 | 值 |
| --- | --- |
| 产物文件 | `node-<version>-setup-x64.exe`（约 25.4 MiB，LZMA2 固实压缩 + 128 MB 字典，2026-10 实测 24.21.0） |
| 附带文件 | `*.exe.sha256.txt`（校验值）、`build-info.json`（版本/来源元数据）、`release-notes.md`（Release 正文） |
| Release 标签 | `node-<version>`；另有常青别名 `node-latest`（资产名固定 `node-setup-x64.exe`，README 下载链接指向它） |
| 规格 | 官方 `node-v<version>-win-x64.zip` 完整解压树 · x64 · LTS（当前线 Krypton） |
| 默认安装目录 | `C:\pf\node`（安装向导中可修改，**不带版本号后缀**） |
| 安装后命令 | `node`、`npm`、`npx`（安装目录强制加入系统 PATH，新开命令行即可用；corepack 随包提供） |
| 运行时依赖 | 无 |
| 权限 | 需要管理员（在 C 盘根目录创建文件夹并改写系统 PATH，安装器内置 UAC 提权） |
| 卸载 | 控制面板 / 安装目录下 `unins000.exe`，完整卸载 |

## 2. 触发构建（GitHub Actions）

手动触发，构建成功后自动发布 Release：

1. 仓库 **Actions** 页签 → **Build Node.js** → **Run workflow**；
2. 输入参数：

| 参数 | 说明 |
| --- | --- |
| `node_version` | 不带 `v` 的精确版本号，如 `24.21.0`；留空则自动取官方 dist 索引中最新的 LTS 版本 |
| `major_track` | 自动发现限定主版本轨道，如 `24`；留空 = 任意 LTS 轨道取最新。`node_version` 显式指定时此项被忽略 |
| `draft_release` | 勾选后 Release 以草稿形式发布，不打公开标签 |

3. 构建完成后在 **Releases** 的 `node-<version>` 标签下载安装包；工作流同时上传同名 build artifact。该标签已有公开（非草稿）Release 时本次不重复发布、不覆盖既有资产。随后把本次安装包以固定资产名 `node-setup-x64.exe` 覆盖到常青别名 `node-latest`（勾选 `draft_release` 时不更新），README 的下载链接只指向它。

## 3. 安装包行为

- 安装器 exe 图标为 Node.js 官方图标（提取自官方 `node.exe` 的图标资源组，16/32/48/64/128/256 px 六帧，随仓库保存在 `builders/node/setup.ico`）。
- 双击安装，向导默认目录 `C:\pf\node`，可自行修改。
- 安装内容即官方 `node-v<version>-win-x64.zip` 解压后的完整目录树（`node.exe`、`npm.cmd`、`npx.cmd`、`node_modules\` 等），安装器只做原样释放，不在安装期下载或拼装任何内容。
- PATH（**必加，无安装选项**）：安装目录加入**系统** PATH，保证新开命令行中 `node` / `npm` / `npx` 可直接使用。
  - 安装时幂等追加（不重复、不动无关条目、顺带去空条目），并广播 `WM_SETTINGCHANGE`；
  - 卸载时精确移除该条目，其余 PATH 内容保留；已打开的旧命令行窗口需重开才能感知变化。
- 安装器固定 `AppId`（`{{5D2A8C41-7B3E-4F69-9A85-C1E4B6D2F308}`），重复安装/升级替换同一安装实例。
- **npm 全局数据不在安装目录**：`npm install -g` 默认前缀为 `%APPDATA%\npm`（用户目录），不由本安装器配置 PATH；卸载本包不清除这些用户数据，重装 Node.js 后仍可用。
- 包内自带 corepack；`corepack enable` 需要向安装目录写 shim（默认 `C:\pf\node`），须在管理员终端执行。

## 4. 组件来源（官方渠道）

| 组件 | 来源 | 取用内容 |
| --- | --- | --- |
| Node.js | <https://nodejs.org/dist/> | `node-v<version>-win-x64.zip` 整包解压拍平为暂存树（根目录 `node.exe`） |
| 版本发现 | 官方 dist 索引 <https://nodejs.org/dist/index.json> | `lts` 字段非 `false` 的最新发布条目（索引按发布时间倒序，可选 `major_track` 限定轨道）；显式指定版本时校验其存在于索引并读取对应元数据 |
| 安装器 | [Inno Setup 6](https://jrsoftware.org/isinfo.php) | GitHub windows runner 预装；缺失时 workflow 用 Chocolatey 兜底安装 |

## 5. 本地构建

前置：Windows + PowerShell 5+；编译安装包需要 Inno Setup 6（仅组装阶段可跳过）。本机执行策略禁止未签名脚本时，用 `powershell -NoProfile -ExecutionPolicy Bypass -File ...` 调起，不修改系统执行策略。

```powershell
# 完整构建（自动发现最新 LTS，产物在 build\output）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\node\build.ps1

# 只做下载与组装，不编译安装包（无需 Inno Setup，产物在 build\stage\node）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\node\build.ps1 -SkipCompile

# 指定版本 / 限定轨道
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\node\build.ps1 -NodeVersion 24.21.0
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\node\build.ps1 -MajorTrack 24
```

构建脚本参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-NodeVersion` | 空（自动发现） | 不带 `v` 的精确版本号，如 `24.21.0` |
| `-MajorTrack` | 空（任意 LTS 轨道） | 自动发现限定主版本轨道，如 `24` |
| `-BuildDir` | `<repo>\build` | 缓存/暂存/输出目录（node 暂存树在 `build\stage\node`，与其他环境隔离） |
| `-SkipCompile` | 关 | 只组装不编译 |

ISCC 查找顺序：`ISCC` 环境变量 → `C:\Program Files (x86)\Inno Setup 6` → `C:\Program Files\Inno Setup 6` → PATH。

输出：

- `build\output\node-<ver>-setup-x64.exe`
- `build\output\node-<ver>-setup-x64.exe.sha256.txt`
- `build\output\build-info.json`（版本、LTS 代号、npm 版本、下载 URL、大小、SHA-256）
- `build\output\release-notes.md`（Release 正文）

## 6. 设计约定

- **不硬编码补丁版本号**：运行时从官方 dist 索引解析最新 LTS；解析为空立即终止报错，不猜测 URL。显式指定的版本也必须在索引中存在（同时借索引取得 npm 版本元数据）。版本发现走 nodejs.org（非 GitHub API），无速率限额问题。
- 暂存目录（`build/stage/node`）根目录即安装后的 `C:\pf\node`，安装器只负责原样释放与 PATH 改写。官方 zip 内含单层 `node-v<ver>-win-x64` 根目录，构建时拍平。
- 下载缓存于 `build/cache`（按官方资产名命名），重复构建不重复下载；下载失败自动重试 3 次。
- 组装完成有强制冒烟测试：暂存 `node.exe --version` 输出必须与版本号逐字一致（`v<version>`）；`npm.cmd --version` 必须与 dist 索引记录的 `npm` 字段逐字一致。另断言官方布局（`node.exe`、`npm.cmd`、`node_modules\npm\bin\npm-cli.js`），上游布局变化时直接构建失败。
- 本机安装闭环验证：静默安装到**非默认目录** → 用注册表 Machine+User PATH 拼出新进程环境验证裸命令 `node` / `npm` / `npx` → 静默卸载 → 确认文件与 PATH 条目都消失。
