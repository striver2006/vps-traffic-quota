; Inno Setup 6 脚本
; 用于为 VPS 流量监控生成 Windows 安装包（支持 x64 和 arm64）

#ifndef MyAppVersion
  #define MyAppVersion "1.0.1"
#endif

#ifndef AppArch
  #define AppArch "x64"
#endif

#ifndef SourceDir
  #define SourceDir "publish-" + AppArch
#endif

#define MyAppName "VPS 流量"
#define MyAppNameEn "VPSQuota"
#define MyAppPublisher "ChenZhenbo"
#define MyAppURL "https://github.com/striver2006/vps-traffic-quota"
#define MyAppExeName "VpsQuota.exe"

[Setup]
AppId={{C8E1B9A2-63FD-4A37-9753-48A5BCB163B8}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppVerName={#MyAppName} {#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={localappdata}\Programs\{#MyAppNameEn}
DisableProgramGroupPage=yes
OutputDir=dist
OutputBaseFilename=VPSQuota-Setup-win-{#AppArch}
SetupIconFile=VpsQuota\Assets\app.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
CloseApplications=yes
CloseApplicationsFilter=*.exe

#if AppArch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent
