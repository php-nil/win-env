<#
.SYNOPSIS
    判断指定 tag 的 Release 是否已作为"公开"（非草稿）发布，结果写入 GITHUB_OUTPUT。

.DESCRIPTION
    每个环境每次构建发两个 Release：
      * 带版本号的 <env>-<version>：只在版本首次构建时发布，重跑不覆盖既有资产；
      * 常青别名 <env>-latest：每次构建原地覆盖，README 的下载链接只指向它。
    本脚本负责第一类的前置判断：tag 已有公开 Release 时输出 published=true，workflow 据此
    跳过正式发布步骤。草稿（draft）不计入 published，便于草稿转正后正常发布。

    需要 GH_TOKEN（或 GITHUB_TOKEN）环境变量；CI 里由 secrets.GITHUB_TOKEN 注入。
    本地没有 GITHUB_OUTPUT 时只打印结果，不做任何写操作。

.EXAMPLE
    scripts\test-release-published.ps1 -Tag php-8.5.11
#>
[CmdletBinding()]
param(
    # 待检查的 Release tag，如 php-8.5.11。
    [Parameter(Mandatory)][string]$Tag,
    # 写入 $env:GITHUB_OUTPUT 的输出名，workflow 用 steps.<id>.outputs.<name> 读取。
    [string]$OutputName = 'published'
)

$ErrorActionPreference = 'Stop'

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

$published = $false
$probe = Invoke-Gh @('release', 'view', $Tag, '--json', 'isDraft')
if ($probe.ExitCode -eq 0 -and $probe.Output) {
    try {
        $isDraft = [bool](($probe.Output | ConvertFrom-Json).isDraft)
        $published = -not $isDraft
    }
    catch {
        # gh 输出不是预期 JSON（版本差异/异常）：按未发布处理，让后续发布步骤暴露真实错误。
        Write-Warning ('gh release view 输出无法解析，按未发布处理: ' + $probe.Output)
    }
}

Write-Host ("release tag '{0}': published={1}" -f $Tag, $published)
if ($env:GITHUB_OUTPUT) {
    "{0}={1}" -f $OutputName, $published.ToString().ToLower() |
        Out-File -FilePath $env:GITHUB_OUTPUT -Encoding ascii -Append
}
