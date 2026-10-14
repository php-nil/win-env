;
; win-env - Git for Windows one-click installer
;
; Compiled by builders/git/build.ps1 via ISCC.exe with these defines:
;   /DMyAppVersion=<2.56.0.windows.2>           full tag, for display strings
;   /DMyAppNumericVersion=<2.56.0.2>            numeric-only, for VersionInfoVersion
;   /DStageDir=<staged binary tree>
;   /DOutputDir=<output folder>
;   /DOutputBaseFilename=<setup exe base name>
;
#ifndef MyAppVersion
  #error MyAppVersion must be defined, e.g. /DMyAppVersion=2.56.0.windows.2
#endif
#ifndef MyAppNumericVersion
  #error MyAppNumericVersion must be defined, e.g. /DMyAppNumericVersion=2.56.0.2
#endif
#ifndef StageDir
  #error StageDir must be defined
#endif
#ifndef OutputDir
  #define OutputDir "output"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "Git-setup-x64"
#endif

[Setup]
AppId={{A98E4B2C-7F3D-4A1B-9C0E-6D5F2B8E1C4A}
AppName=Git for Windows
AppVersion={#MyAppVersion}
AppVerName=Git {#MyAppVersion} (x64)
AppPublisher=win-env
AppComments=Git for Windows one-click installer, packaged by win-env
DefaultDirName=C:\pf\Git
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/max
LZMADictionarySize=131072
SolidCompression=yes
WizardStyle=modern
; Git does not have a single top-level exe that works as the uninstall
; display icon; cmd\git.exe is a small shim that delegates to the real
; bin\git.exe, so we point at that.
UninstallDisplayIcon={app}\cmd\git.exe
UninstallDisplayName=Git {#MyAppVersion} (x64, win-env)
VersionInfoVersion={#MyAppNumericVersion}
VersionInfoCompany=win-env
VersionInfoDescription=Git for Windows one-click installer
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}

#define LangDir SourcePath + "Languages\"

[Languages]
Name: "chinesesimp"; MessagesFile: "{#LangDir}ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

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
var
  CmdDir: String;
begin
  if CurStep = ssPostInstall then
  begin
    CmdDir := ExpandConstant('{app}\cmd');
    UpdateSystemPath(CmdDir, True);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  CmdDir: String;
begin
  if CurUninstallStep = usPostUninstall then
  begin
    CmdDir := ExpandConstant('{app}\cmd');
    UpdateSystemPath(CmdDir, False);
  end;
end;
