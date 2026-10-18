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
; SdkVcPath may be empty if the VC runtime lib dir was not found.
#ifndef SdkVcPath
  #define SdkVcPath "crt\\lib\\x86_64"
#endif
; LLD comes from the rustc component itself. The tiny `gcc-ld\lld-link.exe`
; wrapper spawns `rust-lld.exe` located relative to its own directory, so cargo's
; `linker` must point at this wrapper in its untouched install-tree position.
#ifndef SdkLldPath
  #define SdkLldPath "lib\\rustlib\\x86_64-pc-windows-msvc\\bin\\gcc-ld\\lld-link.exe"
#endif

[Setup]
; A fixed AppId makes upgrades/reinstalls replace the same installation.
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
; A 128 MB dictionary is the largest this (32-bit) ISCC encoder accepts; 256 MB
; fails with LZMA_Encode code 5. The staged rustc + SDK tree is larger, so it
; spans multiple solid blocks.
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
  // User-level PATH lives in HKCU\Environment - that is exactly where official
  // rustup puts its %USERPROFILE%\.cargo\bin entry, so `cargo install`ed
  // subcommands resolve by bare name. Our bookkeeping value records whether WE
  // added that entry, so uninstall never removes one that a pre-existing
  // official rustup install created.
  UserEnvRegKey   = 'Environment';
  PathStateRegKey = 'Software\win-env\rust';
  PathStateValue  = 'CargoBinAdded';
  CargoBinEntry   = '%USERPROFILE%\.cargo\bin';

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

// Normalize a PATH entry for case/separator-insensitive comparison. The user
// PATH may hold our cargo-bin entry either verbatim ('%USERPROFILE%\.cargo\bin',
// exactly as official rustup writes it) or pre-expanded, so %USERPROFILE% is
// expanded before comparing, otherwise a reinstall would append a duplicate.
function NormalizePathEntry(const P: String): String;
var
  S: String;
begin
  S := Trim(P);
  StringChangeEx(S, '%USERPROFILE%', ExpandConstant('{%USERPROFILE}'), False);
  Result := LowerCase(S);
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

// ---------------------------------------------------------------------------
// User-level PATH (HKCU\Environment)
// ---------------------------------------------------------------------------
// Official rustup appends %USERPROFILE%\.cargo\bin to the USER PATH; that is
// what makes `cargo install`ed subcommands callable by bare name. Mirrored here,
// with two additions:
//   - install is idempotent (an equivalent entry, literal or pre-expanded, is
//     never duplicated);
//   - uninstall removes the entry only when THIS installer created it, recorded
//     under HKCU\Software\win-env\rust, so a co-existing official rustup install
//     keeps its own PATH entry untouched.
function WasCargoBinAddedByUs: Boolean;
var
  V: DWORD;
begin
  Result := RegQueryDWordValue(HKCU, PathStateRegKey, PathStateValue, V) and (V = 1);
end;

// Returns True when this call appended the entry (i.e. it was not there before).
function UpdateUserPath(const Dir: String; OnInstall: Boolean): Boolean;
var
  OldPath, Part, Rebuilt, Target: String;
  List: TStringList;
  I: Integer;
  Present, Changed: Boolean;
begin
  Result := False;
  Target := NormalizePathEntry(Dir);
  if Target = '' then
    exit;

  if not RegQueryStringValue(HKCU, UserEnvRegKey, 'Path', OldPath) then
    OldPath := '';

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
      Result := True;
    end;

    if Changed then
    begin
      if RegWriteExpandStringValue(HKCU, UserEnvRegKey, 'Path', Rebuilt) then
      begin
        Log('User PATH updated: ' + Dir);
        BroadcastEnvironmentChange;
      end
      else
        Log('Failed to write user PATH');
    end
    else
      Log('User PATH already up to date');
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
                'linker = ' + Q + AppDir + '\' + '{#SdkLldPath}' + Q + #13#10 +
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

// Reverse of PatchCargoConfig: strip our target section so the uninstalled
// linker/library paths do not linger and break the user's later `cargo build`
// (a leftover section pointing at a removed `lld-link.exe` fails the link).
// Other sections the user may have in config.toml are preserved; if nothing
// but whitespace remains, the file was ours and is deleted.
procedure UnpatchCargoConfig;
var
  ConfigPath, Content: String;
  Lines: TArrayOfString;
  I, J, SectionStart, SectionEnd: Integer;
begin
  ConfigPath := ExpandConstant('{userprofile}\.cargo\config.toml');
  if not FileExists(ConfigPath) then
    Exit;

  LoadStringsFromFile(ConfigPath, Lines);

  SectionStart := -1;
  SectionEnd   := -1;
  for I := 0 to GetArrayLength(Lines) - 1 do
  begin
    if Trim(Lines[I]) = CargoSectionHeader then
    begin
      SectionStart := I;
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

  // Our section is absent: leave the user's file untouched.
  if SectionStart < 0 then
    Exit;

  Content := '';
  for I := 0 to SectionStart - 1 do
    Content := Content + Lines[I] + #13#10;
  for I := SectionEnd to GetArrayLength(Lines) - 1 do
    Content := Content + Lines[I] + #13#10;

  if Trim(Content) = '' then
  begin
    if DeleteFile(ConfigPath) then
      Log('Cargo config removed: ' + ConfigPath);
  end
  else if SaveStringToFile(ConfigPath, Content, False) then
    Log('Cargo config merged: removed our target section');
end;

// ---------------------------------------------------------------------------
// System MSVC detection
// ---------------------------------------------------------------------------
// North star: when the machine already provides what official rustup needs (VS
// with the C++ workload AND the Windows SDK), we must behave exactly like an
// official install: rustc finds link.exe and the SDK libs by itself, so we
// must write NOTHING into the user's cargo config. Only when that toolchain is
// missing do we fall back to the bundled LLD + staged SDK configuration (which
// is the entire reason this package exists).
//
// The check deliberately errs toward "not usable": a false negative just means
// we also write our (working) fallback config, while a false positive would
// leave the user with a cargo that cannot link at all.

const
  SdkRootRegKey    = 'SOFTWARE\Microsoft\Windows Kits\Installed Roots';
  SdkRootValueName = 'KitsRoot10';

function EditionHasCppTools(const EditionDir: String): Boolean;
begin
  Result := DirExists(EditionDir + '\VC\Tools\MSVC');
end;

// Walk <VsBase>\<year>\<edition> looking for the Visual C++ tools directory.
// Two single-level FindFirst passes: Inno's FindFirst only supports a wildcard
// in the last path component, so a multi-level glob is not an option.
function ScanVsBase(const VsBase: String): Boolean;
var
  YearRec, EditionRec: TFindRec;
  YearDir, EditionDir: String;
begin
  Result := False;
  if not DirExists(VsBase) then
    Exit;
  if not FindFirst(VsBase + '\*', YearRec) then
    Exit;
  try
    repeat
      if ((YearRec.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and
         (YearRec.Name <> '.') and (YearRec.Name <> '..') then
      begin
        YearDir := VsBase + '\' + YearRec.Name;
        if not Result then
          if FindFirst(YearDir + '\*', EditionRec) then
          begin
            try
              repeat
                if ((EditionRec.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and
                   (EditionRec.Name <> '.') and (EditionRec.Name <> '..') then
                begin
                  EditionDir := YearDir + '\' + EditionRec.Name;
                  if EditionHasCppTools(EditionDir) then
                    Result := True;
                end;
              until Result or (not FindNext(EditionRec));
            finally
              FindClose(EditionRec);
            end;
          end;
      end;
    until Result or (not FindNext(YearRec));
  finally
    FindClose(YearRec);
  end;
end;

function FindSystemVcTools: Boolean;
begin
  Result := ScanVsBase(ExpandConstant('{pf}\Microsoft Visual Studio'));
  if not Result then
    Result := ScanVsBase(ExpandConstant('{pf32}\Microsoft Visual Studio'));
end;

// The SDK registers under both registry views depending on how it was
// installed, so both are probed. KitsRoot10 is what the toolchain reads to
// locate the UCRT / UM libraries.
function HasWindowsSdk: Boolean;
var
  Root: String;
begin
  Result := False;
  if RegQueryStringValue(HKLM64, SdkRootRegKey, SdkRootValueName, Root) or
     RegQueryStringValue(HKLM32, SdkRootRegKey, SdkRootValueName, Root) then
    Result := (Trim(Root) <> '') and DirExists(Root);
end;

function SystemMsvcUsable: Boolean;
begin
  Result := HasWindowsSdk and FindSystemVcTools;
end;

// Decide whether the user's global cargo config needs our fallback section.
// Called on install only; uninstall always runs UnpatchCargoConfig, which is
// a no-op when nothing of ours is present.
procedure ConfigureCargoToolchain;
begin
  if SystemMsvcUsable then
  begin
    Log('System MSVC toolchain detected - cargo config left untouched (official defaults)');
    // A previous install on a VS-less machine may have left our section behind,
    // pointing at a now-removed lld-link.exe. Clear it so the official link.exe
    // path is used without a stale override.
    UnpatchCargoConfig;
  end
  else
  begin
    Log('No usable system MSVC toolchain - configuring bundled LLD + SDK library paths');
    PatchCargoConfig;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
  begin
    UpdateSystemPath(ExpandConstant('{app}\bin'), True);
    // User-level PATH: mirror official rustup so `cargo install`ed subcommands
    // resolve by bare name. The bookkeeping value lets uninstall remove only the
    // entry this installer created.
    if UpdateUserPath(CargoBinEntry, True) then
      RegWriteDWordValue(HKCU, PathStateRegKey, PathStateValue, 1)
    else if WasCargoBinAddedByUs then
      RegWriteDWordValue(HKCU, PathStateRegKey, PathStateValue, 1)
    else
      RegWriteDWordValue(HKCU, PathStateRegKey, PathStateValue, 0);
    // Remove the staged placeholder cargo config from the install dir: the real
    // one belongs in {userprofile}\.cargo\config.toml, and only when the machine
    // has no usable MSVC toolchain (see ConfigureCargoToolchain).
    if FileExists(ExpandConstant('{app}\.cargo\config.toml')) then
      DeleteFile(ExpandConstant('{app}\.cargo\config.toml'));
    ConfigureCargoToolchain;
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    UpdateSystemPath(ExpandConstant('{app}\bin'), False);
    UnpatchCargoConfig;
    // Remove the user PATH entry only if we added it; an entry created by an
    // official rustup install must survive this uninstall.
    if WasCargoBinAddedByUs then
    begin
      UpdateUserPath(CargoBinEntry, False);
      RegDeleteValue(HKCU, PathStateRegKey, PathStateValue);
    end;
  end;
end;
