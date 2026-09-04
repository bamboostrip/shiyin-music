<#
.SYNOPSIS
  时音 Windows 桌面客户端构建脚本（pwsh 版，与 build_windows.bat 同功能）。
.DESCRIPTION
  用法: .\build_windows.ps1 [release|debug]
    构建类型默认 release。
    产物在 build\windows\x64\runner\<Release|Debug>\，
    分发时把该目录整个打包（exe + dll + data 缺一不可）。
.EXAMPLE
  .\build_windows.ps1
  .\build_windows.ps1 debug
.NOTES
  若提示"无法加载文件，因为在此系统上禁止运行脚本"，执行一次即可：
    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
  或单次绕过：
    pwsh -ExecutionPolicy Bypass -File .\build_windows.ps1
#>
[CmdletBinding()]
param(
    [string]$BuildType = 'release'
)

$ErrorActionPreference = 'Stop'

Write-Host '============================================'
Write-Host '  时音 - Windows 客户端构建工具 (ps1)'
Write-Host '============================================'

if ($BuildType -notin @('release', 'debug')) {
    Write-Error "构建类型只能是 release 或 debug，当前: $BuildType"
    exit 1
}

# 以脚本所在目录为仓库根，不依赖写死盘符
Set-Location $PSScriptRoot

# 兼容 Windows PowerShell 5.1：不用 ?. 操作符
$flutterCmd = Get-Command flutter -ErrorAction SilentlyContinue
$flutter = $null
if ($null -ne $flutterCmd) { $flutter = $flutterCmd.Source }
if (-not $flutter) {
    $fallback = 'E:\flutter\flutter\bin\flutter.bat'
    if (Test-Path $fallback) { $flutter = $fallback }
}
if (-not $flutter) {
    Write-Error '找不到 flutter：请先安装并加入 PATH'
    exit 1
}

Write-Host "[构建类型] $BuildType"

Write-Host ''
Write-Host '[0/3] 安装依赖...'
& $flutter pub get
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ''
Write-Host '[1/3] 代码分析...'
& $flutter analyze
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ''
Write-Host '[2/3] 构建 Windows 客户端...'
& $flutter build windows --$BuildType
if ($LASTEXITCODE -ne 0) { exit 1 }

$dir = Join-Path 'build\windows\x64\runner' (Get-Culture).TextInfo.ToTitleCase($BuildType)
$exe = Join-Path $dir 'kgka_music_hl.exe'
Write-Host ''
Write-Host '============================================'
if (Test-Path $exe) {
    $mb = '{0:N1}' -f ((Get-Item $exe).Length / 1MB)
    $dirMb = '{0:N1}' -f ((Get-ChildItem $dir -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB)
    Write-Host "  [成功] 构建成功！（exe $mb MB，整目录 $dirMb MB）" -ForegroundColor Green
    Write-Host "  产物目录：$dir"
    Write-Host '  分发时把整个目录打包（exe + dll + data 缺一不可）'
} else {
    Write-Host '  [成功] 构建命令已完成，但未找到预期产物：' -ForegroundColor Yellow
    Write-Host "  $exe"
}
Write-Host '============================================'
Write-Host ''
Write-Host '用法: .\build_windows.ps1 [release|debug]'
Write-Host '  默认: release'
Write-Host '  示例: .\build_windows.ps1、.\build_windows.ps1 debug'
