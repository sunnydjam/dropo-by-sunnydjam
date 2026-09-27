#ifndef SourceDir
  #error SourceDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef SetupIconFile
  #error SetupIconFile is required
#endif
#ifndef SetupBaseName
  #define SetupBaseName "dropo-Windows-Setup-x64"
#endif

[Setup]
AppId={{D493210B-63F8-4CA8-B97D-FED5B9E6711E}
AppName=dropo
AppVersion={#AppVersion}
AppVerName=dropo {#AppVersion}
AppPublisher=sunnydjam
AppPublisherURL=https://github.com/sunnydjam/dropo-by-sunnydjam
AppSupportURL=https://github.com/sunnydjam/dropo-by-sunnydjam/issues
AppUpdatesURL=https://github.com/sunnydjam/dropo-by-sunnydjam/releases
DefaultDirName={autopf}\dropo
DefaultGroupName=dropo
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename={#SetupBaseName}
SetupIconFile={#SetupIconFile}
UninstallDisplayIcon={app}\dropo.exe
Compression=lzma2/normal
; Keep the LZMA match finder single-threaded so the release gate can compare
; independent installer builds byte-for-byte on machines with different load.
CompressionThreads=1
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
PrivilegesRequiredOverridesAllowed=commandline
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=force
; Include mapped Flutter DLL/AOT files, not just the small runner executable.
CloseApplicationsFilter=*.exe,*.dll,*.so
; The installer owns the single post-update launch. Restart Manager must not
; race it by restarting old UI/core commands independently.
RestartApplications=no
SetupLogging=yes
UsePreviousTasks=yes
VersionInfoVersion={#AppVersion}.0
VersionInfoProductName=dropo
VersionInfoProductVersion={#AppVersion}
VersionInfoDescription=dropo Windows installer

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать ярлык на рабочем столе"; GroupDescription: "Ярлыки:"; Flags: unchecked
Name: "autostart"; Description: "Запускать dropo при входе в Windows"; GroupDescription: "Автозапуск:"; Flags: checkedonce
Name: "backgroundcore"; Description: "Заранее запускать защищённый фоновый core (быстрее подключение, без повторного UAC)"; GroupDescription: "Автозапуск:"; Flags: checkedonce

[InstallDelete]
; Remove only files shipped by older Windows releases. Do not touch the
; user's Telegram Desktop settings or the per-user tg-ws-proxy config.
Type: files; Name: "{app}\resources\bin\tg-ws-proxy.exe"; Check: IsUpgradeInstall
Type: files; Name: "{app}\resources\licenses\tg-ws-proxy-LICENSE.txt"; Check: IsUpgradeInstall

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs notimestamp; BeforeInstall: EnsureRuntimeUnlocked
Source: "{#SourcePath}\install-mode.json"; DestDir: "{app}"; Flags: ignoreversion notimestamp

[Icons]
Name: "{autoprograms}\dropo"; Filename: "{app}\dropo.exe"; WorkingDir: "{app}"
Name: "{autodesktop}\dropo"; Filename: "{app}\dropo.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""dropo-background-core"" /F"; Flags: runhidden waituntilterminated logoutput 64bit; Check: IsWin64
Filename: "{sys}\schtasks.exe"; Parameters: "/Create /F /TN ""dropo-background-core"" /SC ONLOGON /RL HIGHEST /TR ""\""{app}\resources\dropo-core.exe\"" --listen 127.0.0.1:17890 --no-tray"""; Flags: runhidden waituntilterminated logoutput 64bit; Check: ShouldCreateBackgroundTask
Filename: "{app}\dropo.exe"; Description: "Запустить dropo"; WorkingDir: "{app}"; Flags: nowait postinstall skipifsilent runasoriginaluser; Check: not IsFromUpdate
; Updater hand-off also works for older installed clients using --from-update.
; Do not add postinstall/skipifsilent: automatic updates have no finish page.
Filename: "{app}\dropo.exe"; WorkingDir: "{app}"; Flags: nowait runasoriginaluser; Check: IsFromUpdate

[UninstallRun]
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM dropo-ui.exe"; Flags: runhidden waituntilterminated; RunOnceId: "StopDropoUI"
Filename: "{sys}\taskkill.exe"; Parameters: "/F /IM dropo-core.exe"; Flags: runhidden waituntilterminated; RunOnceId: "StopDropoCore"
Filename: "{sys}\schtasks.exe"; Parameters: "/Delete /TN ""dropo-background-core"" /F"; Flags: runhidden waituntilterminated logoutput 64bit; Check: IsWin64; RunOnceId: "DeleteDropoCoreTask"

[UninstallDelete]
Type: filesandordirs; Name: "{app}\updates"

[Code]
const
  DropoRegistryPath = 'Software\dropo';
  DropoRunRegistryPath = 'Software\Microsoft\Windows\CurrentVersion\Run';

var
  PreserveInstallerChoices: Boolean;
  PreviousBackgroundCoreChoice: Boolean;
  RuntimeUnlocked: Boolean;
  UpdateInstallStarted: Boolean;
  UpdateInstallCompleted: Boolean;

function CreateFileForUpdate(FileName: String; DesiredAccess, ShareMode,
  SecurityAttributes, CreationDisposition, Flags, Template: LongWord): THandle;
  external 'CreateFileW@kernel32.dll stdcall';
function CloseUpdateHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';

function CanReplaceRuntimeFile(const Name: String): Boolean;
var
  Handle: THandle;
begin
  Result := True;
  if not FileExists(Name) then exit;
  { Request write access without sharing; running image mappings must be gone. }
  Handle := CreateFileForUpdate(Name, $40000000, 0, 0, 3, 0, 0);
  Result := Handle <> THandle(-1);
  if Result then CloseUpdateHandle(Handle);
end;

procedure EnsureRuntimeUnlocked();
var
  Attempt: Integer;
begin
  if RuntimeUnlocked then exit;
  { BeforeInstall runs after Restart Manager closes owners, before payload copy.
    A blocked DLL must not leave a new version label with the old Dart snapshot. }
  for Attempt := 1 to 40 do begin
    if CanReplaceRuntimeFile(ExpandConstant('{app}\dropo.exe')) and
       CanReplaceRuntimeFile(ExpandConstant('{app}\resources\dropo-ui.exe')) and
       CanReplaceRuntimeFile(ExpandConstant('{app}\resources\dropo-core.exe')) and
       CanReplaceRuntimeFile(ExpandConstant('{app}\resources\flutter_windows.dll')) and
       CanReplaceRuntimeFile(ExpandConstant('{app}\resources\data\app.so')) then begin
      RuntimeUnlocked := True;
      exit;
    end;
    Sleep(250);
  end;
  MsgBox('Обновление не установлено: файлы Dropo заняты или недоступны. Закройте все окна Dropo и повторите установку. Новые файлы приложения ещё не копировались.', mbError, MB_OK);
  RaiseException('Dropo runtime is still locked; refusing a partial update.');
end;

function IsUpgradeInstall(): Boolean;
begin
  Result :=
    RegKeyExists(HKLM64, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{D493210B-63F8-4CA8-B97D-FED5B9E6711E}_is1') or
    RegKeyExists(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{D493210B-63F8-4CA8-B97D-FED5B9E6711E}_is1');
end;

function HasTaskSelectionParameter(): Boolean;
var
  ParameterIndex: Integer;
begin
  Result := False;
  for ParameterIndex := 1 to ParamCount do
    if Pos('/tasks=', LowerCase(ParamStr(ParameterIndex))) = 1 then begin
      Result := True;
      exit;
    end;
end;

function IsFromUpdate(): Boolean;
var
  ParameterIndex: Integer;
begin
  Result := False;
  for ParameterIndex := 1 to ParamCount do
    if CompareText(ParamStr(ParameterIndex), '--from-update') = 0 then begin
      Result := True;
      exit;
    end;
end;

function InitializeSetup(): Boolean;
var
  StoredChoice: Cardinal;
begin
  PreserveInstallerChoices := IsUpgradeInstall() and WizardSilent() and not HasTaskSelectionParameter();
  if RegQueryDWordValue(HKCU, DropoRegistryPath, 'InstallerBackgroundCoreChoice', StoredChoice) then
    PreviousBackgroundCoreChoice := StoredChoice <> 0
  else
    PreviousBackgroundCoreChoice := FileExists(ExpandConstant('{sys}\Tasks\dropo-background-core'));
  Result := True;
end;

function ShouldCreateBackgroundTask(): Boolean;
begin
  Result := IsWin64 and
    ((PreserveInstallerChoices and PreviousBackgroundCoreChoice) or
     ((not PreserveInstallerChoices) and WizardIsTaskSelected('backgroundcore')));
end;

procedure ConfigureAutoStart();
var
  Enabled: Cardinal;
  Command: String;
begin
  if PreserveInstallerChoices then
    exit;

  if WizardIsTaskSelected('autostart') then begin
    Enabled := 1;
    Command := '"' + ExpandConstant('{app}\dropo.exe') + '" --autostart';
    RegWriteStringValue(HKCU, DropoRunRegistryPath, 'dropo', Command);
  end else begin
    Enabled := 0;
    RegDeleteValue(HKCU, DropoRunRegistryPath, 'dropo');
  end;
  RegWriteDWordValue(HKCU, DropoRegistryPath, 'InstallerAutoStartChoice', Enabled);

  if WizardIsTaskSelected('backgroundcore') then
    Enabled := 1
  else
    Enabled := 0;
  RegWriteDWordValue(HKCU, DropoRegistryPath, 'InstallerBackgroundCoreChoice', Enabled);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if IsFromUpdate() then begin
    if CurStep = ssInstall then begin
      UpdateInstallStarted := True;
      WizardForm.Caption := 'Обновление Dropo {#AppVersion}';
      WizardForm.Show;
    end;
    if CurStep = ssDone then UpdateInstallCompleted := True;
  end;
  if CurStep = ssPostInstall then
    ConfigureAutoStart();
end;

procedure CurInstallProgressChanged(CurProgress, MaxProgress: Integer);
begin
  if IsFromUpdate() and (MaxProgress > 0) then begin
    { Older clients still pass /VERYSILENT. Keep their update visible too. }
    WizardForm.Show;
    WizardForm.StatusLabel.Caption := 'Устанавливаем Dropo {#AppVersion}: ' +
      IntToStr(Round(100.0 * CurProgress / MaxProgress)) +
      '%. После успешной установки приложение откроется автоматически.';
  end;
end;

procedure DeinitializeSetup();
begin
  if UpdateInstallStarted and not UpdateInstallCompleted then
    { Deliberately not suppressible, including updates from legacy clients. }
    MsgBox('Обновление Dropo не завершено. Не запускайте несколько копий приложения. Закройте Dropo и повторите установку. Подробности сохранены в журнале установки Windows.', mbError, MB_OK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then begin
    RegDeleteValue(HKCU, DropoRunRegistryPath, 'dropo');
    RegDeleteValue(HKCU, DropoRegistryPath, 'InstallerAutoStartChoice');
    RegDeleteValue(HKCU, DropoRegistryPath, 'InstallerBackgroundCoreChoice');
  end;
end;
