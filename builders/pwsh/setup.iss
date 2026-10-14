;
; win-env - PowerShell 7 one-click installer for Windows x64
;
; Compiled by builders/pwsh/build.ps1 via ISCC.exe with these defines:
;   /DMyAppVersion=<7.6.6>                full version, for display strings
;   /DMyAppNumericVersion=<7.6.6.0>       numeric-only, for VersionInfoVersion
;   /DStageDir=<staged binary tree>
;   /DOutputDir=<output folder>
;   /DOutputBaseFilename=<setup exe base name>
;
#ifndef MyAppVersion
  #error MyAppVersion must be defined, e.g. /DMyAppVersion=7.6.6
#endif
#ifndef MyAppNumericVersion
  #error MyAppNumericVersion must be defined, e.g. /DMyAppNumericVersion=7.6.6.0
#endif
#ifndef StageDir
  #error StageDir must be defined
#endif
#ifndef OutputDir
  #define OutputDir "output"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "pwsh-setup-x64"
#endif

[Setup]
; A fixed AppId makes upgrades/reinstalls replace the same installation.
AppId={{E4A7C2D1-8B3F-4E6A-9D2C-5F1B8A3E7C94}
AppName=PowerShell 7
AppVersion={#MyAppVersion}
AppVerName=PowerShell {#MyAppVersion} (x64)
AppPublisher=win-env
AppComments=PowerShell 7 one-click installer, packaged by win-env
DefaultDirName=C:\pf\PowerShell7
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/max
; A 128 MB dictionary is the largest this (32-bit) ISCC encoder accepts —
; 256 MB fails with LZMA_Encode code 5 (param/memory). The ~280 MB staged
; tree therefore spans multiple solid blocks; accepted as the cost of a
; self-contained .NET runtime.
LZMADictionarySize=131072
SolidCompression=yes
WizardStyle=modern
; Icon extracted from the official pwsh.exe (builders/pwsh/setup.ico).
SetupIconFile=setup.ico
UninstallDisplayIcon={app}\pwsh.exe
UninstallDisplayName=PowerShell {#MyAppVersion} (x64, win-env)
VersionInfoVersion={#MyAppNumericVersion}
VersionInfoCompany=win-env
VersionInfoDescription=PowerShell 7 one-click installer
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}

; ChineseSimplified.isl is NOT shipped by the official Inno Setup installer
; (it lives in issrc/Files/Languages), so it is vendored next to this script.
#define LangDir SourcePath + "Languages\"

[Languages]
Name: "chinesesimp"; MessagesFile: "{#LangDir}ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

; Explorer context menu "在此处打开 PowerShell 7" on directories and on the
; directory background. Written under HKLM\SOFTWARE\Classes so it applies to
; all users (the installer requires admin anyway). On Windows 11 these classic
; verb entries live under "Show more options"; a first-level entry would need
; an MSIX sparse package + IExplorerCommand, which is out of Inno's scope.
[Registry]
Root: HKLM; Subkey: "SOFTWARE\Classes\Directory\shell\winenv-pwsh"; ValueType: string; ValueName: ""; ValueData: "在此处打开 PowerShell 7"; Flags: uninsdeletekey
Root: HKLM; Subkey: "SOFTWARE\Classes\Directory\shell\winenv-pwsh"; ValueType: string; ValueName: "Icon"; ValueData: "{app}\pwsh.exe,0"
Root: HKLM; Subkey: "SOFTWARE\Classes\Directory\shell\winenv-pwsh\command"; ValueType: string; ValueName: ""; ValueData: """{app}\pwsh.exe"" -NoExit -Command Set-Location -LiteralPath '%V'"
Root: HKLM; Subkey: "SOFTWARE\Classes\Directory\Background\shell\winenv-pwsh"; ValueType: string; ValueName: ""; ValueData: "在此处打开 PowerShell 7"; Flags: uninsdeletekey
Root: HKLM; Subkey: "SOFTWARE\Classes\Directory\Background\shell\winenv-pwsh"; ValueType: string; ValueName: "Icon"; ValueData: "{app}\pwsh.exe,0"
Root: HKLM; Subkey: "SOFTWARE\Classes\Directory\Background\shell\winenv-pwsh\command"; ValueType: string; ValueName: ""; ValueData: """{app}\pwsh.exe"" -NoExit -Command Set-Location -LiteralPath '%V'"

[Code]
const
  EnvRegKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';
  HWND_BROADCAST_MSG = $FFFF;
  WM_SETTINGCHANGE = $001A;
  SMTO_ABORTIFHUNG = $0002;

var
  EnvMsgResult: DWORD;

procedure SendMessageTimeout(hWnd: Integer; Msg: Integer; wParam: Integer;
  lParam: String; fuFlags: Integer; uTimeout: Integer; var lpdwResult: DWORD);
  external 'SendMessageTimeoutW@user32.dll stdcall';

procedure BroadcastEnvironmentChange;
begin
  SendMessageTimeout(HWND_BROADCAST_MSG, WM_SETTINGCHANGE, 0,
    'Environment', SMTO_ABORTIFHUNG, 5000, EnvMsgResult);
end;

function NormalizePathEntry(const P: String): String;
begin
  Result := LowerCase(Trim(P));
  StringChangeEx(Result, '/', '\', True);
  while (Length(Result) > 3) and (Result[Length(Result)] = '\') do
    Delete(Result, Length(Result), 1);
end;

// Add (OnInstall=True) or remove (OnInstall=False) Dir from the machine PATH.
// PATH update is mandatory: the installer guarantees the bare `pwsh` command
// works from a new shell. Idempotent: never duplicates an entry and never
// wipes unrelated entries.
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

// Windows Terminal discovers unpackaged-app profiles via JSON fragments under
// %ProgramData%\Microsoft\Windows Terminal\Fragments\<app>\*.json (system-wide,
// no per-user settings.json edits). The executable path must be the real
// install dir, so the fragment is written at install time, not staged.
// Content is pure ASCII, so AnsiString serialization is lossless.
procedure WriteWTFragment;
var
  FragmentDir, FragmentFile, ExePath: String;
  Content: AnsiString;
begin
  FragmentDir := ExpandConstant('{commonappdata}\Microsoft\Windows Terminal\Fragments\win-env-pwsh');
  if not ForceDirectories(FragmentDir) then
  begin
    Log('Failed to create WT fragment directory: ' + FragmentDir);
    exit;
  end;
  ExePath := ExpandConstant('{app}\pwsh.exe');
  StringChangeEx(ExePath, '\', '\\', True);
  Content := '{ "profiles": [ { "name": "PowerShell 7", "commandline": "' + ExePath +
             '", "icon": "' + ExePath + '", "startingDirectory": "%USERPROFILE%" } ] }';
  FragmentFile := FragmentDir + '\pwsh.json';
  if SaveStringToFile(FragmentFile, Content, False) then
    Log('Windows Terminal fragment written: ' + FragmentFile)
  else
    Log('Failed to write Windows Terminal fragment');
end;

procedure DeleteWTFragment;
var
  FragmentFile: String;
begin
  FragmentFile := ExpandConstant('{commonappdata}\Microsoft\Windows Terminal\Fragments\win-env-pwsh\pwsh.json');
  if DeleteFile(FragmentFile) then
    Log('Windows Terminal fragment deleted');
  // Remove the fragment folder if empty; harmless if Windows Terminal or
  // another fragment owner still uses it.
  RemoveDir(ExpandConstant('{commonappdata}\Microsoft\Windows Terminal\Fragments\win-env-pwsh'));
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    UpdateSystemPath(ExpandConstant('{app}'), True);
    WriteWTFragment;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    DeleteWTFragment;
    UpdateSystemPath(ExpandConstant('{app}'), False);
  end;
end;
