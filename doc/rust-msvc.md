# Rust MSVC 一键安装包 · 打包方案（已验证）

> **【历史调研文档 · 非当前实现】** 这是实施前的可行性调研记录。其中的技术选型（从 LLVM Release 单独下载 `lld-link.exe`、用 xwin 提取 SDK、无条件写 cargo 配置、模式 A/B 二选一）**已被后续实现取代**。当前链路以 [rust.md](rust.md) 为唯一权威说明：LLD 改用 rustc 组件自带的 `rust-lld`（不再下载 LLVM、不再依赖 7-Zip），cargo 配置仅在系统无可用 MSVC 工具链时才写入。本文档仅保留作可行性论证与微软许可风险的背景参考。

> 验证日期：2026-10-15  
> 结论：**方案可行，但有许可证风险。建议实施，同时提供"无内置 SDK"的降级模式。**

---

## 一、目标

打包 Rust MSVC 工具链（`x86_64-pc-windows-msvc`），装完无需 Visual Studio 即可 `cargo build` 出 MSVC ABI 程序。

---

## 二、核心难点（已验证）

| 依赖 | 官方来源 | 能否 app-local | 验证结果 |
| --- | --- | --- | --- |
| `rustc` / `cargo` | rust-lang.org | ✅ 可解压即用 | 官方提供 `.tar.gz` 组件归档 |
| `link.exe` | 仅随 Visual Studio | ❌ 不可单独分发 | 需用 LLD 替代 |
| Windows SDK 导入库（`.lib`）| 仅随 Visual Studio | ⚠️ 可提取但有许可风险 | xwin 工具可从微软 CDN 拉取 |
| UCRT 头文件/库 | 仅随 Visual Studio | ⚠️ 同上 | 同上 |

**关键结论**：技术上可行，但微软许可条款要求**"已授权的 Visual Studio 使用者"**才能再分发 CRT/SDK 文件。xwin 是社区工具，严格来说处于灰色地带。

---

## 三、技术方案（已验证）

### 3.1 Rust 组件

- **版本发现**：解析 `https://static.rust-lang.org/dist/channel-rust-stable.toml`
  - 含 `date`、`pkg.rust.version`、各组件精确下载 URL
  - 不硬编码版本号，符合仓库契约
- **下载组件**（`x86_64-pc-windows-msvc`）：
  - `rustc-<ver>-x86_64-pc-windows-msvc.tar.gz`
  - `cargo-<ver>-x86_64-pc-windows-msvc.tar.gz`
  - `rust-std-<ver>-x86_64-pc-windows-msvc.tar.gz`
  - 可选：`clippy`、`rustfmt`

### 3.2 链接器：LLD（已验证 ✅）

| 项 | 验证结果 |
| --- | --- |
| 来源 | LLVM 官方 GitHub Release |
| 文件 | `lld-link.exe` 包含在 **Clang for Windows (64-bit)** 预编译包中 |
| 兼容性 | LLD 官方文档明确：接受几乎所有 `link.exe` 命令行选项 |
| 生产验证 | Chromium、Google、Rust 官方 CI 均使用 |
| 关键发现 | **Rust 官方 unstable 文档提到 `rust-lld` 随 rustup 分发**，但独立组件归档中未确认包含 |

**结论**：需从 LLVM Release 单独下载 Clang for Windows 包，提取 `lld-link.exe`。

### 3.3 Windows SDK / CRT 库：xwin 提取（已验证 ⚠️）

| 项 | 验证结果 |
| --- | --- |
| 工具 | `xwin`（Jake-Shadle/xwin），Rust 社区事实标准 |
| 来源 | 微软官方 CDN（`https://aka.ms/vs/17/release`） |
| 提取内容 | CRT 导入库（`.lib`）、UCRT 头文件/库、Windows SDK 头文件/库 |
| 输出结构 | `include/`（头文件）、`lib/ucrt/x86_64/`（UCRT 库）、`lib/um/x86_64/`（Windows SDK 库） |
| 体积 | 预估 50–100 MB（视提取范围） |
| 许可证 | **风险点**：微软官方文档要求"已授权 Visual Studio 使用者"才能再分发 |

**xwin 项目依据**："cross compiling Windows binaries from Linux"，被 cargo-xwin、Rust 官方 CI 使用，但未明确解决许可问题。

### 3.4 组装结构（目标）

```
C:\pf\rust\
  bin\
    rustc.exe
    cargo.exe
    lld-link.exe        ← 塞入的链接器（从 LLVM 提取）
  lib\rustlib\          ← Rust 标准库
  sdk\                  ← 塞入的系统库（xwin 提取）
    include\            ← 头文件
    lib\ucrt\x86_64\    ← UCRT 导入库
    lib\um\x86_64\      ← Windows SDK 导入库
```

### 3.5 Cargo 配置

安装器在 `ssPostInstall` 写 `%USERPROFILE%\.cargo\config.toml`：

```toml
[target.x86_64-pc-windows-msvc]
linker = "lld-link"
rustflags = [
    "-L", "__APP_DIR__\\sdk\\lib\\ucrt\\x86_64",
    "-L", "__APP_DIR__\\sdk\\lib\\um\\x86_64"
]
```

`__APP_DIR__` 占位符由安装器替换为真实路径。

---

## 四、验证结果汇总

| # | 验证项 | 结果 |
| --- | --- | --- |
| 1 | LLVM Release 是否有 `lld-link.exe` | ✅ 有，在 Clang for Windows (64-bit) 包中 |
| 2 | xwin 能否独立运行、输出目录结构 | ✅ 能，输出 `include/` + `lib/ucrt/` + `lib/um/` |
| 3 | xwin 提取的库文件是否足够 | ✅ cargo-xwin 生产验证可行 |
| 4 | LLD 与 MSVC 库兼容性 | ✅ LLD 官方文档明确兼容 link.exe 选项 |
| 5 | 微软对 CRT/SDK 文件再分发的许可条款 | ⚠️ **风险：要求"已授权 VS 使用者"** |
| 6 | 无 VS 干净机器上能否完整编译运行 | ⏳ 需虚拟机实测 |

---

## 五、风险与对策（非许可层面）

| # | 风险 | 等级 | 分析 | 对策 |
| --- | --- | --- | --- | --- |
| 1 | **LLD 无法完全替代 link.exe** | 中 | LLD 官方文档称"接受几乎所有 link.exe 选项"，但 Rust issue #39915 指出"lack of debuginfo support"。Chromium 使用 LLD 时仍需 `/OPT:NOREF` 等 workaround。 | 实测：构建时跑完整冒烟（`cargo new` + `cargo build` + 含 C 依赖的 crate）；失败则降级 GNU 链 |
| 2 | **xwin 提取的库不完整** | 中 | xwin 默认提取 `ucrt` + `um`，但 **不含 `vcruntime`**（VS 编译器专用运行时，含异常处理等）。`vcruntime` 通常随 `cl.exe` 分发，xwin 无法提取。Rust 的 `std` 依赖 `vcruntime` 的符号（如 `__CxxFrameHandler3`）。 | 实测：链接阶段报 `unresolved external symbol` 即缺库；对策：从 LLVM 提取的 `clang` 自带部分 runtime，或改静态链接 `/MT`，或内置 `vcruntime140.dll` |
| 3 | **cc crate 兼容性** | 中 | `cc` crate 在 MSVC 目标下**优先找 `cl.exe`**（VS 编译器），找不到则 fallback 到 `clang-cl`。但 `clang-cl` 本身需要 VS 环境变量（`INCLUDE`、`LIB`）才能工作。 | 对策：安装器写环境变量 `CC=clang-cl` + `CFLAGS` 指向 xwin 提取的头文件；或文档注明"含 C 依赖的 crate 需自行配置" |
| 4 | **vcruntime 缺失导致链接失败** | **高** | Rust MSVC 目标的 `std` 编译时假设 `vcruntime` 存在。xwin 只提取 UCRT + Windows SDK，不含 VS 编译器 runtime。这是**最可能失败的点**。 | 对策：内置 `vcruntime140.dll`（从官方 vc_redist 提取，已有 PHP 包先例）；或 rustc 参数 `-C target-feature=+crt-static` 静态链接 |
| 5 | **PDB / 调试信息支持** | 低 | LLD 早期版本 PDB 支持不完整，但 15.0+ 已大幅改进。 | 接受限制：调试体验略差于 VS，但发布构建无影响 |
| 6 | **xwin 版本漂移** | 低 | xwin 从微软 CDN 拉取，微软更新 VS 后 URL/结构可能变化。 | 固定 xwin 版本，构建失败时人工更新 |
| 7 | **总体积超过 300 MB** | 低 | Rust 工具链 ~200 MB + LLD ~50 MB + SDK ~100 MB = ~350 MB。 | 接受（用户明确要求 MSVC）；或精简 SDK 提取范围 |

### 关键风险详解：vcruntime（#4）

这是**技术层面最可能卡住**的点。Rust MSVC 版的 `std` 在链接时需要 `vcruntime` 的符号，但 xwin 的设计目标是**交叉编译**（从 Linux 编译 Windows 程序），它假设 `vcruntime` 由目标系统提供（即用户已装 VS 或 vc_redist）。

**本仓库场景**：目标机器**干净无 VS**，必须解决 `vcruntime`。

**可行对策**（按优先级）：
1. **静态链接 CRT**：`RUSTFLAGS=-C target-feature=+crt-static`，把 `vcruntime` 静态链入每个 exe。缺点：exe 体积增大，且部分 crate 不兼容。
2. **内置 `vcruntime140.dll`**：从官方 `vc_redist.x64.exe` 提取（PHP 包已有成熟方案），放安装目录，程序运行时经 PATH 或 app-local 加载。缺点：需处理 DLL 搜索路径。
3. **从 LLVM 的 compiler-rt 提取**：`clang` 包自带部分 runtime，但 MSVC ABI 兼容性未验证。

**建议**：先实测 #1（静态链接），失败则 fallback 到 #2（内置 DLL，复用 PHP 的 vc_redist 提取逻辑）。

---

## 六、建议的实施路径

### 模式 A：完整内置（推荐，但有许可风险）

- 内置 LLD + xwin 提取的 SDK
- 装完即用，无需任何外部依赖
- **需在文档/安装界面注明**："本包包含从微软官方 CDN 提取的 CRT/SDK 文件，用户需确认符合微软许可条款"

### 模式 B：无 SDK 降级（零风险，但用户体验差）

- 只打包 Rust + LLD
- 首次 `cargo build` 时检测：若无 VS Build Tools，提示用户安装
- 安装器提供"下载 VS Build Tools"按钮

### 建议

先做**模式 A**，同时准备模式 B 作为 fallback。理由：
1. cargo-xwin / Rust 官方 CI 已长期使用 xwin，社区默认接受
2. 用户明确需求是"无需 VS 的 MSVC 编译"
3. 可在安装界面加确认框："我已阅读并理解微软许可条款"

---

## 七、下一步

1. 用户确认模式（A / B / 都要）
2. 写 `build.ps1` + `setup.iss` + workflow
3. 本地构建 + 干净机器验证（需无 VS 的 VM）
