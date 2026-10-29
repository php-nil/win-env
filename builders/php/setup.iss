;
; win-env - PHP 8.5 one-click installer for Windows x64
;
; Compiled by builders/php/build.ps1 via ISCC.exe with these defines:
;   /DMyAppVersion=<8.5.x, e.g. 8.5.12-1>
;   /DMyAppVersionInfo=<numeric form for VersionInfoVersion, e.g. 8.5.12.1>
;   /DXdebugVersion=<x.y.z>
;   /DStageDir=<staged runtime tree>
;   /DOutputDir=<output folder>
;   /DOutputBaseFilename=<setup exe base name>
;
; MyAppVersion is the upstream spelling (a re-spin is "8.5.12-1");
; MyAppVersionInfo must be purely numeric because Inno Setup's
; VersionInfoVersion accepts at most four numeric components.
#ifndef MyAppVersion
  #error MyAppVersion must be defined, e.g. /DMyAppVersion=8.5.11
#endif
#ifndef MyAppVersionInfo
  #define MyAppVersionInfo MyAppVersion
#endif
#ifndef XdebugVersion
  #define XdebugVersion "0.0.0"
#endif
#ifndef StageDir
  #error StageDir must be defined
#endif
#ifndef OutputDir
  #define OutputDir "output"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "php-8.5-setup-x64"
#endif

[Setup]
; A fixed AppId makes upgrades/reinstalls replace the same installation.
AppId={{A7E3C4D2-6B5F-4A9E-9C21-7D8B3F1E5A04}
AppName=PHP 8.5 (x64)
AppVersion={#MyAppVersion}
AppVerName=PHP {#MyAppVersion} (x64, Xdebug {#XdebugVersion})
AppPublisher=win-env
AppComments=PHP 8.5 NTS x64 with Xdebug and cacert.pem, packaged by win-env
DefaultDirName=C:\pf\php-8.5
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/max
; lzma2/max defaults underfit the ~98 MB staging tree: a 128 MB dictionary
; covers it in one solid block (~2.8% smaller setup, measured). Extraction
; needs ~130 MB extra RAM; compression happens once on the build runner.
LZMADictionarySize=131072
SolidCompression=yes
WizardStyle=modern
; Icon extracted from the official php.exe (builders/php/setup.ico).
SetupIconFile=setup.ico
UninstallDisplayIcon={app}\php.exe
UninstallDisplayName=PHP {#MyAppVersion} (x64, win-env)
VersionInfoVersion={#MyAppVersionInfo}
VersionInfoCompany=win-env
VersionInfoDescription=PHP 8.5 (x64) one-click installer
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

// php.ini ships with a __APP_DIR__ placeholder for the CA certificate path;
// replace it with the actual installation directory after files are copied.
procedure ConfigurePhpIni;
var
  IniFile: String;
  RawText: AnsiString;
  Text: String;
begin
  IniFile := ExpandConstant('{app}\php.ini');
  if not FileExists(IniFile) then
  begin
    Log('php.ini not found, skipping configuration');
    exit;
  end;
  try
    // php.ini is ASCII-only by construction, so the AnsiString round-trip
    // performed by LoadStringFromFile is lossless.
    LoadStringFromFile(IniFile, RawText);
  except
    Log('Could not read php.ini, skipping configuration');
    exit;
  end;
  Text := RawText;
  StringChange(Text, '__APP_DIR__', ExpandConstant('{app}'));
  if not SaveStringToFile(IniFile, Text, False) then
    Log('Could not write php.ini');
end;

function NormalizePathEntry(const P: String): String;
begin
  Result := LowerCase(Trim(P));
  StringChangeEx(Result, '/', '\', True);
  while (Length(Result) > 3) and (Result[Length(Result)] = '\') do
    Delete(Result, Length(Result), 1);
end;

// Add (OnInstall=True) or remove (OnInstall=False) Dir from the machine PATH.
// PATH update is mandatory: the installer guarantees the bare `php` and `nil`
// commands work from a new shell. Idempotent: never duplicates an entry and
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
    ConfigurePhpIni;
    UpdateSystemPath(ExpandConstant('{app}'), True);
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    UpdateSystemPath(ExpandConstant('{app}'), False);
end;
