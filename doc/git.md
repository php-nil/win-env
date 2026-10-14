# Git for Windows 一键安装包 · 打包文档

本文档是 Git 打包链路的唯一权威说明。构建配置位于 [builders/git](../builders/git)：

| 文件 | 作用 |
| --- | --- |
| `build.ps1` | 构建脚本：版本发现 → 下载 → 组装暂存目录 → 冒烟测试 → 编译安装包 → 输出元数据与发布说明 |
| `setup.iss` | Inno Setup 6 安装器脚本 |
| `Languages/ChineseSimplified.isl` | 安装向导简体中文语言包（官方 Inno Setup 安装包不含此文件，必须随仓库携带） |

## 1. 产物规格

| 项 | 值 |
| --- | --- |
| 产物文件 | `Git-<tag-version>-setup-x64.exe` |
| 附带文件 | `*.exe.sha256.txt`（校验值）、`build-info.json`（版本/来源元数据）、`release-notes.md`（Release 正文） |
| Release 标签 | `git-<tag-version>`（如 `git-2.56.0.windows.2`） |
| 规格 | 官方 Git for Windows 发行版（自解压 7z 包整包提取）· x64 |
| 默认安装目录 | `C:\pf\Git`（安装向导中可修改，**不带主版本号后缀**） |
| 安装后命令 | `git`（`<安装目录>\cmd` 强制加入系统 PATH，新开命令行即可用；附带 `git-bash`、`ssh`、`bash` 等工具） |
| 运行时依赖 | 无；完整独立发行版 |
| 权限 | 需要管理员（在 C 盘根目录创建文件夹并改写系统 PATH，安装器内置 UAC 提权） |
| 卸载 | 控制面板 / 安装目录下 `unins000.exe`，完整卸载 |

## 2. 触发构建（GitHub Actions）

手动触发，构建成功后自动发布 Release：

1. 仓库 **Actions** 页签 → **Build Git (Windows)** → **Run workflow**；
2. 输入参数：

| 参数 | 说明 |
| --- | --- |
| `git_version` | 不带 `v` 的精确 tag 名，如 `2.56.0.windows.2`；留空则自动取最新稳定版（跳过 prerelease/draft，且必须携带 64 位自解压包） |
| `draft_release` | 勾选后 Release 以草稿形式发布，不打公开标签 |

3. 构建完成后在 **Releases** 的 `git-<tag-version>` 标签下载安装包；工作流同时上传同名 build artifact。同名标签重跑会就地更新该 Release。

## 3. 安装包行为

- 双击安装，向导默认目录 `C:\pf\Git`，可自行修改。
- 安装内容即官方发行版解压后的暂存树（根目录为完整的 Git 目录布局），安装器只做原样释放，不在安装期下载或拼装任何内容。
- PATH（**必加，无安装选项**）：仅 `<安装目录>\cmd` 加入**系统** PATH（官方安装器同样做法；该目录含 `git.exe` shim）。
  - 安装时幂等追加（不重复、不动无关条目、顺带去空条目），并广播 `WM_SETTINGCHANGE`；
  - 卸载时精确移除该条目，其余 PATH 内容保留；已打开的旧命令行窗口需重开才能感知变化。
- 安装器固定 `AppId`（`{{A98E4B2C-7F3D-4A1B-9C0E-6D5F2B8E1C4A}`），重复安装/升级替换同一安装实例。
- 完整发行版自带 `git-bash`、`ssh`、`bash`、`perl` 等附加工具；本安装包**不**配置这些附加工具到 PATH，由用户按需自行决定。
- 安装目录下无任何用户级配置（`.gitconfig` 等），这些位于用户 `HOME`；安装/卸载不会碰用户数据。

## 4. 组件来源（官方渠道）

| 组件 | 来源 | 取用内容 |
| --- | --- | --- |
| Git for Windows | <https://github.com/git-for-windows/git/releases> | 64 位自解压包（asset 名形如 `PortableGit-<numeric-version>-64-bit.7z.exe`）直接解压为暂存树 |
| 版本发现 | GitHub Releases API `repos/git-for-windows/git/releases` | 筛选 tag 匹配 `^v2\.\d+\.\d+\.windows\.\d+$` 的最新稳定版（非 prerelease/draft 且携带 64 位自解压资产） |
| 版本号映射 | tag `2.56.0.windows.2` → asset 数字版本 `2.56.0.2`（去掉 `.windows.` 字面量） | 自动转换，无需手工维护 |
| 安装器 | [Inno Setup 6](https://jrsoftware.org/isinfo.php) | GitHub windows runner 预装；缺失时 workflow 用 Chocolatey 兜底安装 |

## 5. 本地构建

前置：Windows + PowerShell 5+；编译安装包需要 Inno Setup 6（仅组装阶段可跳过）。本机执行策略禁止未签名脚本时，用 `powershell -NoProfile -ExecutionPolicy Bypass -File ...` 调起，不修改系统执行策略。

```powershell
# 完整构建（自动发现最新 v2.x.windows.y，产物在 build\output）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\git\build.ps1

# 只做下载与组装，不编译安装包（无需 Inno Setup，产物在 build\stage\git）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\git\build.ps1 -SkipCompile

# 指定 tag 版本
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\git\build.ps1 -GitVersion 2.56.0.windows.2
```

构建脚本参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-GitVersion` | 空（自动发现） | 不带 `v` 的精确 tag 名，如 `2.56.0.windows.2` |
| `-BuildDir` | `<repo>\build` | 缓存/暂存/输出目录（Git 暂存树在 `build\stage\git`，与其他环境隔离） |
| `-SkipCompile` | 关 | 只组装不编译 |

ISCC 查找顺序：`ISCC` 环境变量 → `C:\Program Files (x86)\Inno Setup 6` → `C:\Program Files\Inno Setup 6` → PATH。

输出：

- `build\output\Git-<tag-ver>-setup-x64.exe`
- `build\output\Git-<tag-ver>-setup-x64.exe.sha256.txt`
- `build\output\build-info.json`（版本、下载 URL、大小、SHA-256）
- `build\output\release-notes.md`（Release 正文）

## 6. 设计约定

- **不硬编码补丁版本号**：运行时经官方 GitHub Releases API 解析；解析为空立即终止并报错，不猜测 URL。API 请求在 CI 中自动携带注入的 `GITHUB_TOKEN`（未认证限流 60 次/小时 → 1000 次/小时），本机无该变量时退化为匿名请求。下载 URL 保持标准 `github.com/.../download/...` 形式（runner 网络正常；本机若 github.com 被沙箱阻断可经 API 资产端点手工取物放入缓存，缓存命中即不重复下载）。
- **tag ↔ asset 版本号转换**：Git for Windows 的 GitHub tag 含字面 token `.windows.`（如 `2.56.0.windows.2`），asset 文件名把它换成 `.`（如 `PortableGit-2.56.0.2-64-bit.7z.exe`）。build.ps1 中 `Convert-TagVersionToAssetVersion` 函数负责这步转换，将来只要上游保持这个模式就自动工作。
- **自解压方式**：官方 64 位包是 7-Zip SFX（`.7z.exe`），直接调用 `<exe> -o<dir> -y -b0` 即可静默解压，无需额外下载 7z 工具。解压脚本会断言 `cmd\git.exe` 或 `bin\git.exe` 存在，防止上游换 asset 类型或解压结构异常继续推进。
- 暂存目录（`build/stage/git`）根目录即安装后的 `C:\pf\Git`，安装器只负责原样释放与 PATH 改写。
- 下载缓存于 `build/cache`（按真实 asset 文件名缓存），重复构建不重复下载；下载失败自动重试 3 次。
- 组装完成有强制冒烟测试：暂存 `cmd\git.exe --version`（或 `bin\git.exe` 兜底）的输出必须与解析出的版本号**逐字一致**（预期输出 `git version 2.56.0.windows.2`），失败即终止，绝不发布坏包。
- PATH 只加 `cmd` 子目录：官方 Git for Windows 同样做法；那里有 `git.exe` shim、`ssh.exe`、`bash.exe` 等 shim，按需使用。安装根目录本身**不**加入 PATH，避免大量无用的一级目录污染系统 PATH。
- 本机安装闭环验证：静默安装到**非默认目录** → 用注册表 Machine+User PATH 拼出新进程环境验证裸命令 `git --version` → 静默卸载 → 确认文件与 PATH 条目都消失。
