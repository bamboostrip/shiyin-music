<#
.SYNOPSIS
  构建脚本共用的「工具链定位」逻辑（只定义函数，不产生副作用）。

.DESCRIPTION
  为什么单独抽一个文件：`build_apk.ps1` 与 `build_windows.ps1` 过去各自把
  兜底路径写死成 `E:\flutter\flutter\bin\flutter.bat`。那套路径来自另一台
  机器（E: 盘），换机后两条查找路径都落空，直接报"找不到 flutter"。
  现在统一按「环境变量 → PATH → 常见安装位置」的顺序探测，换机器无需改脚本。

  约定：
    * 只在找到可执行文件时才返回路径，找不到返回 $null，由调用方决定报错文案；
    * 探测列表按 Windows 上 Flutter/JDK/SDK 的实际常见布局排列，先命中先用。
#>

<#
.SYNOPSIS
  定位 flutter.bat 的绝对路径。
.DESCRIPTION
  查找顺序：
    1. 环境变量 $env:FLUTTER_ROOT / $env:FLUTTER_HOME（Flutter 官方约定 SDK 根）
    2. PATH 里的 flutter
    3. 常见安装位置（含旧脚本用过的 E:\flutter\flutter，兼容老机器）
.PARAMETER SearchRoots
  自定义探测根目录（SDK 根，即 bin 的上一级）。一般不用传。
#>
function Resolve-FlutterPath {
    [CmdletBinding()]
    param([string[]]$SearchRoots)

    foreach ($envName in @('FLUTTER_ROOT', 'FLUTTER_HOME')) {
        $root = [Environment]::GetEnvironmentVariable($envName)
        if (-not $root) { continue }
        $candidate = Join-Path $root 'bin\flutter.bat'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }

    if (-not $SearchRoots) {
        $SearchRoots = @(
            'C:\develop\flutter\flutter',
            'D:\develop\flutter\flutter',
            'E:\flutter\flutter',
            'C:\flutter\flutter',
            'D:\flutter\flutter',
            'C:\src\flutter',
            (Join-Path $HOME 'flutter\flutter'),
            (Join-Path $HOME 'development\flutter')
        )
    }
    foreach ($root in $SearchRoots) {
        $candidate = Join-Path $root 'bin\flutter.bat'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

<#
.SYNOPSIS
  定位 JDK 根目录（含 bin\java.exe 的那一层）。
.DESCRIPTION
  查找顺序：$env:JAVA_HOME → PATH 里的 java 反推 → 常见安装位置。
  返回 $null 表示没找到——调用方应保持 JAVA_HOME 未设置，让 Flutter/Gradle
  自己从 PATH 找 java。
#>
function Resolve-JdkHome {
    [CmdletBinding()]
    param([string[]]$SearchRoots)

    if ($env:JAVA_HOME -and (Test-Path -LiteralPath (Join-Path $env:JAVA_HOME 'bin\java.exe'))) {
        return $env:JAVA_HOME
    }

    # 从 PATH 上的 java 反推：<JDK>\bin\java.exe → <JDK>
    # 注意别用 $home 当变量名：PowerShell 变量名大小写不敏感，会撞只读的 $HOME。
    $java = Get-Command java -ErrorAction SilentlyContinue
    if ($java -and $java.Source) {
        $jdkRoot = Split-Path -Parent (Split-Path -Parent $java.Source)
        if ($jdkRoot -and (Test-Path -LiteralPath (Join-Path $jdkRoot 'bin\java.exe'))) { return $jdkRoot }
    }

    if (-not $SearchRoots) {
        $SearchRoots = @(
            'C:\develop\jdk',
            'C:\develop\jdk17',
            'C:\develop\jdk21',
            'C:\Program Files\Java\jdk-21',
            'C:\Program Files\Java\jdk-17',
            'E:\jdk17\jdk-17.0.12+7',
            'D:\jdk17'
        )
    }
    foreach ($root in $SearchRoots) {
        if (Test-Path -LiteralPath (Join-Path $root 'bin\java.exe')) { return $root }
    }
    return $null
}

<#
.SYNOPSIS
  定位 Android SDK 根目录。
.DESCRIPTION
  查找顺序：$env:ANDROID_HOME → $env:ANDROID_SDK_ROOT → 常见安装位置。
  用「目录里有 platform-tools」作为有效性判据，避免命中同名空目录。
#>
function Resolve-AndroidSdk {
    [CmdletBinding()]
    param([string[]]$SearchRoots)

    foreach ($envName in @('ANDROID_HOME', 'ANDROID_SDK_ROOT')) {
        $root = [Environment]::GetEnvironmentVariable($envName)
        if ($root -and (Test-Path -LiteralPath (Join-Path $root 'platform-tools'))) { return $root }
    }

    if (-not $SearchRoots) {
        $SearchRoots = @(
            'C:\develop\Android\SDK',
            'C:\develop\Android\Sdk',
            (Join-Path $env:LOCALAPPDATA 'Android\Sdk'),
            'C:\Android\Sdk',
            'D:\Android\Sdk',
            'E:\AIwork\android-sdk'
        )
    }
    foreach ($root in $SearchRoots) {
        if (Test-Path -LiteralPath (Join-Path $root 'platform-tools')) { return $root }
    }
    return $null
}
