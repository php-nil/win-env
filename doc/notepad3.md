# Notepad3 Windows 一键安装包 · 打包文档

本文档是 Notepad3 打包链路的唯一权威说明。构建配置位于 [builders/notepad3](../builders/notepad3)：

| 文件 | 作用 |
| --- | --- |
| `build.ps1` | 构建脚本：版本发现 → 下载 → 摘要校验 → 解压 → 语言裁剪 → 冒烟测试 → 编译安装包 → 输出元数据与发布说明 |
| `setup.iss` | Inno Setup 6 安装器脚本（默认目录、PATH、快捷方式、"打开方式"注册、跳转默认应用设置页） |
| `Languages/ChineseSimplified.isl` | 安装向导简体中文语言包（官方 Inno Setup 安装包不含此文件，必须随仓库携带） |
| `setup.ico` | 安装器图标（从官方 `Notepad3.exe` 图标资源组提取，16/32/48/64/128/256 px 共 6 帧） |

## 1. 产物规格

| 项 | 值 |
| --- | --- |
| 产物文件 | `notepad3-<version>-setup-x64.exe`（约 4.37 MiB，LZMA2 固实压缩；暂存树 9.53 MB，2026-11 实测 `7.26.602.1`） |
| 附带文件 | `*.exe.sha256.txt`（校验值）、`build-info.json`（版本/来源/裁剪元数据）、`release-notes.md`（Release 正文） |
| Release 标签 | `notepad3-<version>`；另有常青别名 `notepad3-latest`（资产名固定 `notepad3-setup-x64.exe`，README 下载链接指向它） |
| 规格 | 官方 `Notepad3_<version>_x64_Portable.zip` 完整解压树（**不含**官方 Setup.exe）· x64 · 便携版 |
| 默认安装目录 | `C:\pf\Notepad3`（安装向导中可修改，**不带版本号后缀**） |
| 安装后命令 | `Notepad3`（安装目录强制加入系统 PATH，新开命令行即可用） |
| 快捷方式 | 开始菜单默认创建；桌面为可选任务（`desktopicon`，默认不勾选） |
| 运行时依赖 | 无（静态 CRT；构建期强制断言不依赖 VCRUNTIME140 / MSVCP140 / UCRT） |
| 权限 | 需要管理员（在 C 盘根目录创建文件夹、改写系统 PATH、写 HKLM 关联注册项） |
| 卸载 | 控制面板 / 安装目录下 `unins000.exe`；只删自有注册项与 PATH 条目，保留用户 `Notepad3.ini` |

## 2. 触发构建（GitHub Actions）

手动触发，构建成功后自动发布 Release；另有每周定时自动构建（北京时间每周日 14:00，cron `0 6 * * 0` = UTC 周日 06:00）。定时触发不携带 inputs：`notepad3_version` 留空即自动从官方 GitHub Releases API 发现最新稳定版。

1. 仓库 **Actions** 页签 → **Build Notepad3** → **Run workflow**；
2. 输入参数：

| 参数 | 说明 |
| --- | --- |
| `notepad3_version` | 精确版本号，形如 `7.26.602.1`（即 tag `RELEASE_7.26.602.1` 去掉 `RELEASE_` 前缀，四段纯数字）；留空则自动取最新一个携带 `Notepad3_<version>_x64_Portable.zip` 的**非草稿、非预发布** Release |
| `draft_release` | 勾选后 Release 以草稿形式发布，且不更新常青别名 |

3. 构建完成后在 **Releases** 的 `notepad3-<version>` 标签下载安装包；工作流同时上传同名 build artifact。该标签已有公开（非草稿）Release 时本次不重复发布、不覆盖既有资产。随后把本次安装包以固定资产名 `notepad3-setup-x64.exe` 覆盖到常青别名 `notepad3-latest`（勾选 `draft_release` 时不更新），README 的下载链接只指向它。

## 3. 安装包行为

- 安装器 exe 图标为 Notepad3 官方图标（提取自官方 `Notepad3.exe` 的图标资源组，16/32/48/64/128/256 px 共 6 帧，随仓库保存在 `builders/notepad3/setup.ico`）。
- 双击安装，向导默认目录 `C:\pf\Notepad3`，可自行修改。
- 安装内容即官方 x64 便携包解压后的完整目录树（`Notepad3.exe`、`minipath.exe`、`np3encrypt.exe`、`grepWin\`、`lng\`、`Themes\`、`Docs\`、`Favorites\`、`Notepad3.ini`），**安装器只做原样释放**，不在安装期下载或拼装任何内容。
- **配置就在安装目录**：沿用上游便携约定，`Notepad3.ini` 位于 exe 同目录，**不重定向** 到 `%APPDATA%`。
  - 安装时 `Notepad3.ini` 仅在不存在时写入（`onlyifdoesntexist`）并标记 `uninsneveruninstall`：升级/重装不覆盖用户已改过的配置，卸载也不删除它。
  - `Themes\` 与 `Favorites\` 同样是用户可改的目录，安装时按"已存在则跳过"处理；取舍是：**升级不会覆盖本地修改**，但卸载会移除本安装器曾释放、此后被用户改过的那些主题文件（`Notepad3.ini` 始终受保护）。`Favorites\` 上游为空目录，由 `[Dirs]` 单独创建、空目录随卸载移除。
- PATH（**必加，无安装选项**）：安装目录加入**系统** PATH，保证新开命令行中 `Notepad3` 可直接使用；安装幂等追加、卸载精确移除，并广播 `WM_SETTINGCHANGE`。
- **快捷方式**：开始菜单 `Notepad3` 默认创建；桌面快捷方式为可选任务。
- 安装器固定 `AppId`（`{{5E9B0C7A-3D2F-4A81-B6C4-9F2D7E1A8B35}`），重复安装/升级替换同一安装实例。

### 3.1 文件关联：只注册为"打开方式"候选

安装向导的「文件类型」分组提供逐个扩展名的任务：

| 默认勾选 | 扩展名 |
| --- | --- |
| 勾选 | `.txt` `.log` `.ini` `.md` `.json` `.xml` `.yml` `.yaml` `.csv` |
| **不勾选** | `.bat` `.cmd`（批处理，误关联风险高）、`.ps1`（PowerShell 脚本） |

全部取消勾选时不写入任何关联注册项。勾选后写入的是（全部机器级 `HKLM`）：

- `HKLM\Software\Classes\Applications\Notepad3.exe`：`FriendlyAppName`、`DefaultIcon`、`shell\open\command`；
  该键同时作为 ProgID（`Applications\Notepad3.exe`）被下面的能力声明引用。
- `HKLM\Software\Classes\Applications\Notepad3.exe\SupportedTypes`：所选扩展名各一个值。
- `HKLM\Software\Classes\.<ext>\OpenWithProgids`：值名 `Applications\Notepad3.exe`，类型 `REG_NONE`（Inno 里写作 `ValueType: none`）。
- `HKLM\Software\RegisteredApplications`：值 `Notepad3` = `Software\win-env\Notepad3\Capabilities`。
- `HKLM\Software\win-env\Notepad3\Capabilities`：`ApplicationName` / `ApplicationDescription` / `ApplicationIcon` + `FileAssociations\<ext>` → `Applications\Notepad3.exe`。

写入关联后调用 `SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, 0, 0)` 让"打开方式"菜单立即刷新（未勾选任何扩展名则跳过）。

### 3.2 为什么不能静默设默认

Windows 10 起，用户的默认程序由 `HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.<ext>\UserChoice` 决定，其 `ProgId` 值由一个与用户 SID、扩展名、ProgID、时间戳绑定的哈希保护；直接写入会被系统判定为篡改并重置。Windows 11 更在此之上有 **UCPD**（User Choice Protection Driver）拦截对 `UserChoice` 的写入。因此任何第三方安装器都无法可靠地"静默设默认"，本包**不做**这种尝试。

替代做法：安装完成后（且勾选了关联任务时）用 `[Run]` 打开系统设置页
`ms-settings:defaultapps?registeredAppMachine=Notepad3`，由用户点一次把 Notepad3 设为首选。该条目带 `runasoriginaluser`，因为提权进程直接起 `ms-settings:` 协议不可靠；同时带 `postinstall`，用户可在最后一页取消。

**卸载后关联悬空是系统机制**：卸载只删除本包写入的键；此前被用户选为默认的扩展名，其 `UserChoice` 仍指向已被删除的 `Applications\Notepad3.exe`，双击文件时系统会提示"选择打开方式"。安装器无法把默认程序"还原"成卸载前的状态（原默认程序从未被记录），这是 Windows 的设计，不是本安装器的缺陷。

## 4. 组件来源（官方渠道）与裁剪

| 组件 | 来源 | 取用内容 |
| --- | --- | --- |
| Notepad3 | <https://github.com/rizonesoft/Notepad3> Releases | 仅取 `Notepad3_<version>_x64_Portable.zip`（不使用官方 `*_Setup.exe`），zip 根即暂存树根 |
| 版本发现 | 官方 GitHub Releases API `/releases?per_page=30`（或 `/releases/tags/RELEASE_<version>`） | 过滤 `draft` / `prerelease`，tag 必须匹配 `^RELEASE_(\d+\.\d+\.\d+\.\d+)$`，且资产名中的版本必须与 tag 一致；CI 注入 `GITHUB_TOKEN` 规避未认证限额 |
| 完整性 | Release 资产的 `digest` 字段（`sha256:<hex>`） | **强制**校验下载文件；`digest` 为空或不合法即终止（旧版 Release 早于该字段，故不可用于旧版本） |
| 语言包 | 随 zip 的 `lng\` | 只保留 English（`en-GB`）与简体中文（`zh-CN`）；`lng\mplng.dll`、`lng\np3lng.dll` 是语言加载器（非单语言数据），始终保留 |
| 安装器 | [Inno Setup 6](https://jrsoftware.org/isinfo.php) | GitHub windows runner 预装；缺失时 workflow 用 Chocolatey 兜底安装 |

### 4.1 语言包裁剪

上游 `lng\` 有 25 个语言目录（约 12.46 MB，占解压树约 59%）与 2 个共享加载 DLL。`build.ps1` 用单一白名单 `$KeepLanguages = @('en-GB','zh-CN')` 删除其余目录，逐项打印字节数并汇总：

- 删除 23 个目录、12,015,632 字节（约 11.46 MB）；保留 `en-GB`（518,768 B）+ `zh-CN`（484,464 B）+ 2 个加载器（各 21,816 B）。
- 暂存树由 20.99 MB 降到 9.53 MB；安装包 4.37 MiB。
- 删除后断言：两个保留目录的 `mplng.dll.mui` / `np3lng.dll.mui` 均存在、`lng\` 下无其他语言目录，主程序 PE 版本可读。

语言文件名与目录命名一致（每语言目录内为 `mplng.dll.mui` + `np3lng.dll.mui`，无分离结构）。

### 4.2 许可证

Notepad3 / MiniPath 为 BSD-3-Clause，随包 `grepWin\` 为 GPL-3.0。`Docs\License.txt` 与 `grepWin\LICENSE.txt` 原样保留，构建脚本对二者做存在性断言。

## 5. 本地构建

前置：Windows + PowerShell 5+；编译安装包需要 Inno Setup 6（仅组装阶段可跳过）。本机执行策略禁止未签名脚本时，用 `powershell -NoProfile -ExecutionPolicy Bypass -File ...` 调起，不修改系统执行策略。

```powershell
# 完整构建（产物在 build\output）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\notepad3\build.ps1

# 只做下载、校验与组装（无需 Inno Setup，产物在 build\stage\notepad3）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\notepad3\build.ps1 -SkipCompile -Notepad3Version 7.26.602.1
```

构建脚本参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-Notepad3Version` | 空（自动发现） | 精确版本号，形如 `7.26.602.1` |
| `-BuildDir` | `<repo>\build` | 缓存/暂存/输出目录（notepad3 暂存树在 `build\stage\notepad3`，与其他环境隔离） |
| `-SkipCompile` | 关 | 只组装不编译 |

ISCC 查找顺序：`ISCC` 环境变量 → `C:\Program Files (x86)\Inno Setup 6` → `C:\Program Files\Inno Setup 6` → PATH。

输出：

- `build\output\notepad3-<version>-setup-x64.exe`
- `build\output\notepad3-<version>-setup-x64.exe.sha256.txt`
- `build\output\build-info.json`（版本、上游资产名与 digest、保留/删除的语言目录、裁剪字节数、暂存体积、大小、SHA-256）
- `build\output\release-notes.md`（Release 正文）

## 6. 设计约定

- **绝对不碰 `notepad.exe`**：不写 IFEO（`Image File Execution Options`）、不重命名/替换 `System32\notepad.exe`、不卸载 Win11 商店记事本、不改 `HKCR\.txt` 默认 ProgID 或 `txtfile`，连可选任务也不提供。原因：这类"劫持系统记事本"的做法属于对操作系统的侵入式改写，会在系统更新、签名校验、卸载残留等环节留下难以撤销的副作用，且与"注册为候选、由用户选择默认程序"的定位冲突。
- **不静默设默认**：`UserChoice` 哈希保护 + Win11 UCPD 决定了第三方无法可靠设默认（见 §3.2）；安装器只做"注册候选 + 跳转设置页"。
- **不硬编码版本**：运行时从官方 Releases API 解析；空结果即报错，不猜 URL。显式版本也走 `/releases/tags/RELEASE_<version>` 拿资产元数据，资产缺失即报错并列出可用资产名。
- **摘要强制校验**：只信 Release 的 `digest` 字段；不匹配即删除缓存文件并 throw。缺失 digest 直接拒绝构建。
- 暂存目录（`build/stage/notepad3`）根目录即安装后的 `C:\pf\Notepad3`；安装器只负责原样释放 + PATH 改写 + 快捷方式 + 关联注册。
- 下载缓存于 `build/cache`（按官方资产名命名），重复构建不重复下载；失败自动重试 3 次。
- 组装完成有强制冒烟测试（暂存树内**绝对路径**读取，不启动 GUI）：
  1. 布局哨兵：`Notepad3.exe`、`minipath.exe`、`Notepad3.ini`、`Docs\License.txt`、`grepWin\LICENSE.txt`、`Themes\*.ini`（至少一个）、中英两套语言文件与两个加载器；
  2. **静态 CRT 断言**：解析 `Notepad3.exe` / `minipath.exe` 的 PE 导入表，禁止 `vcruntime140`、`vcruntime140_1`、`msvcp140`、`ucrtbase` 以及 `api-ms-win-crt-*`（实测导入仅 `KERNEL32`/`USER32`/`GDI32`/`COMDLG32`/`ADVAPI32`/`SHELL32`/`ole32`/`OLEAUT32`/`IMM32`/`SHLWAPI`/`ntdll`/`COMCTL32` + 系统 API set `api-ms-win-core-path-l1-1-0.dll`）；
  3. **PE 版本断言**：`Notepad3.exe` 的 `FileVersion` 归一化后必须等于解析出的版本（`7.26.602.1`）。
  - 不用 `Notepad3.exe /?` 或 `/v` 做冒烟（会弹模态框或走打印），也不在 CI 中静默启动 GUI 再杀进程。
- 交付 ISCC 前清理暂存树内所有重解析点（见 [lessons.md §25](lessons.md)）。
- 本机安装闭环验证（未在 CI 执行）：静默安装到**非默认目录** → 用注册表 Machine PATH 拼出新进程环境验证裸命令 `Notepad3` → 确认开始菜单/桌面快捷方式 → 确认「打开方式」出现 Notepad3 → 静默卸载 → 确认文件、PATH 条目与自有注册键消失，且用户 `Notepad3.ini` 仍在。
