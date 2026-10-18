# Python Windows 一键安装包 · 打包文档

本文档是 Python 打包链路的唯一权威说明。构建配置位于 [builders/python](../builders/python)：

| 文件 | 作用 |
| --- | --- |
| `build.ps1` | 构建脚本：版本发现 → 下载校验 → 组装暂存目录 → 生成 `pip.cmd` → 冒烟测试 → 编译安装包 → 输出元数据与发布说明 |
| `setup.iss` | Inno Setup 6 安装器脚本 |
| `Languages/ChineseSimplified.isl` | 安装向导简体中文语言包（官方 Inno Setup 安装包不含此文件，必须随仓库携带） |
| `setup.ico` | 安装器图标（从官方 `python.exe` 图标资源组提取，16–256 px，8bpp/32bpp 成对共 12 帧） |

## 1. 产物规格

| 项 | 值 |
| --- | --- |
| 产物文件 | `python-<version>-setup-x64.exe`（约 17.8 MiB，LZMA2 固实压缩 + 128 MB 字典，2026-10 实测 3.15.0） |
| 附带文件 | `*.exe.sha256.txt`（校验值）、`build-info.json`（版本/来源元数据）、`release-notes.md`（Release 正文） |
| Release 标签 | `python-<version>` |
| 规格 | 官方 `python-<version>-amd64.zip`（install manager 的 **pythoncore 可重定位**布局）· x64 · GIL（非 free-threaded） |
| 默认安装目录 | `C:\pf\python-<major.minor>`（如 `C:\pf\python-3.15`，安装向导中可修改） |
| 安装后命令 | `python`、`pythonw`、`pip`（安装目录强制加入系统 PATH，新开命令行即可用；`pip` 由构建期生成的 `pip.cmd` 提供） |
| 内置内容 | `pip`、`venv`、`tkinter`（Tcl/Tk）、`include\` + `libs\`（C 扩展构建头文件与导入库） |
| 裁剪项 | 官方 `Doc\`（离线 HTML 文档，约 79 MB，默认裁剪，`-KeepDoc` 可保留） |
| 运行时依赖 | 无（官方 zip 自带 app-local `vcruntime140.dll` / `vcruntime140_1.dll`） |
| 权限 | 需要管理员（在 C 盘根目录创建文件夹并改写系统 PATH，安装器内置 UAC 提权） |
| 卸载 | 控制面板 / 安装目录下 `unins000.exe`，完整卸载（系统 PATH 条目精确回收） |

体积链路（2026-10 实测 3.15.0）：官方 zip 45.1 MB → 解压 136.3 MB → 裁 `Doc\` 后暂存 57.6 MB（1950 个文件）→ 安装包 17.8 MiB。

## 2. 触发构建（GitHub Actions）

手动触发，构建成功后自动发布 Release：

1. 仓库 **Actions** 页签 → **Build Python** → **Run workflow**；
2. 输入参数：

| 参数 | 说明 |
| --- | --- |
| `python_version` | 精确版本号，如 `3.15.0`；留空则自动取官方 install-manager 索引中最新的正式版（仅 64 位 GIL 线） |
| `major_track` | 自动发现限定轨道（major.minor），如 `3.14`；留空 = 任意轨道取最新。`python_version` 显式指定时此项被忽略 |
| `draft_release` | 勾选后 Release 以草稿形式发布，不打公开标签 |

3. 构建完成后在 **Releases** 的 `python-<version>` 标签下载安装包；工作流同时上传同名 build artifact。同名标签重跑会就地更新该 Release。

## 3. 安装包行为

- 安装器 exe 图标为 Python 官方图标（提取自官方 `python.exe` 的图标资源组，16/24/32/48/64/256 px 各含 8bpp 与 32bpp 两帧，共 12 帧，随仓库保存在 `builders/python/setup.ico`）。
- 双击安装，向导默认目录 `C:\pf\python-<major.minor>`（如 `C:\pf\python-3.15`），可自行修改。
- 安装内容即官方 `python-<version>-amd64.zip` 解压后的目录树（`python.exe`、`pythonw.exe`、`DLLs\`、`Lib\`、`include\`、`libs\` 等，已裁剪 `Doc\`）加上构建期生成的 `pip.cmd`，安装器只做原样释放，不在安装期下载或拼装任何内容。
- PATH（**必加，无安装选项**）：安装根目录加入**系统** PATH —— `python.exe`、`pythonw.exe` 与生成的 `pip.cmd` 都落在根目录（官方 zip **没有** `Scripts\` 目录）。
  - 安装时幂等追加（不重复、不动无关条目、顺带去空条目），并广播 `WM_SETTINGCHANGE`；
  - 卸载时精确移除该条目，其余 PATH 内容保留；已打开的旧命令行窗口需重开才能感知变化。
- 安装器固定 `AppId`（`{{B3F6D8E5-2A94-4C71-8E5B-7D1A9F3C6B20}}`），重复安装/升级替换同一安装实例。
  - 同轨道小版本升级（`3.15.0` → `3.15.1`）默认目录不变，就地替换；
  - **跨轨道安装**（如已装 3.15 再装 3.14）时 Inno 会沿用检测到的既有安装目录（`C:\pf\python-3.15`），需要并存必须在向导中手动改目录 —— 推荐做法是装不同轨道时指定不同目录，或先卸载旧版。
- **`pip install` 的写入位置**：不加 `-g`-风格前缀时默认装进当前解释器所在安装目录的 `Lib\site-packages`（即 `C:\pf\python-<track>`），因此需要管理员终端；日常开发推荐 `python -m venv .venv` 建虚拟环境后安装依赖（无需管理员，且与安装目录解耦）。
- **不含 `py` 启动器**：官方 Windows 安装器与 Microsoft Store 版才有 `py.exe`；本包只提供 `python.exe`/`pythonw.exe`。多版本并存时按系统 PATH 顺序命中先出现者。
- 不写 Python 注册表运行时（`HKLM\SOFTWARE\Python`）、不注册 `.py` 文件关联，卸载无残留。

## 4. 组件来源（官方渠道）

| 组件 | 来源 | 取用内容 |
| --- | --- | --- |
| CPython | <https://www.python.org/ftp/python/> | `python-<version>-amd64.zip` 整包解压为暂存树（**无包装目录**，解压结果即暂存根） |
| 版本发现 | install-manager 索引 <https://www.python.org/ftp/python/index-windows.json> | `versions` 数组里 `company = PythonCore`、`id` 形如 `pythoncore-<major.minor>-64`（排除 free-threaded 的 `t` 线与 `pythonembed`/`pythontest` 条目）、`sort-version` 为纯 `x.y.z` 正式版的条目取最大；显式版本按 `sort-version` 精确匹配 |
| 完整性校验 | 同索引的 `hash.sha256` | 下载后逐字节比对官方 SHA-256，不一致立即终止（缓存命中时同样校验） |
| pip | 官方 zip 内置 | `Lib\site-packages\pip` + `ensurepip` 随包提供，**无需联网引导**（不走 `get-pip.py`） |
| Tcl/Tk | 官方 zip 内置 | `tkinter` 可用（`DLLs\_tkinter.pyd` + `tcl`/`tk` 运行库） |
| VC++ 运行库 | 官方 zip 内置 app-local | `vcruntime140.dll` / `vcruntime140_1.dll` 就在暂存根目录，目标机器无需预装系统级运行库（**不需要** php/postgres 的 `dark.exe` + `msiexec /a` 提取链路） |
| 安装器 | [Inno Setup 6](https://jrsoftware.org/isinfo.php) | GitHub windows runner 预装；缺失时 workflow 用 Chocolatey 兜底安装 |

## 5. 本地构建

前置：Windows + PowerShell 5+；编译安装包需要 Inno Setup 6（仅组装阶段可跳过）。本机执行策略禁止未签名脚本时，用 `powershell -NoProfile -ExecutionPolicy Bypass -File ...` 调起，不修改系统执行策略。

```powershell
# 完整构建（自动发现最新正式版，产物在 build\output）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\python\build.ps1

# 只做下载与组装，不编译安装包（无需 Inno Setup，产物在 build\stage\python）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\python\build.ps1 -SkipCompile

# 指定版本 / 限定轨道 / 保留官方离线文档
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\python\build.ps1 -PythonVersion 3.15.0
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\python\build.ps1 -MajorTrack 3.14
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\python\build.ps1 -KeepDoc
```

构建脚本参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-PythonVersion` | 空（自动发现） | 精确版本号，如 `3.15.0`（必须是官方索引里的正式版） |
| `-MajorTrack` | 空（任意轨道） | 自动发现限定轨道，如 `3.14` |
| `-BuildDir` | `<repo>\build` | 缓存/暂存/输出目录（python 暂存树在 `build\stage\python`，与其他环境隔离） |
| `-KeepDoc` | 关（裁剪） | 保留官方 `Doc\` 离线 HTML 文档（约 79 MB），默认裁剪 |
| `-SkipCompile` | 关 | 只组装不编译 |

ISCC 查找顺序：`ISCC` 环境变量 → `C:\Program Files (x86)\Inno Setup 6` → `C:\Program Files\Inno Setup 6` → PATH。

输出：

- `build\output\python-<ver>-setup-x64.exe`
- `build\output\python-<ver>-setup-x64.exe.sha256.txt`
- `build\output\build-info.json`（版本、发布名、轨道、下载 URL、官方 SHA-256、裁剪标记、默认目录、大小、SHA-256）
- `build\output\release-notes.md`（Release 正文）

## 6. 设计约定

- **不硬编码补丁版本号**：运行时从官方 install-manager 索引解析最新正式版；解析为空立即终止报错，不猜测 URL。索引里的下载 URL 与 `hash.sha256` 是唯一权威来源，下载前先校验"渠道是 `www.python.org/ftp/python/`"与"资产名等于 `python-<ver>-amd64.zip`"。版本发现走 python.org（非 GitHub API），无速率限额问题。
- **索引文档是对象不是数组**：`index-windows.json` 的顶层是 `{ "next": ..., "versions": [...] }`，条目在 `.versions`；把它当数组读会静默只得到 1 项、所有过滤落空（见 [经验教训 §27](lessons.md)）。
- 暂存目录（`build/stage/python`）根目录即安装后的 `C:\pf\python-<track>`，安装器只负责原样释放与 PATH 改写。与 Node.js/PostgreSQL 的资产不同，本 zip **没有单层包装目录**，解压结果直接就是暂存根，不做拍平；同时断言 `python._pth` 不存在，防止把 embeddable 发行版误当 pythoncore 组装。
- **裁剪 `Doc\`（默认）**：官方 zip 的 `Doc\html` 约 78.7 MB，是解压树里唯一的大单项（占 ~58%），且对 CLI/构建/venv 场景无用；裁剪后暂存树 57.6 MB。需要离线文档时用 `-KeepDoc` 重新构建（安装包会明显变大）。裁剪/保留结果都有断言兜底。
- 下载缓存于 `build/cache`（按官方资产名命名），重复构建不重复下载；下载失败自动重试 3 次；**缓存命中也会重新校验 SHA-256**，避免复用被改坏的缓存。
- 交付给 ISCC 前清理暂存树里的重解析点并复查为 0（见 [经验教训 §14](lessons.md)）。
- **`pip.cmd` 由构建期生成**：官方 zip 没有 `Scripts\`，裸 `pip` 命令不存在；包装器内容为 `"%~dp0python.exe" -m pip %*`，UTF-8 **无 BOM** + CRLF（见 [经验教训 §1.2](lessons.md)），并断言内容与编码，避免依赖调用方工作目录。
- 组装完成有强制冒烟测试（任一失败即 throw，不产出坏包）：
  - `python.exe -V` 输出必须与版本号逐字一致（`Python <version>`）；
  - `sys.prefix` 必须等于暂存目录（证明可重定位布局成立，安装到 `C:\pf\python-<track>` 后仍自洽）；
  - `tkinter` 必须能真实初始化 Tcl 并返回版本号（证明 `DLLs\_tkinter.pyd` 与 Tcl/Tk 运行库可用）；
  - 内置 `pip` 必须可用（`python -m pip -V`），且生成的 `pip.cmd` 包装器同样可执行；
  - `python -m venv` 建出的虚拟环境解释器必须能报告同一版本（覆盖 venv/ensurepip 链路）；
  - 布局断言：`python.exe`、`pythonw.exe`、`python3.dll`、`vcruntime140*.dll`、`DLLs\_tkinter.pyd`、`DLLs\_ssl.pyd`、`Lib\tkinter\__init__.py`、`Lib\site-packages\pip\__init__.py`、`include\Python.h`、`libs\python3.lib`、`build-details.json`。
- 向暂存 python 传 `-c` 载荷时，载荷内部只用**单引号**：PS 5.1 会剥掉内嵌双引号（见 [经验教训 §28](lessons.md)）。
- 被否路线：embeddable 发行版（`python-<ver>-embed-amd64.zip`，约 13.7 MB，stdlib 压成 `python<ver>.zip`、自带 `python._pth`、**无 pip/venv/tkinter/`include`/`libs`**）与"官方 installer exe `/layout` + `msiexec /a` 提取"都不采用 —— 前者缺开发必备组件，后者对同一份 pythoncore 载荷纯属多余步骤。
- 本机安装闭环验证：静默安装到**非默认目录** → 用注册表 Machine+User PATH 拼出新进程环境验证裸命令 `python` / `pip` → 静默卸载 → 确认文件与 PATH 条目都消失（CI 或人工验收）。
