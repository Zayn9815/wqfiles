#define MyAppName "WQGlass Transfer"
#define MyAppVersion "2.2.0"
#define MyAppPublisher "WQ Glass"
#define MyAppExeName "WQGlassTransfer.exe"

[Setup]
AppId={{8F9C312D-9F6A-42D7-9D1C-8A543E1A2201}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
SetupIconFile=Assets\AppIcon.ico
UninstallDisplayIcon={app}\{#MyAppExeName}
AllowNoIcons=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=dist
OutputBaseFilename=WQGlassTransfer-Setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "publish\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "netsh.exe"; Parameters: "advfirewall firewall add rule name=""WQGlass Transfer TCP"" dir=in action=allow protocol=TCP localport=8765-8780 profile=private program=""{app}\{#MyAppExeName}"""; Flags: runhidden; Check: IsAdminInstallMode
Filename: "netsh.exe"; Parameters: "advfirewall firewall add rule name=""WQGlass Transfer UDP"" dir=in action=allow protocol=UDP localport=45888 profile=private program=""{app}\{#MyAppExeName}"""; Flags: runhidden; Check: IsAdminInstallMode
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "netsh.exe"; Parameters: "advfirewall firewall delete rule name=""WQGlass Transfer TCP"""; Flags: runhidden; RunOnceId: "RemoveFirewallTCP"; Check: IsAdminInstallMode
Filename: "netsh.exe"; Parameters: "advfirewall firewall delete rule name=""WQGlass Transfer UDP"""; Flags: runhidden; RunOnceId: "RemoveFirewallUDP"; Check: IsAdminInstallMode
