;
; win-env - Rust MSVC one-click installer for Windows x64
;
; Compiled by builders/rust/build.ps1 via ISCC.exe with these defines:
;   /DMyAppVersion=<x.y.z>
;   /DStageDir=<staged binary tree>
;   /DOutputDir=<output folder>
;   /DOutputBaseFilename=<setup exe base name>
;
#ifndef MyAppVersion
  #error MyAppVersion must be defined, e.g. /DMyAppVersion=1.90.0
#endif
#ifndef StageDir
  #error StageDir must be defined
#endif
#ifndef OutputDir
  #define OutputDir "output"
#endif
#ifndef OutputBaseFilename
  #define OutputBaseFilename "rust-setup-x64"
#endif
; SDK lib paths relative to the install root (verified against xwin 0.10.0
; splat layout: crt\lib\<arch> = VC CRT, sdk\lib\ucrt\<arch> = UCRT,
; sdk\lib\um\<arch> = Windows SDK).
#ifndef SdkUcrtPath
  #define SdkUcrtPath "sdk\\lib\\ucrt\\x86_64"
#endif
#ifndef SdkUmPath
  #define SdkUmPath "sdk\\lib\\um\\x86_64"
#endif
// SdkVcPath may be empty if the VC runtime lib dir was not found.
#ifndef SdkVcPath
  #define SdkVcPath "crt\\lib\\x86_64"
#endif

[Setup]
AppId={{7E3B9A2D-4C5F-4E8A-B1D6-9F0A3C7E2B51}
AppName=Rust (MSVC)
AppVersion={#MyAppVersion}
AppVerName=Rust {#MyAppVersion} MSVC (x64)
AppPublisher=win-env
AppComments=Rust MSVC one-click installer, packaged by win-env
DefaultDirName=C:\pf\rust
DisableProgramGroupPage=yes
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
Compression=lzma2/max
LZMADictionarySize=131072
SolidCompression=yes
WizardStyle=modern
SetupIconFile=setup.ico
UninstallDisplayIcon={app}\bin\rustc.exe
UninstallDisplayName=Rust {#MyAppVersion} MSVC (x64, win-env)
VersionInfoVersion={#MyAppVersion}
VersionInfoCompany=win-env
VersionInfoDescription=Rust MSVC (x64) one-click installer
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
  // Pascal Script does NOT allow a local `const` block inside a procedure,
  // so this shared literal lives in the global const section.
  CargoSectionHeader = '[target.x86_64-pc-windows-msvc]';
  // A single-quote character. Building TOML literal strings with Q avoids
  // fragile runs of quotes that are hard to keep balanced by hand.
  Q = '''';

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

// Write or merge cargo config.toml with our target section.
// Uses {userprofile}\.cargo\config.toml (correct cargo location, NOT {userappdata}).
// Merge strategy: if file exists and already has our target section, replace it
// (preserving all other sections / user settings). Otherwise append or create.
procedure PatchCargoConfig;
var
  ConfigPath, Content, AppDir, NewSection, SdkVc: String;
  SectionStart, SectionEnd: Integer;
  Lines: TArrayOfString;
  I, J: Integer;
  Success: Boolean;
begin
  ConfigPath := ExpandConstant('{userprofile}\.cargo\config.toml');
  AppDir := ExpandConstant('{app}');
  StringChangeEx(AppDir, '/', '\', True);

  // Build the new section we want to write.
  // TOML literal strings (single quotes) → Windows backslashes need zero escaping.
  // SDK paths arrive via ISCC defines already relative to the install root
  // ({app}); SdkVcPath may be empty if the VC lib dir was not found.
  SdkVc := '{#SdkVcPath}';

  NewSection := CargoSectionHeader + #13#10 +
                'linker = "lld-link"' + #13#10 +
                'rustflags = [' + #13#10 +
                '    ' + Q + '-L' + Q + ', ' + Q + AppDir + '\' + '{#SdkUcrtPath}' + Q + ',' + #13#10 +
                '    ' + Q + '-L' + Q + ', ' + Q + AppDir + '\' + '{#SdkUmPath}' + Q + #13#10;
  if SdkVc <> '' then
    NewSection := NewSection + ',' + #13#10 +
                  '    ' + Q + '-L' + Q + ', ' + Q + AppDir + '\' + SdkVc + Q + #13#10;
  NewSection := NewSection + #13#10 +
                ']' + #13#10;

  if not FileExists(ConfigPath) then
  begin
    if not DirExists(ExtractFileDir(ConfigPath)) then
      CreateDir(ExtractFileDir(ConfigPath));
    Success := SaveStringToFile(ConfigPath, NewSection, False);
    if Success then
      Log('Cargo config created at ' + ConfigPath)
    else
      Log('Failed to create cargo config');
    Exit;
  end;

  // File exists: split into lines, find our section, replace or append.
  LoadStringsFromFile(ConfigPath, Lines);

  SectionStart := -1;
  SectionEnd   := -1;
  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    if Trim(Lines[I]) = CargoSectionHeader then
    begin
      SectionStart := I;
      // Find end: next line starting with '[' (or EOF)
      SectionEnd := GetArrayLength(Lines);
      for J := I + 1 to GetArrayLength(Lines) - 1 do
      begin
        if (Length(Trim(Lines[J])) > 0) and (Trim(Lines[J])[1] = '[') then
        begin
          SectionEnd := J;
          Break;
        end;
      end;
      Break;
    end;
  end;

  Content := '';
  if SectionStart >= 0 then
  begin
    // Preserve lines before our section, insert new content, preserve lines after.
    for I := 0 to SectionStart - 1 do
      Content := Content + Lines[I] + #13#10;
    Content := Content + NewSection;
    for I := SectionEnd to GetArrayLength(Lines) - 1 do
      Content := Content + Lines[I] + #13#10;
    Log('Cargo config merged: replaced existing target section');
  end
  else
  begin
    // Append at end (preserve original content + trailing newline if present)
    for I := 0 to GetArrayLength(Lines) - 1 do
      Content := Content + Lines[I] + #13#10;
    Content := Content + #13#10 + NewSection;
    Log('Cargo config merged: appended target section');
  end;

  Success := SaveStringToFile(ConfigPath, Content, False);
  if not Success then
    Log('Failed to write cargo config');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    UpdateSystemPath(ExpandConstant('{app}\bin'), True);
    // Remove the staged placeholder cargo config from the install dir;
    // the real one is written to {userprofile}\.cargo\config.toml by PatchCargoConfig.
    if FileExists(ExpandConstant('{app}\.cargo\config.toml')) then
      DeleteFile(ExpandConstant('{app}\.cargo\config.toml'));
    PatchCargoConfig;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
    UpdateSystemPath(ExpandConstant('{app}\bin'), False);
end;
