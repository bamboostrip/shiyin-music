@echo off
chcp 65001 >nul
echo ============================================
echo   kgka_Music_hl - APK 构建工具
echo ============================================
echo.

setlocal
set JAVA_HOME=E:\jdk17\jdk-17.0.12+7
set ANDROID_HOME=E:\AIwork\android-sdk
set JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8
set PATH=%JAVA_HOME%\bin;%ANDROID_HOME%\platform-tools;%PATH%

cd /d E:\AIwork\kgka_Music_hl

rem 用法: build_apk.bat [impeller^|skia] [release^|debug]
rem   第一个参数是渲染引擎，默认 impeller（老机器闪退/冻屏再打 skia 版）
rem   第二个参数是构建类型，默认 release
rem   兼容老用法：build_apk.bat debug 仍表示 impeller + debug
set RENDERER=%1
set BUILD_TYPE=%2
if "%RENDERER%"=="" set RENDERER=impeller
if "%RENDERER%"=="release" (
    set BUILD_TYPE=release
    set RENDERER=impeller
)
if "%RENDERER%"=="debug" (
    set BUILD_TYPE=debug
    set RENDERER=impeller
)
if "%BUILD_TYPE%"=="" set BUILD_TYPE=release

if not "%RENDERER%"=="impeller" if not "%RENDERER%"=="skia" (
    echo [失败] 渲染引擎只能是 impeller 或 skia，当前: %RENDERER%
    pause
    exit /b 1
)

echo [渲染引擎] %RENDERER%
echo [构建类型] %BUILD_TYPE%
echo.

echo [1/3] 安装依赖...
call E:\flutter\flutter\bin\flutter.bat pub get
if %ERRORLEVEL% neq 0 (
    echo [失败] pub get 出错
    pause
    exit /b 1
)

echo.
echo [2/3] 代码分析...
call E:\flutter\flutter\bin\flutter.bat analyze
if %ERRORLEVEL% neq 0 (
    echo [失败] 分析出错，请检查代码
    pause
    exit /b 1
)

echo.
echo [3/3] 构建 APK...
call E:\flutter\flutter\bin\flutter.bat build apk --%BUILD_TYPE% --flavor %RENDERER% --dart-define=APP_RENDERER=%RENDERER%
if %ERRORLEVEL% neq 0 (
    echo [失败] 构建出错
    pause
    exit /b 1
)

echo.
echo ============================================
echo   ^[成功^] 构建成功！
echo   APK：build\app\outputs\flutter-apk\app-%RENDERER%-%BUILD_TYPE%.apk
echo ============================================
echo.
echo 用法: build_apk.bat [impeller^|skia] [release^|debug]
echo   默认: impeller + release
echo   示例: build_apk.bat（默认）、build_apk.bat skia、build_apk.bat skia release
pause
