; 时音 Windows 安装包脚本（Inno Setup 6，需 Unicode 版）。
;
; CI / 本机用法（SourceDir 必须传绝对路径，Inno 相对路径以本 .iss 所在目录解析）：
;   ISCC.exe /DAppVersion=2.5.2 /DFileVersion=2.5.2.0 ^
;            /DSourceDir=<repo>\build\dist\portable /O<repo>\build\dist installer\shiyin.iss
;
; 设计要点（与 docs/release-process.md 保持一致）：
; - 伪便携：数据存 %APPDATA%，与安装目录无关；卸载不清理用户数据。
; - per-user 安装到 {localappdata}\ShiyinMusic，免 UAC（PrivilegesRequired=lowest）。
; - CloseApplications=yes：安装时通过 Restart Manager 提示关闭正在运行的时音。
; - 安装 installed_by_inno.flag 到 {app}：应用内更新靠它区分安装版/便携版，
;   绝不能打进 portable.zip（便携包由 CI 从 SourceDir 直接压缩，不含本文件）。

#ifndef AppVersion
#define AppVersion "0.0.0"
#endif
#ifndef FileVersion
#define FileVersion "0.0.0.0"
#endif
#ifndef SourceDir
#define SourceDir "..\build\windows\x64\runner\Release"
#endif

[Setup]
; AppId 一经发布不可更改（Inno 靠它识别同一应用的升级/卸载）。
AppId={{53E8B6D2-7C41-4F5A-9D6E-1A0B2C3D4E5F}
AppName=时音
AppVersion={#AppVersion}
AppVerName=时音 {#AppVersion}
AppPublisher=bamboostrip
AppPublisherURL=https://github.com/bamboostrip/shiyin-music
AppUpdatesURL=https://github.com/bamboostrip/shiyin-music/releases/latest
VersionInfoVersion={#FileVersion}
DefaultDirName={localappdata}\ShiyinMusic
DefaultGroupName=时音
DisableProgramGroupPage=yes
; per-user 安装：不写 HKLM / Program Files，全程免 UAC。
PrivilegesRequired=lowest
UsedUserAreasWarning=no
; 安装/卸载时通过 Restart Manager 检测并提示关闭占用文件的进程。
CloseApplications=yes
RestartApplications=no
OutputBaseFilename=shiyin-windows-x64-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
UninstallDisplayName=时音
UninstallDisplayIcon={app}\ShiyinMusic.exe
SetupIconFile=..\windows\runner\resources\app_icon.ico

[Languages]
; 随仓的 Languages/ChineseSimplified.isl 保证本机 winget 精简版与 CI 通用版
; 都能编出中文向导（Inno 原生支持编译时 #include 相对路径，CI 的 choco 完整版
; 自带该文件也能通过；本机缺中文包时不因语言缺失编译失败）。
Name: "chinesesimp"; MessagesFile: "Languages\ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; \
  GroupDescription: "{cm:AdditionalIcons}"

[Files]
; 与 portable.zip 同源的完整运行目录（exe + dll + data）。
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
; 形态标记：仅在安装版存在，供应用内更新判定分发形态。
Source: "installed_by_inno.flag"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\时音"; Filename: "{app}\ShiyinMusic.exe"
Name: "{autodesktop}\时音"; Filename: "{app}\ShiyinMusic.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\ShiyinMusic.exe"; Description: "{cm:LaunchProgram,时音}"; \
  Flags: nowait postinstall skipifsilent
