# pnpm Windows 一键安装包 · 打包文档

本文档是 pnpm 打包链路的唯一权威说明。构建配置位于 [builders/pnpm](../builders/pnpm)：

| 文件 | 作用 |
| --- | --- |
| `build.ps1` | 构建脚本：版本发现 → 下载 → 组装暂存目录 → 冒烟测试 → 编译安装包 → 输出元数据与发布说明 |
| `setup.iss` | Inno Setup 6 安装器脚本 |
| `Languages/ChineseSimplified.isl` | 安装向导简体中文语言包（官方 Inno Setup 安装包不含此文件，必须随仓库携带） |

## 1. 产物规格

| 项 | 值 |
| --- | --- |
| 产物文件 | `pnpm-<version>-setup-x64.exe`（约 16 MB，LZMA2 固实压缩 + 128 MB 字典，2026-10 实测） |
| 附带文件 | `*.exe.sha256.txt`（校验值）、`build-info.json`（版本/来源元数据）、`release-notes.md`（Release 正文） |
| Release 标签 | `pnpm-<version>`；另有常青别名 `pnpm-latest`（资产名固定 `pnpm-setup-x64.exe`，README 下载链接指向它） |
| 规格 | 官方 standalone `pnpm.exe`（Node.js 运行时已内置的单文件可执行程序）· x64 |
| 默认安装目录 | `C:\pf\pnpm`（安装向导中可修改，**不带主版本号后缀**） |
| 安装后命令 | `pnpm`（安装目录强制加入系统 PATH，新开命令行即可用） |
| 运行时依赖 | 无；无需预装 Node.js |
| 权限 | 需要管理员（在 C 盘根目录创建文件夹并改写系统 PATH，安装器内置 UAC 提权） |
| 卸载 | 控制面板 / 安装目录下 `unins000.exe`，完整卸载 |

## 2. 触发构建（GitHub Actions）

手动触发，构建成功后自动发布 Release：

1. 仓库 **Actions** 页签 → **Build pnpm (Windows)** → **Run workflow**；
2. 输入参数：

| 参数 | 说明 |
| --- | --- |
| `pnpm_version` | 不带 `v` 的精确版本号，如 `12.11.2`；留空则自动取 `major_track` 轨道上最新稳定版（跳过 prerelease/draft，且必须携带 `pnpm-win32-x64.zip` 资产） |
| `major_track` | 自动发现使用的主版本轨道，默认 `12`；`pnpm_version` 显式指定时此项被忽略。将来 pnpm 13 发布后可直接填 `13` 切换，无需改代码 |
| `draft_release` | 勾选后 Release 以草稿形式发布，不打公开标签 |

3. 构建完成后在 **Releases** 的 `pnpm-<version>` 标签下载安装包；工作流同时上传同名 build artifact。该标签已有公开（非草稿）Release 时本次不重复发布、不覆盖既有资产。随后把本次安装包以固定资产名 `pnpm-setup-x64.exe` 覆盖到常青别名 `pnpm-latest`（勾选 `draft_release` 时不更新），README 的下载链接只指向它。

## 3. 安装包行为

- 安装器 exe 图标为 pnpm 官方品牌图标（standalone pnpm.exe 本身无内嵌图标，ico 取自 pnpm 官方 GitHub 组织头像生成，随仓库保存在 `builders/pnpm/setup.ico`）。
- 双击安装，向导默认目录 `C:\pf\pnpm`，可自行修改。
- 安装内容即官方 `pnpm-win32-x64.zip` 解压后的暂存树（根目录为 `pnpm.exe`），安装器只做原样释放，不在安装期下载或拼装任何内容。
- PATH（**必加，无安装选项**）：安装目录加入**系统** PATH，保证新开命令行中 `pnpm` 可直接使用。
  - 安装时幂等追加（不重复、不动无关条目、顺带去空条目），并广播 `WM_SETTINGCHANGE`；
  - 卸载时精确移除该条目，其余 PATH 内容保留；已打开的旧命令行窗口需重开才能感知变化。
- 安装器固定 `AppId`（`{{C8D5F2A1-3E7B-4F92-A6D4-1B8E5C2F7A93}`），重复安装/升级替换同一安装实例。
- `pnpm.exe` 可整体迁移目录，安装目录下无占位符配置；全局 store、全局 bin 等用户数据默认位于用户目录（`LOCALAPPDATA` 等），不受安装/卸载影响。
- **全局安装的 CLI 不在本安装目录、也不由安装器配置 PATH**：`pnpm add -g <pkg>` 安装的命令默认位于 `%LOCALAPPDATA%\pnpm`（`PNPM_HOME`）。需要在命令行直接使用这些全局命令时，先执行一次官方的 `pnpm setup`（它会设置 `PNPM_HOME` 并把该目录加入**用户** PATH），然后新开命令行；安装包本身只保证 `pnpm` 本体可用，不代替 `pnpm setup`。
- 包内 `dist\node-gyp-bin` + `dist\node_modules` 是官方包自带的 node-gyp 垫片：安装含原生插件（node-gyp 编译）的依赖时由 pnpm 调用，**不可删除**；构建脚本会断言该目录存在，上游布局变化时直接构建失败。

## 4. 组件来源（官方渠道）

| 组件 | 来源 | 取用内容 |
| --- | --- | --- |
| pnpm | <https://github.com/pnpm/pnpm/releases> | `pnpm-win32-x64.zip` 整包解压为暂存树（根目录 `pnpm.exe`） |
| 版本发现 | GitHub Releases API `repos/pnpm/pnpm/releases` | 筛选主版本轨道 12 的最新稳定版（非 prerelease/draft 且携带 x64 zip 资产） |
| 安装器 | [Inno Setup 6](https://jrsoftware.org/isinfo.php) | GitHub windows runner 预装；缺失时 workflow 用 Chocolatey 兜底安装 |

## 5. 本地构建

前置：Windows + PowerShell 5+；编译安装包需要 Inno Setup 6（仅组装阶段可跳过）。本机执行策略禁止未签名脚本时，用 `powershell -NoProfile -ExecutionPolicy Bypass -File ...` 调起，不修改系统执行策略。

```powershell
# 完整构建（自动发现最新 v12.x，产物在 build\output）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\pnpm\build.ps1

# 只做下载与组装，不编译安装包（无需 Inno Setup，产物在 build\stage\pnpm）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\pnpm\build.ps1 -SkipCompile

# 指定版本
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\pnpm\build.ps1 -PnpmVersion 12.11.2
```

构建脚本参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-PnpmVersion` | 空（自动发现） | 不带 `v` 的精确版本号，如 `12.11.2` |
| `-MajorTrack` | `12` | 自动发现使用的主版本轨道 |
| `-BuildDir` | `<repo>\build` | 缓存/暂存/输出目录（pnpm 暂存树在 `build\stage\pnpm`，与其他环境隔离） |
| `-SkipCompile` | 关 | 只组装不编译 |

ISCC 查找顺序：`ISCC` 环境变量 → `C:\Program Files (x86)\Inno Setup 6` → `C:\Program Files\Inno Setup 6` → PATH。

输出：

- `build\output\pnpm-<ver>-setup-x64.exe`
- `build\output\pnpm-<ver>-setup-x64.exe.sha256.txt`
- `build\output\build-info.json`（版本、下载 URL、大小、SHA-256）
- `build\output\release-notes.md`（Release 正文）

## 6. 设计约定

- **不硬编码补丁版本号**：运行时经官方 GitHub Releases API 解析主版本轨道内的最新稳定版；解析为空立即终止并报错，不猜测 URL。API 请求在 CI 中自动携带注入的 `GITHUB_TOKEN`（未认证限流 60 次/小时 → 1000 次/小时），本机无该变量时退化为匿名请求。下载 URL 保持标准 `github.com/.../download/...` 形式（runner 网络正常；本机若 github.com 被沙箱阻断可经 API 资产端点手工取物放入缓存，缓存命中即不重复下载）。
- 暂存目录（`build/stage/pnpm`）根目录即安装后的 `C:\pf\pnpm`，安装器只负责原样释放与 PATH 改写。
- 下载缓存于 `build/cache`（按版本命名），重复构建不重复下载；下载失败自动重试 3 次。
- 组装完成有强制冒烟测试：暂存 `pnpm.exe --version` 的输出必须与解析出的版本号**逐字一致**，失败即终止，绝不发布坏包。
- 本机安装闭环验证：静默安装到**非默认目录** → 用注册表 Machine+User PATH 拼出新进程环境验证裸命令 `pnpm --version` → 静默卸载 → 确认文件与 PATH 条目都消失。
