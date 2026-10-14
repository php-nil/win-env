# 安装包体积优化评估 · 压缩与内容实测

本文档记录 win-env 安装包（PHP / pnpm）体积优化的**实测评估**，用于回答"能否通过压缩算法进一步减小安装包"。

> **状态：仅评估，未落地改动**。两个 `setup.iss` 保持现有配置（`Compression=lzma2/max` + `LZMADictionarySize=131072` + `SolidCompression=yes`）。
> 全部数字为 2026-10 在本机实测：ISCC 6.7.1（`build/cache/iscc`）+ 7-Zip 26.04（`7zr.exe`）。

## 1. 现状配置

| 项 | 值（`builders/php/setup.iss` 与 `builders/pnpm/setup.iss` 一致） |
| --- | --- |
| 压缩方法 | `Compression=lzma2/max` |
| 字典 | `LZMADictionarySize=131072`（128 MB，KB 单位） |
| 固实压缩 | `SolidCompression=yes` |
| 其它 LZMA 指令 | 均未设置（走默认值） |

暂存树规模（本地 `build/stage/`）：

| 环境 | 文件数 | 未压缩体积 | 已发布安装包 |
| --- | --- | --- | --- |
| PHP | 83 | 98.30 MB | 25,545,070 B（24.36 MiB） |
| pnpm | 438 | 52.26 MB | 16,967,636 B |

## 2. Inno Setup 侧压缩参数逐项实测（PHP 暂存树）

以 `Compression=lzma2/max` + `LZMADictionarySize=131072` 为基准，单独改动一个参数（变体 `.iss` 由 `setup.iss` 派生，逐份编译）：

| 变体 | 产物大小 (B) | 相对基准 | 压缩耗时 |
| --- | --- | --- | --- |
| **基准**（现状，与已发布安装包逐字节一致） | 25,545,070 | — | 22.1 s |
| `LZMANumFastBytes=273`（默认 64） | 25,404,521 | **−0.55%** | 28.4 s |
| `LZMAMatchFinder=BT` | 25,545,070 | 0（**本就是默认**） | 22.1 s |
| `LZMAMatchFinder=HC` | 25,835,251 | +1.14%（变差） | 39.1 s |
| `LZMANumBlockThreads=1` | 25,545,070 | 0（已是单固实块） | 22.1 s |
| `LZMANumBlockThreads=2` + `LZMABlockSize=262144` | 25,545,070 | 0（256 MB 块已覆盖整树） | 22.0 s |
| `LZMAAlgorithm=2` | 编译失败 | `Value of [Setup] section directive "LZMAAlgorithm" is invalid.` | — |

结论：

* **`Compression=lzma2/ultra` / `lzma2/ultra64` 无效**：两者只是把*默认*字典改成 32 MB / 64 MB，而本仓库字典已显式设为 128 MB，预设不会覆盖显式值。
* **继续加大字典无效**：整棵暂存树（98 MB < 128 MB）已经落在一个固实块内，字典再大也没有更远的匹配可利用；`LZMANumBlockThreads=1` 与加大 `LZMABlockSize` 同样零变化，证明"已是单块"。
* **`LZMAAlgorithm` 不是杠杆**：合法值仅 0/1，且 `max` 级别下默认已取 1（normal）；填 2 直接编译报错。
* **唯一还有效的旋钮是 `LZMANumFastBytes`**：64 → 273 得 −0.55%，代价只有构建期压缩时间（22 s → 28 s），无运行时开销、无语义变化。

> 补充：`doc/lessons.md` §2.4 记录的 128 MB 字典收益（约 −3%）应理解为**固实块覆盖**的收益（预设字典 8 MB 时块大小 4×8 MB = 32 MB，会把 98 MB 暂存树切成多块），而非"字典越大越好"；字典一旦 ≥ 整树，继续上调即无收益。

## 3. 对照：现代 7-Zip 的 LZMA2

同一暂存树用 7-Zip 26.04 命令行（`7zr a -t7z -mx=9 ... -ms=on`）压缩：

| 配置 | PHP | pnpm |
| --- | --- | --- |
| `LZMA2:d=128m:fb=273`（纯 LZMA2、固实） | 23,024,076 | 13,665,241 |
| `LZMA2:d=64m:fb=273` | 23,033,760 | — |
| `BCJ + LZMA2:d=64m:fb=273`（x86 滤镜） | 23,474,241（**比不加滤镜更差**） | 14,799,899 |

要正确比较必须扣除 **Inno 固定脚手架**：

* 用"极小载荷 + `Compression=none`"实测：**2,100,576 B**；换回 `lzma2/max` + 128 MB 字典：**2,100,584 B** → 即约 **2.05 MB 固定开销，且不受 `Compression` 设置影响**。
* 扣除脚手架后的**纯载荷**对比：

| 环境 | Inno 载荷 | 7-Zip 载荷 | 差距 |
| --- | --- | --- | --- |
| PHP | 23,444,486 B | 23,024,076 B | 7-Zip 小 **1.79%** |
| pnpm | 14,867,052 B | 13,665,241 B | 7-Zip 小 **8.09%** |

即：对**多文件中型文件树（PHP）**，Inno 的 LZMA2 与现代 7-Zip 几乎持平；对**单个大二进制（pnpm.exe，48.75 MB）**，Inno 编码器约差 8%。x86 BCJ 滤镜在此数据上反而有害。

固定脚手架的占比值得单独记住：**PHP 包 8.0%、pnpm 包 12.4%** 是每份包都逃不掉的底噪。

## 4. 结论与可选方向（均未采纳）

排序按"收益 / 代价"：

| 优先级 | 手段 | 实测收益 | 代价 |
| --- | --- | --- | --- |
| P0 | `LZMANumFastBytes=273`（两个 `setup.iss` 各加一行） | PHP −0.55%（pnpm 预计同类） | 仅构建期压缩时间 +27% |
| P1 | 删除 C 嵌入开发文件 `dev\php8.lib` + `php8embed.lib`（未压缩 2.87 MB） | PHP **−0.90%** | 改变"包内含 C 开发文件"的语义 |
| P1 | 再删非运行时文件：`readme-redist-bins.txt` 0.71 MB、`extras\sbom\*.json` 0.51 MB、`php.ini-development`/`php.ini-production` 各 0.069 MB、`news.txt`、`deplister.exe`、`phpdbg.exe`+`php8phpdbg.dll`、`pharcommand.phar` | 合计约 −1 MB 级 | 同样改变包内容语义（`php-cgi.exe`/`php-win.exe` 属规格内，不可删） |
| P2 | 换打包器：7-Zip SFX，或"Inno 内预压缩载荷 + 安装期解压" | pnpm 载荷 −8.1%、PHP −1.8%，另可省掉 2.05 MB 脚手架 | **属架构级改动**：放弃 Inno 的安装向导 / 干净卸载（注册表）/ 系统 PATH 改写 / UAC 提权，与仓库"一键安装 + 干净卸载"契约冲突 |

**最终决定：保持现状。** 理由：Inno 链路上的压缩参数已到顶，剩余空间都落在"改变包内容语义"或"改变安装契约"上，收益（−0.5%~−8%）与代价不匹配。

## 5. 复现方法（本地，无需联网）

1. 先只组装暂存树：`builders/<env>/build.ps1 -SkipCompile`；
2. 用便携 ISCC 编译变体：把 `setup.iss` 复制到 `build/` 内（同目录需复制 `Languages/`，因为脚本内 `LangDir = SourcePath + "Languages\"`），在 `SolidCompression=yes` 后插入待测指令，再以
   `ISCC.exe <变体>.iss /Q "/DMyAppVersion=8.5.11" "/DXdebugVersion=3.5.3" "/DStageDir=<暂存树>" "/DOutputDir=<输出>" "/DOutputBaseFilename=<名>"` 编译，比对产物字节数；
3. 7-Zip 对照：下载 7-Zip 官方便携 `7zr.exe`，`7zr a -t7z -mx=9 -m0=LZMA2:d=128m:fb=273 -ms=on <archive> <暂存树>`；
4. 脚手架基准：极小载荷 + `Compression=none` 编译一次，即得上表 2.05 MB 固定开销。

> 注意：`LZMANumFastBytes` 上限 273；`d260000`/`d262144` 等字典值会被 LZMA2 向上取整到下一个受支持档位（4/6/8/12/16/24/32… 的 2 倍幂与其中点）。
> 临时变体脚本与产物一律放 `build/`（gitignore），测完即删。
