<#
.SYNOPSIS
    守卫：仓库内所有 .ps1 必须能被 Windows PowerShell 5.1 解析，且文件头 BOM 数量正确。

.DESCRIPTION
    为什么需要它：PS 5.1 只消化**第一个** UTF-8 BOM（EF BB BF）。多余的 BOM 会变成
    正文首个字符 U+FEFF 进入词法分析，报出一堆看着像真实语法错误的解析失败
    （InvalidLeftHandSide / ReservedKeywordNotAllowed / '<' operator is reserved ...），
    而编辑器和 AI 工具会不知不觉地删掉或补上 BOM，只在人工触发构建时才暴露。
    因此文件头改由机器把关，不再靠人眼复查。详见 doc/lessons.md §1.1 / §1.3。

    逐文件检查：
      * 含非 ASCII 字节的 .ps1 必须恰好一个前导 BOM；
      * 纯 ASCII 的 .ps1 不得带 BOM；
      * [Parser]::ParseFile 必须报 0 个错误。
    发现任何违规即列出全部并 throw（退出码非 0）。

.EXAMPLE
    scripts\check-ps1.ps1
#>
[CmdletBinding()]
param(
    # 扫描根目录，默认取本脚本上一级（仓库根）。
    [string]$Root
)

$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path -LiteralPath $Root).Path

# 排除非交付内容：.git 元数据、本地构建目录、下载到仓库内的工具链。
$skipPattern = '\\(\.git|build|tools)\\'

$bad = New-Object System.Collections.Generic.List[string]
$files = @(Get-ChildItem -LiteralPath $Root -Recurse -Filter *.ps1 -File |
    Where-Object { $_.FullName -notmatch $skipPattern })

foreach ($f in $files) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)

    # 数连续前导 BOM 的个数（EF BB BF 可能重复出现，正是要抓的病灶）。
    $bomCount = 0
    while ((3 * ($bomCount + 1)) -le $bytes.Length -and
           $bytes[3 * $bomCount]     -eq 0xEF -and
           $bytes[3 * $bomCount + 1] -eq 0xBB -and
           $bytes[3 * $bomCount + 2] -eq 0xBF) {
        $bomCount++
    }

    # BOM 自身字节 > 0x7F，故从 BOM 之后开始判断是否有非 ASCII 正文字节。
    $hasNonAscii = $false
    for ($i = 3 * $bomCount; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -gt 0x7F) { $hasNonAscii = $true; break }
    }

    # 报错带上十六进制文件头，把"该删还是该补"直接摆出来，不再靠人猜。
    $headLen = [Math]::Min(5, $bytes.Length - 1)
    $headHex = (($bytes[0..$headLen] | ForEach-Object { $_.ToString('X2') }) -join ' ')

    if ($bomCount -gt 1) {
        # 本仓库两次返工的病灶：多余 BOM 会变成正文首字符 U+FEFF 撞坏词法分析。
        $bad.Add(('{0}: BOM={1}（多于一个），PS 5.1 只消化第一个，多余的 BOM 会让解析失败（head {2}）' -f `
            $f.FullName, $bomCount, $headHex))
    }
    elseif ($hasNonAscii -and $bomCount -ne 1) {
        $bad.Add(('{0}: BOM={1} 但文件含非 ASCII 字符，缺 BOM 时 PS 5.1 按 ANSI 解析会乱码（head {2}）' -f `
            $f.FullName, $bomCount, $headHex))
    }

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $first = $errors[0]
        $bad.Add(('{0}: PS 5.1 解析失败 {1} 处，首条 line {2} col {3}: {4}' -f `
            $f.FullName, $errors.Count,
            $first.Extent.StartLineNumber, $first.Extent.StartColumnNumber, $first.Message))
    }
}

if ($bad.Count -gt 0) {
    Write-Host 'PowerShell guard FAILED:'
    foreach ($m in $bad) { Write-Host ('  - ' + $m) }
    throw ('PowerShell guard failed for {0} file(s) under {1}' -f $bad.Count, $Root)
}

Write-Host ('PowerShell guard OK: {0} .ps1 file(s) checked under {1}' -f $files.Count, $Root)
