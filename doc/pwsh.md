# PowerShell 7 一键安装包 · 打包文档

本文档是 PowerShell 7 打包链路的唯一权威说明。构建配置位于 [builders/pwsh](../builders/pwsh)：

| 文件 | 作用 |
| --- | --- |
| `build.ps1` | 构建脚本：版本发现 → 下载 → 组装暂存目录 → 冒烟测试 → 编译安装包 → 输出元数据与发布说明 |
| `setup.iss` | Inno Setup 6 安装器脚本（PATH + 资源管理器右键菜单 + Windows Terminal 配置档 fragment） |
| `Languages/ChineseSimplified.isl` | 安装向导简体中文语言包（官方 Inno Setup 安装包不含此文件，必须随仓库携带） |

## 1. 产物规格

| 项 | 值 |
| --- | --- |
| 产物文件 | `pwsh-<version>-setup-x64.exe` |
| 附带文件 | `*.exe.sha256.txt`（校验值）、`build-info.json`（版本/来源元数据）、`release-notes.md`（Release 正文） |
| Release 标签 | `pwsh-<version>`（如 `pwsh-7.6.7`） |
| 规格 | 官方 PowerShell v7.6.x 发行版（win-x64 zip 整包提取）· x64 |
| 默认安装目录 | `C:\pf\PowerShell7`（安装向导中可修改） |
| 安装后命令 | `pwsh`（安装目录强制加入系统 PATH，新开命令行即可用） |
| 运行时依赖 | 无；zip 包自含 .NET 运行时 |
| 权限 | 需要管理员（在 C 盘根目录创建文件夹并改写系统 PATH / HKLM 注册表，安装器内置 UAC 提权） |
| 卸载 | 控制面板 / 安装目录下 `unins000.exe`，完整卸载（文件、PATH、右键菜单、WT fragment 全部清除） |

## 2. 触发构建（GitHub Actions）

手动触发，构建成功后自动发布 Release：

1. 仓库 **Actions** 页签 → **Build PowerShell 7** → **Run workflow**；
2. 输入参数：

| 参数 | 说明 |
| --- | --- |
| `pwsh_version` | 不带 `v` 的精确版本号，如 `7.6.6`；留空则自动取 v7.6 产品线最新稳定版（跳过 prerelease/draft，且必须携带 win-x64 zip 资产） |
| `draft_release` | 勾选后 Release 以草稿形式发布，不打公开标签 |

3. 构建完成后在 **Releases** 的 `pwsh-<version>` 标签下载安装包；工作流同时上传同名 build artifact。同名标签重跑会就地更新该 Release。

## 3. 安装包行为

- 安装器 exe 图标为 PowerShell 官方图标（构建时从官方 pwsh.exe 提取，随仓库保存在 `builders/pwsh/setup.ico`）。
- 双击安装，向导默认目录 `C:\pf\PowerShell7`，可自行修改。
- 安装内容即官方 zip 解压后的暂存树（`pwsh.exe` 位于根目录），安装器只做原样释放，不在安装期下载或拼装任何内容。
- PATH（**必加，无安装选项**）：安装目录加入**系统** PATH。
  - 安装时幂等追加（不重复、不动无关条目、顺带去空条目），并广播 `WM_SETTINGCHANGE`；
  - 卸载时精确移除该条目，其余 PATH 内容保留；已打开的旧命令行窗口需重开才能感知变化。
- **资源管理器右键菜单**：对文件夹与其空白背景注册 `在此处打开 PowerShell 7`（HKLM\SOFTWARE\Classes\Directory\shell 与 Directory\Background\shell 下的 `winenv-pwsh` 键，带 pwsh 图标），命令为 `pwsh.exe -NoExit -Command Set-Location -LiteralPath '%V'`。卸载时整键删除。
  - **Windows 11 注意**：经典右键菜单项折叠在「显示更多选项」二级菜单内；要做一级菜单项需 MSIX sparse package + IExplorerCommand，超出 Inno Setup 能力范围，不做。
- **Windows Terminal 配置档**：安装时向 `%ProgramData%\Microsoft\Windows Terminal\Fragments\win-env-pwsh\pwsh.json` 写入 fragment（系统级发现机制，不改动任何用户的 settings.json），Windows Terminal 下次启动自动出现「PowerShell 7」配置档；卸载时删除该文件与目录。未安装 Windows Terminal 的机器上写入该文件无副作用。
- 安装器固定 `AppId`（`{{E4A7C2D1-8B3F-4E6A-9D2C-5F1B8A3E7C94}`），重复安装/升级替换同一安装实例。
- 安装目录下无任何用户级配置（`$PROFILE` 等），这些位于用户目录；安装/卸载不会碰用户数据。

## 4. 组件来源（官方渠道）

| 组件 | 来源 | 取用内容 |
| --- | --- | --- |
| PowerShell | <https://github.com/PowerShell/PowerShell/releases> | win-x64 zip（asset 名形如 `PowerShell-<version>-win-x64.zip`）直接解压为暂存树 |
| 版本发现 | GitHub Releases API `repos/PowerShell/PowerShell/releases` | 筛选 tag 匹配 `^v7\.6\.\d+$` 的最新稳定版（非 prerelease/draft 且携带 win-x64 zip 资产） |
| 安装器 | [Inno Setup 6](https://jrsoftware.org/isinfo.php) | GitHub windows runner 预装；缺失时 workflow 用 Chocolatey 兜底安装 |

## 5. 本地构建

前置：Windows + PowerShell 5+；编译安装包需要 Inno Setup 6（仅组装阶段可跳过）。本机执行策略禁止未签名脚本时，用 `powershell -NoProfile -ExecutionPolicy Bypass -File ...` 调起，不修改系统执行策略。

```powershell
# 完整构建（自动发现最新 v7.6.x，产物在 build\output）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\pwsh\build.ps1

# 只做下载与组装，不编译安装包（无需 Inno Setup，产物在 build\stage\pwsh）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\pwsh\build.ps1 -SkipCompile

# 指定版本
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\pwsh\build.ps1 -PwshVersion 7.6.6
```

构建脚本参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-PwshVersion` | 空（自动发现） | 不带 `v` 的精确版本号，如 `7.6.6` |
| `-BuildDir` | `<repo>\build` | 缓存/暂存/输出目录（暂存树在 `build\stage\pwsh`，与其他环境隔离） |
| `-SkipCompile` | 关 | 只组装不编译 |

ISCC 查找顺序：`ISCC` 环境变量 → `C:\Program Files (x86)\Inno Setup 6` → `C:\Program Files\Inno Setup 6` → PATH。

输出：

- `build\output\pwsh-<version>-setup-x64.exe`
- `build\output\pwsh-<version>-setup-x64.exe.sha256.txt`
- `build\output\build-info.json`（版本、下载 URL、大小、SHA-256）
- `build\output\release-notes.md`（Release 正文）

## 6. 设计约定

- **不硬编码补丁版本号**：运行时经官方 GitHub Releases API 解析；解析为空立即终止并报错，不猜测 URL。API 请求在 CI 中自动携带注入的 `GITHUB_TOKEN`（未认证限流 60 次/小时 → 1000 次/小时），本机无该变量时退化为匿名请求。下载 URL 保持标准 `github.com/.../download/...` 形式（runner 网络正常；本机 github.com 直连过慢时可经 gh-proxy 手工取物放入 `build\cache`，缓存命中即不重复下载）。
- **解压方式**：官方 zip 约 100 MB、含数千条目，PS 5.1 的 `Expand-Archive` 极慢；优先用 Windows 10+ 自带的 `C:\Windows\System32\tar.exe`（bsdtar）解包，缺失时才回退 `Expand-Archive`。解压后断言根目录存在 `pwsh.exe`，防止上游换 asset 结构继续推进。
- 暂存目录（`build/stage/pwsh`）根目录即安装后的 `C:\pf\PowerShell7`，安装器只负责原样释放与 PATH/注册表改写。
- 下载缓存于 `build/cache`（按真实 asset 文件名缓存），重复构建不重复下载；下载失败自动重试 3 次。
- 组装完成有强制冒烟测试：暂存 `pwsh.exe -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'` 的输出必须与解析出的版本号**逐字一致**，失败即终止，绝不发布坏包。
- **安装包体积**：暂存树约 245 MB（自含 .NET 运行时），lzma2/max 压缩后安装包约 74 MB（7.6.7 实测）。`LZMADictionarySize` 取 128 MB——32 位 ISCC 编码器不接受 256 MB（`LZMA_Encode failed with code 5`）。
- **Windows Terminal 配置档用 fragment 而非改 settings.json**：fragment 是官方支持的系统级发现机制（`%ProgramData%\Microsoft\Windows Terminal\Fragments\<app>\*.json`），安装器写入真实安装路径（`{app}` 在向导中可改，故 fragment 必须安装期生成而非随包静态携带），卸载即删，不留痕、不与其他 WT 配置冲突。
- 本机安装闭环验证：静默安装到**非默认目录** → 用注册表 Machine+User PATH 拼出新进程环境验证裸命令 `pwsh -NoProfile -Command '$PSVersionTable.PSVersion'` → 检查右键菜单注册表键与 WT fragment 文件 → 静默卸载 → 确认文件、PATH 条目、注册表键、fragment 全部消失。
