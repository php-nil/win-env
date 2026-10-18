;
; win-env - ungoogled-chromium one-click installer for Windows x64
;
; Compiled by builders/chromium/build.ps1 via ISCC.exe with these defines:
;   /DMyAppVersion=<tag>            e.g. 155.0.8059.39-1.1
;   /DMyAppNumericVersion=<four-part>, e.g. 155.0.8059.39 (for VersionInfoVersion)
;   /DStageDir=<staged binary tree>
;   /DOutputDir=<output folder>
;   /DOutputBaseFilename=<setup exe base name>
;
#ifndef MyAppVersion
  #error MyAppVersion must be defined, e.g. /DMyAppVersion=155.0.8059.39-1.1
#endif
#ifndef MyAppNumericVersion
  #error MyAppNumericVersion must be defined, e.g. /DMyAppNumericVersion=155.0.8059.39
#endif
#ifndef StageDir
  #error StageDir must be defined
#endif
#ifndef OutputDir
  #define OutputDir "output"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "chromium-setup-x64"
#endif

[Setup]
; A fixed AppId makes upgrades/reinstalls replace the same installation.
AppId={{9C4E7A13-6B2D-4F85-8E71-3A5C0D9B2F46}
AppName=Chromium
AppVersion={#MyAppVersion}
AppVerName=ungoogled-chromium {#MyAppVersion} (x64)
AppPublisher=win-env
AppComments=ungoogled-chromium browser (upstream Chromium + ungoogled patches), packaged by win-env
DefaultDirName=C:\pf\chromium
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/max
; A 128 MB dictionary covers the whole ~420 MB staging tree in one solid block.
; Extraction needs ~130 MB extra RAM; compression happens on the build runner.
; (128 MB is the verified ISCC limit, see doc/lessons.md 13.)
LZMADictionarySize=131072
SolidCompression=yes
WizardStyle=modern
; Extracted from the official chrome.exe icon resources
; (builders/chromium/setup.ico, includes 16..256 px frames).
SetupIconFile=setup.ico
UninstallDisplayIcon={app}\chrome.exe
UninstallDisplayName=ungoogled-chromium {#MyAppVersion} (x64, win-env)
; VersionInfoVersion is a Windows PE resource: it must be four numeric parts,
; so the ungoogled revision suffix (-1.1) is dropped for the numeric version.
VersionInfoVersion={#MyAppNumericVersion}
VersionInfoCompany=win-env
VersionInfoDescription=ungoogled-chromium (x64) one-click installer
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseFilename}

; ChineseSimplified.isl is NOT shipped by the official Inno Setup installer
; (it lives in issrc/Files/Languages), so it is vendored next to this script.
#define LangDir SourcePath + "Languages\"

[Languages]
Name: "chinesesimp"; MessagesFile: "{#LangDir}ChineseSimplified.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Files]
; The staging tree is the official portable archive with its wrapper folder
; flattened: the installer only unpacks, it never downloads.
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
; All-users desktop shortcut. The install is machine-wide and admin-only, so
; {commondesktop} is available; Inno removes the shortcut on uninstall.
Name: "{commondesktop}\Chromium"; Filename: "{app}\chrome.exe"; WorkingDir: "{app}"; Comment: "ungoogled-chromium"

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
// PATH update is mandatory: the installer guarantees the bare `chrome` command
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

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    UpdateSystemPath(ExpandConstant('{app}'), True);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    UpdateSystemPath(ExpandConstant('{app}'), False);
end;
