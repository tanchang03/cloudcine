#Requires -Version 5.1
<#
.SYNOPSIS
    把 `flutter build windows --release` 的产物打成 Windows 交付物。

.DESCRIPTION
    默认在仓库根目录产出两个文件：

        cloudcine-<版本>-windows-x64.msi     安装包（WiX Toolset v3）
        cloudcine-<版本>-windows-x64.zip     免安装包（解压即用）

    流程：产物目录 → staging → 补 VC++ 运行库 → heat 收集文件清单
          → candle 编译 → light 链接成 MSI → msiexec /a 自检 → 压缩 zip

    为什么需要 staging：`heat.exe` 是按目录扫描来生成文件清单的，而 Flutter
    的产物目录里没有 VC++ 运行库 —— 那部分要另外补进来，补完再扫描。

.PARAMETER Version
    版本号，形如 0.3.0。不传则从 pubspec.yaml 读（那是版本的唯一源头）。

.PARAMETER ReleaseDir
    flutter build windows --release 的产物目录，相对仓库根目录。

.PARAMETER OutputDir
    交付物输出目录，默认仓库根目录。

.EXAMPLE
    pwsh windows/packaging/build_package.ps1 -Version 0.3.1

.NOTES
    只能在 Windows 上跑（WiX 是 Windows 工具）。另外仓库路径里不要有中文：
    WiX 的 light.exe 对非 ASCII 路径支持不好，会报一句看不懂的错。
#>
[CmdletBinding()]
param(
    [string]$Version,
    [string]$ReleaseDir = 'build/windows/x64/runner/Release',
    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'

$scriptDir = $PSScriptRoot
$repoRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if (-not $OutputDir) { $OutputDir = $repoRoot }

# ─────────────────────────────────────────────────────────────────────────────
# 0. 版本号：来自 pubspec.yaml，去掉 `+build` 后缀
# ─────────────────────────────────────────────────────────────────────────────
if (-not $Version) {
    $pubspec = Join-Path $repoRoot 'pubspec.yaml'
    if (-not (Test-Path $pubspec)) { throw "找不到 pubspec.yaml：$pubspec" }
    $line = (Select-String -Path $pubspec -Pattern '^version:').Line
    if (-not $line) { throw "pubspec.yaml 里没有 version 行：$pubspec" }
    $Version = ($line -replace '^version:\s*', '' -replace '\+.*$', '').Trim()
}
# MSI 的 ProductVersion 只认 major.minor.build 三段，且 major/minor 上限 255。
# 在这里拦下来，好过让 light.exe 报一句 LGHT 编号的错误。
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw "版本号必须是 x.y.z 三段式（MSI 的 ProductVersion 只认这个），当前是：$Version"
}
Write-Host "版本号：$Version"

# ─────────────────────────────────────────────────────────────────────────────
# 1. 定位 WiX Toolset
#
#    windows-2022 镜像已经预装了 WiX v3（3.14），所以正常情况下不需要装任何
#    东西。这里做多路查找只是为了本机 / 其它镜像上也能跑。
#
#    ⚠️ 刻意**不**用 `dotnet tool install --global wix`（那是 WiX v4+）：
#    本文件是 v3 语法（candle/light、WixUIExtension），两者不通用。
# ─────────────────────────────────────────────────────────────────────────────
function Find-WixBin {
    $roots = New-Object System.Collections.Generic.List[string]

    if ($env:WIX) { $roots.Add((Join-Path $env:WIX 'bin')) }

    foreach ($pf in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not $pf) { continue }
        Get-ChildItem -Path (Join-Path $pf 'WiX Toolset*\bin') -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { $roots.Add($_.FullName) }
    }

    return $roots |
        Where-Object {
            $_ -and
            (Test-Path (Join-Path $_ 'candle.exe')) -and
            (Test-Path (Join-Path $_ 'light.exe')) -and
            (Test-Path (Join-Path $_ 'heat.exe'))
        } |
        Sort-Object -Descending |
        Select-Object -First 1
}

$wixBin = Find-WixBin
if (-not $wixBin) {
    throw @'
找不到 WiX Toolset（需要 candle.exe / light.exe / heat.exe）。
windows-2022 的 GitHub Actions 镜像自带 WiX 3.14；本机请装 WiX Toolset v3：
https://github.com/wixtoolset/wix3/releases
'@
}
Write-Host "WiX：$wixBin"

$candle = Join-Path $wixBin 'candle.exe'
$light = Join-Path $wixBin 'light.exe'
$heat = Join-Path $wixBin 'heat.exe'

# ─────────────────────────────────────────────────────────────────────────────
# 2. staging：产物目录 + VC++ 运行库
#
#    Flutter 的 Windows 产物是 CMake + MSVC 默认配置编出来的，走的是动态 CRT
#    （/MD），所以目标机器上必须有 VCRUNTIME140.dll / MSVCP140.dll。绝大多数
#    Windows 装过别的软件就已经有了，但「绝大多数」不是「全部」—— 缺了的话
#    用户看到的是一句「找不到 VCRUNTIME140.dll」，完全不知道该怎么办。
#
#    解决办法是微软官方支持的 app-local 部署：把这几个 dll 直接放在 exe 旁边。
#    dll 从构建机自己的 VS 里取，版本和编译时用的 CRT 必然一致。
# ─────────────────────────────────────────────────────────────────────────────
$src = Join-Path $repoRoot $ReleaseDir
if (-not (Test-Path $src)) {
    throw "找不到构建产物目录：$src（先在 Windows 上跑 flutter build windows --release）"
}

$stageRoot = Join-Path $repoRoot 'build\windows-package'
$stage = Join-Path $stageRoot 'cloudcine'
if (Test-Path $stageRoot) { Remove-Item $stageRoot -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
Copy-Item -Path (Join-Path $src '*') -Destination $stage -Recurse -Force

$crtDir = $null
$vsRoot = Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022'
if (Test-Path $vsRoot) {
    $crtDir = Get-ChildItem -Path (Join-Path $vsRoot '*\VC\Redist\MSVC\*\x64') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'Microsoft.VC*.CRT' } |
        Sort-Object FullName -Descending |
        Select-Object -First 1
}
if ($crtDir) {
    Copy-Item -Path (Join-Path $crtDir.FullName '*.dll') -Destination $stage -Force
    $crtNames = (Get-ChildItem -Path $crtDir.FullName -Filter '*.dll' | Select-Object -ExpandProperty Name) -join ', '
    Write-Host "已随包携带 VC++ 运行库（$($crtDir.Name)）：$crtNames"
}
else {
    # 不直接失败：产物本身是好的，只是对目标机器多一个隐含要求。
    Write-Warning '没找到 VC++ 运行库目录，安装包将依赖目标机器上已安装 VC++ 2015-2022 运行库。'
}

$stagedCount = (Get-ChildItem -Path $stage -Recurse -File).Count
Write-Host "staging 文件数：$stagedCount"

# ─────────────────────────────────────────────────────────────────────────────
# 3. heat：扫描 staging 生成文件清单
#
#    -cg  组件组名，cloudcine.wxs 里用 ComponentGroupRef 引它
#    -dr  这些文件装到哪个目录（对应 cloudcine.wxs 里的 INSTALLFOLDER）
#    -ag  组件 GUID 交给 WiX 按 KeyPath 推导（稳定），而不是每次构建随机生成
#    -srd 不要再生成一层根目录元素
#    -sreg 不收集注册表（这个应用不写注册表）
#    -ke  保留空目录
# ─────────────────────────────────────────────────────────────────────────────
$objDir = Join-Path $stageRoot 'obj'
New-Item -ItemType Directory -Path $objDir -Force | Out-Null

$filesWxs = Join-Path $objDir 'Files.wxs'
& $heat dir $stage -ag -cg CloudCineFiles -dr INSTALLFOLDER -srd -sreg -ke -var var.SourceDir -out $filesWxs
if ($LASTEXITCODE -ne 0) { throw "heat.exe 失败，退出码 $LASTEXITCODE" }
if (-not (Test-Path $filesWxs)) { throw "heat.exe 没有产出 $filesWxs" }

# ─────────────────────────────────────────────────────────────────────────────
# 4. candle + light：编译链接成 MSI
#
#    -arch x64   64 位包（决定 ProgramFiles64Folder 等目录是否可用、摘要流模板）
#    -ext WixUIExtension   安装向导界面
#    -cultures:zh-cn       界面文案走简体中文（WixUI_zh-CN.wxl）
#
#    ── 关于 -sice: 这三条 ──────────────────────────────────────────────────
#    light 默认会跑 ICE 校验，而 per-user 安装到用户配置目录会稳定触发三条：
#
#      ICE38  装到用户配置目录的组件必须用 HKCU 注册表项做 KeyPath，不能是文件
#      ICE64  用户配置目录下的每个目录都必须登记进 RemoveFile 表
#      ICE91  这些文件不会被复制到每个用户的配置目录（仅警告）
#
#    这三条是**已知误报**，不是真问题。它们的立论前提是「多用户共用一台机器 /
#    漫游配置文件」；本包是 InstallScope="perUser"（ALLUSERS=2 +
#    MSIINSTALLPERUSER=1），只写安装者自己的配置目录，前提根本不成立。
#
#    难点在于 heat 生成的是几十个「文件做 KeyPath」的组件，逐个人工补 HKCU
#    注册表项既没意义也不现实。WiX 官方 issue #8633（"Generated components
#    should be ICE-clean for per-user target directories"）说的就是这件事，
#    被维护者标成 wip required —— 等于承认这是 heat 输出的局限，而不是作者
#    写错了。所以这里逐条压掉。
#
#    ⚠️ 只压这三条，**不要**图省事换成 -sval（整体关掉校验）—— 那样
#    ICE61（升级表）、ICE30（重复文件）这类真问题会被一起吞掉。
#    万一将来又冒出别的 ICE，先判断是不是同类误报，再单独 -sice: 掉它。
# ─────────────────────────────────────────────────────────────────────────────
$appIcon = Join-Path $scriptDir 'app_icon.ico'
$licenseRtf = Join-Path $scriptDir 'license.rtf'
foreach ($f in @($appIcon, $licenseRtf)) {
    if (-not (Test-Path $f)) { throw "缺少打包输入文件：$f" }
}

$wxs = Join-Path $scriptDir 'cloudcine.wxs'
$productWixobj = Join-Path $objDir 'cloudcine.wixobj'
$filesWixobj = Join-Path $objDir 'Files.wixobj'

& $candle -arch x64 `
    "-dProductVersion=$Version" `
    "-dSourceDir=$stage" `
    "-dAppIcon=$appIcon" `
    "-dLicenseRtf=$licenseRtf" `
    -out $productWixobj $wxs
if ($LASTEXITCODE -ne 0) { throw "candle.exe 编译 cloudcine.wxs 失败，退出码 $LASTEXITCODE" }

& $candle -arch x64 "-dSourceDir=$stage" -out $filesWixobj $filesWxs
if ($LASTEXITCODE -ne 0) { throw "candle.exe 编译 Files.wxs 失败，退出码 $LASTEXITCODE" }

$msiPath = Join-Path $OutputDir "cloudcine-$Version-windows-x64.msi"
if (Test-Path $msiPath) { Remove-Item $msiPath -Force }

& $light -ext WixUIExtension -cultures:zh-cn `
    -sice:ICE38 -sice:ICE64 -sice:ICE91 `
    -out $msiPath $productWixobj $filesWixobj
if ($LASTEXITCODE -ne 0) { throw "light.exe 链接 MSI 失败，退出码 $LASTEXITCODE" }
if (-not (Test-Path $msiPath)) { throw "light.exe 没有产出 $msiPath" }

# ─────────────────────────────────────────────────────────────────────────────
# 5. 自检：用管理式安装（msiexec /a）把 MSI 解到临时目录
#
#    /a 只解包、不注册，不需要管理员权限，也不会真的「安装」到系统里 ——
#    正好用来验证「这个 MSI 是不是完好、里面的东西对不对」。
#    只检查文件大小的话，一个空壳 MSI 也能过。
# ─────────────────────────────────────────────────────────────────────────────
$verifyDir = Join-Path $env:TEMP 'cloudcine-msi-verify'
if (Test-Path $verifyDir) { Remove-Item $verifyDir -Recurse -Force }

$msiexec = Start-Process -FilePath 'msiexec.exe' -Wait -PassThru -ArgumentList @(
    '/a', "`"$msiPath`"", '/qn', "TARGETDIR=`"$verifyDir`""
)
if ($msiexec.ExitCode -ne 0) {
    throw "MSI 自检失败：msiexec /a 退出码 $($msiexec.ExitCode)"
}

$verifyExe = Get-ChildItem -Path $verifyDir -Filter 'cloudcine.exe' -Recurse -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $verifyExe) { throw "MSI 自检失败：解出来的内容里找不到 cloudcine.exe" }

$verifyCount = (Get-ChildItem -Path $verifyDir -Recurse -File).Count
if ($verifyCount -lt $stagedCount) {
    throw "MSI 自检失败：包里只有 $verifyCount 个文件，staging 有 $stagedCount 个"
}
Write-Host "MSI 自检通过：解出 $verifyCount 个文件，含 cloudcine.exe"
Remove-Item $verifyDir -Recurse -Force -ErrorAction SilentlyContinue

# ─────────────────────────────────────────────────────────────────────────────
# 6. zip：免安装包
#
#    压缩 staging 目录本身（而不是它的内容），这样用户解压出来得到的是一个
#    `cloudcine\` 文件夹，而不是散落一地的文件。
# ─────────────────────────────────────────────────────────────────────────────
$zipPath = Join-Path $OutputDir "cloudcine-$Version-windows-x64.zip"
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
Compress-Archive -Path $stage -DestinationPath $zipPath -CompressionLevel Optimal -Force

# ─────────────────────────────────────────────────────────────────────────────
# 7. 结果
# ─────────────────────────────────────────────────────────────────────────────
Get-Item $msiPath, $zipPath |
    Select-Object Name, @{ n = 'SizeMB'; e = { [math]::Round($_.Length / 1MB, 1) } } |
    Format-Table -AutoSize |
    Out-String |
    Write-Host

Write-Host "MSI：$msiPath"
Write-Host "ZIP：$zipPath"
