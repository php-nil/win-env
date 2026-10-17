# 经验教训（Windows 打包链路）

> 只收录在本项目中**实际发生并已验证**的问题。每条结构：现象 → 根因 → 规则。新增条目须是真实踩坑，不收录未经验证的"最佳实践"。

## 1. PowerShell 5.1 编码

### 1.1 含中文的 .ps1 必须保存为 UTF-8 with BOM

* **现象**：CI 发布的 Release 正文中文全部乱码（标题来自 workflow YAML 却正常）。
* **根因**：PS 5.1 对**无 BOM** 的 `.ps1` 按系统 ANSI 代码页（GitHub runner 为 cp1252）解析，中文字面量在解析阶段已损坏，再以 UTF-8 写出形成双重乱码。YAML 由 Actions 按 UTF-8 读取，故标题正常。
* **规则**：任何含非 ASCII 字符的 `.ps1` 必须带 BOM（`EF BB BF`）。加 BOM 后重跑构建，release-notes.md 中文恢复正常。
* **注意**：编辑器/工具链会悄悄去掉 BOM —— 已实测：用 AI 编辑工具改 `builders/rust/build.ps1` 后，文件头从 `EF BB BF` 变成 `3C 23 0A`（BOM 被剥掉），若直接提交会让 CI 重新乱码。**每次改完任何含中文的 `.ps1`，必须复查文件头三字节并补回**：

```powershell
$p = 'builders\rust\build.ps1'; $b = [IO.File]::ReadAllBytes($p)
if (-not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)) {
    $out = New-Object byte[] ($b.Length + 3)
    $out[0] = 0xEF; $out[1] = 0xBB; $out[2] = 0xBF
    [Array]::Copy($b, 0, $out, 3, $b.Length)
    [IO.File]::WriteAllBytes($p, $out)
}
```

### 1.2 PS 5.1 的 `Out-File -Encoding utf8` 会写 BOM

* **现象**：即使脚本解析正确，写出的 release-notes.md / build-info.json 仍可能带 BOM，GitHub 正文开头出现残留字符。
* **规则**：写 UTF-8 文本统一用：

```powershell
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($path, $content, $utf8NoBom)
```

`.bat` 包装器等纯 ASCII 文件用 `ASCIIEncoding`；生成的 php.ini 同样用无 BOM UTF-8。

## 2. Inno Setup / ISCC

### 2.1 禁止用 `ISCC /?` 做健康检查

* **现象**：CI 停在 "Locate Inno Setup compiler" 步骤——ISCC 已找到、帮助信息正常打印，但步骤 exit code 1，构建步骤全部跳过。
* **根因**：`iscc /?` 打印帮助后**退出码恒为 1**；Actions 的 PowerShell step 以 `exit $LASTEXITCODE` 收口。
* **规则**：定位到 ISCC 后只读文件元数据报告版本：`(Get-Item $iscc).VersionInfo.ProductVersion`。真实编译失败由 build.ps1 中 `if ($LASTEXITCODE -ne 0) { throw }` 兜底。

### 2.2 简体中文语言包必须随仓库携带

* **现象**：编译引用 `Languages\ChineseSimplified.isl` 失败。
* **根因**：官方 Inno Setup 安装包**不含**简体中文语言文件。
* **规则**：`builders/<name>/Languages/ChineseSimplified.isl` 随仓库管理，不依赖 runner 环境。

### 2.3 `LoadStringFromFile` 读取 ANSI .isl 需用 AnsiString

* **现象**：读取语言文件相关代码编译告警。
* **规则**：对应缓冲区使用 `AnsiString`（官方示例做法）。修复后 ISCC 6.7.1 编译零警告零错误。

### 2.4 `lzma2/max` 默认字典装不下暂存树，需显式 `LZMADictionarySize`

* **现象**：PHP 暂存树约 98 MB、pnpm 约 52 MB，`Compression=lzma2/max` 出包后仍有约 3% 的可压缩空间未被利用。
* **根因**：`lzma2/max` 预设的默认字典（小于 64 MB）无法在一个固实块内覆盖整个暂存树，跨块重复数据无法去重。
* **规则**：两个安装器均显式设 `LZMADictionarySize=131072`（128 MB，KB 单位），实测 PHP 25.06→24.36 MB、pnpm 16.67→16.18 MB（各约 −2.8%/−2.9%）。代价：解包时额外约 130 MB 内存（开发机可忽略），压缩内存只发生在构建 runner 上。暂存树显著增大后按"大于字典则上调"复核。

### 2.5 本地预编译 `.iss` 时 `[Files]` 的 Source 通配至少匹配一个文件

* **现象**：为验证 `setup.iss` 语法，用便携 ISCC 指向一个**空**的假暂存目录，报 `Error on line <N>: No files found matching "<dir>\*"` 并以 exit 2 中止，看起来像脚本语法错误，实际是通配无匹配。
* **规则**：本地预编译校验时，假暂存目录里先放一个占位文件（`dummy.txt`）再编译；真正的判据是最后必须出现 `Successful compile` 且 `$LASTEXITCODE = 0`。校验产物与假暂存目录同步清理，不留残余。

## 3. PowerShell 正则与文本处理

### 3.1 `[regex]::Replace` 的 int 参数会被当成 RegexOptions

* **现象**：启用扩展时本应只替换第一处注释行，结果同模式所有行被改动（mysqli 重复启用）。
* **根因**：静态重载 `[regex]::Replace($input,$pattern,$replacement,$options)` 的第 4 参数是 `RegexOptions`，传 `1` 等于 `IgnoreCase`，**不是**替换次数。
* **规则**：限制替换次数用实例方法：`([regex]$pattern).Replace($input, '$1', 1)`。

### 3.2 官方 ini 是 CRLF，多行正则的行尾锚点不要用 `$`

* **现象**：`(?m)^[ \t]*;(extension=mysqli[ \t]|$)` 之类模式匹配不到。
* **根因**：CRLF 文本中 `$` 落在 `\r` 之后，分组匹配失败。
* **规则**：行内边界用 `\b` 锚定扩展名（如 `extension[ \t]*=[ \t]*mysqli\b`），不依赖行尾。

## 4. PowerShell 调用原生命令

### 4.1 给 php.exe 传 `-r` 代码极易被拆词/吞变量

* **现象**：`php -r '...$e...'` 接连出现 `unexpected token ")"`、`Unclosed '{'`、`no argument for option r`。
* **规则**：验证扩展/运行时优先用无空格无引号的参数形式（`php --ri pdo_pgsql`，缺失时退出码非 0 并输出 "Extension not present"）；必须执行代码时写入 `build/` 内临时文件并在用后清理。
* 调用外部 exe 一律使用**绝对路径**（机器上可能并存多个 PHP，如 Laragon 自带版本），避免误用 PATH 中的其他发行版。

### 4.2 本机验证 PATH 效果必须模拟全新进程

* **现象**：安装器写入注册表后，当前终端直接敲命令不生效。
* **根因**：现有进程的环境块是启动时的快照；`WM_SETTINGCHANGE` 只通知新进程。
* **规则**：验证时从注册表重新拼接 PATH：`$env:Path = [Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [Environment]::GetEnvironmentVariable('Path','User')`，并把工作目录切到 `C:\`，再用 `where.exe` + 裸命令验证；卸载后同样复查注册表值长度变化（如 192→153）与条目消失。

### 4.3 7-Zip GUI 模块 SFX 不能直接调用解压

* **现象**：CI 里 PortableGit-2.56.0.2-64-bit.7z.exe 调用 `& $gitExe "-o$StageDir" '-y' '-b0'` 后，`$LASTEXITCODE` 为空（连 0 都不是），暂存目录空无一物，`-o` / `-y` / `-b0` 三个参数全被忽略。错误消息打印 `exit code ` 后冒号后面直接空白。
* **根因**：7-Zip SFX 有两种内置模块——**Console 模块**（有控制台 I/O、回传 exit code、识别 CLI flags）和 **GUI 模块**（无控制台窗口、不回传 exit code、忽略所有 CLI 参数）。Git for Windows 的 PortableGit 资产用的是 **GUI 模块** SFX（`.7z.exe`），设计上就是双击弹 GUI 解压的。
* **规则**：GUI 模块 SFX 一律改用 **7z.exe** 解包——7z 能把 SFX 文件当作普通 `.7z` 归档直接读取，命令为 `7z x <file> "-o<stage>" -y -bb0`。7z 发现链：环境变量 `7Z` → `C:\Program Files\7-Zip\7z.exe` → PATH。GitHub windows runner 预装 7-Zip；workflow 步骤里补 Chocolatey 兜底（`choco install 7zip -y --no-progress --limit-output`）。
* **别猜 exit code**：对未知原生命令，先确认它是控制台程序还是 GUI 程序再决定调用方式；GUI 程序 `$LASTEXITCODE` 永远不可靠。

## 7. Inno Setup `VersionInfoVersion` 必须是纯数字四段

* **现象**：ISCC 编译 Git 安装时报 "Value of [Setup] section directive VersionInfoVersion is invalid"，指向 `VersionInfoVersion={#MyAppVersion}`。
* **根因**：`VersionInfoVersion` 写入 Windows PE 资源（FileVersion），规范要求必须是 `a.b.c.d` 四段纯数字；Git 的 tag `2.56.0.windows.2` 含字面 token `.windows.`，ISCC 把它当版本号解析时拒绝。
* **规则**：Git 打包传**两个** ISCC define：`MyAppVersion=2.56.0.windows.2`（完整 tag，用于 `AppVersion`、`AppVerName`、卸载显示名等所有**显示字符串**），`MyAppNumericVersion=2.56.0.2`（纯数字，用于 `VersionInfoVersion`）。build.ps1 里已有的 `$AssetVersion` 正好就是这个数值，直接传给 ISCC 即可。
* **其他打包环境**：pnpm / PHP 版本号本身就是纯数字，`VersionInfoVersion={#MyAppVersion}` 够用。将来若遇到带非数字 token 的版本号（如某些 `-beta`、`-alpha` 后缀），按同样模式拆分显示版号和数值版号。

## 8. GitHub Actions 中 `GITHUB_TOKEN` 必须显式注入 build step

* **现象**：CI 构建 Git 时 `Invoke-RestMethod` 报 `API rate limit exceeded for <IP>`，且错误消息明确说是未认证请求（`Anonymous requests get a higher rate limit`）。匿名限额 60 req/h 很快用完，认证后是 1000 req/h。
* **根因**：虽然 GitHub Actions 会自动给每个 workflow 注入 `GITHUB_TOKEN`，但在 Windows runner 的 PowerShell step 里它**不一定能被脚本进程正确继承**——build.ps1 里 `if ($env:GITHUB_TOKEN)` 判定为空，退化为匿名请求。pnpm workflow 此前也没显式传 token，只是碰巧没撞上 IP 积累的匿名限额。
* **规则**：每个调用 GitHub Releases API 的构建 step 必须显式注入 token：

```yaml
- name: Build Git installer
  shell: powershell
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: |
    & .\builders\git\build.ps1 ...
```

* build.ps1 内部逻辑不变——只要 `$env:GITHUB_TOKEN` 非空就加 `Authorization: Bearer` 头。两个 workflow（Git / pnpm）都按此模式处理。

### 4.4 PowerShell 5 语法约束

* 不支持 `&&` / `||`：顺序执行用 `;`，条件执行用 `if ($LASTEXITCODE -eq 0)`。
* git 命令加 `$env:GIT_PAGER='cat'` 防分页挂起；git 的进度信息走 **stderr**（工具里显示为红色/Error 样式属正常），以 `git ls-remote` 等实际结果判断成败，不看颜色。

### 4.5 EAP=Stop 下原生命令写 stderr 会变成终止错误

* **现象**：`$ErrorActionPreference='Stop'` 的构建脚本里执行 `composer.phar --version`，命令明明退出码 0、输出正常，步骤却直接终止，报 `NativeCommandError`，内容只是 Composer 的信息行 `PHP version 8.5.11 (...)`。
* **根因**：PS 5.1 在 EAP=Stop 时把原生命令的**任何 stderr 输出**都转成终止性 `NativeCommandError`（`2>&1` 合流也躲不开）；Composer 会向 stderr 打一行 PHP 版本提示。此前冒烟的 `php -v`、`nilpack --version` 不写 stderr，所以从未触发。
* **规则**：对已知会写 stderr 的原生命令，调用点局部放宽 EAP 并显式接住退出码：

```powershell
$prevEap = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$out = (& $exe --version 2>&1) -join "`n"
$code = $LASTEXITCODE
$ErrorActionPreference = $prevEap
if ($code -ne 0) { throw ... }
```

## 5. 网络与环境

### 5.1 本机沙箱可能阻断 github.com，但 CI runner 不受影响

* **现象**：本地 `Invoke-WebRequest https://github.com/...` 超时，而 `api.github.com` 可达。
* **应急取物**：通过 API 资产端点下载（先 `repos/:o/:r/releases/tags/<tag>` 取 asset id，再请求 `repos/:o/:r/releases/assets/<id>` 并带 `Accept: application/octet-stream` 与 `User-Agent` 头），并核对字节数与 API 元数据一致。
* **规则**：构建脚本的下载 URL 保持标准 `github.com/.../download/...`（runner 网络正常），不为本机网络加特殊分支。

### 5.2 本机需要完整构建时用便携 ISCC，不污染系统

* 从 choco API 下载 innosetup nupkg（zip），取出 `tools/innosetup-<ver>.exe`，以 `/VERYSILENT /CURRENTUSER /DIR=<repo>\build\cache\iscc` 安装到构建目录，再用 `$env:ISCC` 指向；build.ps1 按 `ISCC` 环境变量 → 标准安装目录 → PATH 的顺序查找。

## 6. 安装器行为模式（复用基线）

* 包内命令包装器固定模式：`"%~dp0php.exe" "%~dp0nilpack.phar" %*`，靠 `%~dp0` 自定位，与调用方 CWD 无关。需要写 Phar 的包装器（`nil.bat`）额外带 `-d phar.readonly=0`——PHP 默认 `phar.readonly=1`，不改 ini 也能让该次调用可写 Phar。
* 安装目录相关配置用 `__APP_DIR__` 占位符写进文件，`CurStepChanged(ssPostInstall)` 时按 `{app}` 替换，改安装目录也不出错。
* PATH 改写：按分号拆分、大小写不敏感比较、去空条目后幂等重写；安装追加、卸载精确删除自身条目。
* 每次改 setup.iss 后必做：静默安装到**非默认目录** → 注册表 PATH + 裸命令验证 → 静默卸载 → 文件/PATH 双清零验证。

## 9. vc_redist.x64.exe 是 WiX Burn 包，解包用 dark.exe + msiexec /a

* **现象**：构建期想从官方 `vc_redist.x64.exe` 提取 CRT DLL 时连踩三坑——7-Zip 报 `Cannot open the file as archive`；`/layout <dir> /quiet` 退出码 `-2147024891`（0x80070005，拒绝访问）；本机也没有 Visual Studio 的 `VC\Redist` 目录可借。
* **根因**：vc_redist 是 WiX **Burn** 引导包（不是自解压压缩包），7-Zip 不支持该格式；`/layout` 因 exe 清单要求管理员权限，提权后 Burn 引擎固定写 `C:\Windows\Temp\{GUID}`（忽略 TEMP 重定向），受限沙箱/CI 外部环境下直接失败。
* **规则**：离线解包链——WiX 3.14 官方 `wix314-binaries.zip` 中的 `dark.exe -nologo -x <dir> vc_redist.x64.exe` 解出载荷（`AttachedContainer\packages\vcRuntimeMinimum_amd64\vc_runtimeMinimum_x64.msi` + cab1.cab），再 `msiexec /a <msi> /qn TARGETDIR=<dir>` 管理安装提取，DLL 落在 `<dir>\System64\`。全程无需提权、不写系统目录，本地沙箱与 GitHub runner 行为一致。核心 CRT 7 DLL 均在 Minimum 包内（vcruntime140(+_1)、msvcp140(+_1/_2/_atomic_wait/_codecvt_ids)），concrt/vccorlib/vcamp/vcomp/vcruntime140_threads 按需另行评估。
* **别忘**：`msiexec` 是异步进程，PowerShell 里用 `Start-Process -Wait -PassThru` 拿退出码，直调 `&` 可能提前返回。

## 10. xwin splat 是 move（rename）语义，cache/unpack/output 必须同盘

* **现象**：CI 上 `xwin --temp splat --output D:\...\stage\rust\sdk` 报 `failed to move ...\unpack\... to \\?\D:\...`，`os error 17`（The system cannot move the file to a different disk drive）。
* **根因**：splat 默认把文件从解压目录**移动**到输出目录；`--temp` 固定把解压目录放 `%TEMP%`（runner 上是 C 盘），与 D 盘的 output 跨盘，Windows rename 不支持跨盘。
* **规则**：用 `--cache-dir <build>\cache\xwin` 而不是 `--temp`——cache、unpack、output 同盘时 move 是零成本 rename；`build\cache` 本来就 gitignore，不污染 repo，重跑还能复用已下载的包。凡"解压/暂存 → move 到目标"类工具（xwin、robocopy /MOV 等）都要先确认两侧在同一卷。
* **旁证**：xwin 的 `splat` 会自动串联 download+unpack，无需分步执行；`--disable-symlinks` 对 Windows 暂存树**没有**意义（详见 §14：`symlink()` 在 Windows 上是空操作，但 `symlink_on_windows_too()` 仍会造出目录链接）。

## 11. `$ErrorActionPreference='Stop'` 下 `2>&1` 捕获 stderr 会误杀成功的原生命令

* **现象**：CI 上 `cargo new --bin --vcs none helloworld 2>&1 | ForEach-Object { ... }` 抛 `NativeCommandError`，log 里只有 cargo 的**成功**提示 `Creating binary (application) \`helloworld\` package`，构建步骤却以退出码 1 失败。
* **根因**：cargo 把全部人读进度（`Creating binary`、`Compiling`、`Finished`）写到 **stderr**。PowerShell 5.1 在 `$ErrorActionPreference='Stop'` 下，一旦原生命令的 stderr 被 `2>&1` 重定向进管道，就会把**第一行 stderr** 当成终止性 `NativeCommandError` 抛出——与命令真实退出码无关，命令其实成功了。
* **规则**：凡需要 `2>&1` 收集原生命令（cargo/rustc/clang/npm 等）输出，调用前后必须临时切 `$ErrorActionPreference='Continue'` 并在 `finally` 还原（本仓库 build.ps1 的两处 `--version` 检查与 cargo build 冒烟块都照此处理）。或者干脆**不重定向**，让 stderr 直接进主机（不重定向就不会触发该错误），只靠 `$LASTEXITCODE` 判成败。
* **判定诀窍**：报错文本是命令行自身的正常输出、且 `FullyQualifiedErrorId` 为 `NativeCommandError` 时，几乎都是这个坑，而非命令真的失败。

## 12. Rust dist 组件 tarball 内层目录名不一致（rust-std 带 target 后缀）

* **现象**：`cargo build` 报 `error[E0463]: can't find crate for 'std'` 并提示 `rustup target add x86_64-pc-windows-msvc`，但 rust-std 组件其实已下载并合并进暂存树。
* **根因**：`rustc-<ver>-<host>.tar.gz` 的内层载荷目录名等于组件名（`rustc/`、`cargo/`），但 `rust-std-<ver>-<host>.tar.gz` 的内层目录是 **target 后缀名** `rust-std-<target>/`。按 `Join-Path <versionDir> 'rust-std'` 取会落空；一旦 fallback 成"整个版本目录"，载荷就被多套一层，std 落到 `<stage>\rust-std-<target>\lib\rustlib\<target>\lib`。而 rustc 的 sysroot 是 `bin\` 的父目录，期望在 `<stage>\lib\rustlib\<target>\lib`，于是找不到 std。
* **规则**：解 Rust dist 组件 tar 包后，载荷目录一律按"版本目录下唯一的子目录"通用取（优先匹配 `组件名` 或 `组件名-*`），不要假设内层目录名恒等于组件名。合并后立即断言 `lib\rustlib\<target>\lib` 存在，把 E0463 提前成明确报错。

## 13. 本地用便携 ISCC 预编译 setup.iss，一次抓完所有只在编译期暴露的错误

* **现象**：Rust 安装器 `setup.iss` 的错误只在 ISCC 编译期出现，且**串行**——修完一个才看得见下一个：先 `Error on line 176: 'BEGIN' expected`，改完又变成 `lzma: Finish: LZMA_Encode failed with code 5`。
* **根因（两个已验证的坑）**：
  1. **Pascal Script 不允许过程内的局部 `const` 块**（`procedure X; const ...; var ...;`）。`const` 只能放 `[Code]` 顶层全局 const 段，过程里只能有 `var`。把 `const` 写在过程里会报 `'BEGIN' expected`。
  2. `LZMADictionarySize` 超过 ISCC 实际可分配的字典上限时，报的是 `LZMA_Encode failed with code 5`，而不是清晰的"参数超范围"。实测本机便携 ISCC：`131072`（128 MB）通过，`163840`（160 MB）及以上全部失败——**可用上限即 128 MB**（与 PHP 包取值一致）。Rust 原本写的 `262144`（256 MB）必然编译失败。
* **规则**：改 `setup.iss` 后先本地预编译一遍（秒级，见 §5.2 便携 ISCC），造一个**极小的假暂存树**当 `StageDir`，带上 `MyAppVersion` 等 define 直接跑 ISCC，把 Pascal / 压缩类错误一次性抓完，再推 CI。另：TOML/配置里含连续单引号的字面量不要手数引号，定义全局常量 `Q = ''''`（一个单引号字符）再拼接，可证明引号平衡。

## 14. 暂存树里的自引用目录链接会让 ISCC 报"无行号"错误（Windows 上 xwin 必产）

* **现象**：Rust 安装器 CI 到 "Compiling installer" 即失败，报
  `Error in D:\a\win-env\win-env\builders\rust\setup.iss: The system cannot find the path specified.`（**不带行号**），exit code 2。同一份 setup.iss、同一个 ISCC 6.7，`[Files]` 源树换成 node 那种无链接的树就正常；`cargo build` 冒烟测试也已通过，说明暂存内容本身是好的。
* **根因**：xwin `splat` 在 Windows 上把 `symlink()` 实现为空操作（`#[cfg(windows)] fn symlink -> Ok(())`），但 `symlink_on_windows_too()` **不是**空操作——处理 SdkLibs / SdkHeaders 时它会创建 `sdk\lib\<sdkversion>` 与 `sdk\include\<sdkversion>` 两个**目录链接**，目标硬编码为 `"."`，即链接指向自己的**父目录**，构成环（`sdk\lib\10.0.26100.0` → `sdk\lib`）。这两个链接在 `if config.enable_symlinks` 之外，**`--disable-symlinks` 挡不住**。Inno Setup 的 `[Files] recursesubdirs` 扫描顺着环回到父目录，路径长度迅速溢出，以 `ERROR_PATH_NOT_FOUND` 中止；此类**扫描期**错误不带行号。
* **复现与验证**（本地便携 ISCC 6.7，秒级）：合成暂存树里只在 `sdk\lib`、`sdk\include` 下各放一个指向**父目录**的链接，即稳定复现同一条无行号 `Error in <setup.iss>: 系统找不到指定的路径。` + exit 2；删掉这两个链接后，同一条 ISCC 命令 exit 0 并正常出包（真实 SDK 目录内容未受影响）。
* **错误消息分流表**（无行号 + exit 2 的三类，本机中文 / runner 英文）：

| 源树里的东西 | 消息 | OS 错误码 |
| --- | --- | --- |
| 目录链接成环（自引用） | `系统找不到指定的路径` / `The system cannot find the path specified.` | `ERROR_PATH_NOT_FOUND` |
| 文件软链悬空 | `系统找不到指定的文件` / `The system cannot find the file specified.` | `ERROR_FILE_NOT_FOUND` |

  与之相对，`Source` 目录不存在（`No files found matching`）、`SetupIconFile` 缺失、`MessagesFile` 缺失、Pascal/压缩错误这些**能定位**的问题都会带 `on line N` 或具体值，可据此先分流。悬空**目录**链接（非环）与有效链接 ISCC 都能容忍（exit 0），别只凭"链接"二字下结论。
* **规则**：暂存树交给 ISCC 前必须**不含任何重解析点**。build.ps1 在 xwin splat 之后、冒烟测试之前清理：枚举 `$StageDir` 下所有带 `ReparsePoint` 属性的条目并删除，随后复查确认为 0。**目录链接必须用 `[IO.Directory]::Delete($p, $false)` 非递归删除**——用 `Remove-Item -Recurse` 会顺着链接把目标（父目录）里的真实文件一起删掉。setup.iss 只用不带版本号的 `sdk\lib\...` 路径，这些版本别名对本包无用，删除无副作用。

## 15. rustc 组件自带 rust-lld，`gcc-ld\lld-link.exe` 是按相对路径拉起它的包装器

* **背景**：Rust MSVC 打包最初为拿到 `linker = "lld-link"`，从 LLVM 官方 Release 下载整个 Clang 包（约 250 MB）再用 7-Zip 解压提取 `lld-link.exe`——既慢又引入外部工具依赖，还硬编码了 LLVM 版本。
* **事实（本地实测，直接查 rustc 组件 tar.gz）**：`rustc-<v>-x86_64-pc-windows-msvc.tar.gz` 内已含
  * `lib\rustlib\x86_64-pc-windows-msvc\bin\rust-lld.exe`——真正的多 flavor LLD 驱动（约 122 MB，全静态）；
  * `...\bin\gcc-ld\{ld.lld,ld64.lld,wasm-ld,lld-link}.exe`——极小的按名分派包装器（`lld-link.exe` 约 325 KB）。
* **包装器行为**：`gcc-ld\lld-link.exe` **不是**自包含链接器，它按**自身所在目录的相对路径**去找并拉起 `rust-lld`。实测：在组件原始布局（包装器在 `...\bin\gcc-ld\`、驱动在 `...\bin\`）下 `lld-link.exe --version` 正常返回 `LLD <ver>`，带真实参数时报的是 `rust-lld: error: ...`（证明子进程已跑起来）；把它单独拷到别的目录（或拷到 `bin\` 而不带驱动）即报 `lld-wrapper: error running rust-lld child process: 系统找不到指定的文件。 (os error 2)`。
* **规则**：直接用 rustc 自带的 LLD——cargo 的 `linker` 指向**安装目录内** `lib\rustlib\x86_64-pc-windows-msvc\bin\gcc-ld\lld-link.exe` 的绝对路径，且**必须保持组件原始相对布局**（不要单独搬运 `lld-link.exe`）。如此可彻底移除 LLVM 下载、7-Zip 依赖与硬编码版本，且 LLD 版本与 rustc 天然一致。冒烟测试**就地**调用该包装器 `--version`，即可顺带证明 `rust-lld` 子进程可被发现。

## 16. rustfmt / clippy 的组件名带 `-preview`，归档文件名不带

* **现象**：给 Rust 包补 rustfmt / clippy 时，按 `pkg.rustfmt` / `pkg.clippy` 去 channel TOML 里找组件节，**两个都搜不到**（全文无匹配）；若按"组件名"拼下载 URL（例如 pinned 版本重建 `rustfmt-preview-<ver>-<target>.tar.gz`），下载必然 404。
* **事实（拉真实样本实测：2026-10-15 的 `channel-rust-stable.toml` + 两个组件归档 `tar -tzf` / `manifest.in`）**：
  * channel 里的组件节名是 `[pkg.rustfmt-preview.target.x86_64-pc-windows-msvc]`、`[pkg.clippy-preview.target.x86_64-pc-windows-msvc]`，**带 `-preview`**；
  * 同一节 `url` 值指向的文件名却是 `rustfmt-1.99.1-x86_64-pc-windows-msvc.tar.gz`、`clippy-1.99.1-x86_64-pc-windows-msvc.tar.gz`，**不带 `-preview`**；
  * 归档内层：版本目录 → 组件目录（名字 **= 组件名**，即 `rustfmt-preview/`、`clippy-preview/`）→ `bin\rustfmt.exe`、`bin\cargo-fmt.exe` / `bin\clippy-driver.exe`、`bin\cargo-clippy.exe`；两者的 `manifest.in` 都同时列出 `*.pdb`，说明**全量拷贝组件目录 = 官方安装内容**（官方也装这些 PDB）。
* **规则**：组件表把"**解析键 / 内层合并目录名**（带 `-preview`）"与"**归档文件名前缀**（不带 `-preview`）"分成两个字段分别存放（本仓库为 `Name` 与 `FileStem`），重建 URL 只用后者，否则 404 或合并目录取空（fallback 会多套一层）。rustfmt / clippy 的全部可执行文件都落在 `bin\`（`cargo fmt` / `cargo clippy` 靠 PATH 找 `cargo-fmt.exe` / `cargo-clippy.exe`），因此必须与 `cargo.exe` 同处 `bin\`——即加入系统 PATH 的那个目录。按此规则补组件后，`[Files]` 源树自然包含它们，安装器无需额外改动。
