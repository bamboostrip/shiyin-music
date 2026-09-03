@echo off
chcp 65001 >nul
echo ============================================
echo   时音 (Shiyin) - APK 构建工具
echo ============================================
echo.

setlocal
set JAVA_HOME=E:\jdk17\jdk-17.0.12+7
set ANDROID_HOME=E:\AIwork\android-sdk
set JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8
set PATH=%JAVA_HOME%\bin;%ANDROID_HOME%\platform-tools;%PATH%

cd /d "%~dp0"

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

echo [0/4] 检查是否需要清理...
rem 切渲染器必须 clean：--dart-define=APP_RENDERER 是编译期烘焙常量，
rem 不清可能复用上个变体的 kernel 缓存，导致关于页标签和更新选包串味。
rem Gradle 变体产物本身是隔离的，不用担心。用 build\.last_renderer
rem （gitignored）记住上次变体，同变体走增量构建不浪费时间。
set STAMP=build\.last_renderer
set LAST_RENDERER=
if exist "%STAMP%" set /p LAST_RENDERER=<"%STAMP%"
if not "%LAST_RENDERER%"=="%RENDERER%" (
    if "%LAST_RENDERER%"=="" (
        echo 上次构建记录不存在，执行 flutter clean 确保干净构建...
    ) else (
        echo 渲染器切换（%LAST_RENDERER% --^> %RENDERER%），执行 flutter clean...
    )
    call E:\flutter\flutter\bin\flutter.bat clean
    if %ERRORLEVEL% neq 0 (
        echo [失败] clean 出错
        pause
        exit /b 1
    )
    if not exist build mkdir build
    echo %RENDERER%>"%STAMP%"
) else (
    echo 同一渲染器（%RENDERER%），跳过 clean，走增量构建。
)

echo.
echo [1/4] 安装依赖...
call E:\flutter\flutter\bin\flutter.bat pub get
if %ERRORLEVEL% neq 0 (
    echo [失败] pub get 出错
    pause
    exit /b 1
)

echo.
echo [2/4] 代码分析...
call E:\flutter\flutter\bin\flutter.bat analyze
if %ERRORLEVEL% neq 0 (
    echo [失败] 分析出错，请检查代码
    pause
    exit /b 1
)

echo.
echo [3/4] 构建 APK...
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
