<#
.SYNOPSIS
  时音 APK 构建脚本（pwsh 版，与 build_apk.bat 同功能）。
.DESCRIPTION
  用法: .\build_apk.ps1 [impeller|skia] [release|debug] [arm64|arm32]
    第一个参数是渲染引擎，默认 impeller（老机器闪退/冻屏再打 skia 版）
    第二个参数是构建类型，默认 release
    第三个参数是目标 ABI，默认 arm64（老车机打 arm32，仅 skia 变体发布）
    兼容老用法：.\build_apk.ps1 debug 等同 impeller + debug
  切渲染器或 ABI 自动 flutter clean（--dart-define 是编译期常量，
  不清会串味），同变体连打走增量构建。
  工具链查找见 scripts/flutter-env.ps1（FLUTTER_ROOT → PATH → 常见位置），
  脚本内不再写死任何盘符路径。
.EXAMPLE
  .\build_apk.ps1
  .\build_apk.ps1 skia
  .\build_apk.ps1 skia debug
  .\build_apk.ps1 skia release arm32   # 老车机 32 位包
  .\build_apk.ps1 -CheckOnly           # 只打印解析到的 flutter/JDK/SDK，不构建
.NOTES
  若提示“无法加载文件，因为在此系统上禁止运行脚本”，执行一次即可：
    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  或单次绕过：
    pwsh -ExecutionPolicy Bypass -File .\build_apk.ps1 skia
#>
[CmdletBinding()]
param(
    [string]$Renderer = 'impeller',
    [string]$BuildType = 'release',
    [string]$Abi = 'arm64',
    # 只解析并打印工具链环境，不执行构建（换机器 / 排查 PATH 问题时用，秒出结果）
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

Write-Host '============================================'
Write-Host '  时音 - APK 构建工具 (ps1)'
Write-Host '============================================'

# 兼容老用法：第一个参数是构建类型时视为 impeller + 该类型
if ($Renderer -in @('release', 'debug')) {
    $BuildType = $Renderer
    $Renderer = 'impeller'
}
if ($Renderer -notin @('impeller', 'skia')) {
    Write-Error "渲染引擎只能是 impeller 或 skia，当前: $Renderer"
    exit 1
}
if ($BuildType -notin @('release', 'debug')) {
    Write-Error "构建类型只能是 release 或 debug，当前: $BuildType"
    exit 1
}
if ($Abi -notin @('arm64', 'arm32')) {
    Write-Error "ABI 只能是 arm64 或 arm32，当前: $Abi"
    exit 1
}

# 以脚本所在目录为仓库根，不依赖写死盘符
Set-Location $PSScriptRoot

# 工具链定位统一交给 scripts/flutter-env.ps1：
# 环境变量（FLUTTER_ROOT / JAVA_HOME / ANDROID_HOME）→ PATH → 常见安装位置。
# 以前这里的兜底路径写死成 E:\...，换到没有 E: 盘的机器就两条都落空。
. (Join-Path $PSScriptRoot 'scripts\flutter-env.ps1')

$flutter = Resolve-FlutterPath
if (-not $flutter) {
    Write-Error ('找不到 flutter：请把 Flutter SDK 的 bin 加入 PATH，或设置 FLUTTER_ROOT 环境变量' +
        '（例：setx FLUTTER_ROOT C:\develop\flutter\flutter，然后重开终端）')
    exit 1
}
if (-not $env:JAVA_HOME) { $env:JAVA_HOME = Resolve-JdkHome }
if (-not $env:ANDROID_HOME) { $env:ANDROID_HOME = Resolve-AndroidSdk }
$env:JAVA_TOOL_OPTIONS = '-Dfile.encoding=UTF-8'

Write-Host "[flutter]      $flutter" -ForegroundColor DarkGray
Write-Host "[JAVA_HOME]    $(if ($env:JAVA_HOME) { $env:JAVA_HOME } else { '(未设置，交给 Gradle 从 PATH 找 java)' })" -ForegroundColor DarkGray
Write-Host "[ANDROID_HOME] $(if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { '(未设置)' })" -ForegroundColor DarkGray

if ($CheckOnly) {
    Write-Host ''
    Write-Host '[仅检查] 以上环境已解析，-CheckOnly 跳过构建。' -ForegroundColor Yellow
    exit 0
}

Write-Host "[渲染引擎] $Renderer"
Write-Host "[构建类型] $BuildType"
Write-Host "[目标 ABI] $Abi"

Write-Host ''
Write-Host '[0/4] 检查是否需要清理...'
$variant = "$Renderer-$Abi"
$stamp = Join-Path 'build' '.last_variant'
$last = ''
if (Test-Path $stamp) { $last = (Get-Content $stamp -Raw).Trim() }
if ($last -ne $variant) {
    if ($last) {
        Write-Host "变体切换（$last --> $variant），执行 flutter clean..."
    } else {
        Write-Host '上次构建记录不存在，执行 flutter clean 确保干净构建...'
    }
    & $flutter clean
    if ($LASTEXITCODE -ne 0) { exit 1 }
    if (-not (Test-Path 'build')) { New-Item -ItemType Directory 'build' | Out-Null }
    Set-Content -NoNewline -Encoding utf8NoBOM -Path $stamp -Value $variant
} else {
    Write-Host "同一变体（$variant），跳过 clean，走增量构建。"
}

Write-Host ''
Write-Host '[1/4] 安装依赖...'
& $flutter pub get
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ''
Write-Host '[2/4] 代码分析...'
& $flutter analyze
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ''
Write-Host '[3/4] 构建 APK...'
# --target-platform 的 32 位值是 android-arm（非 android-arm32）。
$flutterTarget = 'android-arm64'
if ($Abi -eq 'arm32') { $flutterTarget = 'android-arm' }
& $flutter build apk --$BuildType --target-platform $flutterTarget --flavor $Renderer --dart-define=APP_RENDERER=$Renderer --dart-define=APP_ABI=$Abi
if ($LASTEXITCODE -ne 0) { exit 1 }

$apk = Join-Path 'build\app\outputs\flutter-apk' "app-$Renderer-$BuildType.apk"
Write-Host ''
Write-Host '============================================'
if (Test-Path $apk) {
    $mb = '{0:N1}' -f ((Get-Item $apk).Length / 1MB)
    Write-Host "  [成功] 构建成功！（$mb MB）" -ForegroundColor Green
    Write-Host "  APK：$apk"
} else {
    Write-Host '  [成功] 构建命令已完成，但未找到预期产物：' -ForegroundColor Yellow
    Write-Host "  $apk"
}
Write-Host '============================================'
Write-Host ''
Write-Host '用法: .\build_apk.ps1 [impeller|skia] [release|debug] [arm64|arm32]'
Write-Host '  默认: impeller + release + arm64'
Write-Host '  示例: .\build_apk.ps1、.\build_apk.ps1 skia、'
Write-Host '        .\build_apk.ps1 skia release arm32（老车机 32 位包）'
