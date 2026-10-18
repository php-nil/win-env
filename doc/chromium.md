# ungoogled-chromium Windows 一键安装包 · 打包文档

本文档是 ungoogled-chromium 打包链路的唯一权威说明。构建配置位于 [builders/chromium](../builders/chromium)：

| 文件 | 作用 |
| --- | --- |
| `build.ps1` | 构建脚本：版本发现 → 下载 → 组装暂存目录 → 冒烟测试 → 编译安装包 → 输出元数据与发布说明 |
| `setup.iss` | Inno Setup 6 安装器脚本（默认目录、桌面快捷方式、系统 PATH） |
| `Languages/ChineseSimplified.isl` | 安装向导简体中文语言包（官方 Inno Setup 安装包不含此文件，必须随仓库携带） |
| `setup.ico` | 安装器图标（从官方 `chrome.exe` 图标资源提取，含 16–256 px 帧） |

## 1. 产物规格

| 项 | 值 |
| --- | --- |
| 产物文件 | `chromium-<tag>-setup-x64.exe`（约 131.9 MiB，LZMA2 固实压缩 + 128 MB 字典，tag 形如 `155.0.8059.39-1.1`；暂存树约 420.5 MB，2026-10 实测 155.0.8059.39-1.1） |
| 附带文件 | `*.exe.sha256.txt`（校验值）、`build-info.json`（版本/来源元数据）、`release-notes.md`（Release 正文） |
| Release 标签 | `chromium-<tag>` |
| 规格 | 官方 `ungoogled-chromium_<tag>_windows_x64.zip` 完整解压树 · x64 · 便携版（Chromium + ungoogled 补丁） |
| 默认安装目录 | `C:\pf\chromium`（安装向导中可修改，**不带版本号后缀**） |
| 安装后命令 | `chrome`（安装目录强制加入系统 PATH，新开命令行即可用） |
| 桌面快捷方式 | 为所有用户创建 `Chromium`（指向 `<安装目录>\chrome.exe`），卸载时移除 |
| 运行时依赖 | 无（官方便携包自带全部 DLL 与资源） |
| 权限 | 需要管理员（在 C 盘根目录创建文件夹、改写系统 PATH、写公共桌面） |
| 卸载 | 控制面板 / 安装目录下 `unins000.exe`，完整卸载（用户数据除外，见 §3） |

## 2. 触发构建（GitHub Actions）

手动触发，构建成功后自动发布 Release：

1. 仓库 **Actions** 页签 → **Build Chromium (ungoogled)** → **Run workflow**；
2. 输入参数：

| 参数 | 说明 |
| --- | --- |
| `chromium_version` | 精确的发布 tag，如 `155.0.8059.39-1.1`（上游 Chromium 版本 + ungoogled 构建修订号）；留空则自动取最新一个携带 x64 便携 zip 的稳定 Release |
| `mirror_base` | 可选 GitHub-release 镜像基址，同时用于版本发现与下载，如 `https://mirrors.ustc.edu.cn/github-release/ungoogled-software/ungoogled-chromium-windows`（国内速度快）；留空走官方 GitHub 端点 |
| `draft_release` | 勾选后 Release 以草稿形式发布，不打公开标签 |

3. 构建完成后在 **Releases** 的 `chromium-<tag>` 标签下载安装包；工作流同时上传同名 build artifact。同名标签重跑会就地更新该 Release。

## 3. 安装包行为

- 安装器 exe 图标为 Chromium 官方图标（提取自官方 `chrome.exe` 的图标资源组，16/32/48/256 px 帧共 7 个图像，随仓库保存在 `builders/chromium/setup.ico`）。
- 双击安装，向导默认目录 `C:\pf\chromium`，可自行修改。
- 安装内容即官方 `ungoogled-chromium_<tag>_windows_x64.zip` 解压后的完整目录树（`chrome.exe`、`chrome.dll`、`locales\`、`resources.pak`、`icudtl.dat` 等），**暂存时把 zip 内单层包装目录 `ungoogled-chromium_<tag>_windows_x64\` 拍平**，安装器只做原样释放，不在安装期下载或拼装任何内容。
- **桌面快捷方式**：安装时为**所有用户**创建桌面快捷方式 `Chromium` → `{app}\chrome.exe`（安装器以管理员身份运行，故用 `{commondesktop}`）；卸载时由 Inno Setup 自动一并移除。
- PATH（**必加，无安装选项**）：安装目录加入**系统** PATH，保证新开命令行中 `chrome` 可直接使用。
  - 安装时幂等追加（不重复、不动无关条目、顺带去空条目），并广播 `WM_SETTINGCHANGE`；
  - 卸载时精确移除该条目，其余 PATH 内容保留；已打开的旧命令行窗口需重开才能感知变化。
- 安装器固定 `AppId`（`{{9C4E7A13-6B2D-4F85-8E71-3A5C0D9B2F46}`），重复安装/升级替换同一安装实例。
- **用户数据不在安装目录**：浏览器配置与缓存默认位于 `%LOCALAPPDATA%\Chromium\User Data`（与官方 Chromium 一致的默认行为），不由本安装器管理；卸载本包不清除这些用户数据，重装后仍可用。若需便携模式（配置随安装目录走），自行给 `chrome.exe` 加 `--user-data-dir` 参数启动。
- 版本号含非数字 token（`-1.1` 修订后缀）：`VersionInfoVersion` 用去后缀的纯数字版 `155.0.8059.39`，显示字符串（`AppVerName`、卸载显示名等）保留完整 tag（见 [lessons.md §7](lessons.md)）。

## 4. 组件来源（官方渠道）

| 组件 | 来源 | 取用内容 |
| --- | --- | --- |
| ungoogled-chromium | <https://github.com/ungoogled-software/ungoogled-chromium-windows> Releases | `ungoogled-chromium_<tag>_windows_x64.zip` 整包解压、拍平单层包装目录为暂存树（根目录 `chrome.exe`） |
| 版本发现 | 官方 GitHub Releases API `/releases?per_page=30` | 取最新的**非草稿、非预发布**且携带 `*_windows_x64.zip` 资产的 Release，`tag_name` 即版本；CI 注入 `GITHUB_TOKEN` 规避未认证限额（见 [lessons.md §8](lessons.md)） |
| 版本发现（镜像） | `<mirror_base>/LatestRelease/` 目录列表 | 从 `ungoogled-chromium_<tag>_windows_x64.zip` 资产名中直接解析 tag（仅在使用镜像时） |
| 安装器 | [Inno Setup 6](https://jrsoftware.org/isinfo.php) | GitHub windows runner 预装；缺失时 workflow 用 Chocolatey 兜底安装 |

### 4.1 镜像用法（国内本地构建）

- 传入 `mirror_base`（workflow 输入）或 `-MirrorBase`（本地脚本）即把**发现与下载**都切到镜像；镜像目录名等于 GitHub tag、资产名与 GitHub 完全一致，故 URL 可稳定构造。
- **USTC 镜像对直链资产有 JS Cookie 防爬**：首次请求返回一个 877 字节的 `Verifying your browser` 页面（内含 `document.cookie = "addr=<客户端IP>"`）。`Download-File` 会自动识别该页、取出 `addr` 值写入会话 Cookie 后重取一次真实资产；对官方 GitHub 端点无副作用（不会出现该页面）。
- 官方端点（默认）保持标准 `github.com/.../download/...`，镜像只作为可选路径，不改变 CI 默认行为。

## 5. 本地构建

前置：Windows + PowerShell 5+；编译安装包需要 Inno Setup 6（仅组装阶段可跳过）。本机执行策略禁止未签名脚本时，用 `powershell -NoProfile -ExecutionPolicy Bypass -File ...` 调起，不修改系统执行策略。

```powershell
# 完整构建（走官方 GitHub，产物在 build\output）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\chromium\build.ps1

# 国内建议走 USTC 镜像（发现 + 下载都走镜像）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\chromium\build.ps1 `
  -MirrorBase 'https://mirrors.ustc.edu.cn/github-release/ungoogled-software/ungoogled-chromium-windows'

# 只做下载与组装，不编译安装包（无需 Inno Setup，产物在 build\stage\chromium）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\chromium\build.ps1 -SkipCompile -ChromiumVersion 155.0.8059.39-1.1
```

构建脚本参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-ChromiumVersion` | 空（自动发现） | 精确发布 tag，如 `155.0.8059.39-1.1` |
| `-MirrorBase` | 空（官方 GitHub） | 可选的 GitHub-release 镜像基址，同时用于发现与下载 |
| `-BuildDir` | `<repo>\build` | 缓存/暂存/输出目录（chromium 暂存树在 `build\stage\chromium`，与其他环境隔离） |
| `-SkipCompile` | 关 | 只组装不编译 |

ISCC 查找顺序：`ISCC` 环境变量 → `C:\Program Files (x86)\Inno Setup 6` → `C:\Program Files\Inno Setup 6` → PATH。

输出：

- `build\output\chromium-<tag>-setup-x64.exe`
- `build\output\chromium-<tag>-setup-x64.exe.sha256.txt`
- `build\output\build-info.json`（版本、上游 Chromium 版本、下载 URL、镜像基址、大小、SHA-256）
- `build\output\release-notes.md`（Release 正文）

## 6. 设计约定

- **不硬编码 tag**：运行时从官方 GitHub Releases API 解析最新稳定 Release；解析为空立即终止报错，不猜测 URL。显式指定的 tag 也须匹配 `^\d+\.\d+\.\d+\.\d+(-\d+(\.\d+)?)?$`。
- 暂存目录（`build/stage/chromium`）根目录即安装后的 `C:\pf\chromium`，安装器只负责原样释放 + PATH 改写 + 桌面快捷方式。官方 zip 内含单层 `ungoogled-chromium_<tag>_windows_x64\` 根目录，构建时拍平；顶层若不止一个目录则直接报错（上游布局变更）。
- 下载缓存于 `build/cache`（按官方资产名命名，约 190 MB），重复构建不重复下载；下载失败自动重试 3 次；镜像的 Cookie 挑战在下载助手内自动化解。
- 组装完成有强制冒烟测试（暂存树内**绝对路径**调用，避免误用机器上其他浏览器）：
  1. **PE 版本断言**：`chrome.exe` 的 `FileVersion` 必须等于 tag 去掉 `-<修订>` 后的 Chromium 版本（如 `155.0.8059.39`）。`chrome.exe` 是 GUI 子系统程序，`--version` 不打印任何输出、也无退出码，故以嵌入的 PE 版本为准。
  2. **真实无头启动**：`chrome.exe --headless=new --dump-dom` 渲染一个带标记的 `data:` 页面，必须在 90 s 内退出且 stdout 命中标记——这能证明 `chrome.dll`、`.pak` 资源与 V8 快照确实加载成功，截断/错配的载荷会在此失败而不是在用户桌面。
  3. 关键文件存在性断言（`chrome.dll`、`resources.pak`、`icudtl.dat`、`locales\en-US.pak`、`locales\zh-CN.pak` 等）。
- 交付 ISCC 前清理暂存树内所有重解析点（见 [lessons.md §14](lessons.md)）。
- 本机安装闭环验证：静默安装到**非默认目录** → 用注册表 Machine PATH 拼出新进程环境验证裸命令 `chrome` → 确认公共桌面出现 `Chromium` 快捷方式 → 静默卸载 → 确认文件、PATH 条目与快捷方式都消失。
