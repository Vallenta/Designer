// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Packages.Host;

// Loads the design packages named in this program's registry settings under
// HKEY_CURRENT_USER and, with discovery on, those the IDE installed; the
// IDE's keys are read, never written. A candidate the switched-off, allow and
// exclusion lists let through is preflighted, then its Register procedures
// yield palette entries and its type information classes for streaming.
//
// State is held in unit globals without synchronization and a load runs
// package initialization that touches VCL globals, so every entry point is
// main-thread only. Log entries buffer in this unit until ReportInto attaches
// a target.

interface

// Winapi.Windows must precede System.Classes: both declare RegisterClass, and
// this unit calls the System.Classes one, which registers a class for
// streaming.
uses
  Winapi.Windows,
  System.Classes,
  DesignIntf,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Packages.Discovery;

type
  // Load outcome of one package, or the reason it did not load.
  TPackageState = (
    psLoaded,       // loaded this session
    psReady,        // loadable, not loaded this session
    psHeld,         // held back by the allow list
    psExcluded,     // on the exclusion list
    psSwitchedOff,  // switched off in the package settings
    psNotRequested, // IDE-installed while discovery is off
    psMissing,      // file not found
    psArchitecture, // not a 32-bit x86 image
    psRelease,      // built for another Delphi release
    psDependency,   // a required package is missing
    psDuplicate,    // already loaded in this process
    psUnreadable,   // not a readable package file
    psFailed);      // the load raised an exception

  // One package with its origin and load outcome, as the package manager
  // lists it. Description comes from the IDE registry entry and is empty for
  // a configured path.
  TPackageStatus = record
    // Package file path; IDE path variables are already expanded.
    Path: string;
    Description: string;
    // Whether the path came from registry discovery or from configuration.
    Origin: TPackageOrigin;
    // Load outcome of the package, or the reason it did not load.
    State: TPackageState;
    // Reason text for the state; empty when the package loaded or is
    // loadable.
    Detail: string;
    // Palette entries this package contributed; 0 unless State is psLoaded.
    PaletteCount: Integer;
  end;

const
  // Display text per state for the package manager dialog.
  PackageStateCaptions: array [TPackageState] of string = (
    'loaded', 'loads on restart', 'held (allow list)', 'excluded', 'switched off',
    'discovery off', 'missing', 'skipped (64-bit)', 'skipped (other release)',
    'missing dependency', 'already loaded', 'unreadable', 'failed');

// The command-line arguments, ParamStr(1)..ParamStr(ParamCount).
function CommandLineArguments: TArray<string>;

// Loads every package for this session; a package that fails is logged and
// recorded rather than aborting the rest. ASettingsKey names a key below
// HKEY_CURRENT_USER holding the configured paths, the allow list and the
// discovery flag, and becomes what PackageSettingsKey returns.
procedure LoadPackagesFrom(const ASettingsKey: string);

// LoadPackagesFrom with the settings key of this release.
procedure LoadConfiguredPackages;

// Load progress callback, called once per candidate before that candidate is
// considered, skipped ones included. ADone of ACount are finished; APackage
// is the file name without directory or extension.
type
  TPackageProgress = procedure(ADone, ACount: Integer;
    const APackage: string) of object;

// Sets the progress callback used while packages load; nil disables it.
procedure ReportProgressTo(const AProgress: TPackageProgress);

// Moves the buffered log entries into ALog and logs into ALog from then on.
// Nil detaches the target, after which entries buffer again. ALog must stay
// alive until it is detached.
procedure ReportInto(ALog: TDesignLog);

// Drops the palette entries, the harvested icons and every editor group, then
// unloads the packages in reverse load order. Callers must have released
// everything else naming a package class; packages loaded as dependencies
// stay mapped until process exit.
procedure UnloadAll;

// Key below HKEY_CURRENT_USER holding the package settings: the key last
// passed to LoadPackagesFrom, otherwise this release's default. Reading the
// name creates no key.
function PackageSettingsKey: string;

// True when the IDE's list of installed packages is consulted, the default;
// off, only the configured paths load. Written in the registry only, under
// the Discovery value; no dialog offers it.
function DiscoveryEnabled: Boolean;

// True, the default, when the property editors of the loaded packages build
// the inspector rows and the component editor verbs and the IDE's form
// designer package is hosted; off, the inspector reads type information only.
// Read once per process from the HostedEditors registry value.
function HostedEditors: Boolean;

// Broadcast to the IDesignNotification listeners the loaded packages
// registered. Each listener call is exception-guarded: a failure is logged
// and the remaining listeners still run.
procedure NotifyItemDeleted(const ADesigner: IDesigner; AItem: TPersistent);
procedure NotifyItemsModified(const ADesigner: IDesigner);
procedure NotifySelectionChanged(const ADesigner: IDesigner;
  const ASelection: IDesignerSelections);
// Reports the designer closed for good; AGoingDormant is passed False.
procedure NotifyDesignerClosed(const ADesigner: IDesigner);

// Status of every package this session considered, plus every IDE-installed
// package not among them: the recorded outcome for those loaded or failed on,
// a fresh preflight verdict for the rest.
function SurveyPackages: TArray<TPackageStatus>;

// Replaces both registry lists whole: the switched-off paths, and the
// configured paths in load order; the discovery flag and the two name lists
// stay as they are. Takes effect at the next start; False when the write
// failed, with the reason logged.
function WritePackageSettings(
  const ASwitchedOffPaths, AConfiguredPaths: TArray<string>): Boolean;

// A fresh preflight verdict for one path, with the switched-off, allow and
// exclusion lists applied. Nothing is loaded; the state is what a start would
// make of the path now.
function InspectCandidate(const APath: string;
  AOrigin: TPackageOrigin): TPackageStatus;

implementation

uses
  System.SysUtils,
  System.Actions,
  System.IOUtils,
  System.StrUtils,
  System.Rtti,
  System.Win.Registry,
  Vcl.Controls,
  Vcl.Forms,
  ComponentDesigner,
  DesignEditors,
  Vallenta.FormEditor.DesignTime.Environment,
  Vallenta.FormEditor.Core.ComponentRegistry,
  Vallenta.FormEditor.DesignTime.IdeServices,
  Vallenta.FormEditor.Packages.Dependencies,
  Vallenta.FormEditor.Packages.Icons,
  Vallenta.FormEditor.Packages.Preflight,
  Vallenta.FormEditor.Packages.PeImage,
  Vallenta.FormEditor.Packages.Stacks,
  Vallenta.FormEditor.Core.Settings;

const
  // Registry subkey and value names of the package settings. Under
  // Configured and Disabled the value name carries the package path.
  PackageSubKey = 'Packages';
  ConfiguredSubKey = 'Configured';
  DisabledSubKey = 'Disabled';
  DiscoveryValue = 'Discovery';
  AllowListValue = 'AllowList';
  ExcludeValue = 'Exclude';
  // Arbitrary; only the value name is read back.
  SwitchedOffMark = 1;
  // Suffix of a unit's mangled Register export; the unit-name part varies, so
  // exports are matched on this ending.
  RegisterExportSuffix = '@Register$qqrv';
  // Sentinel page for RegisterNoIcon captures; they get no palette entry.
  NoIconPage = '(no icon)';

type
  TPackageCapture = record
    Page: string;
    ComponentClass: TComponentClass;
  end;

  TLoadedPackage = record
    Path: string;
    Module: HMODULE;
    // Module came from the dependency loader; the unload loop skips it.
    Adopted: Boolean;
    // Editor group of this load; dropping it destroys the registered editors.
    Group: Integer;
    Captures: TArray<TPackageCapture>;
    StreamedClasses: TArray<TPersistentClass>;
  end;

  // A path read from a registry value; under Configured the number the value
  // holds is the load order.
  TNumberedPath = record
    Number: Integer;
    Path: string;
  end;

var
  Packages: TArray<TLoadedPackage>;
  // Editor groups of failed loads; their registrations may still stand, so
  // the groups are kept for the shutdown drop.
  OrphanGroups: TArray<Integer>;
  Statuses: TArray<TPackageStatus>;
  HostLog: TDesignLog;
  // Attached log target; entries buffer in HostLog while nil.
  Reader: TDesignLog;
  Watcher: TPackageProgress;
  // Index in Packages the registration hooks capture for; -1 outside a load.
  Capturing: Integer = -1;
  SettingsKeyName: string = '';
  ConfigurationRead: Boolean = False;
  ConfiguredDiscovery: Boolean = False;
  ExplicitPaths: TArray<string>;
  AllowList: TArray<string>;
  ExcludeList: TArray<string>;
  SwitchedOff: TArray<string>;
  InfoRequires: string;
  InfoContains: string;
  // Modules already walked for streamable classes; a shared dependency
  // appears in several candidates' chains and is walked once per load
  // session. UnloadAll clears the list.
  ScannedModules: TArray<HMODULE>;

procedure LogEntry(ASeverity: TLogSeverity; const AText: string);
begin
  if Reader <> nil then
    Reader.Add(ASeverity, AText)
  else if HostLog <> nil then
    HostLog.Add(ASeverity, AText);
end;

function CommandLineArguments: TArray<string>;
var
  I: Integer;
begin
  Result := nil;
  for I := 1 to ParamCount do
    Result := Result + [ParamStr(I)];
end;

function ResolvedAgainst(const ADirectory, APath: string): string;
begin
  if TPath.IsPathRooted(APath) then
    Result := APath
  else
    Result := TPath.GetFullPath(TPath.Combine(ADirectory, APath));
end;

procedure AppendUnique(var APaths: TArray<string>; const APath: string);
var
  Present: string;
begin
  for Present in APaths do
    if SameText(Present, APath) then
      Exit;
  APaths := APaths + [APath];
end;

function NamesPath(const APaths: TArray<string>; const APath: string): Boolean;
var
  Present: string;
begin
  for Present in APaths do
    if SameText(Present, APath) then
      Exit(True);
  Result := False;
end;

function PackageSettingsKey: string;
begin
  if SettingsKeyName = '' then
    SettingsKeyName := SettingsKey(PackageSubKey);
  Result := SettingsKeyName;
end;

function ReadPathValues(const ASubKey: string): TArray<TNumberedPath>;
var
  Registry: TRegistry;
  Names: TStringList;
  Entry: TNumberedPath;
  Name: string;
begin
  Result := [];
  Registry := TRegistry.Create(KEY_READ);
  try
    Registry.RootKey := HKEY_CURRENT_USER;
    if not Registry.OpenKeyReadOnly(PackageSettingsKey + '\' + ASubKey) then
      Exit;
    Names := TStringList.Create;
    try
      Registry.GetValueNames(Names);
      for Name in Names do
      begin
        if Trim(Name) = '' then
          Continue;
        Entry.Number := 0;
        if Registry.GetDataType(Name) = rdInteger then
          Entry.Number := Registry.ReadInteger(Name);
        Entry.Path := ResolvedAgainst(ExtractFilePath(ParamStr(0)), Trim(Name));
        Result := Result + [Entry];
      end;
    finally
      Names.Free;
    end;
  finally
    Registry.Free;
  end;
end;

procedure ReadConfiguredPaths;
var
  Entries: TArray<TNumberedPath>;
  Moved: TNumberedPath;
  I, J: Integer;
begin
  Entries := ReadPathValues(ConfiguredSubKey);
  // Registry value enumeration has no defined order; the number each value
  // holds is the load order.
  for I := 1 to High(Entries) do
    for J := I downto 1 do
    begin
      if Entries[J].Number >= Entries[J - 1].Number then
        Break;
      Moved := Entries[J];
      Entries[J] := Entries[J - 1];
      Entries[J - 1] := Moved;
    end;
  for I := 0 to High(Entries) do
    AppendUnique(ExplicitPaths, Entries[I].Path);
end;

procedure ReadSwitchedOff;
var
  Entry: TNumberedPath;
begin
  for Entry in ReadPathValues(DisabledSubKey) do
    AppendUnique(SwitchedOff, Entry.Path);
end;

function ReadSettingsValue(const AName, ADefault: string;
  out APresent: Boolean): string;
var
  Registry: TRegistry;
begin
  Result := ADefault;
  APresent := False;
  Registry := TRegistry.Create(KEY_READ);
  try
    Registry.RootKey := HKEY_CURRENT_USER;
    if not Registry.OpenKeyReadOnly(PackageSettingsKey) then
      Exit;
    APresent := Registry.ValueExists(AName);
    if APresent then
      Result := Registry.ReadString(AName);
  finally
    Registry.Free;
  end;
end;

function ReadSettingsFlag(const AName: string; ADefault: Boolean): Boolean;
var
  Registry: TRegistry;
begin
  Result := ADefault;
  Registry := TRegistry.Create(KEY_READ);
  try
    Registry.RootKey := HKEY_CURRENT_USER;
    if Registry.OpenKeyReadOnly(PackageSettingsKey) and
      Registry.ValueExists(AName) then
      Result := Registry.ReadBool(AName);
  finally
    Registry.Free;
  end;
end;

procedure ReadConfiguration;
var
  Configured: string;
  Present: Boolean;
begin
  if ConfigurationRead then
    Exit;
  ConfigurationRead := True;
  ExplicitPaths := nil;
  SwitchedOff := nil;
  AllowList := DefaultAllowList;
  ExcludeList := DefaultExclusions;
  ConfiguredDiscovery := True;
  try
    ReadConfiguredPaths;
    ReadSwitchedOff;
    ConfiguredDiscovery := ReadSettingsFlag(DiscoveryValue, True);
    Configured := Trim(ReadSettingsValue(AllowListValue, '', Present));
    if Configured <> '' then
      AllowList := ParseNameList(Configured);
    // Absent and present-but-empty must stay distinct: absent leaves
    // DefaultExclusions standing, empty excludes nothing.
    Configured := Trim(ReadSettingsValue(ExcludeValue, '', Present));
    if Present then
      ExcludeList := ParseNameList(Configured);
  except
    on E: Exception do
      LogEntry(lsWarn, Format('the package settings could not be read from ' +
        'HKEY_CURRENT_USER\%s (%s) - the designer starts on its defaults',
        [PackageSettingsKey, E.Message]));
  end;
end;

function DiscoveryEnabled: Boolean;
begin
  ReadConfiguration;
  Result := ConfiguredDiscovery;
end;

function IsSwitchedOff(const APath: string): Boolean;
begin
  Result := NamesPath(SwitchedOff, APath);
end;

procedure CaptureComponents(const Page: string;
  const ComponentClasses: array of TComponentClass);
var
  I: Integer;
  Capture: TPackageCapture;
begin
  if Capturing < 0 then
    Exit;
  for I := Low(ComponentClasses) to High(ComponentClasses) do
  begin
    Capture.Page := Page;
    Capture.ComponentClass := ComponentClasses[I];
    Packages[Capturing].Captures := Packages[Capturing].Captures + [Capture];
  end;
end;

procedure CaptureNoIcon(const ComponentClasses: array of TComponentClass);
begin
  CaptureComponents(NoIconPage, ComponentClasses);
end;

procedure CaptureNonActiveX(const ComponentClasses: array of TComponentClass;
  AxRegType: TActiveXRegType);
begin
end;

procedure CaptureActions(const CategoryName: string;
  const AClasses: array of TBasicActionClass; Resource: TComponentClass);
begin
end;

procedure CaptureActionRemoval(const AClasses: array of TBasicActionClass);
begin
end;

// The active class group decides which class a streamed name resolves to, and
// a package activates its own framework's group while registering.
procedure ClaimClassGroup(const AWhat: string);
begin
  if ActiveClassGroup = ClassGroupOf(TControl) then
    Exit;
  ActivateClassGroup(TControl);
  if AWhat <> '' then
    LogEntry(lsInfo, Format('%s left another framework''s class group active ' +
      '- the VCL class group is restored', [AWhat]));
end;

var
  DesignNotifications: TInterfaceList;

procedure CaptureDesignNotification(const DesignNotification: IDesignNotification);
begin
  if DesignNotification = nil then
    Exit;
  if DesignNotifications = nil then
    DesignNotifications := TInterfaceList.Create;
  if DesignNotifications.IndexOf(DesignNotification) < 0 then
    DesignNotifications.Add(DesignNotification);
end;

procedure CaptureDesignNotificationRemoval(
  const DesignNotification: IDesignNotification);
begin
  if DesignNotifications <> nil then
    DesignNotifications.Remove(DesignNotification);
end;

// A listener may unregister itself or others while being notified, so the
// list is snapshotted and each entry re-checked before its call.
procedure BroadcastNotification(const AWhat: string;
  const ACall: TProc<IDesignNotification>);
var
  Listeners: TArray<IInterface>;
  Listener: IInterface;
  I: Integer;
begin
  if DesignNotifications = nil then
    Exit;
  SetLength(Listeners, DesignNotifications.Count);
  for I := 0 to DesignNotifications.Count - 1 do
    Listeners[I] := DesignNotifications[I];
  for Listener in Listeners do
  begin
    if DesignNotifications.IndexOf(Listener) < 0 then
      Continue;
    try
      ACall(Listener as IDesignNotification);
    except
      on E: Exception do
        LogEntry(lsWarn, Format('a design notification listener failed on ' +
          '%s: %s: %s', [AWhat, E.ClassName, E.Message]));
    end;
  end;
end;

procedure NotifyItemDeleted(const ADesigner: IDesigner; AItem: TPersistent);
begin
  BroadcastNotification('ItemDeleted',
    procedure(AListener: IDesignNotification)
    begin
      AListener.ItemDeleted(ADesigner, AItem);
    end);
end;

procedure NotifyItemsModified(const ADesigner: IDesigner);
begin
  BroadcastNotification('ItemsModified',
    procedure(AListener: IDesignNotification)
    begin
      AListener.ItemsModified(ADesigner);
    end);
end;

procedure NotifySelectionChanged(const ADesigner: IDesigner;
  const ASelection: IDesignerSelections);
begin
  BroadcastNotification('SelectionChanged',
    procedure(AListener: IDesignNotification)
    begin
      AListener.SelectionChanged(ADesigner, ASelection);
    end);
end;

procedure NotifyDesignerClosed(const ADesigner: IDesigner);
begin
  BroadcastNotification('DesignerClosed',
    procedure(AListener: IDesignNotification)
    begin
      AListener.DesignerClosed(ADesigner, False);
    end);
end;

procedure IdeServiceRefused(const AService, AHow: string);
begin
  LogEntry(lsWarn, Format('IDE service %s is not implemented (requested via ' +
    '%s)', [AService, AHow]));
end;

// A call into an unset hook raises and aborts the rest of the Register
// procedure that reached it, so every hook is set before package code runs,
// the ones with an empty body included.
procedure InstallRegistrationHooks;
begin
  InstallStackCapture;
  InstallIdeServicesStub(IdeServiceRefused);
  ClaimClassGroup('');
  RegisterComponentsProc := CaptureComponents;
  RegisterNoIconProc := CaptureNoIcon;
  RegisterNonActiveXProc := CaptureNonActiveX;
  System.Actions.RegisterActionsProc := CaptureActions;
  System.Actions.UnRegisterActionsProc := CaptureActionRemoval;
  DesignIntf.RegisterDesignNotificationProc := CaptureDesignNotification;
  DesignIntf.UnregisterDesignNotificationProc :=
    CaptureDesignNotificationRemoval;
end;

function DisplacedHooks: string;

  procedure Note(ADisplaced: Boolean; const AName: string);
  begin
    if ADisplaced then
      Result := Result + IfThen(Result <> '', ', ') + AName;
  end;

begin
  Result := '';
  Note(@RegisterComponentsProc <> @CaptureComponents, 'components');
  Note(@RegisterNoIconProc <> @CaptureNoIcon, 'no-icon');
  Note(@RegisterNonActiveXProc <> @CaptureNonActiveX, 'non-ActiveX');
  Note(@System.Actions.RegisterActionsProc <> @CaptureActions, 'actions');
  Note(@System.Actions.UnRegisterActionsProc <> @CaptureActionRemoval,
    'action removal');
  Note(@DesignIntf.RegisterDesignNotificationProc <>
    @CaptureDesignNotification, 'design notification');
  Note(@DesignIntf.UnregisterDesignNotificationProc <>
    @CaptureDesignNotificationRemoval, 'design notification removal');
end;

// Loading a package or one of its dependencies overwrites hooks and the
// active class group; both must be restored before anything registers again.
procedure RestoreHooksAfterLoad(const AWhat: string);
var
  Displaced: string;
begin
  ClaimClassGroup(AWhat);
  Displaced := DisplacedHooks;
  if Displaced <> '' then
  begin
    InstallRegistrationHooks;
    LogEntry(lsInfo, Format('%s unset the %s registration hook(s) - all ' +
      'hooks are reinstalled', [AWhat, Displaced]));
  end;
end;

procedure PackageInfoEntry(const Name: string; NameType: TNameType; Flags: Byte;
  Param: Pointer);
begin
  case NameType of
    ntContainsUnit:
      InfoContains := InfoContains + IfThen(InfoContains <> '', ', ') + Name;
    ntRequiresPackage:
      InfoRequires := InfoRequires + IfThen(InfoRequires <> '', ', ') + Name;
  end;
end;

procedure LogPackageInfo(AModule: HMODULE);
var
  Flags: Integer;
begin
  InfoRequires := '';
  InfoContains := '';
  GetPackageInfo(AModule, nil, Flags, PackageInfoEntry);
  if InfoRequires <> '' then
    LogEntry(lsInfo, '  requires ' + InfoRequires);
  if InfoContains <> '' then
    LogEntry(lsInfo, '  contains ' + InfoContains);
end;

function FindRegisterExports(AModule: HMODULE): TArray<string>;
var
  ExportName: string;
begin
  Result := [];
  for ExportName in ExportedNames(AModule) do
    if EndsStr(RegisterExportSuffix, ExportName) then
      Result := Result + [ExportName];
end;

function PackageFileVersion(const APath: string): string;
var
  Size, Ignored, Taken: Cardinal;
  Block: TBytes;
  Fixed: Pointer;
  Info: VS_FIXEDFILEINFO;
begin
  Result := '';
  Size := GetFileVersionInfoSize(PChar(APath), Ignored);
  if Size = 0 then
    Exit;
  SetLength(Block, Size);
  if GetFileVersionInfo(PChar(APath), Ignored, Size, Pointer(Block)) and
    VerQueryValue(Pointer(Block), '\', Fixed, Taken) and (Taken > 0) then
  begin
    Move(Fixed^, Info, SizeOf(Info));
    Result := Format('%d.%d.%d.%d',
      [HiWord(Info.dwFileVersionMS), LoWord(Info.dwFileVersionMS),
       HiWord(Info.dwFileVersionLS), LoWord(Info.dwFileVersionLS)]);
  end;
end;

function PackageBuild(const APath: string): string;
begin
  Result := PackageFileVersion(APath);
  if Result = '' then
    Result := 'no version info';
end;

// Writes what a support log needs beside the exception message. EIntfCastError
// says only 'interface not supported', localized, and raises inside the RTL
// rather than in the package: the refusal list names the IDE service the stub
// withheld, an empty list says the cast was not a BorlandIDEServices query at
// all, and the captured stack names the unit that asked.
procedure ReportFailureDetail(E: Exception);
var
  Refused, Service, Frame: string;
  Frames: TArray<string>;
begin
  Refused := '';
  for Service in RefusedIdeServices do
    Refused := Refused + IfThen(Refused <> '', ', ') + Service;
  if Refused <> '' then
    LogEntry(lsWarn, Format('    IDE services this package was refused: %s',
      [Refused]))
  else
    LogEntry(lsWarn, '    no IDE service was refused during this load - what ' +
      'raised was not a BorlandIDEServices query');
  Frames := StackFrames(E);
  if Length(Frames) = 0 then
  begin
    LogEntry(lsWarn, '    no call stack was captured');
    Exit;
  end;
  for Frame in Frames do
    LogEntry(lsWarn, '    ' + Frame);
end;

procedure ReportRegisterFailure(AIndex: Integer; const AProcName: string;
  E: Exception);
begin
  LogEntry(lsWarn, Format('  %s failed in %s (%s): %s: %s - its remaining ' +
    'registrations are skipped',
    [AProcName, ExtractFileName(Packages[AIndex].Path),
     PackageBuild(Packages[AIndex].Path), E.ClassName, E.Message]));
  ReportFailureDetail(E);
end;

procedure CallRegisterProcs(AIndex: Integer);
var
  ProcNames: TArray<string>;
  ProcName: string;
  Proc: procedure;
begin
  ProcNames := FindRegisterExports(Packages[AIndex].Module);
  if Length(ProcNames) = 0 then
  begin
    LogEntry(lsWarn, '  the package exports no Register procedure');
    Exit;
  end;
  for ProcName in ProcNames do
  begin
    @Proc := GetProcAddress(Packages[AIndex].Module, PChar(ProcName));
    if @Proc = nil then
    begin
      LogEntry(lsWarn, Format('  %s: GetProcAddress failed', [ProcName]));
      Continue;
    end;
    // The guard belongs inside the loop: one failing Register procedure must
    // not skip the package's remaining ones.
    try
      Proc;
    except
      on E: Exception do
        ReportRegisterFailure(AIndex, ProcName, E);
    end;
  end;
end;

function IsAmong(const AModules: TArray<HMODULE>; AModule: HMODULE): Boolean;
var
  Module: HMODULE;
begin
  for Module in AModules do
    if Module = AModule then
      Exit(True);
  Result := False;
end;

procedure IgnorePackageEntry(const Name: string; NameType: TNameType;
  Flags: Byte; Param: Pointer);
begin
end;

// True when the package carries the pfDesignOnly flag. Such packages are
// never linked into a target program, so their classes cannot appear in form
// files, and walking them would collide with the IDE design package's
// duplicate class names.
function IsDesignOnly(AModule: HMODULE): Boolean;
var
  Flags: Integer;
begin
  Flags := 0;
  GetPackageInfo(AModule, nil, Flags, IgnorePackageEntry);
  Result := Flags and pfDesignOnly <> 0;
end;

// True for classes in the VCL group, the TComponent root group, or no group.
// Framework-neutral suites (network, database, REST) deliberately stay in the
// root group and belong on a VCL form; other frameworks' classes do not.
function BelongsToThisFramework(AClass: TPersistentClass): Boolean;
var
  Group: TPersistentClass;
begin
  Group := ClassGroupOf(AClass);
  Result := (Group = nil) or (Group = ClassGroupOf(TControl)) or
    (Group = ClassGroupOf(TComponent));
end;

// Registers component classes for streaming from AModules: the candidate plus
// the runtime dependencies it brought in. A design/runtime package split keeps
// the classes in the runtime packages, so the candidate alone is not enough.
procedure RegisterStreamableClasses(AIndex: Integer;
  const AModules: TArray<HMODULE>);
var
  Context: TRttiContext;
  Package: TRttiPackage;
  RttiType: TRttiType;
  Meta: TClass;
  Known: TPersistentClass;
begin
  Context := TRttiContext.Create;
  try
    for Package in Context.GetPackages do
    begin
      if not IsAmong(AModules, Package.Handle) then
        Continue;
      if IsAmong(ScannedModules, Package.Handle) then
        Continue;
      ScannedModules := ScannedModules + [Package.Handle];
      for RttiType in Package.GetTypes do
      begin
        if not (RttiType is TRttiInstanceType) then
          Continue;
        Meta := TRttiInstanceType(RttiType).MetaclassType;
        if not Meta.InheritsFrom(TComponent) then
          Continue;
        if not BelongsToThisFramework(TPersistentClass(Meta)) then
          Continue;
        Known := GetClass(Meta.ClassName);
        if Known = Meta then
          Continue;
        if Known <> nil then
        begin
          LogEntry(lsWarn, Format('  %s in %s is already registered from ' +
            'another module - this copy is skipped',
            [Meta.ClassName, ExtractFileName(Package.Name)]));
          Continue;
        end;
        // GetClass answers from the active class groups only while
        // RegisterClass checks the class's own group, so a nil lookup does
        // not prove the name is free and RegisterClass can still raise.
        try
          RegisterClass(TPersistentClass(Meta));
          Packages[AIndex].StreamedClasses := Packages[AIndex].StreamedClasses +
            [TPersistentClass(Meta)];
        except
          on E: EFilerError do
            LogEntry(lsWarn, Format('  %s cannot be streamed: %s',
              [Meta.ClassName, E.Message]));
        end;
      end;
    end;
  finally
    Context.Free;
  end;
  LogEntry(lsInfo, Format('  %d class(es) registered for streaming',
    [Length(Packages[AIndex].StreamedClasses)]));
end;

function CanBeStreamed(AComponentClass: TComponentClass): Boolean;
var
  Known: TPersistentClass;
begin
  Known := GetClass(AComponentClass.ClassName);
  if Known = TPersistentClass(AComponentClass) then
    Exit(True);
  if Known <> nil then
    Exit(False);
  try
    RegisterClass(TPersistentClass(AComponentClass));
    Result := True;
  except
    on EFilerError do
      Result := False;
  end;
end;

function PublishCaptures(AIndex: Integer): Integer;
var
  Capture: TPackageCapture;
begin
  Result := 0;
  for Capture in Packages[AIndex].Captures do
  begin
    if Capture.Page = NoIconPage then
    begin
      LogEntry(lsInfo, Format('  %s is registered for streaming only - no ' +
        'palette entry', [Capture.ComponentClass.ClassName]));
      Continue;
    end;
    if not BelongsToThisFramework(TPersistentClass(Capture.ComponentClass)) then
    begin
      LogEntry(lsInfo, Format('  %s belongs to another framework - no ' +
        'palette entry', [Capture.ComponentClass.ClassName]));
      Continue;
    end;
    if not CanBeStreamed(Capture.ComponentClass) then
    begin
      LogEntry(lsWarn, Format('  %s gets no palette entry: its class cannot ' +
        'be registered for streaming', [Capture.ComponentClass.ClassName]));
      Continue;
    end;
    if AddDynamicClass(Capture.ComponentClass, Capture.Page,
      Packages[AIndex].Path) then
    begin
      Inc(Result);
      LogEntry(lsInfo, Format('  palette "%s": %s',
        [Capture.Page, Capture.ComponentClass.ClassName]));
    end
    else
      LogEntry(lsWarn, Format('  %s is already on the palette - this ' +
        'duplicate entry is skipped', [Capture.ComponentClass.ClassName]));
  end;
end;

function StatusIndexOf(const AStatuses: TArray<TPackageStatus>;
  const APath: string): Integer;
var
  I: Integer;
begin
  for I := 0 to High(AStatuses) do
    if SameText(AStatuses[I].Path, APath) then
      Exit(I);
  Result := -1;
end;

procedure RecordStatus(const ACandidate: TDiscoveredPackage;
  AState: TPackageState; const ADetail: string; APaletteCount: Integer = 0);
var
  Status: TPackageStatus;
  Index: Integer;
begin
  Status.Path := ACandidate.Path;
  Status.Description := ACandidate.Description;
  Status.Origin := ACandidate.Origin;
  Status.State := AState;
  Status.Detail := ADetail;
  Status.PaletteCount := APaletteCount;
  Index := StatusIndexOf(Statuses, ACandidate.Path);
  if Index >= 0 then
    Statuses[Index] := Status
  else
    Statuses := Statuses + [Status];
end;

function StateOf(AVerdict: TPreflightVerdict): TPackageState;
begin
  case AVerdict of
    pvMissing:
      Result := psMissing;
    pvArchitecture:
      Result := psArchitecture;
    pvRelease:
      Result := psRelease;
    pvDuplicate:
      Result := psDuplicate;
    pvUnreadable:
      Result := psUnreadable;
  else
    Result := psReady;
  end;
end;

procedure LogSkip(const ACandidate: TDiscoveredPackage;
  const ACheck: TPreflight);
begin
  case ACheck.Verdict of
    pvMissing:
      LogEntry(lsWarn, Format('package file not found: %s - its components ' +
        'are unavailable this session', [ACandidate.Path]));
    pvDuplicate:
      LogEntry(lsInfo, Format('%s skipped: %s',
        [ACandidate.Path, ACheck.Detail]));
    pvArchitecture:
      LogEntry(lsInfo, Format('%s skipped: %s',
        [ACandidate.Path, ACheck.Detail]));
  else
    LogEntry(lsWarn, Format('%s cannot be loaded: %s',
      [ACandidate.Path, ACheck.Detail]));
  end;
end;

function ChosenPaths: TArray<string>;
var
  Package: TLoadedPackage;
begin
  Result := [];
  for Package in Packages do
    Result := Result + [Package.Path];
end;

function AdoptableModule(const APath: string): HMODULE;
var
  Dependency: TLoadedDependency;
begin
  Result := 0;
  for Dependency in LoadedDependencies do
    if SameText(Dependency.Name, ExtractFileName(APath)) then
      Exit(Dependency.Module);
end;

procedure DropEditorGroup(AGroup: Integer);
begin
  try
    FreeEditorGroup(AGroup);
  except
    on E: Exception do
      LogEntry(lsError, Format('editor group %d could not be dropped: %s: %s',
        [AGroup, E.ClassName, E.Message]));
  end;
end;

procedure LoadOne(const ACandidate: TDiscoveredPackage; AAdopted: HMODULE = 0);
var
  Index: Integer;
  Package: TLoadedPackage;
  Chain: TArray<TLoadedDependency>;
  Dependency: TLoadedDependency;
  Brought: TArray<HMODULE>;
  Names: TArray<string>;
  Missing: string;
  IconCount: Integer;
begin
  Package.Path := ACandidate.Path;
  Package.Module := 0;
  Package.Adopted := AAdopted <> 0;
  // Group and Capturing must be set before any load: dependency-chain unit
  // initialization registers just as Register procedures do.
  Package.Group := NewEditorGroup;
  Package.Captures := nil;
  Package.StreamedClasses := nil;
  Packages := Packages + [Package];
  Index := High(Packages);
  Capturing := Index;
  ResetIdeServiceRefusals;
  // The capture window must cover the load itself: LoadPackage unloads a
  // package that raises while it initializes, unmapping the modules the
  // frames of that exception name.
  SetStackCapture(True);
  try
    try
      // The rollback drops the group before unloading what the attempt
      // loaded: chain initialization may have registered under it, and the
      // drop has to run while that code is still mapped.
      if not EnsureDependencies(ACandidate.Path, Chain, Missing,
        procedure
        begin
          DropEditorGroup(Packages[Index].Group);
        end) then
      begin
        LogEntry(lsWarn, Format('%s skipped: required package %s was not ' +
          'found', [ACandidate.Path, Missing]));
        RecordStatus(ACandidate, psDependency,
          Format('required package %s was not found', [Missing]));
        Delete(Packages, Index, 1);
        Exit;
      end;
      RestoreHooksAfterLoad(Format('loading what %s needs',
        [ExtractFileName(ACandidate.Path)]));
      if AAdopted <> 0 then
      begin
        // LoadPackage would run its unit initialization a second time.
        Packages[Index].Module := AAdopted;
        LogEntry(lsInfo, Format('%s is already loaded as a dependency - ' +
          'collecting its registrations without loading it again',
          [ACandidate.Path]));
      end
      else
      begin
        Packages[Index].Module := LoadPackage(ACandidate.Path);
        LogEntry(lsInfo, Format('loaded %s', [ACandidate.Path]));
      end;
      RestoreHooksAfterLoad(Format('loading %s',
        [ExtractFileName(ACandidate.Path)]));
      Brought := [];
      if not IsDesignOnly(Packages[Index].Module) then
        Brought := [Packages[Index].Module];
      for Dependency in Chain do
      begin
        Names := Names + [Dependency.Name];
        if not IsDesignOnly(Dependency.Module) then
          Brought := Brought + [Dependency.Module];
      end;
      if Length(Names) > 0 then
        LogEntry(lsInfo, '  loaded dependencies: ' + string.Join(', ', Names));
      LogPackageInfo(Packages[Index].Module);
      CallRegisterProcs(Index);
      RegisterStreamableClasses(Index, Brought);
      IconCount := HarvestIcons(ACandidate.Path);
      if IconCount > 0 then
        LogEntry(lsInfo, Format('  %d component icon(s) found in its resources',
          [IconCount]));
      RecordStatus(ACandidate, psLoaded, '', PublishCaptures(Index));
    except
      on E: Exception do
      begin
        LogEntry(lsError, Format('%s (%s) could not be loaded: %s: %s',
          [ACandidate.Path, PackageBuild(ACandidate.Path), E.ClassName,
           E.Message]));
        Names := [];
        for Dependency in Chain do
          Names := Names + [Dependency.Name];
        if Length(Names) > 0 then
          LogEntry(lsWarn, '    it had loaded: ' + string.Join(', ', Names));
        ReportFailureDetail(E);
        RecordStatus(ACandidate, psFailed,
          Format('%s: %s', [E.ClassName, E.Message]));
        if Packages[Index].Module = 0 then
        begin
          OrphanGroups := OrphanGroups + [Packages[Index].Group];
          Delete(Packages, Index, 1);
        end;
      end;
    end;
  finally
    SetStackCapture(False);
    Capturing := -1;
  end;
end;

procedure Consider(const ACandidate: TDiscoveredPackage;
  var AHeld, AExcluded, ASwitchedOff: Integer);
var
  Check: TPreflight;
  Adopted: HMODULE;
begin
  if IsSwitchedOff(ACandidate.Path) then
  begin
    RecordStatus(ACandidate, psSwitchedOff, '');
    Inc(ASwitchedOff);
    Exit;
  end;
  if (ACandidate.Origin = poRegistry) and
    IsHeldBack(ACandidate.Path, AllowList) then
  begin
    RecordStatus(ACandidate, psHeld, '');
    Inc(AHeld);
    Exit;
  end;
  if (ACandidate.Origin = poRegistry) and
    IsExcluded(ACandidate.Path, ExcludeList) then
  begin
    LogEntry(lsInfo, Format('%s is on the exclusion list and is not loaded',
      [ACandidate.Path]));
    RecordStatus(ACandidate, psExcluded, '');
    Inc(AExcluded);
    Exit;
  end;
  Check := InspectPackage(ACandidate.Path, ChosenPaths);
  Adopted := 0;
  if Check.Verdict = pvDuplicate then
    Adopted := AdoptableModule(ACandidate.Path);
  if (Check.Verdict <> pvLoadable) and (Adopted = 0) then
  begin
    RecordStatus(ACandidate, StateOf(Check.Verdict), Check.Detail);
    LogSkip(ACandidate, Check);
    Exit;
  end;
  LoadOne(ACandidate, Adopted);
end;

function CandidatePackages: TArray<TDiscoveredPackage>;
var
  Explicit, Installed: TDiscoveredPackage;
  Path: string;
begin
  Result := [];
  Explicit.Origin := poExplicit;
  Explicit.Description := '';
  for Path in ExplicitPaths do
  begin
    Explicit.Path := Path;
    Result := Result + [Explicit];
  end;
  if not DiscoveryEnabled then
    Exit;
  for Installed in InstalledPackages do
    if not NamesPath(ExplicitPaths, Installed.Path) then
      Result := Result + [Installed];
end;

const
  HostedEditorsValue = 'HostedEditors';
  FormDesignerPackage = 'vcldesigner' + PackageSuffix + '.bpl';
  // Mangled export name of Vclformdesigner.InitializeDesigner.
  DesignerInitializerExport: AnsiString =
    '@Vclformdesigner@InitializeDesigner$qqrx63System@%DelphiInterface$36' +
    'Componentdesigner@IDesignEnvironment%';

type
  // Signature DesignerInitializerExport is called through; a mismatch is not
  // diagnosed.
  TInitializeDesigner = procedure(const AEnvironment: IDesignEnvironment);
  // Grants access to the protected RootActivated.
  TComponentDesignerAccess = class(TComponentDesigner);

var
  HostedRead: Boolean = False;
  Hosted: Boolean = False;
  DesignerHosted: Boolean = False;
  // Held for the process lifetime: the designer package calls back into it
  // long after initialization.
  DesignEnvironment: IDesignEnvironment;

function HostedEditors: Boolean;
begin
  if not HostedRead then
  begin
    HostedRead := True;
    Hosted := ReadSettingsFlag(HostedEditorsValue, True);
  end;
  Result := Hosted;
end;

procedure EnvironmentAsked(const AMethod: string);
begin
  LogEntry(lsInfo, Format('design environment call: %s', [AMethod]));
end;

// ComponentDesigner.ActiveDesigner stays nil until a designer window
// activates a root, and no window here does; editor dialogs that read it
// directly need the .dfm designer activated once, with no root.
procedure ActivateDfmDesigner;
var
  Designer: IComponentDesigner;
  Instance: TObject;
begin
  Designer := Designers.DesignerFromExtension('dfm');
  if Designer = nil then
  begin
    LogEntry(lsWarn, 'no component designer answers for .dfm - editor ' +
      'dialogs that read the active designer are unavailable');
    Exit;
  end;
  Instance := Designer as TObject;
  if Instance is TComponentDesigner then
    TComponentDesignerAccess(Instance).RootActivated(nil)
  else
    LogEntry(lsWarn, Format('the .dfm component designer is a %s and was ' +
      'not activated - editor dialogs that read the active designer are ' +
      'unavailable', [Instance.ClassName]));
end;

procedure HostFormDesigner;
var
  Stub: TDesignEnvironmentStub;
  Module: HMODULE;
  Initializer: Pointer;
  FormsBefore, I: Integer;
  Hidden: string;
begin
  if DesignerHosted or not HostedEditors then
    Exit;
  DesignerHosted := True;
  try
    Stub := TDesignEnvironmentStub.Create;
    Stub.OnCall := EnvironmentAsked;
    DesignEnvironment := Stub;
    Module := LoadPackage(IdeBinDirectory + '\' + FormDesignerPackage);
    RestoreHooksAfterLoad('the form designer package');
    Initializer := GetProcAddress(Module,
      PAnsiChar(DesignerInitializerExport));
    if Initializer = nil then
    begin
      LogEntry(lsWarn, Format('%s exports no designer initializer - design-' +
        'window editor dialogs are unavailable', [FormDesignerPackage]));
      Exit;
    end;
    FormsBefore := Screen.FormCount;
    TInitializeDesigner(Initializer)(DesignEnvironment);
    RestoreHooksAfterLoad('the form designer initializer');
    Hidden := '';
    for I := FormsBefore to Screen.FormCount - 1 do
      if Screen.Forms[I].Visible then
      begin
        Screen.Forms[I].Hide;
        Hidden := Hidden + IfThen(Hidden <> '', ', ') +
          Screen.Forms[I].ClassName;
      end;
    if Hidden <> '' then
      LogEntry(lsInfo, Format('the form designer package showed %s - hidden',
        [Hidden]));
    ActivateDfmDesigner;
    LogEntry(lsInfo, 'the form designer package is hosted - design-window ' +
      'editor dialogs (collection editors among them) are available');
  except
    on E: Exception do
      LogEntry(lsWarn, Format('hosting the form designer package failed: ' +
        '%s: %s - design-window editor dialogs are unavailable',
        [E.ClassName, E.Message]));
  end;
end;

procedure LoadPackagesFrom(const ASettingsKey: string);
var
  Candidates: TArray<TDiscoveredPackage>;
  Held, Excluded, TurnedOff, I: Integer;
begin
  // SettingsKeyName must be set before anything reads the configuration.
  SettingsKeyName := ASettingsKey;
  InstallRegistrationHooks;
  // Registrations made before the first candidate, the hosted form designer
  // package above all, land in this ambient group; it is never dropped, so no
  // candidate may share a group with them.
  NewEditorGroup;
  HostFormDesigner;
  try
    ReadConfiguration;
    Candidates := CandidatePackages;
  except
    on E: Exception do
    begin
      LogEntry(lsError, Format('the package list could not be read: %s: %s',
        [E.ClassName, E.Message]));
      Exit;
    end;
  end;
  if Length(Candidates) = 0 then
  begin
    LogEntry(lsInfo, Format('no component packages are configured - looked ' +
      'in HKEY_CURRENT_USER\%s', [PackageSettingsKey]));
    Exit;
  end;

  Held := 0;
  Excluded := 0;
  TurnedOff := 0;
  for I := 0 to High(Candidates) do
  begin
    if Assigned(Watcher) then
      Watcher(I, Length(Candidates),
        TPath.GetFileNameWithoutExtension(Candidates[I].Path));
    Consider(Candidates[I], Held, Excluded, TurnedOff);
  end;
  if TurnedOff > 0 then
    LogEntry(lsInfo, Format('%d package(s) are switched off - listed under ' +
      'Tools, Packages', [TurnedOff]));
  if Held > 0 then
    LogEntry(lsInfo, Format('%d installed package(s) are held back by the ' +
      'allow list (%s)', [Held, string.Join(', ', AllowList)]));
  if Excluded > 0 then
    LogEntry(lsInfo, Format('%d installed package(s) are on the exclusion ' +
      'list (%s) - add one under Tools, Packages to load it anyway',
      [Excluded, string.Join(', ', ExcludeList)]));
end;

procedure LoadConfiguredPackages;
begin
  LoadPackagesFrom(PackageSettingsKey);
end;

procedure Reconsider(var AStatus: TPackageStatus);
var
  Check: TPreflight;
begin
  Check := InspectPackage(AStatus.Path, []);
  if Check.Verdict <> pvLoadable then
  begin
    AStatus.State := StateOf(Check.Verdict);
    AStatus.Detail := Check.Detail;
    Exit;
  end;
  AStatus.Detail := '';
  if IsSwitchedOff(AStatus.Path) then
    AStatus.State := psSwitchedOff
  else if (AStatus.Origin = poRegistry) and
    IsHeldBack(AStatus.Path, AllowList) then
    AStatus.State := psHeld
  else if (AStatus.Origin = poRegistry) and
    IsExcluded(AStatus.Path, ExcludeList) then
    AStatus.State := psExcluded
  else if (AStatus.Origin = poRegistry) and not DiscoveryEnabled then
    AStatus.State := psNotRequested
  else
    AStatus.State := psReady;
end;

function SurveyPackages: TArray<TPackageStatus>;
var
  Installed: TDiscoveredPackage;
  Status: TPackageStatus;
  I: Integer;
begin
  ReadConfiguration;
  Result := Statuses;
  for Installed in InstalledPackages do
    if StatusIndexOf(Result, Installed.Path) < 0 then
    begin
      Status.Path := Installed.Path;
      Status.Description := Installed.Description;
      Status.Origin := Installed.Origin;
      Status.State := psNotRequested;
      Status.Detail := '';
      Status.PaletteCount := 0;
      Result := Result + [Status];
    end;
  for I := 0 to High(Result) do
    if not (Result[I].State in [psLoaded, psFailed]) then
      Reconsider(Result[I]);
end;

function InspectCandidate(const APath: string;
  AOrigin: TPackageOrigin): TPackageStatus;
begin
  ReadConfiguration;
  Result.Path := APath;
  Result.Description := '';
  Result.Origin := AOrigin;
  Result.State := psReady;
  Result.Detail := '';
  Result.PaletteCount := 0;
  Reconsider(Result);
end;

// One TRegistry per call: OpenKey moves the current key, against which a
// following relative key name would resolve.
procedure WritePathValues(const ASubKey: string; const APaths: TArray<string>;
  ANumbered: Boolean);
var
  Registry: TRegistry;
  Key: string;
  I: Integer;
begin
  Key := PackageSettingsKey + '\' + ASubKey;
  Registry := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    Registry.RootKey := HKEY_CURRENT_USER;
    if Registry.KeyExists(Key) then
      Registry.DeleteKey(Key);
    if Length(APaths) = 0 then
      Exit;
    if not Registry.OpenKey(Key, True) then
      raise ERegistryException.CreateFmt('cannot open HKEY_CURRENT_USER\%s',
        [Key]);
    for I := 0 to High(APaths) do
      if ANumbered then
        Registry.WriteInteger(APaths[I], I)
      else
        Registry.WriteInteger(APaths[I], SwitchedOffMark);
  finally
    Registry.Free;
  end;
end;

function WritePackageSettings(
  const ASwitchedOffPaths, AConfiguredPaths: TArray<string>): Boolean;
begin
  Result := True;
  try
    WritePathValues(ConfiguredSubKey, AConfiguredPaths, True);
    WritePathValues(DisabledSubKey, ASwitchedOffPaths, False);
  except
    on E: Exception do
    begin
      Result := False;
      LogEntry(lsError, Format('the package settings could not be written to ' +
        'HKEY_CURRENT_USER\%s: %s', [PackageSettingsKey, E.Message]));
    end;
  end;
  ConfigurationRead := False;
  ReadConfiguration;
end;

procedure ReportProgressTo(const AProgress: TPackageProgress);
begin
  Watcher := AProgress;
end;

procedure ReportInto(ALog: TDesignLog);
var
  I: Integer;
begin
  Reader := ALog;
  if (ALog = nil) or (HostLog = nil) then
    Exit;
  for I := 0 to HostLog.Count - 1 do
    ALog.Add(HostLog[I].Severity, HostLog[I].Text);
  HostLog.Clear;
end;

procedure UnloadAll;
var
  I: Integer;
begin
  DropDynamicClasses;
  ReleaseIcons;
  // Every group before any module: a group holds interfaced editors
  // implemented in the packages, and destroying them has to happen while that
  // code is still mapped.
  for I := High(Packages) downto 0 do
    DropEditorGroup(Packages[I].Group);
  for I := High(OrphanGroups) downto 0 do
    DropEditorGroup(OrphanGroups[I]);
  OrphanGroups := nil;
  for I := High(Packages) downto 0 do
  begin
    Packages[I].Captures := nil;
    Packages[I].StreamedClasses := nil;
    if (Packages[I].Module = 0) or Packages[I].Adopted then
      Continue;
    try
      UnloadPackage(Packages[I].Module);
    except
      on E: Exception do
        LogEntry(lsError, Format('%s could not be unloaded: %s: %s',
          [Packages[I].Path, E.ClassName, E.Message]));
    end;
  end;
  Packages := nil;
  ScannedModules := nil;
  // Dependencies are left mapped on purpose: they register into one another
  // without unregistering (emshosting into emsserverapi's singleton), so no
  // unload order of theirs is safe. Process exit is the only safe teardown.
end;

initialization
  HostLog := TDesignLog.Create;

finalization
  FreeAndNil(DesignNotifications);
  FreeAndNil(HostLog);

end.
