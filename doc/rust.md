# Rust MSVC Windows 一键安装包 · 打包文档

本文档是 Rust MSVC 打包链路的唯一权威说明。构建配置位于 [builders/rust](../builders/rust)：

| 文件 | 作用 |
| --- | --- |
| `build.ps1` | 构建脚本：版本发现 → 下载 → 组装暂存目录 → 冒烟测试 → 编译安装包 → 输出元数据与发布说明 |
| `setup.iss` | Inno Setup 6 安装器脚本 |
| `Languages/ChineseSimplified.isl` | 安装向导简体中文语言包（官方 Inno Setup 安装包不含此文件，必须随仓库携带） |
| `setup.ico` | 安装器图标（Rust 官方图标，随仓库保存） |

> 方案可行性、许可风险与历史验证记录见 [rust-msvc.md](rust-msvc.md)（实施前的调研文档，非本链路权威说明）。

## 1. 产物规格

| 项 | 值 |
| --- | --- |
| 产物文件 | `rust-<version>-msvc-setup-x64.exe`（LZMA2 固实压缩 + 128 MB 字典；2026-10 实测 1.99.1 约 166 MiB，新增 rustfmt/clippy 组件后的体积以 CI 实测为准） |
| 附带文件 | `*.exe.sha256.txt`（校验值）、`build-info.json`（版本/来源元数据）、`release-notes.md`（Release 正文） |
| Release 标签 | `rust-<version>-msvc`；另有常青别名 `rust-latest`（资产名固定 `rust-setup-x64.exe`，README 下载链接指向它） |
| 规格 | 官方 Rust 组件归档（`rustc` / `cargo` / `rust-std` / `rustfmt-preview` / `clippy-preview`）· x86_64-pc-windows-msvc · stable channel |
| 默认安装目录 | `C:\pf\rust`（安装向导中可修改，**不带版本号后缀**） |
| 安装后命令 | `rustc`、`cargo`、`rustfmt`、`cargo fmt`、`cargo clippy`（安装目录的 `bin` 加入系统 PATH，`%USERPROFILE%\.cargo\bin` 加入用户 PATH，新开命令行即可用） |
| 运行时依赖 | 无（免 Visual Studio：无系统 MSVC 工具链时用内置 LLD 链接器 + 经 xwin 提取的 Windows SDK / CRT 兜底；系统已有 VS C++ 工具 + SDK 时走官方默认） |
| 权限 | 需要管理员（在 C 盘根目录创建文件夹、改写系统 PATH、写系统级环境） |
| 卸载 | 控制面板 / 安装目录下 `unins000.exe`；文件、系统/用户 PATH 条目与 `%USERPROFILE%\.cargo\config.toml` 中的目标段一并清理（用户 PATH 条目仅在由本安装器新增时回收） |

## 2. 触发构建（GitHub Actions）

手动触发，构建成功后自动发布 Release：

1. 仓库 **Actions** 页签 → **Build Rust MSVC** → **Run workflow**；
2. 输入参数：

| 参数 | 说明 |
| --- | --- |
| `rust_version` | 不带 `v` 的精确版本号，如 `1.99.1`；留空则从官方 `channel-rust-stable.toml` 取最新 stable |
| `draft_release` | 勾选后 Release 以草稿形式发布，不打公开标签 |

3. 构建完成后在 **Releases** 的 `rust-<version>-msvc` 标签下载安装包；工作流同时上传同名 build artifact。该标签已有公开（非草稿）Release 时本次不重复发布、不覆盖既有资产。随后把本次安装包以固定资产名 `rust-setup-x64.exe` 覆盖到常青别名 `rust-latest`（勾选 `draft_release` 时不更新），README 的下载链接只指向它。

## 3. 安装包行为

- 双击安装，向导默认目录 `C:\pf\rust`，可自行修改。
- 安装内容即暂存树 `build/stage/rust` 的原样释放：`bin\`（`rustc.exe` / `cargo.exe`）、`lib\rustlib\`（标准库与内置 LLD）、`crt\` / `sdk\`（经 xwin 提取的 CRT/SDK 头文件与库），安装器不在安装期下载或拼装任何内容。
- PATH（**必加，无安装选项**）：`{app}\bin` 加入**系统** PATH，保证新开命令行中 `rustc` / `cargo` / `rustfmt` 可直接使用。
  - 安装时幂等追加（不重复、不动无关条目、顺带去空条目），并广播 `WM_SETTINGCHANGE`；
  - 卸载时精确移除该条目，其余 PATH 内容保留。
- **用户级 PATH（对齐官方 rustup）**：安装时把 `%USERPROFILE%\.cargo\bin` 追加到**用户** PATH（`HKCU\Environment`）——
  - 条目内容与官方 rustup 写入的完全相同（保留 `%USERPROFILE%` 字面量），使 `cargo install` 装出的子命令可直接按名调用；
  - 比较条目时先把 `%USERPROFILE%` 展开，因此"字面量形式"与"已展开形式"视为同一条目，重复安装不会追加重复项；
  - 卸载时**仅当该条目由本安装器新增**才回收（依据 `HKCU\Software\win-env\rust` 的记录值）；机器上若已装官方 rustup 并自带该条目，则保持不动。
- **Cargo 链接器配置（"与官方一致"优先，安装时按环境决定）**：安装器在 `ssPostInstall` 探测系统是否已有可用的 MSVC 工具链——
  - **探测到**（系统存在 VS C++ 工具目录 `…\VC\Tools\MSVC`，且 Windows SDK 已注册）：**不写任何 cargo 配置**，与官方 rustup 行为一致，rustc 自行发现 `link.exe` 与 SDK 库路径；若此前在无 VS 机器上安装过并残留本段，安装时一并回收；
  - **探测不到**：写 `%USERPROFILE%\.cargo\config.toml`，新增/替换 `[target.x86_64-pc-windows-msvc]` 段——`linker` 指向安装目录内 rustc 自带的 `lib\rustlib\x86_64-pc-windows-msvc\bin\gcc-ld\lld-link.exe`（`{app}` 绝对路径，不依赖 PATH），`rustflags` 追加 `-L` 指向 `crt\lib\x86_64`、`sdk\lib\ucrt\x86_64`、`sdk\lib\um\x86_64` 三个库目录；
  - **段级合并**：文件已存在时只替换本段，保留用户其他配置；卸载时移除本段（若文件仅剩空白则删除文件）。
  - 探测规则**偏保守**：误判为"不可用"最多是多写一份可用的兜底配置（无害），误判为"可用"却实际不可用才会让用户构建失败，因此要求 VS C++ 工具目录与 SDK 注册**同时**成立。
- 安装器固定 `AppId`（`{{7E3B9A2D-4C5F-4E8A-B1D6-9F0A3C7E2B51}`），重复安装/升级替换同一安装实例。

## 4. 组件来源（官方渠道）

| 组件 | 来源 | 取用内容 |
| --- | --- | --- |
| Rust 工具链 | <https://static.rust-lang.org/dist/channel-rust-stable.toml> | 版本与各组件精确 URL；下载 `rustc` / `cargo` / `rust-std` / `rustfmt-preview` / `clippy-preview` 的 `-x86_64-pc-windows-msvc.tar.gz` 并合并为暂存树（后两者的**归档文件名**为 `rustfmt` / `clippy`，无 `-preview`，见 §6 与 [lessons.md §15](lessons.md)） |
| LLD 链接器 | **rustc 组件自带**，无独立下载 | `lib\rustlib\x86_64-pc-windows-msvc\bin\rust-lld.exe`（真正的多 flavor 驱动）+ `gcc-ld\lld-link.exe`（按名分派的极小包装器，按相对路径拉起 `rust-lld`） |
| Windows SDK / CRT | 微软官方 CDN（`https://aka.ms/vs/17/release`），经 [xwin](https://github.com/Jake-Shadle/xwin) 提取 | `crt\`（VC 头文件与 `msvcrt`/`vcruntime` 导入库）、`sdk\`（UCRT 与 Windows SDK 头文件/`kernel32` 等导入库） |
| 版本发现 | GitHub API（xwin 最新 release） | 自动取最新 xwin 的 Windows MSVC `.tar.gz` 资产，避免硬编码版本被清理后 404 |
| 安装器 | [Inno Setup 6](https://jrsoftware.org/isinfo.php) | GitHub windows runner 预装；缺失时 workflow 用 Chocolatey 兜底安装 |

## 5. 本地构建

前置：Windows + PowerShell 5+；编译安装包需要 Inno Setup 6（仅组装阶段可跳过）。本机执行策略禁止未签名脚本时，用 `powershell -NoProfile -ExecutionPolicy Bypass -File ...` 调起。

```powershell
# 完整构建（自动发现最新 stable，产物在 build\output）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\rust\build.ps1

# 只做下载与组装，不编译安装包（产物在 build\stage\rust）
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\rust\build.ps1 -SkipCompile

# 指定版本
powershell -NoProfile -ExecutionPolicy Bypass -File .\builders\rust\build.ps1 -RustVersion 1.99.1
```

构建脚本参数：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `-RustVersion` | 空（自动发现） | 不带 `v` 的精确版本号，如 `1.99.1` |
| `-BuildDir` | `<repo>\build` | 缓存/暂存/输出目录（rust 暂存树在 `build\stage\rust`，与其他环境隔离） |
| `-SkipCompile` | 关 | 只组装不编译 |

ISCC 查找顺序：`ISCC` 环境变量 → `C:\Program Files (x86)\Inno Setup 6` → `C:\Program Files\Inno Setup 6` → PATH。

输出：

- `build\output\rust-<ver>-msvc-setup-x64.exe`
- `build\output\rust-<ver>-msvc-setup-x64.exe.sha256.txt`
- `build\output\build-info.json`（版本、channel 日期、目标、组件 URL、LLD 版本与来源、xwin 版本、大小、SHA-256）
- `build\output\release-notes.md`（Release 正文）

## 6. 设计约定

- **不硬编码版本**：Rust 补丁版本从官方 channel TOML 解析（`[pkg.rust].version` 去括号后缀，顶层 `date` 为 channel 日期），组件 URL 亦直接取自该文件，不猜测；解析为空立即终止。TOML 解析需同时兼容 `[table]` 与 `[[array-of-table]]` 两种括号形式（见 [lessons.md §16](lessons.md)）。
- **组件名 ≠ 归档文件名**：channel 中 rustfmt / clippy 的组件名是 `rustfmt-preview` / `clippy-preview`，归档文件名却是 `rustfmt-<ver>-<target>.tar.gz` / `clippy-<ver>-<target>.tar.gz`（无 `-preview`）。因此 `$components` 同时保存 `Name`（解析键 + 内层合并目录名）与 `FileStem`（pinned 版本重建 URL 用的文件名前缀）；把二者混用会拼出 `rustfmt-preview-<ver>-…tar.gz` 而 404。实测内部布局：`rustfmt-preview/` 含 `bin\rustfmt.exe`、`bin\cargo-fmt.exe`，`clippy-preview/` 含 `bin\clippy-driver.exe`、`bin\cargo-clippy.exe`；两者 `manifest.in` 都列出 `*.pdb` —— 官方安装同样包含这些 PDB，故**全量拷贝即与官方一致**（见 [lessons.md §15](lessons.md)）。
- **LLD 不额外下载**：rustc 组件已内置 `rust-lld` 与其 `gcc-ld` 小小的 per-flavor 包装器，`linker` 指向 `gcc-ld\lld-link.exe` 即可；该包装器**按相对路径**定位 `rust-lld`，因此**必须保持组件原始相对布局**（不得把 `lld-link.exe` 单独搬到 `bin\`）。此前从 LLVM Release 下载并解压 `lld-link.exe` 的做法已移除。
- **"与官方安装一致"优先**：官方 rustup 在 MSVC 下**不写任何 cargo 配置**、使用系统 VS 的 `link.exe`。本包只在系统确实没有可用 MSVC 工具链时才偏离这一默认（写 LLD + 内置 SDK 的兜底配置），有 VS 的机器上与官方行为一致。不能用 `-C link-self-contained=+linker` 这类官方机制"零配置启用内置 LLD"——该选项目前仅在 `x86_64-unknown-linux-gnu` 上稳定，Windows MSVC 目标不适用（见 [rustc codegen-options](https://doc.rust-lang.org/rustc/codegen-options/index.html)）。
- 暂存目录（`build/stage/rust`）根目录即安装后的 `C:\pf\rust`。组件 tar.gz 内层多一层版本目录、再内层才是真正的组件目录（`rust-std` 内层名带 target 后缀），合并时须取组件子目录本身，否则 `bin\rustc.exe` / `lib\rustlib\<target>\lib` 布局错位（`E0463: can't find crate for std`）。
- 下载缓存于 `build/cache`，重复构建不重复下载；下载失败自动重试 3 次。
- **xwin 同盘约束**：xwin `splat` 用 move（rename）语义把文件从 unpack 目录移到输出目录，跨盘会以 os error 17 失败；因此 `--cache-dir` 指向 `build/cache`（与暂存树同盘），**不要**用 `--temp`（落到 `%TEMP%` 后再移盘会失败）。
- **重解析点清理（强制）**：xwin 在 Windows 上仍会生成 `sdk\lib\<sdkversion>`、`sdk\include\<sdkversion>` 两个指向父目录的目录链接（`--disable-symlinks` 挡不住）。交给 ISCC 前必须枚举并**非递归**删除暂存树内所有重解析点（`[IO.Directory]::Delete($p, $false)`），否则 `[Files] recursesubdirs` 绕环溢出，报无行号的 `The system cannot find the path specified` + exit 2（见 [lessons.md §14](lessons.md)）。
- 组装完成有强制冒烟测试，任一失败即 throw，不产出坏包：
  1. 暂存 `rustc.exe --version` 必须与解析出的版本号逐字一致；
  2. 暂存 `cargo.exe --version` 退出码为 0；
  3. 暂存 `lld-link.exe --version` 退出码为 0（就地调用即证明包装器能找到 `rust-lld` 子进程）；
  4. **真实 `cargo new` + `cargo build --release`**：用临时 `CARGO_HOME` 写指向内置 `lld-link` 与三个 SDK 库目录的 config，清空 `RUSTC` / `RUSTUP_*` 环境变量后构建一个二进制 crate，必须产出 `helloworld.exe`。这是"免 VS 可编译"的端到端证明。
  5. 暂存 `bin\rustfmt.exe --version` 退出码必须为 0，且 `bin\rustfmt.exe`、`bin\cargo-fmt.exe`、`bin\cargo-clippy.exe`、`bin\clippy-driver.exe` 四个文件必须存在（合并布局错误在此提前暴露）。
  6. 在冒烟 crate 上真实执行 `cargo fmt --check` 与 `cargo clippy`：前者证明 `cargo-fmt` 能经 PATH 被 cargo 解析且代码通过格式检查，后者证明 clippy 能真实 lint 该 crate。任一失败即 throw。
- **本地安装闭环验证**：静默安装到**非默认目录** → 用注册表 Machine+User PATH 拼出新进程环境验证裸命令 `rustc` / `cargo` → 按本机环境核对 cargo 配置（无系统 MSVC 工具链时 `%USERPROFILE%\.cargo\config.toml` 应出现指向实际安装目录的目标段；有则不应出现本段）→ 核对 `HKCU\Environment` 的 `Path` 是否含 `%USERPROFILE%\.cargo\bin` → 静默卸载 → 确认文件、系统 PATH 条目、本安装器新增的用户 PATH 条目与 config 目标段都消失。

## 7. 已知限制

- **许可**：包内含从微软官方 CDN 提取的 CRT/SDK 文件，微软条款要求再分发对象为"已授权的 Visual Studio 使用者"，用户需自行确认。见 [rust-msvc.md §五](rust-msvc.md)。
- **PDB / 调试信息**：MSVC 目标用 **CodeView / PDB**，调试器为 VS / WinDbg / CDB（`gdb` / `lldb` 读不了 PDB，它们要 DWARF，只有 `*-windows-gnu` 目标才产出 DWARF）。官方 LLD 文档明确声明其 PDB 与 `link.exe` **同级（at parity）**，唯一缺口是已废弃的 `/DEBUG:FASTLINK`（VS 2026 起该选项已被移除）；另外 `link.exe` 在超大 PDB（单流 > ~2 GB）上会链接失败，LLD 反而更能扛。因此对**纯 Rust** 的调试体验，本包（LLD）与原生 `link.exe` 实际等同，发布构建更无影响。机器上已装 VS（C++ 工具 + Windows SDK）时，安装器会自动走官方 `link.exe` 路径、不写任何配置（见 §3），无需手工覆盖；只有在**无 VS** 的机器上才由本包提供 LLD 兜底，此时若确需 `link.exe`（如重度 C++ 互操作调试、Edit-and-Continue），再自备 VS 并设 `CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER=link.exe`。
  - 提示：`cargo build` 的 debug profile 默认已带 `debug = true`（等价 `-C debuginfo=2`）；release 默认 `-C debuginfo=0`，如需发布版也能调试可显式设 `[profile.release] debug = true`。
- **含 C 依赖的 crate**：包内不提供 `clang-cl`，此类 crate 需自行准备 C 编译器（如另装 LLVM）。`cc` crate 在 MSVC 目标下优先找 `cl.exe`。
- **兜底 cargo 配置为当前用户级**（仅在没有系统 MSVC 工具链的机器上出现）：`config.toml` 写在执行安装的用户的 `%USERPROFILE%` 下；同一机器的**其他用户**没有该段配置，其 `cargo build` 需自行补 `linker` / `rustflags`（机器级方案未落地）。用户 PATH 条目（`%USERPROFILE%\.cargo\bin`）同样只作用于执行安装的用户。
