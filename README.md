# win-env

自动打包 Windows 常用开发环境：GitHub Actions 手动触发构建，产物自动发布到 GitHub Releases，最终交付物为**一键安装包（.exe）**。

## 打包清单

| 环境 | 版本/规格 | 下载地址 |
| --- | --- | --- |
| PHP | 8.5.x · NTS · VS17 · x64 | [GitHub](https://github.com/php-nil/win-env/releases/download/php-8.5.11/php-8.5.11-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/php-8.5.11/php-8.5.11-setup-x64.exe) |
| pnpm | 12.x · standalone · x64 | [GitHub](https://github.com/php-nil/win-env/releases/download/pnpm-12.13.0/pnpm-12.13.0-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/pnpm-12.13.0/pnpm-12.13.0-setup-x64.exe) |
| Git | v2.x.windows.y · x64 | [GitHub](https://github.com/php-nil/win-env/releases/download/git-2.56.0.windows.2/Git-2.56.0.windows.2-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/git-2.56.0.windows.2/Git-2.56.0.windows.2-setup-x64.exe) |
| PowerShell 7 | 7.6.x · x64 | [GitHub](https://github.com/php-nil/win-env/releases/download/pwsh-7.6.7/pwsh-7.6.7-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/pwsh-7.6.7/pwsh-7.6.7-setup-x64.exe) |
| Node.js | 24.x LTS · x64 · 内置 npm | [GitHub](https://github.com/php-nil/win-env/releases/download/node-24.22.0/node-24.22.0-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/node-24.22.0/node-24.22.0-setup-x64.exe) |
| Rust (MSVC) | 1.99.x · x64 · x86_64-pc-windows-msvc | [GitHub](https://github.com/php-nil/win-env/releases/download/rust-1.99.1-msvc/rust-1.99.1-msvc-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/rust-1.99.1-msvc/rust-1.99.1-msvc-setup-x64.exe) |
| PostgreSQL | 18.x · x64 · 命令行为主（含 `pg-start`/`pg-stop` 管理脚本） | [GitHub](https://github.com/php-nil/win-env/releases/download/postgres-18.6/postgres-18.6-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/postgres-18.6/postgres-18.6-setup-x64.exe) |
| Chromium (ungoogled) | 155.x · x64 · 便携版 · 含桌面快捷方式 | [GitHub](https://github.com/php-nil/win-env/releases/download/chromium-155.0.8059.39-1.1/chromium-155.0.8059.39-1.1-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/chromium-155.0.8059.39-1.1/chromium-155.0.8059.39-1.1-setup-x64.exe) |
| Python | 3.15.x · x64 · 内置 pip/venv/tkinter | [GitHub](https://github.com/php-nil/win-env/releases/download/python-3.15.0/python-3.15.0-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/python-3.15.0/python-3.15.0-setup-x64.exe) |

> 下载地址为当前最新 Release 的安装包直链（代理走 gh-proxy），新版本发布后版本号同步变化；历史版本见 [Releases](https://github.com/php-nil/win-env/releases)。

## 快速开始

1. **构建**：仓库 **Actions** 页签 → 选对应环境的 workflow（如 `Build PHP 8.5`）→ **Run workflow**（版本号留空即自动取最新），构建成功后自动发布 Release。
2. **安装**：在对应 Release 下载 `*-setup-x64.exe` 双击安装（默认装到 `C:\pf\<env>`，需管理员权限；向导中可改目录）。
3. **使用**：安装后**新开**命令行即可直接调用该环境命令（安装目录已加入系统 PATH，旧窗口需重开才能感知）。

> 各环境的详细打包文档（产物规格、workflow 参数、安装行为、组件来源、本地构建、设计约定等）见 [AGENTS.md 文档索引](AGENTS.md#四文档索引)。
