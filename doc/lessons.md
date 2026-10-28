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

* **补充（2026-10-19 本机实测）**：缺 BOM 不只是"中文乱码"——它会让 PS 5.1 **解析失败**。用一个**无 BOM、含中文注释**的脚本跑 `Parser::ParseFile`，报 `line 67 col 1: Unexpected token '}'`（该文件括号实为配平、终末 depth 为 0，正文完全合法），补一个 BOM 后 `parseErrors` 立刻归 0。原因：无 BOM 时 PS 5.1 按 ANSI 代码页解码，中文注释字节被曲解后撞坏词法分析，症状表现为"看起来像语法错误、但人眼查不出错"的假报错。故"含非 ASCII ⇒ 必须带单 BOM"是**解析正确性**要求，不是观感要求。

### 1.2 PS 5.1 的 `Out-File -Encoding utf8` 会写 BOM

* **现象**：即使脚本解析正确，写出的 release-notes.md / build-info.json 仍可能带 BOM，GitHub 正文开头出现残留字符。
* **规则**：写 UTF-8 文本统一用：

```powershell
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[IO.File]::WriteAllText($path, $content, $utf8NoBom)
```

`.bat` 包装器等纯 ASCII 文件用 `ASCIIEncoding`；生成的 php.ini 同样用无 BOM UTF-8。

### 1.3 `.ps1` 出现**双 BOM** 会让 PS 5.1 解析直接失败（`InvalidLeftHandSide`）

* **现象（2026-10 CI 实测，gnu 路线 `builders/opencv-shim/build.ps1`）**：脚本停在**解析阶段**，报 5 条 `The assignment expression is not valid. The input to an assignment operator must be an object that is able to accept assignments, such as a variable or a property.`（`FullyQualifiedErrorId: InvalidLeftHandSide`），位置集中在 `param()` 块——`[string]$Stage = "all"`、`[string]$OpenCvSrc = ""` 等（行 45/47/48/49/50），步骤 `exit 1`，没有任何运行时输出。
* **根因**：文件头是**双 BOM**（`EF BB BF EF BB BF`）。PS 5.1 只消化第一个 `EF BB BF`，第二个 BOM 被当成**正文首个字符 U+FEFF** 进入词法分析，紧随其后的 `param(` 于是被解析成表达式而非关键字，`param()` 内每个 `[类型]$变量 = 值` 都报"赋值号左侧不是可赋值对象"。
* **本机实测（PS 5.1.19041）**：`[System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)` 复现出**同样 5 条错误、行号与 CI 完全一致**；字节检查 `BOM count = 2`；去掉多余 BOM 后 `parseErrors = 0`（文件仅少 3 字节，正文内容零改动）。
* **规则**：`.ps1` 只允许**一个** `EF BB BF`。用 AI/编辑器批量改脚本后别只问"有没有 BOM"，要数**有几个**；消除多余 BOM 用字节级重写（先 `ReadAllBytes`，再 `TrimStart([char]0xFEFF)` 后补回单 BOM）：

```powershell
$f = 'builders\opencv-shim\build.ps1'
$b = [IO.File]::ReadAllBytes($f)
$text = [Text.Encoding]::UTF8.GetString($b).TrimStart([char]0xFEFF)
[IO.File]::WriteAllBytes($f, [byte[]](0xEF,0xBB,0xBF) + [Text.Encoding]::UTF8.GetBytes($text))
```

**体检方法**：全仓库扫描 `Get-ChildItem -Recurse -Filter *.ps1`，对每个文件数 `EF BB BF` 出现次数并跑 `Parser::ParseFile` 数错误，一次揪出所有解析期隐患（本轮据此确认 12 个 `.ps1` 中仅 `builders/opencv-shim/build.ps1` 异常，其余 `BOM=1 parseErrors=0`）。

* **复发与症状变体（2026-10-19，`setup-mingw.ps1`）**：一次"修复"提交误把**合法单 BOM**（`EF BB BF 3C 23 …`）当成"多余前导字符"，往行首又补了一个 U+FEFF（`<#` 前变双 BOM），方向做反造成复发。症状随双 BOM 后的首个 token 改变：这次紧跟 `<#` 块注释，整个注释头被当代码解析，报的不再是 `InvalidLeftHandSide`，而是注释文本深处才浮现的 `The 'from' keyword is not supported` / `The '<' operator is reserved for future use` / `The ampersand (&) character is not allowed` / `Unexpected attribute 'CmdletBinding'`（首条错误在行 7 而非行 1，因为注释里恰好有能"凑合解析"的命令行）。**规则**：动文件头之前先 `ReadAllBytes` 看前 6 字节——`EF BB BF 3C 23` 是"单 BOM + `<#`"的**正常**形态，处理"多余前导字符"只删不添；诊断一律以字节为准，别按编辑器里可见的 `﻿` 或 Read 工具的渲染猜测。

* **自动闸门（已落地，2026-10-19）**：`scripts/check-ps1.ps1` 由 `.github/workflows/lint-ps1.yml` 在每次 `push`/`pull_request` 调用，逐文件断言"BOM 不多于一个""含非 ASCII 必带单 BOM""`Parser::ParseFile` 零错误"，违规即列清单（附 head 十六进制字节，直接指出该删还是该补）并 throw；本地与 CI 是同一份脚本，从此**不再需要人工复查文件头**。闸门逻辑本身已在临时目录用植入样本实测：双 BOM、缺 BOM 的中文脚本、真实语法错误各命中且措辞准确，纯 ASCII 带 BOM 与正常文件不误伤。

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

### 3.3 PS 5.1 的 `ConvertFrom-Json` 不展开 JSON 数组

* **现象**：`'["a","b"]' | ConvertFrom-Json` 放进 `@()` 后 `Count` 是 **1**，`-contains 'a'` 恒为 false——用它比对 release 资产名时，齐全的资产清单会被误判成"缺资产"，脚本 throw。
* **根因**：PS 5.1 的 `ConvertFrom-Json` 把整个 JSON 数组当作**单个** `Object[]` 对象返回，`@()` 再包一层仍是 1 个元素（PS 7 才按管道展平）。
* **规则**：机器判据优先让 `--jq` / `-o` 直接输出逐行文本，再用 `-split "`r?`n"` 拆数组；必须解析 JSON 数组时双层展开 `foreach ($x in @($json | ConvertFrom-Json)) { foreach ($y in @($x)) { ... } }`。本仓库 `publish-alias-release.ps1` 的资产闸门用 `--jq '.assets[].name'` 逐行解析。

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

### 4.6 `powershell -File` 外起进程时会丢掉空字符串实参

* **现象**：workflow 想用 `powershell -ExecutionPolicy Bypass -File setup-mingw.ps1 -Mirror ''` 传"空镜像 = 直连 GitHub"，子进程却报 `Missing an argument for parameter 'Mirror'. Specify a parameter of type 'System.String' and try again.`，参数绑定直接失败；同一命令在当前会话内用 call 运算符调用（`& .\setup-mingw.ps1 -Mirror ''`）则正常拿到空字符串。
* **根因（实测三种调用方式）**：PS 5.1 把实参拼成子进程命令行时，**空字符串实参被整体丢弃**（`''` 不产生任何 token），于是 `-Mirror` 后面没有值；`& <script> -Mirror ''`（会话内）与 `-Command "& ... -Mirror ''"` 都能正确保住空串。
* **规则**：要给脚本传**空字符串**时，用会话内调用（`& <script> -Mirror ''`，本仓库 workflow 统一如此，见 build-rust.yml）；不要用 `powershell -File ...` 外起进程。若必须外起进程，把"空"表达成显式开关（如 `-Direct`）或干脆不传该参数。

### 4.7 `cmd /c 'call "' + $vcvars + '" ...'` 不会拼接：命令参数模式把 `+` 当普通词

* **现象（2026-10 CI 实测，MSVC 路线 dumpbin 门禁步骤）**：`'""' is not recognized as an internal or external command, operable program or batch file.`，紧接着 `imports: `（空），步骤 `exit 1`。
* **根因**：`$out = cmd /c 'call "' + $vcvars + '" >nul && dumpbin ...'` —— PowerShell 的**命令参数模式**不执行 `+` 运算，`'call "'`、`+`、`$vcvars`、`+` … 被当成一串彼此独立的实参交给 cmd，拼不出成型命令行，cmd 就把 `""` 当命令去执行。同一文件里"先把命令行拼进字符串变量、再 `cmd /c $cmd`"的写法不受影响（这正是 build / compile 步骤能跑通的原因）。
* **本机实测（PS 5.1）**：同一段文本，内联形式输出 `'""' is not recognized ...` 且退出码 1；`$cmd = '...' + ...; cmd /c $cmd` 形式正常执行、退出码 0。
* **规则**：给 `cmd /c` 传命令行时先拼进一个字符串变量再传，不在实参位置写 `+` 拼接。**附带必做**：门禁/校验步骤要断言"确实跑出了东西"（如 `if (-not $deps) { throw 'the gate did not run' }`），否则 cmd 拼坏时输出为空、过滤结果也为空，门禁会**静默假通过**。

### 4.8 原生命令直接管进 `Select-Object -First N` 会杀掉进程，留下非 0 的 `$LASTEXITCODE`

* **现象（2026-10 CI 实测，gnu 路线 setup-mingw.ps1）**：脚本已打印完最后一行 `[setup] Done: ...`，步骤仍 `exit 1`。
* **根因**：脚本里唯一未校验的原生命令是末行的 `& $Gxx --version | Select-Object -First 1`。`Select-Object -First N` 拿到 N 个对象即**终止整条管道**，PS 随之 Kill 上游原生命令——进程若尚未自然退出，`$LASTEXITCODE` 就留在非 0（本机 PS 5.1 实测：持续大量输出的原生命令被中断后 `$LASTEXITCODE = -1`；CI 里 g++ 输出很短，抢在 Kill 前因断管自行退出，留下退出码 1）。GitHub Actions 的 PowerShell 包装器结尾是 `if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit $LASTEXITCODE }`，于是"脚本明明成功、步骤却失败"，且报错里没有任何可读信息。
* **规则**：不要把原生命令**直接**管进 `Select-Object -First N`。先把完整输出收进变量（`$lines = & $exe --version`），再从数组取前几行——此时管道下游只是数组、不会中断任何进程；并顺带显式校验退出码（`if ($LASTEXITCODE -ne 0 -or -not $lines) { throw }`），让探针失败时给出可读错误而不是裸退出码。

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
* **旁证（2026-10）**：`gh release view <tag>` 查不存在的 release 时把 `release not found` 写到 stderr、退出码 1——这是"该版本尚未发布"的**正常分支**，但 EAP=Stop + `2>&1` 会直接打挂步骤（本机复现：`test-release-published.ps1` 首行就抛 `NativeCommandError`）。按本条规则用局部 `EAP=Continue` 的 `Invoke-Gh` 包装、只取退出码与输出文本即可。

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

## 15. rustfmt / clippy 的组件名带 `-preview`，归档文件名不带

* **现象**：给 Rust 包补 rustfmt / clippy 时，按 `pkg.rustfmt` / `pkg.clippy` 去 channel TOML 里找组件节，**两个都搜不到**（全文无匹配）；若按"组件名"拼下载 URL（例如 pinned 版本重建 `rustfmt-preview-<ver>-<target>.tar.gz`），下载必然 404。
* **事实（拉真实样本实测：2026-10-15 的 `channel-rust-stable.toml` + 两个组件归档 `tar -tzf` / `manifest.in`）**：
  * channel 里的组件节名是 `[pkg.rustfmt-preview.target.x86_64-pc-windows-msvc]`、`[pkg.clippy-preview.target.x86_64-pc-windows-msvc]`，**带 `-preview`**；
  * 同一节 `url` 值指向的文件名却是 `rustfmt-1.99.1-x86_64-pc-windows-msvc.tar.gz`、`clippy-1.99.1-x86_64-pc-windows-msvc.tar.gz`，**不带 `-preview`**；
  * 归档内层：版本目录 → 组件目录（名字 **= 组件名**，即 `rustfmt-preview/`、`clippy-preview/`）→ `bin\rustfmt.exe`、`bin\cargo-fmt.exe` / `bin\clippy-driver.exe`、`bin\cargo-clippy.exe`；两者的 `manifest.in` 都同时列出 `*.pdb`，说明**全量拷贝组件目录 = 官方安装内容**（官方也装这些 PDB）。
* **规则**：组件表把"**解析键 / 内层合并目录名**（带 `-preview`）"与"**归档文件名前缀**（不带 `-preview`）"分成两个字段分别存放（本仓库为 `Name` 与 `FileStem`），重建 URL 只用后者，否则 404 或合并目录取空（fallback 会多套一层）。rustfmt / clippy 的全部可执行文件都落在 `bin\`（`cargo fmt` / `cargo clippy` 靠 PATH 找 `cargo-fmt.exe` / `cargo-clippy.exe`），因此必须与 `cargo.exe` 同处 `bin\`——即加入系统 PATH 的那个目录。按此规则补组件后，`[Files]` 源树自然包含它们，安装器无需额外改动。

## 16. Rust channel TOML 的 per-target 组件节是双括号数组表，单括号匹配会漏解析

* **现象**：解析 `channel-rust-stable.toml` 取各组件（`rustc` / `cargo` / `rust-std` / `rustfmt-preview` / `clippy-preview`）的 per-target 下载 URL 时，若按 `[pkg.<name>.target.<target>]` 单括号节名匹配，**一个 URL 都取不到**，脚本随即以"解析为空"终止。
* **根因**：PS 5.1 无内置 TOML 解析器，需自行按行扫描；而官方 channel TOML 里 per-target 组件节用的是 **`[[...]]` 双括号数组表**语法（如 `[[pkg.rustc.target.x86_64-pc-windows-msvc]]`），顶层 `date`、`[pkg.rust]` 等才是单括号表。只认单括号就会与双括号节名擦肩而过，解析结果为空。
* **规则**：按行跟踪"当前节"，节名匹配用 `^\[+(.+?)\]+$` 一次性吃掉 `[` 与 `[[`（剥掉全部方括号得到节路径），再据路径取字段。取组件名要用**节路径**而非 `$Matches[0]`——后续行内的 `url = "..."` 正则会把 `$Matches` 覆盖成 URL 行。实现见 `builders/rust/build.ps1` 第 1 节的解析循环。

## 17. postgresql.org versions.json 的主版本号是裸数字，`[version]` 直接转换会抛错

* **现象**：PostgreSQL 包按"最高 supported 主版本"选版本时，`Sort-Object { [version]$_.major }` 抛 `Cannot convert value "14" to type "System.Version". Error: "Version string portion was too short or too long."`，构建立刻在发现阶段终止。
* **根因**：`versions.json` 的 `major` 在 10 及以上是**裸主版本号**（`"14"`、`"18"`），10 以下才是点分形式（`"6.3"`、`"7.4"`）；而 `System.Version` 要求至少 `major.minor` 两段。`latestMinor` 同样是裸 minor（`"6"`），完整版本号必须自行拼成 `<major>.<latestMinor>`。
* **规则**：解析上游版本字段前先拉真实样本核对形态（见 §16 同类教训）。本仓库 `builders/postgres/build.ps1` 用 `ConvertTo-MajorVersion` 补齐第二段（不足两段补 `'0'`）后再 `[version]`；凡"裸数字主版本号"都按此处理，不要直接丢给 `[version]`。

## 18. PostgreSQL Windows 二进制：URL 可构造，下载页不可机器解析

* **事实（2026-10 实测，含 HTTP Range + .NET `ZipArchive` 读远端中央目录）**：
  * `https://get.enterprisedb.com/postgresql/postgresql-<ver>-<rev>-windows-x64-binaries.zip` **可直接构造**：14.24-1 / 15.19-1 / 16.15-1 / 17.11-1 / 18.6-1 全部 `200`，344 MB 量级；`<rev>` 是 EDB 对同一版本的重新构建序号，从 1 起向上探测。
  * 版本发现走官方 <https://www.postgresql.org/versions.json>（`supported` / `current` / `latestMinor`，机器可读）。EDB 的下载页（`enterprisedb.com/download-postgresql-binaries`、`/downloads/...`）**没有可解析的直链**，只有 `getfile.jsp?fileid=…` 不透明链接 → 不能作为发现入口。
  * 官方 zip 顶层唯一根目录 `pgsql/`（21,968 条目，raw 913.6 MB / 压缩 339.0 MB）；`pgAdmin 4/` 一项就占压缩体积 **274.5 MB（整包的 ~81%）**，是本仓库裁剪的最大单项。
  * **zip 内不含任何 CRT DLL**（`vcruntime140.dll` / `msvcp140.dll` 全 missing）→ 必须 app-local 注入，复用 [doc/php-8.5.md](php-8.5.md) 已验证的 vc_redist 提取链路。
* **规则**：`versions.json`（PostgreSQL 项目维护）领先 EDB 发布（Windows 二进制滞后）——某 minor 的 rev 1..3 全 404 时按 **minor 递减**重试，全部失败即 `throw`，绝不猜 URL。裁剪后必须对真实解压树做白名单断言（删多了比删少了更隐蔽）。

## 19. `--locale-provider` / builtin 是 PG 17 才有的，决定 initdb 默认参数

* **事实**：官方 PG 16 initdb 文档只列 `libc` / `icu` 两个 locale provider，且**没有** `--builtin-locale`；`builtin` provider 与 `--builtin-locale` 是 **PG 17 引入**。PG 16 及更早，locale 由 libc 派生编码（中文 Windows 上会派生出 GBK 类编码与不稳定排序，导致跨机器 dump/restore 不可复现）。
* **规则**：需要"UTF8 + 与宿主 locale 无关的确定性排序"的集群默认值时，版本下限必须定在 **PG 17**；`build.ps1` 在**下载前**按主版本号下限报错终止（不浪费 340 MB 下载），组装后再用 `initdb --help` 复核 `--builtin-locale` 确实存在，避免产出"行为随宿主 locale 变化"的包。

## 20. 禁止直接运行 `postgres.exe`，但 `pg_ctl` / `initdb` 在管理员终端下可用

* **现象（源码核实）**：`src/backend/main/main.c` 的 `check_root()` 在 WIN32 分支调用 `pgwin32_is_admin()`（`src/port/win32security.c`：令牌含 Administrators **或 PowerUsers** 即判为管理员）并直接 FATAL：`Execution of PostgreSQL by a user with administrative permissions is not permitted`。
* **根因**：Windows 上 PostgreSQL 不允许以管理员令牌运行 postmaster。
* **规则**：管理脚本只能经 `pg_ctl.exe` / `initdb.exe` 调起（它们会以**受限令牌**重新执行 postmaster），**绝不直接调用 `postgres.exe`**；因此管理员/提权终端（含 GitHub runner 的管理员令牌）下 `pg-start` 仍可正常工作，无需 `schtasks /ru` 委派这类绕行方案。

## 21. EDB Windows 二进制的头文件是扁平布局（`include\server\...`），不是 `include\postgresql\server\...`

* **现象（2026-10 实测）**：白名单断言 `include\postgresql\server\postgres.h` 失败（`Required file missing after trimming`），实际 EDB zip 的解压树是 `include\server\postgres.h`、`include\internal\`、`include\libpq\`，`include\` 下**没有** `postgresql\` 这一层。
* **根因**：Unix 的 `make install` 会把头文件装到 `$INCLUDEDIR/postgresql/...`，而 EDB 的 Windows MSVC 构建直接把 `src/include` 的目录平铺进 `include\`（`pg_config --includedir-server` 亦指向该扁平目录）。
* **规则**：断言/引用 PG 头文件路径时以**真实解压树**为准（先下载真实样本再写断言，别照搬 Unix 布局）；本仓库用 `include\server\postgres.h` 作为"开发头文件在位"的哨兵文件。

## 22. `initdb -D <dir>` 要求目标目录"不存在或为空"，管理脚本不得预建 `data\`

* **现象（2026-10 安装闭环实测）**：安装后的 `pg-start` 首次启动初始化失败，`initdb` 报
  `initdb: 错误: 目录 "…\data" 已存在，但不为空`（exit 1），首次启动直接卡死。
* **根因**：`pg-start` 在调 `initdb` 之前先 `mkdir "%DATA%\logs"` 并把口令临时文件写到 `%DATA%\win-env.pw.tmp`，使 `-D` 目标目录**非空**；而 `initdb` 明确拒绝"已存在且非空"的目标目录（受控实验：**空目录 exit 0，含任意 1 个文件的目录 exit 1**）。
* **为何没被暂存冒烟测试拦下**：冒烟测试用**独立的 scratch 目录**（`build/cache/pgsmoke`）、且直接调用 `initdb.exe`，不走管理脚本里"先建目录再 initdb"的那段逻辑，因此这条路径漏检；只有**真机静默安装 → 裸命令首次 `pg-start`** 才暴露。教训：管理脚本自身的逻辑要在**安装后的真实路径**上验证，不能只靠暂存树冒烟。
* **规则**：管理脚本初始化集群时，`-D` 目标目录**只允许为空**——先只 `mkdir "%DATA%"`（或干脆不建、让 `initdb` 自建），口令临时文件一律放 `%TEMP%`，`logs\` 及其它运行期文件都在 `initdb` 成功**之后**才创建。

## 23. OpenCV `BUILD_LIST` 剔除 gapi 后，`ade` 目标仍被导出进 `OpenCVModules.cmake`（引用不存在的 `libade.a`）

* **现象（2026-10 CI 实测，OpenCV 4.14.0）**：MinGW 路线 configure shim 时 `find_package(OpenCV)` 失败，栈为 `OpenCVConfig.cmake` → `OpenCVModules.cmake`，报文 `The imported target "ade" references the file "…/x64/mingw/staticlib/libade.a" but this file does not exist`。
* **根因**：`-DBUILD_LIST=core,imgproc` 只在 `OpenCVModule.cmake` 的白名单层剔掉 gapi，但 `modules/gapi/cmake/init.cmake` 在 configure 期仍被求值：`OCV_OPTION(WITH_ADE "…" ON)` 默认开启后经 `DownloadADE.cmake` 创建 `ade` 目标，并被 `ocv_install_target(... EXPORT OpenCVModules ...)` 写进安装出的 `OpenCVModules.cmake`——而 gapi 不在构建列表里，`libade.a` 从不产出。
* **规则**：最小裁剪 OpenCV 时，凡"被 `BUILD_LIST` 剔除但仍会创建副作用目标"的模块，要显式关掉其开关；此处 `-DWITH_ADE=OFF` 命中 `init.cmake` 的 `if(NOT WITH_ADE) return()` 短路，`ade` 目标既不创建也不导出（对已剔除的 gapi 无任何影响）。注意 msvc 路线不走 `find_package`（cl 直编），本不会被这个坏 config 绊到，但仍加同一旗标以保持两条路线旗标集一致。

## 24. OpenCV `cmake --install` 的头文件布局随 host 分支而变；Windows host 下是扁平的 `include\opencv2`（**无** `opencv4` 层）

* **现象（2026-10 CI 实测，OpenCV 4.14.0）**：msvc 路线按目录名检索头文件目录（`Get-ChildItem -Recurse … -Directory -Filter opencv4`）落空，构建在 `opencv4 include dir not found under msvc-install\include` 处终止。
* **根因**：`cmake/OpenCVInstallLayout.cmake` 里 `OPENCV_INCLUDE_INSTALL_PATH` 因 host 而异——Windows host 走 `elseif(WIN32 AND CMAKE_HOST_SYSTEM_NAME MATCHES Windows)` 分支，取 `include`，头文件由 `install(FILES … DESTINATION "${OPENCV_INCLUDE_INSTALL_PATH}/opencv2/…")` 直接落 `<prefix>\include\opencv2\…`；`opencv4` 这一层只在 UNIX / QNX 分支出现（`include\opencv4\opencv2\…`）。同一分支还决定 `OPENCV_CONFIG_INSTALL_PATH "."`、静态库落 `x64/<runtime>/staticlib`。
* **规则**：定位 OpenCV 头文件根目录（`-I`）时**不要假设布局**——递归检索 `opencv_modules.hpp`（必位于 `opencv2\` 内）取其上一级目录作为 include 根，Windows / UNIX 两种布局通吃；检索为空即显式 `throw`，不要退化成"猜一个路径"。

## 25. 手写 cl 链接静态 OpenCV 时，必须显式补齐其传递依赖（zlib / ole32）

* **现象（2026-10 CI 实测，OpenCV 4.14.0 / MSVC 静态 core,imgproc）**：`cl ... /link opencv_core4140.lib opencv_imgproc4140.lib` 报 `LNK2019: unresolved external symbol __imp_CoCreateGuid`（`cv::tempfile`）、`gzputs`/`gzgets`/`gzrewind`/`gzeof`/`gzclose`/`gzopen`（`cv::FileStorage`），合计 `LNK1120: 7 unresolved externals`。
* **根因**：静态 OpenCV 的链接不是"两个模块库"就够——`opencv_core` 还依赖内置 zlib（`FileStorage` 的 gz 系列）与系统库 ole32（`CoCreateGuid`）。走 `find_package` 时这些经模块的 `INTERFACE_LINK_LIBRARIES` 自动带上；绕过它手写 cl，就得自己列全。
* **规则**：绕开 `find_package` 手写链接静态 OpenCV 时，必须补传递依赖：`zlib.lib`（OpenCV 内置 zlib 静态库，装在 `OPENCV_3P_LIB_INSTALL_PATH` = `<prefix>/x64/<rt>/staticlib`，**与模块库同一目录**，故共用同一个 `LIBPATH`，按 glob `zlib*.lib` 取实名）+ `ole32.lib`（Windows SDK 系统库，vcvars 的 LIBPATH 已覆盖）。任何"缺库"报错都以 LNK2019/LNK1120 形式出现，先从未解析符号判断它属于哪个库。

## 26. CI 内查询 GitHub releases API 必须带 token，否则共享出口 IP 易 403

* **现象（2026-10 CI 实测）**：`builders/opencv-shim/setup-mingw.ps1 -Mirror ''` 解析 WinLibs 最新 release 时，`Invoke-RestMethod` 对 `api.github.com` 返回 `(403) Forbidden`，"镜像与直连均不可用"，构建在解析阶段即终止。
* **根因**：匿名访问 GitHub API 限额 60 次/小时且**按出口 IP 计**；GitHub 托管 runner 共享出口 IP，配额极易被同池其它 job 耗尽而 403——同一 workflow 里 `resolve` job 因带了 `secrets.GITHUB_TOKEN` 反而不受影响，恰好反证了这一点。
* **规则**：凡是 CI 内调用 GitHub API 的步骤，都要经 `env:` 注入 `GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}`；脚本侧按"**存在该变量才**加 `Authorization: Bearer`"实现，保证本地匿名直连行为不变（见 [setup-mingw.ps1](../builders/opencv-shim/setup-mingw.ps1)）。

## 27. python.org install-manager 索引 `index-windows.json` 是对象（条目在 `.versions`），当数组读会静默落空

* **现象（2026-10 实测，3.15.0/3.16.0a1 时期）**：`Invoke-RestMethod https://www.python.org/ftp/python/index-windows.json` 之后按数组过滤（`@($doc) | Where-Object { $_.company -eq 'PythonCore' ... }`）**一条都筛不出来**；打印 `@($doc).Count` 得到 **1**，看上去像"文档里只有一条记录"，而实际有 258 条。
* **根因**：该文档顶层是**对象**，不是数组：`{ "next": "...", "versions": [ ...258 条... ] }`。`Invoke-RestMethod` 把它反序列化成 `PSCustomObject`，`@($doc)` 只是把这**一个对象**包成单元素数组，条目列表在 `$doc.versions`。
* **事实（同一次实测）**：条目字段有 `id`、`company`、`sort-version`、`url`、`hash.sha256`、`display-name`。`id` 形如 `<company>-<x.y>[-t]-<arch>`：`company` ∈ {`PythonCore`（常规 CPython）、`PythonEmbed`（embeddable）、`PythonTest`（测试用运行时）}；free-threaded 线把 `t` 挂在次版本号后面（`pythoncore-3.15t-64`），与 `-64` 的锚定正则 `^pythoncore-\d+\.\d+-64$` 天然不相交；`arch` ∈ {`32`,`64`,`arm64`}。`sort-version` 是发现用的排序键：正式版是**纯 `x.y.z`**，预发布带后缀（`3.16.0a1`、`3.15.0b3`）——存在 `pythoncore-3.16-64` 这种"新轨道但只有 alpha"的条目，只有加 `sort-version -match '^\d+\.\d+\.\d+$'` 才不会被它顶掉（否则 `[version]'3.16.0a1'` 转换也会直接抛错）。
* **规则**：解析前先打印顶层属性名（`Get-Member -MemberType NoteProperty`）确认形态，别按"有多个版本 → 一定是数组"推断；下载 URL 与 `hash.sha256` 一律直接取自条目，不自行拼 URL。

## 28. PS 5.1 会把原生命令参数里的内嵌双引号剥掉（含空格的载荷还会被切开）

* **现象（2026-10 实测）**：冒烟测试执行 `& $pyExe -c 'import tkinter; print(tkinter.Tcl().eval("info patchlevel"))'`，Python 实际收到的是 `import tkinter; print(tkinter.Tcl().eval(info)` —— 内嵌 `"` 被删除，且 `info patchlevel` 之间的空格把参数**又切成了两段**，测试以 `SyntaxError: invalid syntax. Perhaps you forgot a comma?` 失败（构建脚本本身没问题，是参数在 PS → en-US CRT 命令行这一层被改写）。
* **根因**：PS 5.1 拼原生命令命令行时不转义参数里的内嵌双引号（该行为到 PS 7 才改善），双引号被解析层吃掉后，剩余文本再按空格分词。
* **规则**：向 `python -c` / `node -e` / `perl -e` 这类命令传脚本载荷时，载荷内部**只用单引号**，PS 侧用双引号字符串包住它（`-c "print(t.eval('info patchlevel'))"`）；确实需要内嵌双引号或多行时，写临时 `.ps`/`.py` 文件或经 stdin 送入，别把它塞进命令行。

## 29. MinGW（posix 线程模型）下 `-static-libgcc -static-libstdc++` 消不掉 `libwinpthread-1.dll`

* **现象（2026-10 CI 实测，gnu 路线 shim 导入表闸门）**：`imports: api-ms-win-crt-*.dll…, KERNEL32.dll, libwinpthread-1.dll, ole32.dll`，闸门报 `unexpected imports: libwinpthread-1.dll, ole32.dll (shim must stay self-contained)` 并 exit 1。该闸门此前从未真正跑到（更早阶段就失败），这是首次看到真实导入表。
* **根因（`libwinpthread-1.dll` 部分）**：WinLibs `x86_64-posix-seh` 是 **POSIX 线程模型**。`-static-libstdc++` 只把 libstdc++ **库本身**静态链入，但**静态 libstdc++ 内部仍动态导入 `libwinpthread-1.dll`**（线程原语走它），而 `-static-libgcc`/`-static-libstdc++` 都**不含** libwinpthread——所以两个开关都设了也消不掉。仅关 OpenCV 的 pthreads 并行框架（`-DWITH_PTHREADS_PF=OFF`）同样不够。
* **规则**：MinGW 上要"单文件、零 C++ 运行库依赖"，用 `-static`（**超集**：把 libgcc、libstdc++、libwinpthread 一并静态链入）而不是只加 `-static-libgcc -static-libstdc++`。OS CRT（`msvcrt.dll`/`ucrtbase.dll`）在 MinGW 上只有导入库、没有静态形式，故仍是动态导入，`KERNEL32.dll` 同理——这属于允许范围。
* **附带（`ole32.dll` 部分）**：`ole32.dll` 是 Windows 自带 OS 组件（OpenCV core `modules/core/src/system.cpp` 的 `cv::tempfile` 用 `CoCreateGuid`），与 `KERNEL32.dll` 同一类，**不是**可再发行运行库，不应判为"破坏自包含"——闸门白名单须纳入它。msvc 路线链接 `ole32.lib` 也会导入该 DLL。

## 30. 按"表头切区段"解析 `objdump -p` 的导出名，在真实 CI 上解析为空——改为整段扫描

* **现象（2026-10 CI 实测，gnu 路线 shim 单导出闸门）**：闸门要从 `objdump -p` 断言"恰有一个导出名 `shim_match_template`"，连续两轮都报 `exports: ` 为空、`expected exactly one export 'shim_match_template', got: ` 并 exit 1。第一轮用 `$out | Select-String '\[Ordinal/Name Pointer\] Table' | Select-Object -First 1` 取 `$header.LineNumber` 再 `$out[$header.LineNumber..($out.Count-1)]` 切片；第二轮改为**显式索引 `for`** 定位同一表头、只收集紧随其后的 `[   N] name` 行。两轮都为空，且第二轮新增的 dump 显示表头之后很快就是 `The Function Table (interpreted .pdata section contents)`——按"表头定位 + 逐行收集"的思路拿不到任何名字条目。
* **根因（经排查后收敛为"方法脆弱"，非单点）**：① `Select-String` 的 `.LineNumber` 并**不**映射为"匹配在捕获数组中的下标"，据此切片会落到错误区间；② 即便改用显式索引，"表头紧跟条目"这一**区段假设**也站不住——表头之后未必紧跟条目行（不同 binutils 版本的表头措辞/排版、表头与后续区段之间可能夹其他行，都会让"首条非条目行即表尾"的 `break` 立刻收摊）。真实 `objdump` 文本格式无法在本机复现（本机无 binutils、binutils 源码站被反爬挡），故**不再依赖任何表头/区段假设**。
* **规则**：解析原生命令（`objdump`/`dumpbin`/`gcc` …）输出时——① 先把整段输出收进变量并校验 `$LASTEXITCODE`、断言非空（同 §4.7 的收口纪律）；② **不做**表头定位/区段切片，直接对**整段**逐行 `Trim()` 后按**条目形状**正则筛选（导出名条目 `^\[\s*\d+\]\s+(\S+)$` 只命中名字；Export Address Table 行 `[   N] +base[   M] 1234 Export RVA` 因含空格 token 不会误配）；③ 结果不符合预期时 `Write-Host` dump **整段**原始输出（不是某个窗口），让格式意外在下一轮完全自诊断。

```powershell
$out = & objdump.exe -p $dll; if ($LASTEXITCODE -ne 0) { throw "objdump failed: $LASTEXITCODE" }
if (-not $out) { throw 'objdump produced no output' }
$names = @()
foreach ($raw in $out) { $l = $raw.Trim(); if ($l -match '^\[\s*\d+\]\s+(\S+)$') { $names += $Matches[1] } }
if ($names.Count -ne 1 -or $names[0] -ne 'shim_match_template') {
  $out | ForEach-Object { Write-Host $_ }   # dump every line on failure
  throw "expected exactly one export 'shim_match_template', got: $($names -join ', ')"
}
```

* **本机复现验证**：构造两份 mock `objdump -p` 输出（表头分别写作 `[Ordinal/Name Pointer] Table` 与 `[Name Pointer/Ordinal] Table`，都含一行 `[   0] shim_match_template` 与若干 `[   N] +base[   M] 1234 Export RVA` 干扰行），整段扫描法对两份都稳定提取**恰一条** `shim_match_template`；纯干扰行输出提取 0 条（不会误配）。

## 31. `objdump -p` 的导出名解析第二次仍为空——放弃文本解析，改为直读 PE 导出目录

* **现象（2026-10 CI 实测，gnu 路线 shim 单导出闸门）**：按 §30 改成"整段逐行按条目形状筛选"后，CI **仍然**报 `exports: ` 为空、`expected exactly one export 'shim_match_template', got: ` 并 exit 1。至此三轮写法（`Select-String` 取表头行号切片 → 显式索引定位表头收集 → 整段形状筛选）全部拿到空集合，而**同一份 `objdump -p` 输出、同一套捕获管线**在紧邻的**导入表**闸门里正常工作（`Select-String 'DLL Name:'` 有真实结果）——说明 stdout 捕获没问题，问题就在"导出表这一段文本本身"。
* **根因（收敛结论）**：`objdump` **是否打印导出表、以及怎么排版**取决于 bfd 后端与该次 binutils 构建，不是一份稳定契约。只要判据依赖它的**人类可读文本**，就会随工具链版本/布局漂移而落空；继续换正则写法只是把同一个脆弱点换个马甲（§30 的整段扫描已经是当时能想到的最宽松写法，仍然为空）。
* **规则**：要断言 PE 产物的**导出面/导入面**时，**不要解析 `objdump`/`dumpbin` 的文本**，直接读 PE 头部——导出：`DataDirectory[0]` → `IMAGE_EXPORT_DIRECTORY` → `AddressOfNames`（+24 `NumberOfNames`、+32 `AddressOfNames`）；导入：`DataDirectory[1]` → `IMAGE_IMPORT_DESCRIPTOR` → `Name`。判据只依赖 PE 规范（多年稳定），与任何工具的输出格式无关。仓库落地为 [scripts/get-pe-exports.ps1](../scripts/get-pe-exports.ps1)：`Get-PeExportName -Path <pe>` 返回导出名数组，`build-opencv-shim.yml` 的 gnu 单导出闸门改为 dot-source 它、断言 `$names` 恰为 `@('shim_match_template')`；判据不符时把 PE 读到的清单写进异常消息，另 dump 整段 `objdump -p` 供事后比对。
* **本机验证（真实系统 DLL，非 mock）**：`C:\Windows\System32\kernel32.dll`（**PE32+**，走 `optOff+112` 分支）解析出 1633 个导出，含 `CreateFileW`/`LoadLibraryW`/`GetProcAddress`/`VirtualAlloc`；`C:\Windows\SysWOW64\kernel32.dll`（**PE32**，走 `optOff+96` 分支）1607 个、含 `CreateFileW`；`ole32.dll` 546 个（含 `CoCreateGuid`）；`gdi32.dll` 973 个（含 `BitBlt`）——两条 Optional Header 分支都被真实数据覆盖。RVA→文件偏移的节表映射用 `max(VirtualSize, RawSize)` 判归属，兼容未初始化数据节。

## 32. GitHub Actions 的 `powershell` shell 会把脚本内部残留的 `$LASTEXITCODE` 当成步骤退出码

* **现象（2026-10-28 CI 实测，`build-git.yml` 的 `Check versioned release`）**：脚本输出 `release tag 'git-2.56.0.windows.4': published=False` 之后步骤立刻 `Process completed with exit code 1`——判据本身正确（该 tag 尚未发布，`published=false` 正是期望结果），失败来自退出码，而不是逻辑。
* **根因**：`shell: powershell` 的步骤由 runner 成 `powershell.EXE -Command ". '<run>.ps1'"`，并在**步骤脚本末尾追加** `if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit $LASTEXITCODE }`。`gh release view <未发布的 tag>` 会以非 0 退出（`release not found`），该退出码在 `$LASTEXITCODE` 里留存下来；本脚本把这种情况当正常分支处理（`Invoke-Gh` 只回传退出码、不抛错），于是步骤末尾拿到的是 gh 的失败码，整步被判失败。换句话说：**"自检命令预期失败"必须自己把退出码收干净，不能指望"我没 throw 就没事"**。
* **规则**：凡是用原生命令做**存在性/状态探针**、且探针失败属于正常分支的脚本，在脚本末尾显式 `$global:LASTEXITCODE = 0`（不要用 `exit 0`——脚本被 dot-source 时会把调用者的会话一起退掉）。真正的异常在此之前就已 `throw`，不受影响；用 `$global:` 而不是裸赋值，是为了让外层（runner 追加的那段）读到的就是 0。
* **本机验证（复刻 runner 的包装 + mock `gh`，四条分支全跑）**：包装脚本 = `$ErrorActionPreference='stop'` + `& <script>` + runner 同款 `exit $LASTEXITCODE` 尾行；`build/probe/mockbin/gh.ps1` 分别模拟 create/出错：
  * 未发布（stderr `release not found`、exit 1，即 CI 那次）：修复前 `exit=1`（与 CI 日志一致），修复后 `exit=0` 且 `GITHUB_OUTPUT` 写入 `published=false`；
  * 草稿（`{"isDraft":true}`，exit 0）：`exit=0`、`published=false`（草稿不计入）；
  * 已发布（`{"isDraft":false}`，exit 0）：`exit=0`、`published=true`；
  * 真异常（PATH 里无 `gh`，`CommandNotFoundException`）：仍 `exit=1`——清零没有掩盖真实故障。
* **落地**：[scripts/test-release-published.ps1](../scripts/test-release-published.ps1) 末尾加注释说明 + `$global:LASTEXITCODE = 0`，9 个 `build-*.yml` 的调用行无需改动；[scripts/publish-alias-release.ps1](../scripts/publish-alias-release.ps1) 含同类"别名 Release 是否存在"探针（当前各路径都以必须成功的 gh 调用/资产闸门收尾，只是**眼下**不触发），按同一规则补上清零与注释。本机用 mock `gh`（分别模拟不存在→create、已存在→upload+edit、资产缺失→throw）复跑该脚本三条路径：`exit=0` / `exit=0` / `exit=1`，与闸门语义一致。
* **审计结论（2026-10-28，全仓库 15 个 `.ps1` + 所有 workflow `run` 块）**：仅 `test-release-published.ps1` 会踩中——10 个 `builders/*/build.ps1` 对每个非 0 一律 `throw`（`-SkipCompile` 下最后一个原生命令也是"非 0 即 throw"的冒烟测试），`setup-mingw.ps1` 探测 g++ 后即校验退出码，`check-ps1.ps1` / `get-pe-exports.ps1` 不含原生命令；workflow 里的定位/缓存/门禁步骤要么以成功命令收尾，要么显式 `throw`（opencv-shim 两条 dumpbin 闸门还额外断言"闸门确实跑过"）。
