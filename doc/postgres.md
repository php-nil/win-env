# PostgreSQL Windows 一键安装包 · 打包文档

本文档是 PostgreSQL 打包链路的唯一权威说明。构建配置位于 [builders/postgres](../builders/postgres)：

| 文件 | 作用 |
| --- | --- |
| `build.ps1` | 构建脚本：版本发现 → 下载 → 解压拍平 → 裁剪与白名单断言 → app-local 运行库 → 生成管理脚本 → 冒烟测试 → 编译安装包 → 输出元数据与发布说明 |
| `setup.iss` | Inno Setup 6 安装器脚本 |
| `Languages/ChineseSimplified.isl` | 安装向导简体中文语言包（官方 Inno Setup 安装包不含此文件，必须随仓库携带） |
| `setup.ico` | 安装器图标（官方 Windows 二进制无内嵌图标资源，取自 postgresql.org 官方品牌图形 `elephant.png` 生成，含 16–256 px 共 6 帧） |

> **管理脚本（`pg-start` / `pg-stop` / `pg-restart` / `pg-status`）不是独立仓库文件**：它们是 `build.ps1` 在组装阶段生成的，写入暂存树的 `bin\`，因此"暂存目录即安装目录"的契约不破，安装器无需额外处理。修改脚本内容 = 修改 `build.ps1` 里的模板。

## 1. 产物规格

| 项 | 值 |
| --- | --- |
| 产物文件 | `postgres-<version>-setup-x64.exe`（约 27.5 MiB，LZMA2 固实压缩 + 128 MB 字典，2026-10 实测 18.6；裁剪前约 344 MB 的官方 zip 经裁剪后约 170 MB 暂存树压到该体积） |
| 附带文件 | `*.exe.sha256.txt`（校验值）、`build-info.json`（版本/来源元数据）、`release-notes.md`（Release 正文） |
| Release 标签 | `postgres-<version>`（如 `postgres-18.6`）；另有常青别名 `postgres-latest`（资产名固定 `postgres-setup-x64.exe`，README 下载链接指向它） |
| 规格 | EDB 官方 `postgresql-<version>-<rev>-windows-x64-binaries.zip` 解压树（拍平 `pgsql\` 根目录）· x64 · 命令行/扩展开发用途 |
| 默认安装目录 | `C:\pf\postgres-<major>`（安装向导中可修改，**只带主版本号后缀**：minor 升级替换同一实例、沿用同一 `data\`） |
| 安装后命令 | `psql`、`pg_ctl`、`initdb`、`pg_dump`、`pg_restore`、`createdb` 等（安装目录的 `bin` 强制加入系统 PATH）；管理脚本 `pg-start`、`pg-stop`、`pg-restart`、`pg-status` 同处 `bin` |
| 数据目录 | `<安装目录>\data`，**首次 `pg-start` 时由 initdb 创建**，安装期不创建 |
| 运行时依赖 | 无（app-local 内置 VC++ 运行库 7 个 DLL） |
| 权限 | 需要管理员（在 C 盘根目录创建文件夹并改写系统 PATH，安装器内置 UAC 提权） |
| 不包含 | pgAdmin 4、StackBuilder、`doc\src` SGML 源码文档（见 §4 裁剪）；**不注册 Windows 服务、不随包创建数据目录** |
| 卸载 | 控制面板 / 安装目录下 `unins000.exe`；删除安装文件与自身 PATH 条目，**`data\` 目录保留**（见 §3） |

## 2. 触发构建（GitHub Actions）

手动触发，构建成功后自动发布 Release：

1. 仓库 **Actions** 页签 → **Build PostgreSQL** → **Run workflow**；
2. 输入参数：

| 参数 | 说明 |
| --- | --- |
| `pg_version` | 精确版本 `<major>.<minor>`，如 `18.6`；留空则自动取官方 `versions.json` 中 supported 的最高主版本的最新 minor |
| `pg_major` | 自动发现限定主版本，如 `18`（**要求 ≥ 17**，见 §6）；留空 = 最高 supported 主版本。`pg_version` 显式指定时此项被忽略 |
| `draft_release` | 勾选后 Release 以草稿形式发布，不打公开标签 |

3. 构建完成后在 **Releases** 的 `postgres-<version>` 标签下载安装包；工作流同时上传同名 build artifact。该标签已有公开（非草稿）Release 时本次不重复发布、不覆盖既有资产。随后把本次安装包以固定资产名 `postgres-setup-x64.exe` 覆盖到常青别名 `postgres-latest`（勾选 `draft_release` 时不更新），README 的下载链接只指向它。

## 3. 安装包行为

- 安装器 exe 图标为 PostgreSQL 官方品牌图标（官方 Windows 二进制**均无内嵌图标资源**，ico 取自 postgresql.org 官方 `elephant.png` 生成，随仓库保存在 `builders/postgres/setup.ico`）。
- 双击安装，向导默认目录 `C:\pf\postgres-<major>`，可自行修改。
- 安装内容即官方 zip 解压并裁剪后的目录树（`bin\`、`lib\`、`share\`、`include\`、`doc\html` 等），安装器只做原样释放，不在安装期下载或拼装任何内容。
- PATH（**必加，无安装选项**）：安装目录下的 **`bin`**（唯一一条目）加入**系统** PATH，保证新开命令行中 `psql` / `pg_ctl` / `pg-start` 等直接可用。
  - 安装时幂等追加（不重复、不动无关条目、顺带去空条目），并广播 `WM_SETTINGCHANGE`；
  - 卸载时精确移除该条目，其余 PATH 内容保留；已打开的旧命令行窗口需重开才能感知变化。
- 安装器固定 `AppId`（`{{E4B7C1A9-2D58-4F31-8C6E-9A3F5B0D7E62}`），重复安装/升级替换同一安装实例；升级 minor（18.6 → 18.7）安装目录不变、`data\` 不受影响。
- **不注册 Windows 服务**：PostgreSQL 服务需要非管理员服务账号（`pg_ctl register -U <user>`），与"安装器不做系统级安装、无重启依赖"的仓库约定冲突，因此启动永远是显式的 `pg-start`。需要开机自启的用户可在文档指引下手动注册。
- **卸载保留 `data\`**：数据目录是运行期生成的用户数据，不在安装器的文件清单内，卸载不会删除；不需要时手动删除 `C:\pf\postgres-<major>\data`。
- 需要图形客户端（pgAdmin）时请另行安装官方 pgAdmin：它占官方 zip 压缩体积的约 81%，属独立桌面工具，不在本包范围内。

### 3.1 管理脚本

| 命令 | 行为 |
| --- | --- |
| `pg-start [--port 5432] [--listen 127.0.0.1] [--password postgres]` | 1) `data\PG_VERSION` 不存在 → 先 `initdb` 初始化（约 10–30 秒，脚本打印进度提示）；2) 已在运行（`pg_isready` 判定）→ 直接提示，不重复启动；3) `pg_ctl start -D ..\data -l ..\data\logs\server.log -w -t 60`；4) `pg_isready` 复核并打印端口、数据目录、日志与连接示例 |
| `pg-stop [-m fast\|smart\|immediate]` | `pg_ctl status` 判定未运行 → 提示"未启动"并正常退出（不报错）；否则 `pg_ctl stop -w` |
| `pg-restart` | 先 `pg-stop` 再 `pg-start`，端口 / 监听沿用 `data\win-env.env` 中记录的上次取值 |
| `pg-status` | 打印安装目录、数据目录、端口、日志路径，并输出 `pg_ctl status` / `pg_isready` 结果（未初始化返回码 3） |

要点：

- 路径全部基于 `%~dp0` 自定位（不依赖调用方工作目录），符合仓库 `.bat` 包装器约定。
- **只用 `pg_ctl.exe` / `initdb.exe`，绝不直接运行 `postgres.exe`**：PostgreSQL 源码 `src/backend/main/main.c` 的 `check_root()` 直接 FATAL 退出（`Execution of PostgreSQL by a user with administrative permissions is not permitted`），它调 `src/port/win32security.c` 的 `pgwin32_is_admin()`：令牌含 Administrators **或 PowerUsers** 即判为管理员。`pg_ctl` / `initdb` 会以**受限令牌**重新执行 postmaster，因此**管理员/提权终端下也能正常工作**（CI runner 的管理员令牌同理；副作用是 `%APPDATA%` 等路径按安装用户解析），无需 `schtasks /ru` 委派这类绕行方案。
- 首次启动的口令通过临时 `--pwfile`（`%TEMP%\pg-start-win-env.pw.tmp`）传给 `initdb`，成功后立即删除，不写入任何配置文件；默认 `postgres`，可用 `--password` 覆盖（批处理限制：口令请勿含 `& | < >` 等 shell 特殊字符）。
- **`initdb` 要求 `-D` 目标目录"不存在或为空"**：目录已存在但不为空时直接报 `initdb: 错误: 目录 "…\data" 已存在，但不为空`（exit 1）；受控实验确认**空目录 exit 0、含任意 1 个文件的目录 exit 1**。因此 `pg-start` 在初始化前只创建空的 `data\`（口令临时文件放 `%TEMP%`），`data\logs\` 等一切运行期文件都在 `initdb` 成功之后才创建。早期版本先 `mkdir data\logs` 并把口令文件写进 `data\`，导致首次 `pg-start` 卡死；构建期冒烟用独立 scratch 目录、直接调 `initdb.exe`，没走管理脚本这段逻辑，故只有真机安装后跑 `pg-start` 才暴露——**管理脚本自身的逻辑必须在安装后的真实路径上验证**，不能只靠组装期冒烟。
- 脚本按 UTF-8（无 BOM）+ `chcp 65001` 写入，中文提示在任意系统区域设置下都能正确显示（写入用 `[IO.File]::WriteAllText`，不用 `Out-File -Encoding utf8`）。

### 3.2 默认集群参数

```
initdb -D <app>\data -U postgres -E UTF8
        --locale-provider=builtin --builtin-locale=C.UTF-8
        --auth-host=scram-sha-256 --pwfile=<临时文件>
        -c listen_addresses=127.0.0.1 -c port=5432
        -c timezone=Asia/Shanghai -c log_timezone=Asia/Shanghai
```

- `builtin` + `C.UTF-8`：**避免中文 Windows 上 libc 默认 locale 派生出 GBK/CP936 类编码与不稳定排序**，UTF8 存储 + 确定性排序，跨机器 dump/restore 可复现。需要拼音排序时按库使用包内自带 ICU（`CREATE DATABASE ... LOCALE_PROVIDER icu ICU_LOCALE 'zh-CN'`）。官方 PG 16 文档只列 `libc` / `icu` 两个 provider 且**没有** `--builtin-locale`——`builtin` provider 与 `--builtin-locale` 参数是 **PG 17 引入**的，这一点也是主版本下限取 17 的依据（见 §6）。
- 超级用户 `postgres`、默认口令 `postgres`（scram-sha-256），仅监听回环地址 → 与仓库内其它包开箱互通（PHP 包默认启用 `pdo_pgsql`）：`postgres://postgres:postgres@127.0.0.1:5432/postgres`。
- `timezone` / `log_timezone` 对齐仓库既有约定（PHP 包 `date.timezone=Asia/Shanghai`）。
- 端口 5432 被占用时用 `pg-start --port 5433`；取值的持久化位置是 `data\win-env.env`。

## 4. 组件来源（官方渠道）与裁剪

| 环节 | 来源 | 说明 |
| --- | --- | --- |
| 版本发现 | <https://www.postgresql.org/versions.json> | 机器可读 JSON：取 `supported=true` 的最高 major（或 `pg_major` 指定）与其 `latestMinor` |
| 二进制 | `https://get.enterprisedb.com/postgresql/postgresql-<ver>-<rev>-windows-x64-binaries.zip` | 官方下载页指向 EDB 提供的 Windows 二进制；zip 顶层唯一 `pgsql\` 根目录 |
| EDB 下载页 | <https://www.enterprisedb.com/download-postgresql-binaries> | **不可机器解析**（只有 `getfile.jsp?fileid=…` 不透明链接），因此绝不作为发现入口 |
| VC++ 运行库 | `https://aka.ms/vs/17/release/vc_redist.x64.exe` + WiX 3.14 `dark.exe` | 见 §5；EDB zip 内**不含** CRT DLL |
| 安装器 | [Inno Setup 6](https://jrsoftware.org/isinfo.php) | GitHub windows runner 预装；缺失时 workflow 用 Chocolatey 兜底安装 |

裁剪（`build.ps1` 内单一清单维护，删后强断言关键文件仍在）：

| 处理 | 内容 | 依据 |
| --- | --- | --- |
| 删除 | `pgAdmin 4\` 整棵 | 占官方 zip 压缩体积约 274 MB（整包 ~81%），独立桌面工具 |
| 删除 | `StackBuilder\`、`bin\stackbuilder.exe`、`bin\wx*_vc_x64_custom.dll` | EDB GUI 安装器组件，命令行环境不需要；wx* DLL 是其唯一消费者 |
| 删除 | `doc\src\`（SGML 源码，含 12.8 MB `postgres-full.xml`） | 离线 HTML 文档保留在 `doc\html` |
| 删除 | `bin\test_cloexec.exe`、`bin\testplug.dll` | 上游自测二进制 |
| 保留 | `bin\`、`lib\`、`share\`（含时区数据）、`include\` | 开发环境需要客户端工具与扩展编译能力 |

## 5. 本地构建

前置：Windows + PowerShell 5+；编译安装包需要 Inno Setup 6（仅组装阶段可跳过）。本机执行策略禁止未签名脚本时，用 `powershell -NoProfile -ExecutionPolicy Bypass -File ...` 调起，不修改系统执行策略。

```powershell
# 完整构建（自动发现最高 supported 主版本，产物在 build\output）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\postgres\build.ps1

# 只做下载与组装（含 initdb/pg_ctl/psql 冒烟），不编译安装包
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\postgres\build.ps1 -SkipCompile

# 指定版本 / 限定主版本
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\postgres\build.ps1 -PgVersion 18.6
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\postgres\build.ps1 -PgMajor 18
```

构建脚本参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-PgVersion` | 空（自动发现） | 精确版本 `<major>.<minor>`，如 `18.6` |
| `-PgMajor` | 空（最高 supported 主版本） | 自动发现限定主版本，如 `18`（要求 ≥ 17） |
| `-BuildDir` | `<repo>\build` | 缓存/暂存/输出目录（postgres 暂存树在 `build\stage\postgres`，与其他环境隔离） |
| `-SkipCompile` | 关 | 只组装不编译 |

ISCC 查找顺序：`ISCC` 环境变量 → `C:\Program Files (x86)\Inno Setup 6` → `C:\Program Files\Inno Setup 6` → PATH。

输出：

- `build\output\postgres-<ver>-setup-x64.exe`
- `build\output\postgres-<ver>-setup-x64.exe.sha256.txt`
- `build\output\build-info.json`（版本、EDB rev、来源 URL、CRT 版本、裁剪清单、大小、SHA-256）
- `build\output\release-notes.md`（Release 正文）

## 6. 设计约定

- **不硬编码补丁版本号**：运行时从官方 `versions.json` 解析 supported 的最高主版本与 latestMinor；解析为空立即终止报错，不猜测 URL。该文件的 `major` 在 10 及以上是**裸主版本号**（`"14"`、`"18"`），10 以下才是点分形式（`"6.3"`、`"7.4"`），`latestMinor` 同样可能是裸 minor（`"6"`）——直接 `[version]$_.major` 会抛 `Cannot convert value "14" to type "System.Version"`（`System.Version` 至少要求 `major.minor` 两段）。`build.ps1` 用 `ConvertTo-MajorVersion` 补齐第二段（不足两段补 `.0`）后再 `[version]`；凡"裸数字主版本号"都按此处理。
- **EDB 与 versions.json 的时差**：`versions.json` 由 PostgreSQL 项目维护，EDB 二进制略有滞后。发现流程为：该 minor 按 `rev` 1→3 做 HEAD 探测（EDB 用 rev 表示同版本的重新构建）；该 minor 全部 404 时 **minor 递减**重试（最多 3 个 minor），全部失败即 `throw`，绝不猜 URL。URL 形态稳定可构造，实测 14.24-1 / 15.19-1 / 16.15-1 / 17.11-1 / 18.6-1 全部 200、约 344 MB；官方 zip 顶层唯一 `pgsql\` 根目录（21,968 条目，raw 913.6 MB / 压缩 339.0 MB），其中 `pgAdmin 4\` 一项就占压缩体积 274.5 MB（约 81%）。EDB 的下载页（`enterprisedb.com/download-postgresql-binaries` 及 `/downloads/...`）只有 `getfile.jsp?fileid=…` 不透明链接、没有可解析直链，因此只作人工下载入口，绝不作为发现入口。
- **主版本下限 17**：确定性 UTF-8 排序依赖 PG 17 引入的 `builtin` locale provider（PG 16 及更早只有 libc/icu）。低于 17 时在下载前即报错终止，避免产出"行为随宿主 locale 变化"的包；组装期还会用 `initdb --help` 复核 `--builtin-locale` 确实存在。
- 暂存目录（`build/stage/postgres`）根目录即安装后的 `C:\pf\postgres-<major>`，安装器只负责原样释放与 PATH 改写。官方 zip 内含单层 `pgsql\` 根目录，构建时拍平。
- 下载缓存于 `build/cache`（按官方资产名命名，340 MB 的 zip 不会重复下载）；`vc_redist.x64.exe` 例外，每次重取（aka.ms 始终指向最新 14.x，缓存会静默钉住旧运行库）。
- 组装完成后对真实解压树做**白名单断言**：关键文件（`bin\{postgres,initdb,pg_ctl,psql,pg_dump,pg_restore,pg_isready,pg_config,createdb}.exe`、`bin\libpq.dll`、`share\{postgresql.conf.sample,pg_hba.conf.sample}`、`share\timezone\Asia\Shanghai`、`include\server\postgres.h`）缺一即失败，避免上游布局变化导致"删多了"；ICU 库名带 ICU 主版本号（PG 18 为 `icuuc77`）故按 `icuuc*` / `icudt*` / `icuin*` 通配断言。EDB 的头文件是**扁平布局**：真实解压树为 `include\server\postgres.h`、`include\internal\`、`include\libpq\`，`include\` 下**没有** `postgresql\` 这一层（`pg_config --includedir-server` 也指向扁平目录）；Unix `make install` 才是 `$INCLUDEDIR/postgresql/...`。断言路径一律以真实解压树为准，哨兵文件用 `include\server\postgres.h`（照搬 Unix 布局会得到 `Required file missing after trimming`）。
- 暂存树交给 ISCC 前断言**不含重解析点**（链接会让 `[Files]` 扫描绕环，报无行号的"系统找不到指定的路径"，见 [doc/lessons.md](lessons.md) §14）。
- app-local 运行库：EDB zip 内没有 CRT DLL，构建期从官方 `vc_redist.x64.exe`（WiX `dark.exe` 解 Burn 包 + `msiexec /a` 解 MSI）提取 7 个 DLL 释放到 `bin\`，并断言版本为 `14.x`。构建机预装运行库会掩盖缺库问题，因此**必须靠文件存在性 + 版本断言**兜底。
- 冒烟测试（强制门槛，失败即 `throw`，不产出坏包）：在 `build/cache/pgsmoke` 上用**非默认端口 55432** 跑完整闭环 `initdb` → `pg_ctl start -w` → `psql -U postgres -tAc "select version()"`（输出须含 `PostgreSQL <version>`）→ `pg_isready` → `pg_ctl stop -m fast -w`，并在 `finally` 中无条件回收（残留 postmaster 会锁住数据目录，导致后续构建清理失败）。
- 管理脚本生成后立即做**编码断言**：不得带 BOM，且按 UTF-8 解码后必须能读回中文横幅（防止写出乱码脚本）。
- 安装闭环验证（每次改动安装器必做，见 [AGENTS.md](../AGENTS.md) §3.6）：静默安装到**非默认目录** → 用注册表 Machine+User PATH 拼出新进程环境，以裸命令验证 `psql` / `pg-start` / `pg-stop` / `pg-status` 与 `select version()` → 静默卸载 → 确认文件与 PATH 条目都消失、`data\` 保留。本次交付**未在本机复跑该闭环**（属破坏性操作、本机未获授权），需由 CI 或人工验收；`initdb` 空目录这类只在安装后路径才暴露的坑见 §3.1 要点第 4 条。
