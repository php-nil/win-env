# win-env

自动打包 Windows 常用开发环境：GitHub Actions 手动触发构建，产物自动发布到 GitHub Releases，最终交付物为**一键安装包（.exe）**。

## 打包清单

| 环境 | 版本/规格 | 下载地址 |
| --- | --- | --- |
| PHP | 8.5.x · NTS · VS17 · x64（内置 Composer、VC++ 运行库） | [GitHub](https://github.com/php-nil/win-env/releases/download/php-8.5.11/php-8.5.11-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/php-8.5.11/php-8.5.11-setup-x64.exe) |
| pnpm | 12.x · standalone · x64 | [GitHub](https://github.com/php-nil/win-env/releases/download/pnpm-12.13.0/pnpm-12.13.0-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/pnpm-12.13.0/pnpm-12.13.0-setup-x64.exe) |
| Git | v2.x.windows.y · x64 | [GitHub](https://github.com/php-nil/win-env/releases/download/git-2.56.0.windows.2/Git-2.56.0.windows.2-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/git-2.56.0.windows.2/Git-2.56.0.windows.2-setup-x64.exe) |
| PowerShell 7 | 7.6.x · x64 · 内置右键菜单/WT 配置档 | [GitHub](https://github.com/php-nil/win-env/releases/download/pwsh-7.6.7/pwsh-7.6.7-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/pwsh-7.6.7/pwsh-7.6.7-setup-x64.exe) |
| Node.js | 24.x LTS · x64 · 内置 npm | [GitHub](https://github.com/php-nil/win-env/releases/download/node-24.21.0/node-24.21.0-setup-x64.exe) · [代理](https://gh-proxy.com/https://github.com/php-nil/win-env/releases/download/node-24.21.0/node-24.21.0-setup-x64.exe) |

> 下载地址为当前最新 Release 的安装包直链（代理走 gh-proxy），新版本发布后版本号同步变化；历史版本见 [Releases](https://github.com/php-nil/win-env/releases)。

> 各环境的详细打包文档（产物规格、workflow 参数、安装行为、组件来源、本地构建、设计约定等）见 [AGENTS.md 文档索引](AGENTS.md#四文档索引)。
