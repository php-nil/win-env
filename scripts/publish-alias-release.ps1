<#
.SYNOPSIS
    发布/更新某环境的"常青下载别名" Release（固定 tag + 固定资产名）。

.DESCRIPTION
    README 的下载链接不能写死版本号：版本 tag 与安装包文件名每次构建都会变，链接必然过期。
    本脚本把本次构建的安装包另存为固定资产名 <env>-setup-x64.exe（并生成同名 sha256），
    上传到固定 tag <env>-latest：
      * 别名 Release 不存在 -> gh release create（--prerelease，不抢仓库 "Latest" 指向）；
      * 已存在 -> gh release upload --clobber 原地覆盖 + gh release edit 刷新说明。
    带版本号的 Release 由 workflow 另行判断（已存在则跳过），与本别名互不影响。
    末尾闸门断言别名 Release 里确实存在固定资产名，避免"创建成功但资产没上去"的静默坏链。

    需要 GH_TOKEN（或 GITHUB_TOKEN）环境变量；CI 里由 secrets.GITHUB_TOKEN 注入。

.EXAMPLE
    scripts\publish-alias-release.ps1 -Env python -Version 3.15.0 `
        -AssetPath build\output\python-3.15.0-setup-x64.exe `
        -VersionedTag python-3.15.0 -DisplayName Python
#>
[CmdletBinding()]
param(
    # 环境短名，同时用作 tag 前缀与资产名前缀（小写字母/数字），如 python。
    [Parameter(Mandatory)][string]$Env,
    # 本次构建的精确版本，仅用于说明文本。
    [Parameter(Mandatory)][string]$Version,
    # 本次构建产出的带版本号安装包路径。
    [Parameter(Mandatory)][string]$AssetPath,
    # 带版本号的 Release tag，仅用于说明文本。
    [string]$VersionedTag = '',
    # 说明文本里显示的名字，默认用 $Env。
    [string]$DisplayName = '',
    # 仓库 slug（owner/repo），默认取 CI 的 GITHUB_REPOSITORY。
    [string]$RepoSlug = $env:GITHUB_REPOSITORY
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Invoke-Gh {
    # PS 5.1 的坑：EAP=Stop 下把原生命令 stderr 用 2>&1 合并会当成终止错误抛出
    # （NativeCommandError），"release not found" 这种正常分支也会把步骤打挂。
    # 这里临时放开 EAP，只回传输出文本与退出码，由调用方判断。
    param([string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & gh @Arguments 2>&1
        return [pscustomobject]@{
            Output   = ($output | Out-String).Trim()
            ExitCode = $LASTEXITCODE
        }
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

# 用 -cnotmatch 做大小写敏感校验：-notmatch 默认忽略大小写，'Demo' 也能通过，会产出
# 'Demo-latest' / 'Demo-setup-x64.exe' 这类与 README 链接不一致的资产名。
if ($Env -cnotmatch '^[a-z0-9]+$') { throw "Env '$Env' 只能是小写 a-z0-9（用于 tag 与资产名）" }
if (-not $DisplayName) { $DisplayName = $Env }
if (-not $RepoSlug) { $RepoSlug = 'php-nil/win-env' }
if (-not $VersionedTag) { $VersionedTag = "$Env-$Version" }

$aliasTag = "$Env-latest"
$aliasAssetName = "$Env-setup-x64.exe"
$shaName = "$aliasAssetName.sha256.txt"

if (-not (Test-Path -LiteralPath $AssetPath -PathType Leaf)) {
    throw "安装包不存在: $AssetPath"
}
$source = (Resolve-Path -LiteralPath $AssetPath).Path
$outDir = Split-Path -Parent $source
$aliasPath = Join-Path $outDir $aliasAssetName
$shaPath = Join-Path $outDir $shaName
$notesPath = Join-Path $outDir 'alias-release-notes.md'

# 别名资产与版本包字节相同，只改文件名；校验值按固定资产名重写（原 sha 文件里写的是版本化文件名）。
Copy-Item -LiteralPath $source -Destination $aliasPath -Force
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $aliasPath).Hash.ToLower()
"$hash  $aliasAssetName" | Out-File -FilePath $shaPath -Encoding ascii

$download = "https://github.com/$RepoSlug/releases/download/$aliasTag/$aliasAssetName"
$proxy = "https://gh-proxy.com/$download"
$history = "https://github.com/$RepoSlug/releases?q=$Env-"
$versionedUrl = "https://github.com/$RepoSlug/releases/tag/$VersionedTag"

$notes = @"
# $DisplayName 最新构建（常青下载别名 $aliasTag）

本 Release 是固定下载入口：tag 与资产名都不含版本号，每次构建原地覆盖，
因此 README 里的下载链接永远指向该环境最新一次成功构建。

| 项 | 值 |
| --- | --- |
| 下载（GitHub） | $download |
| 下载（代理） | $proxy |
| 本次构建版本 | $Version |
| 带版本号的发布 | $versionedUrl |
| SHA-256 | $hash |
| 历史版本 | $history |

> 资产名固定为 $aliasAssetName（不含版本号）；实际版本号见安装向导标题或"应用和功能"列表。
> 带版本号的 Release 只在版本首次构建时创建，重跑不覆盖既有资产；本别名始终跟随最新构建。
"@
[IO.File]::WriteAllText($notesPath, $notes, $utf8NoBom)

$title = "$DisplayName 最新构建（常青下载别名）"
$probe = Invoke-Gh @('release', 'view', $aliasTag)
if ($probe.ExitCode -eq 0) {
    Write-Host "alias release $aliasTag 已存在，原地覆盖资产与说明"
    $upload = Invoke-Gh @('release', 'upload', $aliasTag, $aliasPath, $shaPath, '--clobber')
    if ($upload.ExitCode -ne 0) { throw "gh release upload 失败（tag $aliasTag）: $($upload.Output)" }
    $edit = Invoke-Gh @('release', 'edit', $aliasTag, '--title', $title, '--notes-file', $notesPath, '--prerelease')
    if ($edit.ExitCode -ne 0) { throw "gh release edit 失败（tag $aliasTag）: $($edit.Output)" }
}
else {
    Write-Host "alias release $aliasTag 不存在，创建（prerelease）"
    $create = Invoke-Gh @('release', 'create', $aliasTag, $aliasPath, $shaPath,
        '--prerelease', '--title', $title, '--notes-file', $notesPath)
    if ($create.ExitCode -ne 0) { throw "gh release create 失败（tag $aliasTag）: $($create.Output)" }
}

# 闸门：确认固定资产名确实在别名 Release 中，避免"发布成功但链接 404"的静默坏链。
# 用 --jq 逐行输出资产名（PS 5.1 的 ConvertFrom-Json 把 JSON 数组整体当单个对象，不展开）。
$assets = Invoke-Gh @('release', 'view', $aliasTag, '--json', 'assets', '--jq', '.assets[].name')
if ($assets.ExitCode -ne 0) { throw "gh release view --json assets 失败（tag $aliasTag）: $($assets.Output)" }
$assetNames = @($assets.Output -split "`r?`n" | Where-Object { $_ })
$missing = @($aliasAssetName, $shaName) | Where-Object { $assetNames -notcontains $_ }
if ($missing.Count -gt 0) {
    throw ('alias release {0} 缺少资产: {1}' -f $aliasTag, ($missing -join ', '))
}

Write-Host "  alias tag : $aliasTag"
Write-Host "  asset     : $aliasAssetName"
Write-Host "  download  : $download"
Write-Host "  proxy     : $proxy"

# 与 test-release-published.ps1 同一规则：本脚本用 gh 做"别名 Release 是否存在"的探针，
# "release not found" 属正常分支；GitHub Actions 的 powershell shell 会在步骤末尾追加
#   if ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit $LASTEXITCODE }
# 所以不能把任何 gh 的退出码留给步骤收尾。当前路径都以"必须成功、失败即 throw"的 gh 调用
# 或资产闸门收尾，这里再显式清零一次，避免以后调整顺序时又踩同一个坑（真异常仍会 throw）。
$global:LASTEXITCODE = 0
