;
; win-env - Python (CPython, x64) one-click installer for Windows
;
; Compiled by builders/python/build.ps1 via ISCC.exe with these defines:
;   /DMyAppVersion=<x.y.z>    e.g. 3.15.0
;   /DPyTrack=<x.y>           e.g. 3.15 (drives the default install dir)
;   /DStageDir=<staged binary tree>
;   /DOutputDir=<output folder>
;   /DOutputBaseFilename=<setup exe base name>
;
#ifndef MyAppVersion
  #error MyAppVersion must be defined, e.g. /DMyAppVersion=3.15.0
#endif
#ifndef PyTrack
  #error PyTrack must be defined, e.g. /DPyTrack=3.15
#endif
#ifndef StageDir
  #error StageDir must be defined
#endif
#ifndef OutputDir
  #define OutputDir "output"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "python-setup-x64"
#endif

[Setup]
; A fixed AppId makes upgrades/reinstalls replace the same installation. The
; default directory only carries the major.minor track, so a patch upgrade
; (3.15.0 -> 3.15.1) replaces the same instance at the same path.
AppId={{B3F6D8E5-2A94-4C71-8E5B-7D1A9F3C6B20}
AppName=Python
AppVersion={#MyAppVersion}
AppVerName=Python {#MyAppVersion} (x64)
AppPublisher=win-env
AppComments=Python (CPython) command-line/build environment, packaged by win-env
DefaultDirName=C:\pf\python-{#PyTrack}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/max
; A 128 MB dictionary covers the whole staging tree (about 58 MB after the Doc\
; trim, 137 MB when built with -KeepDoc) in one solid block. Extraction needs
; ~130 MB extra RAM; compression happens on the build runner.
LZMADictionarySize=131072
SolidCompression=yes
WizardStyle=modern
; Extracted from the official python.exe icon resource group
; (builders/python/setup.ico, 16..256 px frames, 8bpp + 32bpp pairs).
SetupIconFile=setup.ico
UninstallDisplayIcon={app}\python.exe
UninstallDisplayName=Python {#MyAppVersion} (x64, win-env)
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany=win-env
VersionInfoDescription=Python (x64) one-click installer
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}

; ChineseSimplified.isl is NOT shipped by the official Inno Setup installer
; (it lives in issrc/Files/Languages), so it is vendored next to this script.
#define LangDir SourcePath + "Languages\"

[Languages]
Name: "chinesesimp"; MessagesFile: "{#LangDir}ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; The staging tree already contains the trimmed pythoncore payload plus the
; generated pip.cmd wrapper: the installer only unpacks, it never downloads.
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

// Add (OnInstall=True) or remove (OnInstall=False) Dir from the machine PATH.
// PATH update is mandatory: the installer guarantees the bare `python` /
// `pythonw` / `pip` commands work from a new shell. Idempotent: never
// duplicates an entry and never wipes unrelated entries.
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
  // Only the install root goes on PATH: python.exe, pythonw.exe and the
  // generated pip.cmd live there (the zip has no Scripts\ folder).
  if CurStep = ssPostInstall then
    UpdateSystemPath(ExpandConstant('{app}'), True);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    UpdateSystemPath(ExpandConstant('{app}'), False);
end;
