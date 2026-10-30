; Inno Setup 6 script for PlexiChore Desktop.
; Build:  .\publish.ps1 -Installer      (or)   ISCC.exe /DAppVersion=1.0.0 /DDistDir=..\dist installer\PlexiChore.iss

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef DistDir
  #define DistDir "..\dist"
#endif
#define AppName "PlexiChore Desktop"
#define AppExe "PlexiChore.exe"
#define AppPublisher "PNT Apps"
#define TcpRule "PlexiChore Stream (TCP 47800)"
#define UdpRule "PlexiChore Discovery (UDP 47801)"

[Setup]
AppId={{6B0E3C2A-6F7B-4B6E-9A43-2D51C0A7E9F4}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL=https://www.pntapps.com
AppCopyright=Copyright (C) 2026 PNT Apps. Licensed under GPL-3.0 (see LICENSE.txt and NOTICE.txt).
DefaultDirName={autopf}\PlexiChore
DefaultGroupName=PlexiChore
DisableProgramGroupPage=yes
OutputDir={#DistDir}
OutputBaseFilename=PlexiChoreSetup-{#AppVersion}
SetupIconFile=..\src\PlexiChore.App\Assets\PlexiChore.ico
UninstallDisplayIcon={app}\{#AppExe}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
MinVersion=10.0.17763
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"
Name: "startup"; Description: "Start PlexiChore when I sign in to Windows (runs in the tray)"; GroupDescription: "Startup:"
Name: "firewall"; Description: "Allow tablets on my network to connect (Windows Firewall rules for TCP 47800 / UDP 47801)"; GroupDescription: "Network:"

[Files]
Source: "{#DistDir}\{#AppExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md"; DestDir: "{app}"; Flags: ignoreversion isreadme
Source: "..\driver\README.md"; DestDir: "{app}\driver"; DestName: "README-driver.md"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "..\..\NOTICE"; DestDir: "{app}"; DestName: "NOTICE.txt"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\PlexiChore"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\PlexiChore"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; Same value the app writes from Settings -> "Start with Windows" (per user, HKCU Run).
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "PlexiChore"; \
    ValueData: """{app}\{#AppExe}"" --minimized"; Tasks: startup; Flags: uninsdeletevalue

[Run]
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#TcpRule}"""; Flags: runhidden; Tasks: firewall
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#UdpRule}"""; Flags: runhidden; Tasks: firewall
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#TcpRule}"" dir=in action=allow protocol=TCP localport=47800 profile=private,domain,public"; Flags: runhidden; Tasks: firewall; StatusMsg: "Adding firewall rules..."
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall add rule name=""{#UdpRule}"" dir=in action=allow protocol=UDP localport=47801 profile=private,domain,public"; Flags: runhidden; Tasks: firewall
Filename: "{app}\{#AppExe}"; Description: "Launch PlexiChore"; Flags: nowait postinstall skipifsilent runasoriginaluser

[UninstallRun]
Filename: "{cmd}"; Parameters: "/c taskkill /im {#AppExe} /f"; Flags: runhidden; RunOnceId: "KillApp"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#TcpRule}"""; Flags: runhidden; RunOnceId: "FwTcp"
Filename: "{sys}\netsh.exe"; Parameters: "advfirewall firewall delete rule name=""{#UdpRule}"""; Flags: runhidden; RunOnceId: "FwUdp"

[UninstallDelete]
; Downloaded platform-tools / driver payloads (user settings in %APPDATA% are kept).
Type: filesandordirs; Name: "{localappdata}\PlexiChore\platform-tools"
Type: filesandordirs; Name: "{localappdata}\PlexiChore\vdd"

[Code]
// The app runs as two PlexiChore.exe processes (tray app + window-less crash watchdog). Restart Manager cannot close
// the watchdog politely, so end both before files are replaced. Killed with /F, the watchdog sees exit code 1 and
// does not relaunch the app.
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  Code: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/F /IM {#AppExe}', '', SW_HIDE, ewWaitUntilTerminated, Code);
  Result := '';
end;
