# win-env

自动打包 Windows 常用开发环境：GitHub Actions 手动触发构建，产物自动发布到 GitHub Releases，最终交付物为**一键安装包（.exe）**。

## 打包清单

| 环境 | 版本/规格 | 下载地址 |
| --- | --- | --- |
| PHP | 8.5.x · NTS · VS17 · x64 | [GitHub](https://github.com/php-nil/win-env/releases/download/php-latest/php-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/php-latest/php-setup-x64.exe) |
| pnpm | 12.x · standalone · x64 | [GitHub](https://github.com/php-nil/win-env/releases/download/pnpm-latest/pnpm-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/pnpm-latest/pnpm-setup-x64.exe) |
| Git | v2.x.windows.y · x64 | [GitHub](https://github.com/php-nil/win-env/releases/download/git-latest/git-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/git-latest/git-setup-x64.exe) |
| PowerShell 7 | 7.6.x · x64 | [GitHub](https://github.com/php-nil/win-env/releases/download/pwsh-latest/pwsh-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/pwsh-latest/pwsh-setup-x64.exe) |
| Node.js | 24.x LTS · x64 · 内置 npm | [GitHub](https://github.com/php-nil/win-env/releases/download/node-latest/node-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/node-latest/node-setup-x64.exe) |
| Rust (MSVC) | 1.99.x · x64 · x86_64-pc-windows-msvc | [GitHub](https://github.com/php-nil/win-env/releases/download/rust-latest/rust-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/rust-latest/rust-setup-x64.exe) |
| PostgreSQL | 18.x · x64 · 命令行为主（含 `pg-start`/`pg-stop` 管理脚本） | [GitHub](https://github.com/php-nil/win-env/releases/download/postgres-latest/postgres-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/postgres-latest/postgres-setup-x64.exe) |
| Chromium (ungoogled) | 155.x · x64 · 便携版 · 含桌面快捷方式 | [GitHub](https://github.com/php-nil/win-env/releases/download/chromium-latest/chromium-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/chromium-latest/chromium-setup-x64.exe) |
| Python | 3.15.x · x64 · 内置 pip/venv/tkinter | [GitHub](https://github.com/php-nil/win-env/releases/download/python-latest/python-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/python-latest/python-setup-x64.exe) |

> 下载地址为各环境的**常青别名**（tag `<env>-latest`，资产名固定 `<env>-setup-x64.exe`）：每次构建原地覆盖，链接永不随版本号失效，始终指向该环境最新一次构建。带版本号的历史发布（含发布说明、SHA-256、`build-info.json`）见 [Releases](https://github.com/php-nil/win-env/releases)。

## 快速开始

1. **构建**：仓库 **Actions** 页签 → 选对应环境的 workflow（如 `Build PHP 8.5`）→ **Run workflow**（版本号留空即自动取最新），构建成功后自动发布 Release。
2. **安装**：点上方打包清单的下载链接（常青别名，始终指向最新构建），或到 Releases 选具体版本，下载 `*-setup-x64.exe` 双击安装（默认装到 `C:\pf\<env>`，需管理员权限；向导中可改目录）。
3. **使用**：安装后**新开**命令行即可直接调用该环境命令（安装目录已加入系统 PATH，旧窗口需重开才能感知）。

> 各环境的详细打包文档（产物规格、workflow 参数、安装行为、组件来源、本地构建、设计约定等）见 [AGENTS.md 文档索引](AGENTS.md#四文档索引)。
