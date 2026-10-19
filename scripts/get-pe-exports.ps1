<#
.SYNOPSIS
    直接读 PE 导出目录（IMAGE_EXPORT_DIRECTORY），返回导出名列表。

.DESCRIPTION
    给 workflow 的「导出面」闸门提供**不依赖文本输出格式**的判据。
    先前 build-opencv-shim.yml 的 gnu 路线靠 objdump -p 的文本输出 + 正则提取
    导出名，连续多轮 CI 都拿到空列表（objdump 打印导出表取决于 binutils 版本的
    措辞与 ".edata" 段落是否存在），闸门因此误报。这里改为按 PE 头部
    DataDirectory[0] 直接定位导出目录、读 AddressOfNames 表，与 objdump / dumpbin
    的措辞彻底解耦。

    只读文件字节，不加载也不执行目标 DLL，不依赖任何外部工具。

.PARAMETER Path
    PE 文件（.dll / .exe）路径。

.OUTPUTS
    [string[]] 导出目录中的全部名字；无导出目录或名字表为空时返回空数组。

.EXAMPLE
    . .\scripts\get-pe-exports.ps1
    Get-PeExportName -Path .\out-gnu\opencv_shim.dll
#>
function Get-PeExportName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $file = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $b = [IO.File]::ReadAllBytes($file)
    $u16 = { param([int]$o) [BitConverter]::ToUInt16($b, $o) }
    $u32 = { param([int]$o) [BitConverter]::ToUInt32($b, $o) }
    # 读以 NUL 结尾的 ASCII 串（PE 导出名一律 ASCII）。
    $ascii = { param([int]$o)
        $e = $o
        while ($e -lt $b.Length -and $b[$e] -ne 0) { $e++ }
        [Text.Encoding]::ASCII.GetString($b, $o, $e - $o)
    }

    if ($b.Length -lt 0x40 -or (& $u16 0) -ne 0x5A4D) { throw "not a PE image (no MZ): $file" }
    $peOff = [int](& $u32 0x3C)
    if ((& $u32 $peOff) -ne 0x4550) { throw "not a PE image (no PE signature): $file" }

    $numSections  = [int](& $u16 ($peOff + 6))
    $sizeOfOptHdr = [int](& $u16 ($peOff + 20))
    $optOff = $peOff + 24
    # DataDirectory 数组起点随 Optional Header 的 magic 变化：
    #   PE32+ (0x20B) 在 optOff+112，PE32 (0x10B) 在 optOff+96。
    $magic = & $u16 $optOff
    switch ($magic) {
        0x20B   { $dirBase = $optOff + 112 }
        0x10B   { $dirBase = $optOff + 96 }
        default { throw ("unknown optional-header magic 0x{0:X4}: $file" -f $magic) }
    }

    $expRva = [int](& $u32 $dirBase)   # DataDirectory[0] = 导出表 RVA
    if ($expRva -eq 0) { return @() }  # 无导出目录

    # RVA -> 文件偏移：遍历节表（节表紧跟 Optional Header）。$secOff / $numSections
    # 由脚本块的动态作用域取自外层函数，故无需传参。
    $secOff = $optOff + $sizeOfOptHdr
    $rvaToOff = {
        param([int]$rva)
        for ($i = 0; $i -lt $numSections; $i++) {
            $s = $secOff + 40 * $i
            $vSize   = [int](& $u32 ($s + 8))
            $vAddr   = [int](& $u32 ($s + 12))
            $rawSize = [int](& $u32 ($s + 16))
            $rawPtr  = [int](& $u32 ($s + 20))
            # 未初始化数据节的 VirtualSize 可能大于 RawSize，按两者较大者判归属。
            $span = [Math]::Max($vSize, $rawSize)
            if ($rva -ge $vAddr -and $rva -lt ($vAddr + $span)) { return $rawPtr + ($rva - $vAddr) }
        }
        return -1
    }

    $func = & $rvaToOff $expRva
    if ($func -lt 0) { throw ("export dir RVA 0x{0:X} is not covered by any section: $file" -f $expRva) }

    # IMAGE_EXPORT_DIRECTORY：+24 NumberOfNames，+32 AddressOfNames。
    $numNames = [int](& $u32 ($func + 24))
    if ($numNames -eq 0) { return @() }
    $namesOff = & $rvaToOff ([int](& $u32 ($func + 32)))
    if ($namesOff -lt 0) { throw "export name table RVA is not covered by any section: $file" }

    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $numNames; $i++) {
        $strOff = & $rvaToOff ([int](& $u32 ($namesOff + 4 * $i)))
        if ($strOff -lt 0) { throw ("export name #$i RVA is not covered by any section: $file") }
        $out.Add((& $ascii $strOff))
    }
    return $out.ToArray()
}
