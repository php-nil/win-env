# win-env

自动打包 Windows 常用开发环境：GitHub Actions 手动触发构建，产物自动发布到 GitHub Releases，最终交付物为**一键安装包（.exe）**。

## 打包清单

| 环境 | 版本/规格 | 默认安装目录 |
| --- | --- | --- |
| PHP | 8.5.x · NTS · VS17 · x64（含 Xdebug、cacert.pem、nilpack） | `C:\pf\php-8.5`（安装后 `php` / `nil` 直接可用） |
| pnpm | 12.x · standalone `pnpm.exe`（内置 Node.js 运行时）· x64 | `C:\pf\pnpm`（安装后 `pnpm` 直接可用） |
| Git | v2.x.windows.y · 官方发行版（自解压 7z 整包提取）· x64 | `C:\pf\Git`（安装后 `git` 直接可用，PATH 追加 `<安装目录>\cmd`） |

> 各环境的详细打包文档（产物规格、workflow 参数、安装行为、组件来源、本地构建、设计约定等）见 [AGENTS.md 文档索引](AGENTS.md#四文档索引)。
