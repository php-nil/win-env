# win-env

Windows 常用开发环境的一键安装包：下载 `.exe` 双击安装即可使用，无需自行配置环境。

## 打包清单

| 环境 | 版本/规格 | 下载地址 | 使用说明 |
| --- | --- | --- | --- |
| PHP | 8.5.x · NTS · VS17 · x64 | [GitHub](https://github.com/php-nil/win-env/releases/download/php-latest/php-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/php-latest/php-setup-x64.exe) | [文档](doc/php-8.5.md) |
| pnpm | 12.x · standalone · x64 | [GitHub](https://github.com/php-nil/win-env/releases/download/pnpm-latest/pnpm-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/pnpm-latest/pnpm-setup-x64.exe) | [文档](doc/pnpm.md) |
| Git | v2.x.windows.y · x64 | [GitHub](https://github.com/php-nil/win-env/releases/download/git-latest/git-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/git-latest/git-setup-x64.exe) | [文档](doc/git.md) |
| PowerShell 7 | 7.6.x · x64 | [GitHub](https://github.com/php-nil/win-env/releases/download/pwsh-latest/pwsh-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/pwsh-latest/pwsh-setup-x64.exe) | [文档](doc/pwsh.md) |
| Node.js | 24.x LTS · x64 · 内置 npm | [GitHub](https://github.com/php-nil/win-env/releases/download/node-latest/node-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/node-latest/node-setup-x64.exe) | [文档](doc/node.md) |
| Rust (MSVC) | 1.99.x · x64 · x86_64-pc-windows-msvc | [GitHub](https://github.com/php-nil/win-env/releases/download/rust-latest/rust-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/rust-latest/rust-setup-x64.exe) | [文档](doc/rust.md) |
| PostgreSQL | 18.x · x64 · 命令行为主（含 `pg-start`/`pg-stop` 管理脚本） | [GitHub](https://github.com/php-nil/win-env/releases/download/postgres-latest/postgres-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/postgres-latest/postgres-setup-x64.exe) | [文档](doc/postgres.md) |
| Chromium (ungoogled) | 155.x · x64 · 便携版 · 含桌面快捷方式 | [GitHub](https://github.com/php-nil/win-env/releases/download/chromium-latest/chromium-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/chromium-latest/chromium-setup-x64.exe) | [文档](doc/chromium.md) |
| Python | 3.15.x · x64 · 内置 pip/venv/tkinter | [GitHub](https://github.com/php-nil/win-env/releases/download/python-latest/python-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/python-latest/python-setup-x64.exe) | [文档](doc/python.md) |
| Notepad3 | 7.26.x · x64 · 便携文本编辑器 · 仅含中英语言包 | [GitHub](https://github.com/php-nil/win-env/releases/download/notepad3-latest/notepad3-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/notepad3-latest/notepad3-setup-x64.exe) | [文档](doc/notepad3.md) |

> 下载地址为各环境的**常青别名**（tag `<env>-latest`，资产名固定 `<env>-setup-x64.exe`）：每次打包原地覆盖，链接不随版本号失效，始终指向该环境最新一次成功打包。带版本号的历史发布见 [Releases](https://github.com/php-nil/win-env/releases)。

## 自动打包周期

每个环境每周自动打包一次，时间错开。上游发布新版本后，会在下一次周期内自动跟进，无需手动操作。

| 环境 | 周期 | 执行时间（北京时间） |
| --- | --- | --- |
| PHP | 每周一次 | 周一 02:00 |
| pnpm | 每周一次 | 周一 14:00 |
| Git | 每周一次 | 周二 02:00 |
| PowerShell 7 | 每周一次 | 周三 02:00 |
| Node.js | 每周一次 | 周四 02:00 |
| Rust | 每周一次 | 周五 02:00 |
| PostgreSQL | 每周一次 | 周六 02:00 |
| Chromium | 每周一次 | 周六 14:00 |
| Python | 每周一次 | 周日 02:00 |
| Notepad3 | 每周一次 | 周日 14:00 |

## 安装

1. 在上方清单点 **GitHub**（或网络不畅时点 **代理**）下载对应环境的 `*-setup-x64.exe`。
2. 双击安装，按向导完成即可。默认装到 `C:\pf\<env>`（PHP、PostgreSQL 带版本后缀，如 `C:\pf\php-8.5`、`C:\pf\postgres-18`），可在向导中改目录。
3. 安装需要管理员权限；安装目录会自动加入系统 PATH。
4. 装完请**新开**命令行窗口再使用，已打开的旧窗口不会感知新的 PATH。

> Notepad3 安装后如需设为默认编辑器，需在 Windows 设置的"默认应用"里手动选择一次。

## 升级与确认最新版

- 上方下载链接始终指向对应环境的 `-latest` 页面，下载到的就是最新一次成功打包的安装包。
- 在 `-latest` 页面可看到本次打包的版本号与 SHA-256；带版本号的发布中还附带 `build-info.json`，记录各组件实际使用的版本与来源。

## 校验下载

每个 `-latest` 页面都提供同名校验文件 `<env>-setup-x64.exe.sha256.txt`。下载后在 PowerShell 中比对：

```powershell
Get-FileHash .\php-setup-x64.exe -Algorithm SHA256
```

输出的哈希值应与校验文件中的一致。

## 卸载

在 Windows"设置 → 应用 → 已安装的应用"（或"控制面板 → 程序和功能"）中找到对应环境卸载即可，安装文件与 PATH 条目会被一并清除。

## 许可证

本仓库只提供打包脚本与安装器，安装包内的软件版权归各上游项目所有，并按其各自许可证分发。详情见各环境文档与上游项目主页。
