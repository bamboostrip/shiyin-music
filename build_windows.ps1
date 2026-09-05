<#
.SYNOPSIS
  时音 Windows 构建与分发打包脚本（pwsh 版，与 build_windows.bat 同功能）。
.DESCRIPTION
  一键完成：Flutter 构建 → exe 改名 → 打 portable.zip → 编 setup.exe。

  用法:
    .\build_windows.ps1                          # release，全量打包
    .\build_windows.ps1 -BuildType debug         # debug 构建（仅产物目录，不打安装包）
    .\build_windows.ps1 -SkipBuild               # 跳过构建，仅重新打包 build\dist\portable
    .\build_windows.ps1 -NoInstaller             # 只打 portable.zip，不编 setup.exe
    .\build_windows.ps1 -NoPortable              # 只编 setup.exe，不打 zip
    .\build_windows.ps1 -PortableOnly            # 仅便携包（等价 -NoInstaller）
    .\build_windows.ps1 -InstallerOnly           # 仅安装包（等价 -NoPortable）

  产物（build/ 已在 .gitignore，flutter clean 会清理）:
    build\dist\shiyin-vX.Y.Z-windows-x64-portable.zip  # 便携版（zip 根即文件，解压即覆盖）
    build\dist\shiyin-vX.Y.Z-windows-x64-setup.exe     # 安装版（Inno Setup，装到 %LocalAppData%\ShiyinMusic）

  要求:
    - Flutter 已在 PATH（或 E:\flutter\flutter\bin\flutter.bat）
    - Inno Setup 6 已安装（winget: JRSoftware.InnoSetup，或官网 jrsoftware.org/isinfo.php）
      本机 winget 精简版缺 ChineseSimplified.isl 时，脚本会自动用随仓的
      installer\Languages\ChineseSimplified.isl 补齐，保证编出中文向导。
.EXAMPLE
  .\build_windows.ps1
  .\build_windows.ps1 -BuildType debug
.NOTES
  若提示"无法加载文件，因为在此系统上禁止运行脚本"，执行一次即可：
    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  或单次绕过：
    pwsh -ExecutionPolicy Bypass -File .\build_windows.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('release', 'debug')]
    [string]$BuildType = 'release',
    [switch]$SkipBuild,
    [switch]$NoInstaller,
    [switch]$NoPortable,
    [switch]$PortableOnly,
    [switch]$InstallerOnly
)

# 互斥开关归一。
if ($PortableOnly) { $NoInstaller = $true }
if ($InstallerOnly) { $NoPortable = $true }

$ErrorActionPreference = 'Stop'

Write-Host '============================================'
Write-Host '  时音 - Windows 客户端构建工具 (ps1)'
Write-Host '============================================'

# 以脚本所在目录为仓库根，不依赖写死盘符
Set-Location $PSScriptRoot

# 从 pubspec.yaml / app_config.dart 取版本号（CI 同款：v 前缀 + fileVersion 兜底）。
function Get-AppVersion {
    $ver = $null
    try {
        $pub = Get-Content 'pubspec.yaml' -Raw -ErrorAction Stop
        if ($pub -match 'version:\s*([0-9]+\.[0-9]+(?:\.[0-9]+)?)') { $ver = $Matches[1] }
    } catch {}
    if (-not $ver) {
        try {
            $cfg = Get-Content 'lib/config/app_config.dart' -Raw -ErrorAction Stop
            if ($cfg -match "appVersion\s*=\s*'([^']+)'") { $ver = $Matches[1] }
        } catch {}
    }
    if (-not $ver) { $ver = '0.0.0' }
    $parts = $ver.Split('.').Count
    $fileVer = $ver + ('.0' * (4 - $parts))
    return @{ Version = $ver; FileVersion = $fileVer; Tag = "v$ver" }
}

function Find-Flutter {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and $cmd.Source) { return $cmd.Source }
    $fallback = 'E:\flutter\flutter\bin\flutter.bat'
    if (Test-Path $fallback) { return $fallback }
    return $null
}

function Find-Iscc {
    $candidates = @(
        "$env:LocalAppData\Programs\Inno Setup 6\ISCC.exe",
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    $cmd = Get-Command ISCC -ErrorAction SilentlyContinue
    if ($null -ne $cmd -and $cmd.Source) { return $cmd.Source }
    return $null
}

function Ensure-ChineseLanguage {
    param([string]$IsccPath)
    $isccDir = Split-Path $IsccPath -Parent
    $target = Join-Path $isccDir 'Languages\ChineseSimplified.isl'
    if (Test-Path $target) { return }
    $vendored = Join-Path $PSScriptRoot 'installer\Languages\ChineseSimplified.isl'
    if (-not (Test-Path $vendored)) { return }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
        Copy-Item $vendored $target -Force
        Write-Host "  [补齐] 已将随仓中文语言包复制到 Inno 目录：$target" -ForegroundColor DarkGray
    } catch {
        Write-Host "  [警告] 补齐中文语言包失败：$_" -ForegroundColor Yellow
    }
}

# ── 0. 依赖 ──
$flutter = Find-Flutter
if (-not $flutter) {
    Write-Error '找不到 flutter：请先安装并加入 PATH'
    exit 1
}

$appVer = Get-AppVersion
Write-Host "[版本] $($appVer.Tag)  (FileVersion $($appVer.FileVersion))  [构建类型] $BuildType"

# ── 1. Flutter 构建 ──
if (-not $SkipBuild) {
    Write-Host ''
    Write-Host '[0/3] 安装依赖...'
    & $flutter pub get
    if ($LASTEXITCODE -ne 0) { exit 1 }

    Write-Host ''
    Write-Host '[1/3] 代码分析...'
    & $flutter analyze
    if ($LASTEXITCODE -ne 0) { exit 1 }

    Write-Host ''
    Write-Host "[2/3] 构建 Windows 客户端 ($BuildType)..."
    & $flutter build windows --$BuildType
    if ($LASTEXITCODE -ne 0) { exit 1 }
} else {
    Write-Host ''
    Write-Host '[跳过] 已跳过 Flutter 构建（-SkipBuild）'
}

$buildDir = Join-Path 'build\windows\x64\runner' (Get-Culture).TextInfo.ToTitleCase($BuildType)
$exe = Join-Path $buildDir 'kgka_music_hl.exe'
if (-not (Test-Path $exe)) {
    Write-Error "未找到构建产物：$exe（先运行不带 -SkipBuild 的构建）"
    exit 1
}

# ── 2. 暂存 portable 目录（与 CI 同款：exe 改名 ShiyinMusic.exe） ──
Write-Host ''
Write-Host '[3/3] 分发打包...'
$stage = Join-Path $PSScriptRoot 'build\dist\portable'
New-Item -ItemType Directory -Force -Path $stage | Out-Null
# 清空旧暂存（避免残留旧 dll 漏进新包）
Get-ChildItem $stage -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item "$buildDir\*" $stage -Recurse -Force
$oldExe = Join-Path $stage 'kgka_music_hl.exe'
$newExe = Join-Path $stage 'ShiyinMusic.exe'
if (Test-Path $oldExe) { Move-Item $oldExe $newExe -Force }
if (-not (Test-Path $newExe)) {
    Write-Error "暂存目录缺少 ShiyinMusic.exe：$newExe"
    exit 1
}

$tag = $appVer.Tag
$distDir = Join-Path $PSScriptRoot 'build\dist'
New-Item -ItemType Directory -Force -Path $distDir | Out-Null

# ── 3a. portable.zip ──
$zipName = "shiyin-$tag-windows-x64-portable.zip"
$zipPath = Join-Path $distDir $zipName
if (-not $NoPortable) {
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Write-Host "  打包 $zipName ..."
    try {
        Compress-Archive -Path "$stage\*" -DestinationPath $zipPath -Force
    } catch {
        Write-Error "打包 portable.zip 失败：$_"
        exit 1
    }
    $zipMb = '{0:N1}' -f ((Get-Item $zipPath).Length / 1MB)
    Write-Host "  [完成] $zipName ($zipMb MB)" -ForegroundColor Green
    # 校验：zip 不应含 flag（否则便携版被误判为安装版）
    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue | Out-Null
        $zip = [IO.Compression.ZipFile]::OpenRead($zipPath)
        $hasFlag = $zip.Entries | Where-Object { $_.FullName -like '*installed_by_inno.flag*' }
        $zip.Dispose()
        if ($hasFlag) {
            Write-Host '  [警告] portable.zip 误含 installed_by_inno.flag（不应出现）' -ForegroundColor Yellow
        }
    } catch {}
}

# ── 3b. setup.exe ──
$setupName = "shiyin-$tag-windows-x64-setup.exe"
$setupPath = Join-Path $distDir $setupName
if (-not $NoInstaller) {
    $iscc = Find-Iscc
    if (-not $iscc) {
        Write-Host "  [跳过] 未找到 ISCC.exe，跳过安装包编译" -ForegroundColor Yellow
        Write-Host "  安装 Inno Setup 6 后重试：winget install JRSoftware.InnoSetup" -ForegroundColor Yellow
        Write-Host "  或官网：https://jrsoftware.org/isinfo.php" -ForegroundColor Yellow
    } else {
        Write-Host "  编译 $setupName ..."
        Ensure-ChineseLanguage -IsccPath $iscc
        $stageAbs = (Resolve-Path $stage).Path
        $distAbs = (Resolve-Path $distDir).Path
        $issAbs = (Resolve-Path 'installer\shiyin.iss').Path
        $isccArgs = @(
            "/DAppVersion=$($appVer.Version)",
            "/DFileVersion=$($appVer.FileVersion)",
            "/DSourceDir=$stageAbs",
            "/O$distAbs",
            $issAbs
        )
        & $iscc @isccArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Error "ISCC 编译失败（exit $LASTEXITCODE）"
            exit 1
        }
        # ISCC 固定输出 shiyin-windows-x64-setup.exe，需重命名到带 tag 的发版命名
        $rawSetup = Join-Path $distDir 'shiyin-windows-x64-setup.exe'
        if (Test-Path $rawSetup) {
            if (Test-Path $setupPath) { Remove-Item $setupPath -Force }
            Move-Item $rawSetup $setupPath -Force
        }
        if (-not (Test-Path $setupPath)) {
            Write-Error "未找到安装包产物：$setupPath"
            exit 1
        }
        $setupMb = '{0:N1}' -f ((Get-Item $setupPath).Length / 1MB)
        Write-Host "  [完成] $setupName ($setupMb MB)" -ForegroundColor Green
    }
}

# ── 汇总 ──
Write-Host ''
Write-Host '============================================'
Write-Host '  产物一览 (build/dist/)'
Write-Host '============================================'
Get-ChildItem $distDir -File -Filter 'shiyin-*' | ForEach-Object {
    $mb = '{0:N1}' -f ($_.Length / 1MB)
    Write-Host "  $($_.Name)  ($mb MB)"
}
Write-Host ''
Write-Host "  暂存目录：$stage"
Write-Host '  分发说明：'
Write-Host '    便携版：解压 portable.zip 覆盖旧目录即可'
Write-Host '    安装版：运行 setup.exe，装到 %LocalAppData%\ShiyinMusic（免 UAC）'
Write-Host '============================================'
