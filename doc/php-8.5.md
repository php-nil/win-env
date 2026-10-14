# PHP 8.5 Windows 一键安装包 · 打包文档

本文档是 PHP 8.5 打包链路的唯一权威说明。构建配置位于 [builders/php](../builders/php)：

| 文件 | 作用 |
| --- | --- |
| `build.ps1` | 构建脚本：版本发现 → 下载 → 组装暂存目录 → 生成 php.ini → 编译安装包 → 输出元数据与发布说明 |
| `setup.iss` | Inno Setup 6 安装器脚本 |
| `Languages/ChineseSimplified.isl` | 安装向导简体中文语言包（官方 Inno Setup 安装包不含此文件，必须随仓库携带） |

## 1. 产物规格

| 项 | 值 |
| --- | --- |
| 产物文件 | `php-<version>-setup-x64.exe`（约 24 MB，LZMA2 固实压缩 + 128 MB 字典，2026-10 实测） |
| 附带文件 | `*.exe.sha256.txt`（校验值）、`build-info.json`（组件版本/来源元数据） |
| Release 标签 | `php-<version>` |
| PHP 规格 | 8.5.x · NTS（非线程安全）· VS17 · x64 |
| 默认安装目录 | `C:\pf\php-8.5`（安装向导中可修改） |
| 安装后命令 | `php`、`nil`（安装目录强制加入系统 PATH，新开命令行即可用） |
| 权限 | 需要管理员（在 C 盘根目录创建文件夹并改写系统 PATH，安装器内置 UAC 提权） |
| 卸载 | 控制面板 / 安装目录下 `unins000.exe`，完整卸载 |

## 2. 触发构建（GitHub Actions）

手动触发，构建成功后自动发布 Release：

1. 仓库 **Actions** 页签 → **Build PHP 8.5 (Windows)** → **Run workflow**；
2. 输入参数：

| 参数 | 说明 |
| --- | --- |
| `php_version` | 留空自动选取 windows.php.net 最新发布的 8.5.x；也可手动指定，如 `8.5.11` |
| `xdebug_version` | 留空自动从新到旧遍历 PECL 目录，选取第一个提供 PHP 8.5 / NTS / VS17 / x64 构建的版本；也可手动指定，如 `3.5.3` |
| `nilpack_version` | 内置 `nil` 命令所用 [php-nil/nilpack](https://github.com/php-nil/nilpack) 的 release tag（不带 `v`），默认 `0.2` |
| `draft_release` | 勾选后 Release 以草稿形式发布，不打公开标签 |

3. 构建完成后在 **Releases** 的 `php-<version>` 标签下载安装包；工作流同时上传同名 build artifact。

## 3. 安装包行为

- 双击安装，向导默认目录 `C:\pf\php-8.5`，可自行修改。
- 配置文件 `php.ini` 由构建脚本基于官方 `php.ini-development` 生成（不是直接使用原文件）：
  - `extension_dir = "ext"`；
  - 默认开启扩展：curl、fileinfo、exif、gd、intl、mbstring、openssl、**pdo_pgsql**、pdo_sqlite、sodium、sockets、sqlite3、zip；
  - 默认不启用 MySQL 相关扩展（mysqli、pdo_mysql 在 php.ini 中被显式注释；需要时取消注释即可，DLL 仍在包内）；
  - `curl.cainfo` / `openssl.cafile` 指向包内 `cacert.pem`；
  - Xdebug 以 `zend_extension=xdebug` 方式从 `ext` 加载，`xdebug.mode=develop,debug,coverage`，监听 `127.0.0.1:9003`。
- `cacert.pem` 路径改写机制：构建时 php.ini 中写入占位符 `__APP_DIR__/cacert.pem`，安装器在文件释放后（`CurStepChanged = ssPostInstall`）将占位符替换为实际安装目录，因此修改安装目录后路径依然正确。
- PATH（**必加，无安装选项**）：安装目录加入**系统** PATH，保证新开命令行中 `php`、`nil` 可直接使用。
  - 安装时幂等追加（不重复、不动无关条目），并广播 `WM_SETTINGCHANGE`；
  - 卸载时精确移除该条目，其余 PATH 内容保留；已打开的旧命令行窗口需重开才能感知变化。
- `nil` 命令：安装根目录下的 `nil.bat` 包装器以同目录 `php.exe` 运行 `nilpack.phar`（通过 `%~dp0` 定位，与调用方工作目录无关）。常用命令：`nil --version`、`nil list`、`nil phar`（目录打包为 Phar）、`nil composer`（composer 包打包为 Phar）。
- 安装器固定 `AppId`，重复安装/升级会替换同一安装实例。

## 4. 组件来源（均为官方渠道）

| 组件 | 来源 | 取用内容 |
| --- | --- | --- |
| PHP | <https://windows.php.net/downloads/releases/> | `php-<ver>-nts-Win32-vs17-x64.zip` 整包解压为暂存树 |
| Xdebug | <https://windows.php.net/downloads/pecl/releases/xdebug/> | `php_xdebug-<ver>-8.5-nts-vs17-x64.zip` 中的 `php_xdebug.dll`，放入 `ext\` |
| nilpack | <https://github.com/php-nil/nilpack/releases>（v0.2） | `nilpack.phar` 放入安装根目录，配 `nil.bat` 包装器提供 `nil` 命令 |
| CA 证书 | <https://curl.se/ca/cacert.pem> | 原样放入安装根目录 `cacert.pem` |
| 安装器 | [Inno Setup 6](https://jrsoftware.org/isinfo.php) | GitHub windows runner 预装；缺失时 workflow 用 Chocolatey 兜底安装 |

`pdo_pgsql` 的运行依赖 `libpq.dll` 已包含在 PHP 官方 Windows 包根目录，无需额外获取。

## 5. 本地构建

前置：Windows + PowerShell 5+；编译安装包需要 Inno Setup 6（仅组装阶段可跳过）。

```powershell
# 完整构建（自动发现最新版本，产物在 build\output）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\php\build.ps1

# 只做下载与组装，不编译安装包（无需 Inno Setup，产物在 build\stage\php）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\php\build.ps1 -SkipCompile

# 指定版本
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\php\build.ps1 -PhpVersion 8.5.11 -XdebugVersion 3.5.3
```

构建脚本参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-PhpVersion` | 空（自动发现） | 指定 8.5 补丁版本 |
| `-XdebugVersion` | 空（自动发现） | 指定 Xdebug 版本 |
| `-NilpackVersion` | `0.2` | nilpack release tag（不带 `v`），决定内置 `nil` 命令版本 |
| `-BuildDir` | `<repo>\build` | 缓存/暂存/输出目录 |
| `-SkipCompile` | 关 | 只组装不编译 |

ISCC 查找顺序：`ISCC` 环境变量 → `C:\Program Files (x86)\Inno Setup 6` → `C:\Program Files\Inno Setup 6` → PATH。

输出：

- `build\output\php-<ver>-setup-x64.exe`
- `build\output\php-<ver>-setup-x64.exe.sha256.txt`
- `build\output\build-info.json`（版本、下载 URL、大小、SHA-256）
- `build\output\release-notes.md`（Release 正文）

## 6. 设计约定

- **不硬编码补丁版本号**：运行时解析官方目录列表；解析为空立即终止并报错，不猜测 URL。
- 暂存目录（`build/stage/php`，与其他环境的暂存树隔离）根目录即安装后的 `C:\pf\php-8.5`，安装器只负责原样释放与少量配置改写（占位符替换、PATH）。
- 下载缓存于 `build/cache`，重复构建不重复下载；下载失败自动重试 3 次。
- 组装完成有强制冒烟测试：暂存 `php.exe -v` 必须看到 PHP 8.5 与 Xdebug，`php.exe nilpack.phar --version` 必须输出 `Nil Pack Tool`，任一失败即终止，绝不发布坏包。
- php.ini 扩展处理有三道保险：注释行按需取消注释、`$DisabledExtensions` 强制禁用清单（防止上游把 mysqli/pdo_mysql 改为默认开启）、重复生效行自动注释去重。
- 新增环境（Nginx、Node.js 等）在 `builders/<name>/` 下平行增加构建脚本，并新建对应 workflow；本文档同级新增 `doc/<name>.md`。
