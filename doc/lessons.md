# 经验教训（Windows 打包链路）

> 只收录在本项目中**实际发生并已验证**的问题。每条结构：现象 → 根因 → 规则。新增条目须是真实踩坑，不收录未经验证的"最佳实践"。

## 1. PowerShell 5.1 编码

### 1.1 含中文的 .ps1 必须保存为 UTF-8 with BOM

* **现象**：CI 发布的 Release 正文中文全部乱码（标题来自 workflow YAML 却正常）。
* **根因**：PS 5.1 对**无 BOM** 的 `.ps1` 按系统 ANSI 代码页（GitHub runner 为 cp1252）解析，中文字面量在解析阶段已损坏，再以 UTF-8 写出形成双重乱码。YAML 由 Actions 按 UTF-8 读取，故标题正常。
* **规则**：任何含非 ASCII 字符的 `.ps1` 必须带 BOM（`EF BB BF`）。加 BOM 后重跑构建，release-notes.md 中文恢复正常。
* **注意**：部分编辑器/格式化器会悄悄去掉 BOM；修改此类文件后需复查文件头三字节。

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

### 4.3 PowerShell 5 语法约束

* 不支持 `&&` / `||`：顺序执行用 `;`，条件执行用 `if ($LASTEXITCODE -eq 0)`。
* git 命令加 `$env:GIT_PAGER='cat'` 防分页挂起；git 的进度信息走 **stderr**（工具里显示为红色/Error 样式属正常），以 `git ls-remote` 等实际结果判断成败，不看颜色。

## 5. 网络与环境

### 5.1 本机沙箱可能阻断 github.com，但 CI runner 不受影响

* **现象**：本地 `Invoke-WebRequest https://github.com/...` 超时，而 `api.github.com` 可达。
* **应急取物**：通过 API 资产端点下载（先 `repos/:o/:r/releases/tags/<tag>` 取 asset id，再请求 `repos/:o/:r/releases/assets/<id>` 并带 `Accept: application/octet-stream` 与 `User-Agent` 头），并核对字节数与 API 元数据一致。
* **规则**：构建脚本的下载 URL 保持标准 `github.com/.../download/...`（runner 网络正常），不为本机网络加特殊分支。

### 5.2 本机需要完整构建时用便携 ISCC，不污染系统

* 从 choco API 下载 innosetup nupkg（zip），取出 `tools/innosetup-<ver>.exe`，以 `/VERYSILENT /CURRENTUSER /DIR=<repo>\build\cache\iscc` 安装到构建目录，再用 `$env:ISCC` 指向；build.ps1 按 `ISCC` 环境变量 → 标准安装目录 → PATH 的顺序查找。

## 6. 安装器行为模式（复用基线）

* 包内命令包装器固定模式：`"%~dp0php.exe" "%~dp0nilpack.phar" %*`，靠 `%~dp0` 自定位，与调用方 CWD 无关。
* 安装目录相关配置用 `__APP_DIR__` 占位符写进文件，`CurStepChanged(ssPostInstall)` 时按 `{app}` 替换，改安装目录也不出错。
* PATH 改写：按分号拆分、大小写不敏感比较、去空条目后幂等重写；安装追加、卸载精确删除自身条目。
* 每次改 setup.iss 后必做：静默安装到**非默认目录** → 注册表 PATH + 裸命令验证 → 静默卸载 → 文件/PATH 双清零验证。
