;
; win-env - PostgreSQL one-click installer for Windows x64
;
; Compiled by builders/postgres/build.ps1 via ISCC.exe with these defines:
;   /DMyAppVersion=<x.y>      e.g. 18.6
;   /DPgMajor=<major>         e.g. 18 (drives the default install dir)
;   /DStageDir=<staged binary tree>
;   /DOutputDir=<output folder>
;   /DOutputBaseFilename=<setup exe base name>
;
#ifndef MyAppVersion
  #error MyAppVersion must be defined, e.g. /DMyAppVersion=18.6
#endif
#ifndef PgMajor
  #error PgMajor must be defined, e.g. /DPgMajor=18
#endif
#ifndef StageDir
  #error StageDir must be defined
#endif
#ifndef OutputDir
  #define OutputDir "output"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "postgres-setup-x64"
#endif

[Setup]
; A fixed AppId makes upgrades/reinstalls replace the same installation. The
; default directory only carries the major version, so a minor upgrade
; (18.6 -> 18.7) replaces the same instance and keeps the existing data\ tree.
AppId={{E4B7C1A9-2D58-4F31-8C6E-9A3F5B0D7E62}
AppName=PostgreSQL
AppVersion={#MyAppVersion}
AppVerName=PostgreSQL {#MyAppVersion} (x64)
AppPublisher=win-env
AppComments=PostgreSQL command-line/build environment (EDB binaries), packaged by win-env
DefaultDirName=C:\pf\postgres-{#PgMajor}
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/max
; A 128 MB dictionary covers the whole ~170 MB staging tree in one solid block.
; Extraction needs ~130 MB extra RAM; compression happens on the build runner.
; (128 MB is the verified ISCC limit, see doc/lessons.md 13.)
LZMADictionarySize=131072
SolidCompression=yes
WizardStyle=modern
; Built from the official PostgreSQL brand mark (the postgresql.org press
; asset elephant.png); the official Windows binaries embed no icon resources.
; (builders/postgres/setup.ico, includes 16..256 px frames).
SetupIconFile=setup.ico
UninstallDisplayIcon={app}\bin\psql.exe
UninstallDisplayName=PostgreSQL {#MyAppVersion} (x64, win-env)
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany=win-env
VersionInfoDescription=PostgreSQL (x64) one-click installer
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}

; ChineseSimplified.isl is NOT shipped by the official Inno Setup installer
; (it lives in issrc/Files/Languages), so it is vendored next to this script.
#define LangDir SourcePath + "Languages\"

[Languages]
Name: "chinesesimp"; MessagesFile: "{#LangDir}ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; The staging tree already contains the management scripts
; (pg-start/pg-stop/pg-restart/pg-status) in bin\, the app-local CRT DLLs and
; the trimmed EDB payload: the installer only unpacks, it never downloads.
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

; NOTE: the data directory ({app}\data) is created at first pg-start (initdb)
; and is deliberately NOT listed here, so uninstalling keeps the user's
; databases. No Windows service is registered either: starting PostgreSQL is
; always an explicit pg-start.

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
// PATH update is mandatory: the installer guarantees the bare `psql` /
// `pg-start` commands work from a new shell. Idempotent: never duplicates an
// entry and never wipes unrelated entries.
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
  // Only bin\ goes on PATH: it holds psql, pg_ctl, pg_dump, ... and the
  // pg-start/pg-stop/pg-restart/pg-status management scripts.
  if CurStep = ssPostInstall then
    UpdateSystemPath(ExpandConstant('{app}\bin'), True);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    UpdateSystemPath(ExpandConstant('{app}\bin'), False);
end;
