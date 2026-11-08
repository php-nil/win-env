;
; win-env - Notepad3 one-click installer for Windows x64
;
; Compiled by builders/notepad3/build.ps1 via ISCC.exe with these defines:
;   /DMyAppVersion=<7.26.602.1>           full version, for display strings
;   /DMyAppNumericVersion=<7.26.602.1>    numeric-only, for VersionInfoVersion
;   /DStageDir=<staged binary tree>
;   /DOutputDir=<output folder>
;   /DOutputBaseFilename=<setup exe base name>
;
#ifndef MyAppVersion
  #error MyAppVersion must be defined, e.g. /DMyAppVersion=7.26.602.1
#endif
#ifndef MyAppNumericVersion
  #error MyAppNumericVersion must be defined, e.g. /DMyAppNumericVersion=7.26.602.1
#endif
#ifndef StageDir
  #error StageDir must be defined
#endif
#ifndef OutputDir
  #define OutputDir "output"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "notepad3-setup-x64"
#endif

; Every association registry entry is gated on this task list (Inno processes
; the entry if ANY listed task is selected), so nothing is written when the
; user unchecks all file types.
#define AssocTasks "assoc_txt assoc_log assoc_ini assoc_md assoc_json assoc_xml assoc_yml assoc_yaml assoc_csv assoc_bat assoc_cmd assoc_ps1"

[Setup]
; A fixed AppId makes upgrades/reinstalls replace the same installation.
AppId={{5E9B0C7A-3D2F-4A81-B6C4-9F2D7E1A8B35}
AppName=Notepad3
AppVersion={#MyAppVersion}
AppVerName=Notepad3 {#MyAppVersion} (x64)
AppPublisher=win-env
AppComments=Notepad3 text editor (x64 portable build), packaged by win-env
DefaultDirName=C:\pf\Notepad3
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; Icon extracted from the official Notepad3.exe icon resources
; (builders/notepad3/setup.ico, includes 16..256 px frames).
SetupIconFile=setup.ico
UninstallDisplayIcon={app}\Notepad3.exe
UninstallDisplayName=Notepad3 {#MyAppVersion} (x64, win-env)
VersionInfoVersion={#MyAppNumericVersion}
VersionInfoCompany=win-env
VersionInfoDescription=Notepad3 (x64) one-click installer
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}

; ChineseSimplified.isl is NOT shipped by the official Inno Setup installer
; (it lives in issrc/Files/Languages), so it is vendored next to this script.
#define LangDir SourcePath + "Languages\"

[Languages]
Name: "chinesesimp"; MessagesFile: "{#LangDir}ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
; Desktop shortcut is opt-in; the Start menu entry is always created.
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务:"; Flags: unchecked
; File types are only registered as "Open with" candidates - never as the
; default program (see doc/notepad3.md).
Name: "assoc_txt";  Description: ".txt · 纯文本";  GroupDescription: "将 Notepad3 加入以下文件类型的「打开方式」列表（不会改变默认程序）:"
Name: "assoc_log";  Description: ".log · 日志";    GroupDescription: "将 Notepad3 加入以下文件类型的「打开方式」列表（不会改变默认程序）:"
Name: "assoc_ini";  Description: ".ini · 配置";    GroupDescription: "将 Notepad3 加入以下文件类型的「打开方式」列表（不会改变默认程序）:"
Name: "assoc_md";   Description: ".md · Markdown"; GroupDescription: "将 Notepad3 加入以下文件类型的「打开方式」列表（不会改变默认程序）:"
Name: "assoc_json"; Description: ".json";          GroupDescription: "将 Notepad3 加入以下文件类型的「打开方式」列表（不会改变默认程序）:"
Name: "assoc_xml";  Description: ".xml";           GroupDescription: "将 Notepad3 加入以下文件类型的「打开方式」列表（不会改变默认程序）:"
Name: "assoc_yml";  Description: ".yml";           GroupDescription: "将 Notepad3 加入以下文件类型的「打开方式」列表（不会改变默认程序）:"
Name: "assoc_yaml"; Description: ".yaml";          GroupDescription: "将 Notepad3 加入以下文件类型的「打开方式」列表（不会改变默认程序）:"
Name: "assoc_csv";  Description: ".csv";           GroupDescription: "将 Notepad3 加入以下文件类型的「打开方式」列表（不会改变默认程序）:"
Name: "assoc_bat";  Description: ".bat · 批处理（默认不勾选）"; GroupDescription: "将 Notepad3 加入以下文件类型的「打开方式」列表（不会改变默认程序）:"; Flags: unchecked
Name: "assoc_cmd";  Description: ".cmd · 批处理（默认不勾选）"; GroupDescription: "将 Notepad3 加入以下文件类型的「打开方式」列表（不会改变默认程序）:"; Flags: unchecked
Name: "assoc_ps1";  Description: ".ps1 · PowerShell 脚本（默认不勾选）"; GroupDescription: "将 Notepad3 加入以下文件类型的「打开方式」列表（不会改变默认程序）:"; Flags: unchecked
; Offers the Default Apps settings page after install; the association cannot
; be made default silently (UserChoice hash + Windows 11 UCPD).
Name: "opendefaultapps"; Description: "安装完成后打开 Windows「默认应用」设置页，由我手动确认一次设为默认"; GroupDescription: "安装完成后:"

[Files]
; The staging tree is the official portable zip (already trimmed to en-GB
; and zh-CN language packs): the installer only unpacks, it never downloads.
; Notepad3.ini is a user-editable config in the install dir, so it is written
; only when absent and never removed by the uninstaller. Themes\ and
; Favorites\ are likewise user-editable: pre-existing files win, so an
; upgrade never overwrites local edits.
Source: "{#StageDir}\*"; DestDir: "{app}"; Excludes: "Notepad3.ini,Themes\*,Favorites\*"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "{#StageDir}\Notepad3.ini"; DestDir: "{app}"; Flags: onlyifdoesntexist uninsneveruninstall
Source: "{#StageDir}\Themes\*"; DestDir: "{app}\Themes"; Flags: recursesubdirs createallsubdirs onlyifdoesntexist ignoreversion
; Favorites\ ships empty (no files in the upstream zip), so the folder itself
; needs an explicit [Dirs] entry; it is removed again when empty.
[Dirs]
Name: "{app}\Favorites"

[Icons]
Name: "{group}\Notepad3"; Filename: "{app}\Notepad3.exe"; WorkingDir: "{app}"; Comment: "Notepad3 文本编辑器"
Name: "{commondesktop}\Notepad3"; Filename: "{app}\Notepad3.exe"; WorkingDir: "{app}"; Comment: "Notepad3 文本编辑器"; Tasks: desktopicon

[Registry]
; ---- Application registration --------------------------------------------
; Applications\Notepad3.exe doubles as the ProgID referenced by the
; capabilities below (the same identity Explorer's "Open with" uses).
Root: HKLM; Subkey: "SOFTWARE\Classes\Applications\Notepad3.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "Notepad3"; Tasks: {#AssocTasks}; Flags: uninsdeletekey
Root: HKLM; Subkey: "SOFTWARE\Classes\Applications\Notepad3.exe"; ValueType: string; ValueName: "DefaultIcon"; ValueData: "{app}\Notepad3.exe,0"; Tasks: {#AssocTasks}
Root: HKLM; Subkey: "SOFTWARE\Classes\Applications\Notepad3.exe\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\Notepad3.exe"" ""%1"""; Tasks: {#AssocTasks}

; ---- SupportedTypes (drives the "Open with" list) ------------------------
Root: HKLM; Subkey: "SOFTWARE\Classes\Applications\Notepad3.exe\SupportedTypes"; ValueType: string; ValueName: ".txt";  ValueData: ""; Tasks: assoc_txt;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\Applications\Notepad3.exe\SupportedTypes"; ValueType: string; ValueName: ".log";  ValueData: ""; Tasks: assoc_log;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\Applications\Notepad3.exe\SupportedTypes"; ValueType: string; ValueName: ".ini";  ValueData: ""; Tasks: assoc_ini;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\Applications\Notepad3.exe\SupportedTypes"; ValueType: string; ValueName: ".md";   ValueData: ""; Tasks: assoc_md;   Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\Applications\Notepad3.exe\SupportedTypes"; ValueType: string; ValueName: ".json"; ValueData: ""; Tasks: assoc_json; Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\Applications\Notepad3.exe\SupportedTypes"; ValueType: string; ValueName: ".xml";  ValueData: ""; Tasks: assoc_xml;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\Applications\Notepad3.exe\SupportedTypes"; ValueType: string; ValueName: ".yml";  ValueData: ""; Tasks: assoc_yml;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\Applications\Notepad3.exe\SupportedTypes"; ValueType: string; ValueName: ".yaml"; ValueData: ""; Tasks: assoc_yaml; Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\Applications\Notepad3.exe\SupportedTypes"; ValueType: string; ValueName: ".csv";  ValueData: ""; Tasks: assoc_csv;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\Applications\Notepad3.exe\SupportedTypes"; ValueType: string; ValueName: ".bat";  ValueData: ""; Tasks: assoc_bat;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\Applications\Notepad3.exe\SupportedTypes"; ValueType: string; ValueName: ".cmd";  ValueData: ""; Tasks: assoc_cmd;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\Applications\Notepad3.exe\SupportedTypes"; ValueType: string; ValueName: ".ps1";  ValueData: ""; Tasks: assoc_ps1;  Flags: uninsdeletevalue

; ---- OpenWithProgids (REG_NONE values on the extension keys) -------------
; "none" is Inno's REG_NONE: a value name with no data, which is exactly what
; Explorer expects here. The extension keys themselves belong to Windows, so
; only our own value is removed on uninstall.
Root: HKLM; Subkey: "SOFTWARE\Classes\.txt\OpenWithProgids";  ValueType: none; ValueName: "Applications\Notepad3.exe"; Tasks: assoc_txt;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\.log\OpenWithProgids";  ValueType: none; ValueName: "Applications\Notepad3.exe"; Tasks: assoc_log;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\.ini\OpenWithProgids";  ValueType: none; ValueName: "Applications\Notepad3.exe"; Tasks: assoc_ini;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\.md\OpenWithProgids";   ValueType: none; ValueName: "Applications\Notepad3.exe"; Tasks: assoc_md;   Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\.json\OpenWithProgids"; ValueType: none; ValueName: "Applications\Notepad3.exe"; Tasks: assoc_json; Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\.xml\OpenWithProgids";  ValueType: none; ValueName: "Applications\Notepad3.exe"; Tasks: assoc_xml;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\.yml\OpenWithProgids";  ValueType: none; ValueName: "Applications\Notepad3.exe"; Tasks: assoc_yml;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\.yaml\OpenWithProgids"; ValueType: none; ValueName: "Applications\Notepad3.exe"; Tasks: assoc_yaml; Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\.csv\OpenWithProgids";  ValueType: none; ValueName: "Applications\Notepad3.exe"; Tasks: assoc_csv;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\.bat\OpenWithProgids";  ValueType: none; ValueName: "Applications\Notepad3.exe"; Tasks: assoc_bat;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\.cmd\OpenWithProgids";  ValueType: none; ValueName: "Applications\Notepad3.exe"; Tasks: assoc_cmd;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\Classes\.ps1\OpenWithProgids";  ValueType: none; ValueName: "Applications\Notepad3.exe"; Tasks: assoc_ps1;  Flags: uninsdeletevalue

; ---- Default Apps registration (machine-wide capability declaration) -----
; The value name below must stay "Notepad3": the ms-settings deep link uses
; it as registeredAppMachine=<value>.
Root: HKLM; Subkey: "SOFTWARE\RegisteredApplications"; ValueType: string; ValueName: "Notepad3"; ValueData: "Software\win-env\Notepad3\Capabilities"; Tasks: {#AssocTasks}; Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\win-env\Notepad3\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "Notepad3"; Tasks: {#AssocTasks}; Flags: uninsdeletekey
Root: HKLM; Subkey: "SOFTWARE\win-env\Notepad3\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "Notepad3 文本编辑器（win-env 打包）"; Tasks: {#AssocTasks}
Root: HKLM; Subkey: "SOFTWARE\win-env\Notepad3\Capabilities"; ValueType: string; ValueName: "ApplicationIcon"; ValueData: "{app}\Notepad3.exe,0"; Tasks: {#AssocTasks}
Root: HKLM; Subkey: "SOFTWARE\win-env\Notepad3\Capabilities\FileAssociations"; ValueType: string; ValueName: ".txt";  ValueData: "Applications\Notepad3.exe"; Tasks: assoc_txt;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\win-env\Notepad3\Capabilities\FileAssociations"; ValueType: string; ValueName: ".log";  ValueData: "Applications\Notepad3.exe"; Tasks: assoc_log;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\win-env\Notepad3\Capabilities\FileAssociations"; ValueType: string; ValueName: ".ini";  ValueData: "Applications\Notepad3.exe"; Tasks: assoc_ini;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\win-env\Notepad3\Capabilities\FileAssociations"; ValueType: string; ValueName: ".md";   ValueData: "Applications\Notepad3.exe"; Tasks: assoc_md;   Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\win-env\Notepad3\Capabilities\FileAssociations"; ValueType: string; ValueName: ".json"; ValueData: "Applications\Notepad3.exe"; Tasks: assoc_json; Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\win-env\Notepad3\Capabilities\FileAssociations"; ValueType: string; ValueName: ".xml";  ValueData: "Applications\Notepad3.exe"; Tasks: assoc_xml;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\win-env\Notepad3\Capabilities\FileAssociations"; ValueType: string; ValueName: ".yml";  ValueData: "Applications\Notepad3.exe"; Tasks: assoc_yml;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\win-env\Notepad3\Capabilities\FileAssociations"; ValueType: string; ValueName: ".yaml"; ValueData: "Applications\Notepad3.exe"; Tasks: assoc_yaml; Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\win-env\Notepad3\Capabilities\FileAssociations"; ValueType: string; ValueName: ".csv";  ValueData: "Applications\Notepad3.exe"; Tasks: assoc_csv;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\win-env\Notepad3\Capabilities\FileAssociations"; ValueType: string; ValueName: ".bat";  ValueData: "Applications\Notepad3.exe"; Tasks: assoc_bat;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\win-env\Notepad3\Capabilities\FileAssociations"; ValueType: string; ValueName: ".cmd";  ValueData: "Applications\Notepad3.exe"; Tasks: assoc_cmd;  Flags: uninsdeletevalue
Root: HKLM; Subkey: "SOFTWARE\win-env\Notepad3\Capabilities\FileAssociations"; ValueType: string; ValueName: ".ps1";  ValueData: "Applications\Notepad3.exe"; Tasks: assoc_ps1;  Flags: uninsdeletevalue

; Deliberately NOT touched anywhere in this script: HKCU\...\UserChoice, the
; default value of HKCR\.<ext>, txtfile, and Applications\notepad.exe / IFEO.

[Run]
; Opens the per-machine Default Apps page for this registration (the deep link
; takes the RegisteredApplications value name). runasoriginaluser is required:
; the elevated installer process cannot reliably hand an ms-settings: URI to
; the interactive shell.
Filename: "ms-settings:defaultapps?registeredAppMachine=Notepad3"; Description: "打开 Windows「默认应用」设置页，手动将 Notepad3 设为默认文本编辑器"; Flags: shellexec postinstall nowait skipifsilent runasoriginaluser; Tasks: opendefaultapps; Check: AnyAssocTaskSelected

[Code]
const
  EnvRegKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';
  HWND_BROADCAST_MSG = $FFFF;
  WM_SETTINGCHANGE = $001A;
  SMTO_ABORTIFHUNG = $0002;
  SHCNE_ASSOCCHANGED = $08000000;
  SHCNF_IDLIST = $0000;

var
  EnvMsgResult: DWORD;

procedure SendMessageTimeout(hWnd: Integer; Msg: Integer; wParam: Integer;
  lParam: String; fuFlags: Integer; uTimeout: Integer; var lpdwResult: DWORD);
  external 'SendMessageTimeoutW@user32.dll stdcall';

procedure SHChangeNotify(EventId: Integer; Flags: Integer;
  Item1: Integer; Item2: Integer);
  external 'SHChangeNotify@shell32.dll stdcall';

procedure BroadcastEnvironmentChange;
begin
  SendMessageTimeout(HWND_BROADCAST_MSG, WM_SETTINGCHANGE, 0,
    'Environment', SMTO_ABORTIFHUNG, 5000, EnvMsgResult);
end;

// True when at least one file type was selected: only then do we write (or
// later delete) the association registry entries and refresh the shell.
function AnyAssocTaskSelected: Boolean;
begin
  Result :=
    WizardIsTaskSelected('assoc_txt') or
    WizardIsTaskSelected('assoc_log') or
    WizardIsTaskSelected('assoc_ini') or
    WizardIsTaskSelected('assoc_md') or
    WizardIsTaskSelected('assoc_json') or
    WizardIsTaskSelected('assoc_xml') or
    WizardIsTaskSelected('assoc_yml') or
    WizardIsTaskSelected('assoc_yaml') or
    WizardIsTaskSelected('assoc_csv') or
    WizardIsTaskSelected('assoc_bat') or
    WizardIsTaskSelected('assoc_cmd') or
    WizardIsTaskSelected('assoc_ps1');
end;

function NormalizePathEntry(const P: String): String;
begin
  Result := LowerCase(Trim(P));
  StringChangeEx(Result, '/', '\', True);
  while (Length(Result) > 3) and (Result[Length(Result)] = '\') do
    Delete(Result, Length(Result), 1);
end;

// Add (OnInstall=True) or remove (OnInstall=False) Dir from the machine PATH.
// PATH update is mandatory: the installer guarantees the bare `Notepad3`
// command works from a new shell. Idempotent: never duplicates an entry and
// never wipes unrelated entries.
procedure UpdateSystemPath(const Dir: String; OnInstall: Boolean);
var
  OldPath, Part, Rebuilt, Target: String;
  List: TStringList;
  I: Integer;
  Present, Changed: Boolean;
begin
  Target := NormalizePathEntry(Dir);
  if Target = '' then
    exit;

  if not RegQueryStringValue(HKLM, EnvRegKey, 'Path', OldPath) then
  begin
    Log('System PATH could not be read, skipping PATH update');
    exit;
  end;

  List := TStringList.Create;
  try
    List.StrictDelimiter := True;
    List.Delimiter := ';';
    List.DelimitedText := OldPath;

    Present := False;
    Changed := False;
    Rebuilt := '';
    for I := 0 to List.Count - 1 do
    begin
      Part := Trim(List[I]);
      if Part = '' then
      begin
        Changed := True;
        Continue;
      end;
      if NormalizePathEntry(Part) = Target then
      begin
        Present := True;
        if not OnInstall then
        begin
          Changed := True;
          Continue;
        end;
      end;
      if Rebuilt <> '' then
        Rebuilt := Rebuilt + ';';
      Rebuilt := Rebuilt + Part;
    end;

    if OnInstall and not Present then
    begin
      if Rebuilt <> '' then
        Rebuilt := Rebuilt + ';';
      Rebuilt := Rebuilt + Trim(Dir);
      Changed := True;
    end;

    if Changed then
    begin
      if RegWriteExpandStringValue(HKLM, EnvRegKey, 'Path', Rebuilt) then
      begin
        Log('System PATH updated');
        BroadcastEnvironmentChange;
      end
      else
        Log('Failed to write system PATH');
    end
    else
      Log('System PATH already up to date');
  finally
    List.Free;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    UpdateSystemPath(ExpandConstant('{app}'), True);
    // Refresh Explorer's "Open with" menus right away instead of waiting for
    // the next shell event; skipped when no association was registered.
    if AnyAssocTaskSelected then
      SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, 0, 0);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    UpdateSystemPath(ExpandConstant('{app}'), False);
    // Only a notification - Explorer is never restarted by this installer.
    // Extensions that pointed at Notepad3 are left dangling by Windows itself
    // and will prompt the user to pick a program again.
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, 0, 0);
  end;
end;
