# win-env

自动打包 Windows 常用开发环境：GitHub Actions 手动触发构建，产物自动发布到 GitHub Releases，最终交付物为**一键安装包（.exe）**。

## 打包清单

| 环境 | 版本/规格 | 默认安装目录 | 详细打包文档 |
| --- | --- | --- | --- |
| PHP | 8.5.x · NTS · VS17 · x64（含 Xdebug、cacert.pem、nilpack） | `C:\pf\php-8.5`（安装后 `php` / `nil` 直接可用） | [doc/php-8.5.md](doc/php-8.5.md) |

## 快速开始

1. 推送本仓库到 GitHub；
2. **Actions** → **Build PHP 8.5 (Windows)** → **Run workflow**（PHP/Xdebug 版本留空即自动取最新，可选草稿发布）；
3. 在 **Releases** 的 `php-<version>` 标签下载 `php-<version>-setup-x64.exe`。

安装包行为、组件来源、本地构建、参数与设计约定等细节见 [doc/php-8.5.md](doc/php-8.5.md)。

## 目录结构

```
.github/workflows/   GitHub Actions（手动触发 + 自动发版）
builders/<name>/     各环境的构建脚本与安装器脚本
doc/                 各环境打包文档（详细说明的唯一归属地）与经验教训 doc/lessons.md
build/               本地构建工作目录（已 gitignore）
```
