// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.DesignTime.IdeServices;

// BorlandIDEServices stub that lets design-time packages load and register
// outside the IDE. Most services are inert: calls are accepted and discarded,
// getters answer nil or an empty value. The installation directories and the
// IDE main menu, action list, image list and toolbars are answered for real.
//
// A hard cast to a service the stub cannot answer raises EIntfCastError in
// the caller; a refused query this class answers itself is recorded, and
// reported through TServiceRefused when a handler was installed. The refusal
// state is an unguarded unit-level global, so installation and package loads
// must stay on one thread.

interface

type
  // Reports one refused service: AService is the ToolsAPI interface name with
  // its GUID, or the GUID alone when the name is unknown, and AHow names the
  // query ('an interface cast', 'GetService', 'SupportsService'). Each pair is
  // reported once until ResetIdeServiceRefusals.
  TServiceRefused = procedure(const AService, AHow: string);

// Installs the stub as ToolsAPI.BorlandIDEServices and TStubSplashScreen as
// SplashScreenServices; a global that is already assigned is left untouched.
// AOnRefused is stored only by the call that creates the stub.
procedure InstallIdeServicesStub(AOnRefused: TServiceRefused = nil);

// Clears the recorded refusals. Called before each package load so a failing
// load reports everything it was refused, not only what no earlier load had
// already recorded.
procedure ResetIdeServiceRefusals;

// Refusals recorded since the last ResetIdeServiceRefusals, each entry the
// query followed by the service GUID, prefixed with the interface name where
// it is known. Read after a failed package load: EIntfCastError reports only
// a localized 'interface not supported'.
function RefusedIdeServices: TArray<string>;

implementation

uses
  Winapi.Windows,
  Winapi.ActiveX,
  System.SysUtils,
  System.Classes,
  Vcl.Graphics,
  Vcl.ImgList,
  Vcl.Controls,
  Vcl.ActnList,
  Vcl.Menus,
  Vcl.ComCtrls,
  Vcl.Forms,
  Vcl.Dialogs,
  Vcl.TitleBarCtrls,
  Vcl.ImageCollection,
  ToolsAPI,
{$IF CompilerVersion >= 36.0} 
  ToolsAPI.UI,
{$IFEND}
  PaletteAPI,
  PlatformAPI,
  DataExplorerAPI,
  VisualizationServicesAPI,
  System.Types,
  Xml.XMLIntf,
  Vallenta.FormEditor.Packages.Discovery;

type
  // Palette services stub; palette state and notifiers are accepted and
  // discarded. The list getters return an empty list rather than nil because
  // callers iterate the result.
  TStubPaletteServices = class(TInterfacedObject, IOTAPaletteServices270,
    IOTAPaletteServices280, IOTAPaletteServices)
  public
    { IOTAPaletteServices270 }
    procedure SetSelectedTool(const Value: IOTABasePaletteItem);
    function GetBaseGroup: IOTAPaletteGroup;
    function GetSelectedTool: IOTABasePaletteItem;
    function AddNotifier(const Notifier: IOTAPaletteNotifier): Integer;
    procedure BeginUpdate;
    procedure EndUpdate;
    procedure ItemAdded(const Group: IOTAPaletteGroup;
      const Item: IOTABasePaletteItem);
    procedure ItemRemoved(const Group: IOTAPaletteGroup;
      const Item: IOTABasePaletteItem);
    procedure Modified;
    function RegisterDragAcceptor(
      const Acceptor: IOTAPaletteDragAcceptor): Integer;
    procedure UnRegisterDragAcceptor(const Index: Integer);
    function GetDragAcceptors: IInterfaceList;
    function RegisterColorScheme(
      const ColorScheme: IOTAPaletteColorScheme): Integer;
    procedure UnRegisterColorScheme(const Index: Integer);
    function GetColorSchemes: IInterfaceList;
    procedure RemoveNotifier(const Index: Integer);
    procedure AddPaletteState(const State: string);
    procedure RemovePaletteState(const State: string);
    procedure AddPaletteDesignerState(const State: string);
    function ContainsPaletteState(const State: string): Boolean;
    function GetPaletteState: string;
    { IOTAPaletteServices280 }
    procedure SetImageCollection(const AValue: TImageCollection);
    function GetImageCollection: TImageCollection;
  end;

  // Project-file storage stub; notifier registration is accepted and
  // discarded, and the node getters return nil because there is no project
  // file. Stubbed because the database and DataSnap design packages cast for
  // it while loading.
  TStubProjectFileStorage = class(TInterfacedObject, IOTAProjectFileStorage)
  public
    function AddNewSection(const ProjectOrGroup: IOTAModule;
      SectionName: string; LocalProjectFile: Boolean): IXMLNode;
    function AddNotifier(const ANotifier: IOTAProjectFileStorageNotifier): Integer;
    function GetNotifierCount: Integer;
    function GetNotifier(Index: Integer): IOTAProjectFileStorageNotifier;
    function GetProjectStorageNode(const ProjectOrGroup: IOTAModule;
      const NodeName: string; LocalProjectFile: Boolean): IXMLNode;
    procedure RemoveNotifier(Index: Integer);
  end;

  // Gallery category created by TStubGalleryCategories; holds the id string,
  // display name and parent it was created with.
  TStubGalleryCategory = class(TInterfacedObject, IOTAGalleryCategory)
  private
    FIDString: string;
    FDisplayName: string;
    FParent: IOTAGalleryCategory;
  public
    constructor Create(const AIDString, ADisplayName: string;
      const AParent: IOTAGalleryCategory);
    { IOTAGalleryCategory }
    function GetDisplayName: string;
    function GetIDString: string;
    function GetParent: IOTAGalleryCategory;
  end;

  // Gallery category manager stub; the categories AddCategory creates are
  // kept so FindCategory answers them. Stubbed because the SOAP and DataSnap
  // design packages cast for it while registering their project wizards, and
  // a raised cast skips the rest of their Register procedure.
  TStubGalleryCategories = class(TInterfacedObject, IOTAGalleryCategoryManager)
  private
    FCategories: TArray<IOTAGalleryCategory>;
  public
    { IOTAGalleryCategoryManager }
    function FindCategory(const IDString: string): IOTAGalleryCategory;
    function AddCategory(const IDString, DisplayName: string;
      IconHandle: Integer = 0): IOTAGalleryCategory; overload;
    function AddCategory(const ParentCategory: IOTAGalleryCategory;
      const IDString, DisplayName: string;
      IconHandle: Integer = 0): IOTAGalleryCategory; overload;
    procedure DeleteCategory(const Category: IOTAGalleryCategory);
  end;

  // Splash screen stub; every call is discarded. Installed into the global
  // ToolsAPI.SplashScreenServices, which is not reached through
  // BorlandIDEServices: a package calling it while that global is nil faults
  // on address 0 instead of producing a refusal.
  TStubSplashScreen = class(TInterfacedObject, IOTASplashScreenServices270,
    IOTASplashScreenServices280, IOTASplashScreenServices)
  public
    { IOTASplashScreenServices270 }
    procedure AddPluginBitmap(const ACaption: string; ABitmap: HBITMAP;
      AIsUnRegistered: Boolean = False; const ALicenseStatus: string = '';
      const ASKUName: string = ''); overload;
    procedure AddProductBitmap(const ACaption: string; ABitmap: HBITMAP;
      IsUnRegistered: Boolean = False; const ALicenseStatus: string = '';
      const ASKUName: string = ''); overload;
    procedure ShowProductSplash(ABitmap: HBITMAP);
    procedure StatusMessage(const StatusMessage: string);
    procedure SetProductIcon(AIcon: HICON);
    { IOTASplashScreenServices280 }
    procedure AddPluginBitmap(const Caption: string;
      const AImageArray: TGraphicArray; AIsUnRegistered: Boolean = False;
      const ALicenseStatus: string = ''; const ASKUName: string = ''); overload;
    procedure AddProductBitmap(const Caption: string;
      const AImageArray: TGraphicArray; AIsUnRegistered: Boolean = False;
      const ALicenseStatus: string = ''; const ASKUName: string = ''); overload;
  end;

  // Message group returned by TStubMessageServices in place of nil, since
  // callers use the answer without a nil check; holds the fixed name 'Build'
  // and the two flags.
  TStubMessageGroup = class(TInterfacedObject, IOTAMessageGroup80,
    IOTAMessageGroup90, IOTAMessageGroup)
  private
    FName: string;
    FAutoScroll: Boolean;
    FCanClose: Boolean;
  public
    constructor Create(const AName: string);
    { IOTAMessageGroup80 }
    function GetGroupName: string;
    { IOTAMessageGroup90 }
    function GetAutoScroll: Boolean;
    procedure SetAutoScroll(Value: Boolean);
    { IOTAMessageGroup }
    function GetCanClose: Boolean;
    procedure SetCanClose(Value: Boolean);
  end;

  // Message services stub; there is no message view, so messages and
  // notifiers are discarded and one shared group named 'Build' answers every
  // group request. Stubbed because the version-control design packages cast
  // for it while they initialize, where a refused cast aborts the load.
  TStubMessageServices = class(TInterfacedObject, IOTAMessageServices40,
    IOTAMessageServices50, IOTAMessageServices60, IOTAMessageServices70,
    IOTAMessageServices80, IOTAMessageServices)
  private
    FGroup: IOTAMessageGroup;
  public
    constructor Create;
    { IOTAMessageServices40 }
    procedure AddCustomMessage(const CustomMsg: IOTACustomMessage); overload;
    procedure AddTitleMessage(const MessageStr: string); overload;
    procedure AddToolMessage(const FileName, MessageStr, PrefixStr: string;
      LineNumber, ColumnNumber: Integer); overload;
    procedure ClearAllMessages;
    procedure ClearCompilerMessages;
    procedure ClearSearchMessages;
    procedure ClearToolMessages; overload;
    { IOTAMessageServices50 }
    procedure AddToolMessage(const FileName, MessageStr, PrefixStr: string;
      LineNumber, ColumnNumber: Integer; Parent: Pointer;
      out LineRef: Pointer); overload;
    { IOTAMessageServices60 }
    function AddNotifier(const ANotifier: IOTAMessageNotifier): Integer;
    procedure RemoveNotifier(Index: Integer);
    function AddMessageGroup(const GroupName: string): IOTAMessageGroup;
    procedure AddCustomMessage(const CustomMsg: IOTACustomMessage;
      const MessageGroupIntf: IOTAMessageGroup); overload;
    procedure AddTitleMessage(const MessageStr: string;
      const MessageGroupIntf: IOTAMessageGroup); overload;
    procedure AddToolMessage(const FileName, MessageStr, PrefixStr: string;
      LineNumber, ColumnNumber: Integer; Parent: Pointer; out LineRef: Pointer;
      const MessageGroupIntf: IOTAMessageGroup); overload;
    procedure ClearMessageGroup(const MessageGroupIntf: IOTAMessageGroup);
    procedure ClearToolMessages(
      const MessageGroupIntf: IOTAMessageGroup); overload;
    function GetMessageGroupCount: Integer;
    function GetMessageGroup(Index: Integer): IOTAMessageGroup;
    function GetGroup(const GroupName: string): IOTAMessageGroup;
    procedure ShowMessageView(const MessageGroupIntf: IOTAMessageGroup);
    procedure RemoveMessageGroup(const MessageGroupIntf: IOTAMessageGroup);
    { IOTAMessageServices70 }
    procedure AddCompilerMessage(const FileName, MessageStr, ToolName: string;
      Kind: TOTAMessageKind; LineNumber, ColumnNumber: Integer; Parent: Pointer;
      out LineRef: Pointer); overload;
    { IOTAMessageServices80 }
    procedure NextMessage(GoForward: Boolean);
    procedure NextErrorMessage(GoForward: Boolean; ErrorsOnly: Boolean);
    procedure AddCompilerMessage(const FileName, MessageStr, ToolName: string;
      Kind: TOTAMessageKind; LineNumber, ColumnNumber: Integer; Parent: Pointer;
      out LineRef: Pointer; HelpKeyword: string); overload;
    procedure AddCompilerMessage(const FileName, MessageStr, ToolName: string;
      Kind: TOTAMessageKind; LineNumber, ColumnNumber: Integer; Parent: Pointer;
      out LineRef: Pointer; HelpContext: Integer); overload;
    { IOTAMessageServices }
    function AddCustomMessage(const CustomMsg: IOTACustomMessage;
      Parent: Pointer): Pointer; overload;
    function AddCustomMessagePtr(const CustomMsg: IOTACustomMessage;
      const MessageGroupIntf: IOTAMessageGroup): Pointer;
    procedure AddWideCompilerMessage(const FileName, MessageStr,
      ToolName: WideString; Kind: TOTAMessageKind;
      LineNumber, ColumnNumber: Integer; Parent: Pointer;
      out LineRef: Pointer); overload;
    procedure AddWideCompilerMessage(const FileName, MessageStr,
      ToolName: WideString; Kind: TOTAMessageKind;
      LineNumber, ColumnNumber: Integer; Parent: Pointer; out LineRef: Pointer;
      HelpKeyword: WideString); overload;
    procedure AddWideCompilerMessage(const FileName, MessageStr,
      ToolName: WideString; Kind: TOTAMessageKind;
      LineNumber, ColumnNumber: Integer; Parent: Pointer; out LineRef: Pointer;
      HelpContext: Integer); overload;
    function AddWideMessageGroup(const GroupName: WideString): IOTAMessageGroup;
    procedure AddWideTitleMessage(const MessageStr: WideString); overload;
    procedure AddWideTitleMessage(const MessageStr: WideString;
      const MessageGroupIntf: IOTAMessageGroup); overload;
    procedure AddWideToolMessage(const FileName, MessageStr,
      PrefixStr: WideString; LineNumber, ColumnNumber: Integer); overload;
    procedure AddWideToolMessage(const FileName, MessageStr,
      PrefixStr: WideString; LineNumber, ColumnNumber: Integer; Parent: Pointer;
      out LineRef: Pointer); overload;
    procedure AddWideToolMessage(const FileName, MessageStr,
      PrefixStr: WideString; LineNumber, ColumnNumber: Integer; Parent: Pointer;
      out LineRef: Pointer;
      const MessageGroupIntf: IOTAMessageGroup); overload;
    function GetWideGroup(const GroupName: WideString): IOTAMessageGroup;
  end;

  // Keyboard services stub; bindings, playback and recording are accepted and
  // discarded. GetEditorServices returns nil rather than a stub, so a caller
  // that dereferences it raises an access violation, caught by the package
  // load as a refused cast is. Stubbed because the editor-extension packages
  // cast for it inside their Register procedures.
  TStubKeyboardServices = class(TInterfacedObject, IOTAKeyboardServices)
  public
    function AddKeyboardBinding(const KeyBinding: IOTAKeyboardBinding): Integer;
    function GetCurrentPlayback: IOTARecord;
    function GetCurrentRecord: IOTARecord;
    function GetEditorServices: IOTAEditorServices;
    function GetKeysProcessed: LongWord;
    function NewRecordObject(out ARecord: IOTARecord): Boolean;
    procedure PausePlayback;
    procedure PauseRecord;
    procedure PopKeyboard(const Keyboard: string);
    function PushKeyboard(const Keyboard: string): string;
    procedure RestartKeyboardServices;
    procedure ResumePlayback;
    procedure ResumeRecord;
    procedure RemoveKeyboardBinding(Index: Integer);
    procedure SetPlaybackObject(const ARecord: IOTARecord);
    procedure SetRecordObject(const ARecord: IOTARecord);
    function LookupKeyBinding(const Keys: array of TShortCut;
      out BindingRec: TKeyBindingRec;
      const KeyBoard: string = ''): Boolean;
    function GetNextBindingRec(var BindingRec: TKeyBindingRec): Boolean;
    function CallKeyBindingProc(
      const BindingRec: TKeyBindingRec): TKeyBindingResult;
  end;

  // Compile services stub; there is no project and no compiler.
  // CompileProjects returns crOTAFailed, CancelBackgroundCompile returns True
  // and background compilation is never active.
  TStubCompileServices = class(TInterfacedObject, IOTACompileServices)
  public
    function AddNotifier(Notifier: IOTACompileNotifier): Integer;
    procedure RemoveNotifier(Index: Integer);
    function CancelBackgroundCompile(Prompt: Boolean): Boolean;
    function CompileProjects(Projects: array of IOTAProject;
      CompileMode: TOTACompileMode;
      Wait, ClearMessages: Boolean): TOTACompileResult;
    procedure DisableBackgroundCompilation;
    procedure EnableBackgroundCompilation;
    function IsBackgroundCompileActive: Boolean;
  end;

  // Debugger services stub; process and breakpoint counts are zero and the
  // factory methods return nil. Stubbed because the debug visualizer packages
  // cast for it to register a visualizer from their Register procedures.
  TStubDebuggerServices = class(TInterfacedObject, IOTADebuggerServices60,
    IOTADebuggerServices90, IOTADebuggerServices120, IOTADebuggerServices150,
    IOTADebuggerServices)
  public
    { IOTADebuggerServices60 }
    function AddNotifier(const Notifier: IOTADebuggerNotifier): Integer;
    procedure AttachProcess(Pid: Integer;
      const RemoteHost: string = ''); overload;
    procedure CreateProcess(const ExeName, Args: string;
      const RemoteHost: string = '');
    procedure EnumerateRunningProcesses(
      Callback: TEnumerateProcessesCallback; Param: Pointer;
      const HostName: string = '');
    function GetAddressBkptCount: Integer;
    function GetAddressBkpt(Index: Integer): IOTAAddressBreakpoint;
    function GetCurrentProcess: IOTAProcess;
    function GetProcessCount: Integer;
    function GetProcess(Index: Integer): IOTAProcess;
    function GetSourceBkptCount: Integer;
    function GetSourceBkpt(Index: Integer): IOTASourceBreakpoint;
    procedure LogString(const LogStr: string); overload;
    function NewAddressBreakpoint(Address, Length: LongWord;
      AccessType: TOTAAccessType;
      const AProcess: IOTAProcess = nil): IOTABreakpoint; overload;
    function NewModuleBreakpoint(const ModuleName: string;
      const AProcess: IOTAProcess): IOTABreakpoint; overload;
    function NewSourceBreakpoint(const FileName: string; LineNumber: Integer;
      const AProcess: IOTAProcess): IOTABreakpoint;
    procedure RemoveNotifier(Index: Integer);
    procedure SetCurrentProcess(const Process: IOTAProcess);
    { IOTADebuggerServices90 }
    procedure LogString(const LogStr: string;
      LogItemType: TLogItemType); overload;
    { IOTADebuggerServices120 }
    procedure AttachProcess(Pid: Integer; PauseAfterAttach: Boolean;
      DetachOnReset: Boolean; const RemoteHost: string = ''); overload;
    { IOTADebuggerServices150 }
    function GetModuleBkptCount: Integer;
    function GetModuleBkpt(Index: Integer): string;
    procedure NewModuleBreakpoint(const ModuleName: string); overload;
    procedure RemoveModuleBreakpoint(const ModuleName: string);
    procedure RemoveBreakpoint(const Breakpoint: IOTABreakpoint);
    procedure RegisterDebugVisualizer(
      const Visualizer: IOTADebuggerVisualizer);
    procedure UnregisterDebugVisualizer(
      const Visualizer: IOTADebuggerVisualizer);
    procedure ProcessDebugEvents;
    { IOTADebuggerServices }
    function NewAddressBreakpoint(Address: TOTAAddress; Length: LongWord;
      AccessType: TOTAAccessType;
      const AProcess: IOTAProcess = nil): IOTABreakpoint; overload;
  end;

  // Remote profile services stub; no profile exists, every operation that
  // reports success returns False and the profile dialogs return nil, while
  // the path expanders return their argument unchanged. Operations that
  // report an ErrorMessage set it to RemoteRefusal. Stubbed because the
  // mobile wizard package casts for it in its Register procedure.
  TStubRemoteProfileServices = class(TInterfacedObject,
    IOTARemoteProfileServices160)
  public
    function GetProfileCount(const PlatformName: string): Integer;
    function GetProfile(const PlatformName: string;
      Index: Integer): IOTARemoteProfile; overload;
    function GetProfile(const ProfileName: string): IOTARemoteProfile; overload;
    function AddProfile(const Name: string; const PlatformName: string;
      const HostName: string; PortNumber: Integer;
      const Credential: TOTARemoteProfileCredential; const SystemRoot: string;
      const Paths: TOTARemoteProfilePathArray;
      IsDefault: Boolean): IOTARemoteProfile;
    procedure EditProfile(const Name: string);
    procedure RemoveProfile(const Profile: IOTARemoteProfile);
    function GetDefaultForPlatform(
      const PlatformName: string): IOTARemoteProfile;
    procedure SetAsDefaultForPlatform(const Profile: IOTARemoteProfile);
    procedure BeginOperation(const Profile: IOTARemoteProfile);
    procedure EndOperation(const Profile: IOTARemoteProfile);
    function TestConnection(const Profile: IOTARemoteProfile;
      out ErrorMessage: string;
      ConnectionCallBack: IOTAConnectionCallback = nil): Boolean;
    function GetProfileFiles(const Profile: IOTARemoteProfile;
      OverwriteControl: TOTAFileOverwriteControl = ofocPromptUserToOverwrite;
      ConnectionCallback: IOTAConnectionCallback = nil;
      ProgressCallback: TOTAGetProfileFilesProgressCallback = nil): Boolean;
    function GetFileInfo(const Profile: IOTARemoteProfile; const Path: string;
      out LastWriteTime: TDateTime; out Size: Int64): Boolean;
    function GetRemoteFileInfo(const Profile: IOTARemoteProfile;
      const Path: string; out LastWriteTime: TDateTime; out Size: Int64;
      ConnectionCallBack: IOTAConnectionCallback = nil): Boolean;
    function GetProfileFilesWithProgress(
      const Profile: IOTARemoteProfile): Boolean;
    function PutFiles(const Profile: IOTARemoteProfile;
      const Files: TOTAPutFileArray;
      OverwriteControl: TOTAFileOverwriteControl = ofocAlwaysOverwrite;
      ConnectionCallback: IOTAConnectionCallback = nil;
      ProgressCallback: TOTAGetProfileFilesProgressCallback = nil): Boolean;
    function PutFilesWithProgress(const Profile: IOTARemoteProfile;
      const Files: TOTAPutFileArray): Boolean;
    function RemoveRemoteFiles(const Profile: IOTARemoteProfile;
      const Files: TStringDynArray;
      ConnectionCallback: IOTAConnectionCallback = nil;
      ProgressCallback: TOTAGetProfileFilesProgressCallback = nil): Boolean;
    function RemoveRemoteFilesWithProgress(const Profile: IOTARemoteProfile;
      const Files: TStringDynArray): Boolean;
    function BrowseRemoteFileSystem(const Profile: IOTARemoteProfile;
      const Path: string; Attributes: Integer; IncludeTimeStamp: Boolean;
      ConnectionCallBack: IOTAConnectionCallback = nil)
      : TOTARemoteFileInfoArray;
    function RemoteDirectoryExists(const Profile: IOTARemoteProfile;
      const Directory: string;
      ConnectionCallBack: IOTAConnectionCallback = nil): Boolean;
    function GetRemoteBaseDirectory(const Profile: IOTARemoteProfile;
      ConnectionCallBack: IOTAConnectionCallback = nil): string;
    function ExpandPath(const Profile: IOTARemoteProfile; const Path: string;
      ConnectionCallBack: IOTAConnectionCallback = nil): string;
    function ExpandAllPaths(const Profile: IOTARemoteProfile;
      const Paths: string;
      ConnectionCallBack: IOTAConnectionCallback = nil): string;
    function CreateSymLink(const Profile: IOTARemoteProfile;
      const LinkPath: string; const TargetPath: string;
      ConnectionCallBack: IOTAConnectionCallback = nil): Boolean;
    function Run(const Profile: IOTARemoteProfile;
      const PathUnderScratchDir: string; const ExeName: string;
      const Params: string; const Launcher: string; const WorkingDir: string;
      const EnvList: TStrings; const UserName: string;
      out ErrorMessage: string;
      ConnectionCallback: IOTAConnectionCallback = nil): Boolean;
    function StartRemoteDebugger(const Profile: IOTARemoteProfile;
      const UserName: string; const ProcessType: TOTAProcessType;
      out DebuggerId: Integer; out DebuggerPort: Integer;
      out ErrorMessage: string;
      ConnectionCallback: IOTAConnectionCallback = nil): Boolean;
    function ExecuteNewProfileWizard(const InitialPlatform: string = '';
      RestrictToInitialPlatform: Boolean = False): IOTARemoteProfile;
    function ShowSelectProfileDialog(
      const PlatformName: string = ''): IOTARemoteProfile;
    function CanDeployProject(const Project: IOTAProject;
      const Profile: IOTARemoteProfile): Boolean;
    function DeployProject(const Project: IOTAProject;
      const Profile: IOTARemoteProfile; Configuration: string = '';
      PlatformName: string = ''; ClearMessages: Boolean = True): Boolean;
    function EnsureProfileForCompile(const Project: IOTAProject;
      const PlatformName: string;
      var ErrorMessage: string): TOTARemoteProfileStatus;
    function EnsureProfileForRun(const Project: IOTAProject;
      var ErrorMessage: string): TOTARemoteProfileStatus;
    function AddNotifier(const Notifier: IOTARemoteProfileNotifier): Integer;
    procedure RemoveNotifier(Index: Integer);
    function GetEnvironmentVariables(const Profile: IOTARemoteProfile;
      ConnectionCallBack: IOTAConnectionCallback = nil): TStringDynArray;
  end;

  // Data explorer stub; root nodes, tabs and images are accepted and
  // discarded, no tab is ever reported as present, and ObjInspectorSelect
  // does not reach this program's object inspector.
  TStubDataExplorerService = class(TInterfacedObject, IOTADataExplorerService)
  public
    procedure DeleteGroup(const AGroupNum: Integer);
    procedure RegisterRootNode(ARootItem: IOTADataExplorerItem);
    procedure UnregisterRootNode(ARootItem: IOTADataExplorerItem);
    function GetRootNodes: TArray<IOTADataExplorerItem>;
    procedure RefreshNode(AIdentity: TObject; AItem: IOTADataExplorerItem;
      AChildren: Boolean);
    procedure DeleteNode(AIdentity: TObject);
    procedure SelectNewChildNode(AParentIdentity: TObject;
      AItem: IOTADataExplorerItem; const AName: string);
    procedure RefreshChildNode(AParentIdentity: TObject;
      AItem: IOTADataExplorerItem; const AName: string; AChildren: Boolean);
    function AddImages(const Images: TCustomImageList): Integer;
    procedure AddTab(const ATabCaption: string; AFrameClass: TFrameClass;
      AFrameCreatedProc: TProc<TFrame>);
    procedure RenameTab(const AOldCaption, ANewCaption: string);
    procedure RemoveTab(const ATabCaption: string);
    function HasTab(const ATabCaption: string): Boolean;
    procedure ActivateTab(const ATabCaption: string);
    procedure ObjInspectorSelect(const AObj: TPersistent);
  end;

  // Visualization service stub; drawing controls and graph handlers are
  // accepted and discarded, and there is no active graph or model.
  TStubVisualizationService = class(TInterfacedObject, IVisualizationService)
  public
    procedure DeleteGroup(const AGroupNum: Integer);
    procedure RegisterDrawingControl(const ADrawing: IInterface);
    procedure UnregisterDrawingControl(const ADrawing: IInterface);
    function GetDrawingControl: IVGDrawing;
    procedure FocusDrawing;
    procedure RegisterGraphHandler(const AGraphHandler: IVGHandler);
    procedure UnregisterGraphHandler(const AGraphHandler: IVGHandler);
    function ActiveGraph: IVGHandler;
    procedure ActivateGraph(const AGraphHandlerId: string);
    procedure ClearActiveGraph;
    function GetGraphIds: TArray<string>;
    procedure ActivateModule(const AModule: IVGModule);
    function ActiveModel: IVGModel;
    function VGDirToLBDir(const ALinkDir: TVGDirection): string;
    function VGElementKindToLBPropertyValue(
      const AElementKind: TVGElementKind): string;
    function GetActive: Boolean;
    procedure SetActive(AValue: Boolean);
  end;

  // The BorlandIDEServices stub. The ten stub services held in the fields
  // below are reached through the implements properties, their method names
  // colliding with each other and with the services declared here; an
  // interface query this class cannot answer is recorded and reported once
  // through the refusal handler.
  TStubIdeServices = class(TInterfacedObject, IBorlandIDEServices,
    IBorlandIDEServices70, IOTAPersonalityServices, IOTAPersonalityServices140,
    IOTAPersonalityServices100, IOTAWizardServices,
{$IF CompilerVersion >= 36.0}
    INTAIDEUIServices, INTAIDEUIServices290,
{$IFEND}
    IOTAModuleServices70, IOTAModuleServices,
    IOTAServices50, IOTAServices60, IOTAServices70, IOTAServices100,
    IOTAServices110, IOTAServices140, IOTAServices160, IOTAServices,
    INTAServices40, INTAServices70, INTAServices90, INTAServices120,
    INTAServices270, INTAServices280,
{$IF CompilerVersion >= 36.0}
    INTAServices290,
{$IFEND}
    INTAServices,
    IOTAAboutBoxServices120, IOTAAboutBoxServices270,
    IOTAAboutBoxServices280, IOTAAboutBoxServices,
    IOTAPaletteServices270, IOTAPaletteServices280, IOTAPaletteServices,
    IOTAProjectFileStorage, IOTAGalleryCategoryManager,
    IOTAMessageServices40, IOTAMessageServices50, IOTAMessageServices60,
    IOTAMessageServices70, IOTAMessageServices80, IOTAMessageServices,
    INTAEnvironmentOptionsServices, IOTAKeyboardServices, IOTACompileServices,
    IOTADebuggerServices60, IOTADebuggerServices90, IOTADebuggerServices120,
    IOTADebuggerServices150, IOTADebuggerServices,
    IOTARemoteProfileServices160, IOTADataExplorerService,
    IVisualizationService)
  private
    FPalette: IOTAPaletteServices;
    FProjectStorage: IOTAProjectFileStorage;
    FGalleryCategories: IOTAGalleryCategoryManager;
    FMessages: IOTAMessageServices;
    FKeyboard: IOTAKeyboardServices;
    FCompile: IOTACompileServices;
    FDebugger: IOTADebuggerServices;
    FRemoteProfiles: IOTARemoteProfileServices160;
    FDataExplorer: IOTADataExplorerService;
    FVisualization: IVisualizationService;
    // IDE-window objects returned by INTAServices, never shown; freed with
    // FIdeUi, their component owner. They stay non-nil and FMainMenu keeps
    // the IDE's top-level items, because a package looks an item up by name
    // and uses the result without a nil check.
    FIdeUi: TComponent;
    FMainMenu: TMainMenu;
    FActionList: TActionList;
    FImageList: TImageList;
    // Name-to-TToolBar map, matched case-insensitively; one toolbar per
    // requested name, each owned by FIdeUi.
    FToolBars: TStringList;
    procedure BuildIdeMenu;
    function ToolBarNamed(const AName: string): TToolBar;
{$IF CompilerVersion >= 36.0}
    function ColorFor(ITC: TIDEThemeColors): TColor;
{$IFEND}
  public
    constructor Create;
    destructor Destroy; override;
    // Hides the non-virtual TInterfacedObject.QueryInterface; a cast through
    // IBorlandIDEServices or another interface implemented by this class
    // dispatches to it, while a reference obtained from an implements
    // property carries the delegate's QueryInterface. Records the GUID of
    // every query it cannot answer, which names the missing service after a
    // package load fails.
    function QueryInterface(const IID: TGUID; out Obj): HResult; stdcall;
    // Delegation to the stub objects created in the constructor.
    property PaletteServices: IOTAPaletteServices read FPalette
      implements IOTAPaletteServices270, IOTAPaletteServices280,
      IOTAPaletteServices;
    property ProjectFileStorage: IOTAProjectFileStorage read FProjectStorage
      implements IOTAProjectFileStorage;
    property GalleryCategories: IOTAGalleryCategoryManager
      read FGalleryCategories implements IOTAGalleryCategoryManager;
    property Messages: IOTAMessageServices read FMessages
      implements IOTAMessageServices40, IOTAMessageServices50,
      IOTAMessageServices60, IOTAMessageServices70, IOTAMessageServices80,
      IOTAMessageServices;
    property Keyboard: IOTAKeyboardServices read FKeyboard
      implements IOTAKeyboardServices;
    property Compile: IOTACompileServices read FCompile
      implements IOTACompileServices;
    property Debugger: IOTADebuggerServices read FDebugger
      implements IOTADebuggerServices60, IOTADebuggerServices90,
      IOTADebuggerServices120, IOTADebuggerServices150, IOTADebuggerServices;
    property RemoteProfiles: IOTARemoteProfileServices160 read FRemoteProfiles
      implements IOTARemoteProfileServices160;
    property DataExplorer: IOTADataExplorerService read FDataExplorer
      implements IOTADataExplorerService;
    property Visualization: IVisualizationService read FVisualization
      implements IVisualizationService;
    { INTAEnvironmentOptionsServices }
    procedure RegisterAddInOptions(const AddInOptions: INTAAddInOptions);
    procedure UnregisterAddInOptions(const AddInOptions: INTAAddInOptions);
    { IBorlandIDEServices }
    function SupportsService(const Service: TGUID): Boolean;
    function GetService(const Service: TGUID): IInterface; overload;
    function GetService(const Service: TGUID; out Svc): Boolean; overload;
    { IOTAWizardServices }
    function AddWizard(const AWizard: IOTAWizard): Integer;
    procedure RemoveWizard(Index: Integer);
    { IOTAPersonalityServices100 }
    function GetPersonalityCount: Integer;
    function GetPersonality(Index: Integer): string;
    function AddPersonality(const APersonality: string): Integer;
    procedure RemovePersonality(const APersonality: string);
    procedure AddPersonalityTrait(const APersonality: string;
      const ATraitGUID: TGUID; const ATrait: IInterface);
    procedure RemovePersonalityTrait(const APersonality: string;
      const ATraitGUID: TGUID);
    procedure AddFileType(const APersonality, AFileType: string);
    procedure RemoveFileType(const APersonality, AFileType: string);
    procedure AddFileExtensions(const APersonality, AFileType,
      AFileExtensions: string);
    procedure RemoveFileExtensions(const APersonality, AFileType,
      AFileExtensions: string);
    procedure AddFileTrait(const APersonality, AFileType: string;
      const ATraitGUID: TGUID; const ATrait: IInterface);
    procedure RemoveFileTrait(const APersonality, AFileType: string;
      const ATraitGUID: TGUID);
    function GetCurrentPersonality: string;
    procedure SetCurrentPersonality(const APersonality: string);
    function GetFileTrait(const APersonality, AFileName: string;
      const ATraitGUID: TGUID; SearchDefault: Boolean): IInterface; overload;
    function GetFileTrait(const AFileName: string; const ATraitGUID: TGUID;
      SearchDefault: Boolean): IInterface; overload;
    function GetFileTrait(const APersonality, AFileName: string;
      const ATraitGUID: TGUID): IInterface; overload;
    function GetFileTrait(const AFileName: string;
      const ATraitGUID: TGUID): IInterface; overload;
    function GetTrait(const APersonality: string;
      const ATraitGUID: TGUID): IInterface; overload;
    function GetTrait(const ATraitGUID: TGUID): IInterface; overload;
    function SupportsFileTrait(const APersonality, AFileName: string;
      const ATraitGUID: TGUID; SearchDefault: Boolean): Boolean; overload;
    function SupportsFileTrait(const AFileName: string;
      const ATraitGUID: TGUID; SearchDefault: Boolean): Boolean; overload;
    function SupportsFileTrait(const APersonality, AFileName: string;
      const ATraitGUID: TGUID): Boolean; overload;
    function SupportsFileTrait(const AFileName: string;
      const ATraitGUID: TGUID): Boolean; overload;
    function SupportsTrait(const APersonality: string;
      const ATraitGUID: TGUID): Boolean; overload;
    function SupportsTrait(const ATraitGUID: TGUID): Boolean; overload;
    function PromptUserForPersonality(const ATraitGUID: TGUID;
      const Prompt: string): Boolean;
    { IOTAPersonalityServices140 }
    function GetFilePersonality(const AFileName: string): string;
    function FindFileTrait(const AFileName: string;
      const ATraitGUID: TGUID): IInterface;
    function PersonalityExists(const APersonality: string): Boolean;
    { IOTAPersonalityServices }
    function GetPersonalityId(const APersonality: string): Integer;
{$IF CompilerVersion >= 36.0}
    { INTAIDEUIServices }
    function GetThemeAwareColor(ITC: TIDEThemeColors): TColor;
    function GetDarkColor(ITC: TIDEThemeColors): TColor;
    function GetGenericColor(ITC: TIDEThemeColors): TColor;
    function GetLightColor(ITC: TIDEThemeColors): TColor;
    procedure SetupTitleBar(AForm: TCustomForm; ATitleBar: TTitleBarPanel;
      InsertRootPanel: Boolean = False);
    function MessageDlg(const Msg: string; DlgType: TMsgDlgType;
      Buttons: TMsgDlgButtons; HelpCtx: Longint): Integer; overload;
    function MessageDlg(const Msg: string; DlgType: TMsgDlgType;
      Buttons: TMsgDlgButtons; HelpCtx: Longint;
      DefaultButton: TMsgDlgBtn): Integer; overload;
    function InputBox(const ACaption, APrompt, ADefault: string): string;
    function InputQuery(const ACaption: string; const APrompts: array of string;
      var AValues: array of string;
      const CloseQueryFunc: TInputCloseQueryFunc = nil): Boolean; overload;
    function InputQuery(const ACaption: string; const APrompts: array of string;
      var AValues: array of string;
      const CloseQueryEvent: TInputCloseQueryEvent;
      Context: TObject = nil): Boolean; overload;
    function InputQuery(const ACaption, APrompt: string;
      var Value: string): Boolean; overload;
    procedure ShowMessage(const Msg: string);
{$IFEND}
    { IOTAModuleServices70 }
    function AddFileSystem(FileSystem: IOTAFileSystem): Integer;
    function CloseAll: Boolean;
    function CreateModule(const Creator: IOTACreator): IOTAModule;
    function CurrentModule: IOTAModule;
    function FindFileSystem(const Name: string): IOTAFileSystem;
    function FindFormModule(const FormName: string): IOTAModule;
    function FindModule(const FileName: string): IOTAModule;
    function GetModuleCount: Integer;
    function GetModule(Index: Integer): IOTAModule;
    procedure GetNewModuleAndClassName(const Prefix: string; var UnitIdent,
      ClassName, FileName: string);
    function NewModule: Boolean;
    procedure RemoveFileSystem(Index: Integer);
    function SaveAll: Boolean;
    { IOTAModuleServices }
    function GetMainProjectGroup: IOTAProjectGroup;
    function OpenModule(const FileName: string): IOTAModule;
    function GetActiveProject: IOTAProject;
    { IOTAServices50 }
    function AddNotifier(const Notifier: IOTAIDENotifier): Integer;
    procedure RemoveNotifier(Index: Integer);
    function GetBaseRegistryKey: string;
    function GetProductIdentifier: string;
    function GetParentHandle: HWND;
    function GetEnvironmentOptions: IOTAEnvironmentOptions;
    { IOTAServices60 }
    function GetActiveDesignerType: string;
    { IOTAServices70 }
    function GetRootDirectory: string;
    function GetBinDirectory: string;
    function GetTemplateDirectory: string;
    { IOTAServices100 }
    function GetApplicationDataDirectory: string;
    { IOTAServices110 }
    function GetLocalApplicationDataDirectory: string;
    { IOTAServices140 }
    function GetIDEPreferredUILanguages: string;
    { IOTAServices160 }
    function GetStartupDirectory: string;
    function IsProject(const FileName: string): Boolean;
    function IsProjectGroup(const FileName: string): Boolean;
    function SaveStream(const Stream: IStream): string;
    { IOTAServices }
    function ExpandRootMacro(const S: string): string;
    { INTAServices40 }
    function AddMasked(Image: TBitmap; MaskColor: TColor): Integer; overload;
    function GetActionList: TCustomActionList;
    function GetImageList: TCustomImageList;
    function GetMainMenu: TMainMenu;
    function GetToolBar(const ToolBarName: string): TToolBar;
    { INTAServices70 }
    function AddMasked(Image: TBitmap; MaskColor: TColor;
      const Ident: string): Integer; overload;
    { INTAServices90 }
    function AddImages(AImages: TCustomImageList): Integer; overload;
    procedure AddActionMenu(const Name: string; NewAction: TCustomAction;
      NewItem: TMenuItem; InsertAfter: Boolean = True;
      InsertAsChild: Boolean = False);
    function NewToolbar(const Name, Caption: string;
      const ReferenceToolBar: string = '';
      InsertBefore: Boolean = False): TToolbar;
    function AddToolButton(const ToolBarName, ButtonName: string;
      AAction: TCustomAction; const IsDivider: Boolean = False;
      const ReferenceButton: string = '';
      InsertBefore: Boolean = False): TControl;
    procedure UpdateMenuAccelerators(Menu: TMenu);
    procedure ReadToolbar(AOwner: TComponent; AParent: TWinControl;
      const AName: string; var AToolBar: TWinControl;
      const ASubKey: string = ''; AStream: TStream = nil;
      DefaultToolbar: Boolean = False);
    procedure WriteToolbar(AToolbar: TWinControl; const AName: string = '';
      const ASubkey: string = ''; AStream: TStream = nil);
    function CustomizeToolbar(const AToolbars: array of TWinControl;
      const ANotifier: INTACustomizeToolbarNotifier;
      AButtonOwner: TComponent = nil; AActionList: TCustomActionList = nil;
      AButtonsOnly: Boolean = True): TComponent;
    procedure CloseCustomize;
    procedure ToolbarModified(AToolbar: TWinControl);
    function RegisterToolbarNotifier(const ANotifier: IOTANotifier): Integer;
    procedure UnregisterToolbarNotifier(Index: Integer);
    procedure MenuBeginUpdate;
    procedure MenuEndUpdate;
    { INTAServices120 }
    function AddImages(AImages: TCustomImageList;
      const Ident: string): Integer; overload;
    { INTAServices270 }
    procedure RegisterDockableForm(
      const CustomDockableForm: INTACustomDockableForm);
    procedure UnregisterDockableForm(
      const CustomDockableForm: INTACustomDockableForm);
    function CreateDockableForm(
      const CustomDockableForm: INTACustomDockableForm): TCustomForm;
    { INTAServices280 }
    function AddImage(const AImageName: string;
      const AImage: TGraphicArray): Integer;
{$IF CompilerVersion >= 36.0}
    { INTAServices290 }
    function CreateDockableFormEx(
      const CustomDockableForm: INTACustomDockableForm;
      Titlebar: Boolean): TCustomForm;
{$IFEND}
    { IOTAAboutBoxServices120 }
    function AddPluginInfo(const ATitle, ADescription: string;
      AImage: HBITMAP; AIsUnRegistered: Boolean = False;
      const ALicenseStatus: string = '';
      const ASKUName: string = ''): Integer; overload;
    function AddProductInfo(const ADialogTitle, ACopyright, ATitle,
      ADescription: string; AAboutImage, AProductImage: HBITMAP;
      AIsUnRegistered: Boolean = False; const ALicenseStatus: string = '';
      const ASKUName: string = ''): Integer; overload;
    procedure RemovePluginInfo(Index: Integer);
    procedure RemoveProductInfo(Index: Integer);
    { IOTAAboutBoxServices270 }
    function AddPluginInfo(const ATitle, ADescription: string;
      AImage: HBITMAP; AIsUnRegistered: Boolean;
      const ALicenseStatus: string; const ASKUName: string;
      AAlphaFormat: TOTAAlphaFormat): Integer; overload;
    function AddProductInfo(const ADialogTitle, ACopyright, ATitle,
      ADescription: string; AAboutImage, AProductImage: HBITMAP;
      AIsUnRegistered: Boolean; const ALicenseStatus: string;
      const ASKUName: string; AAboutImageAlphaFormat: TOTAAlphaFormat;
      AProductImageAlphaFormat: TOTAAlphaFormat): Integer; overload;
    { IOTAAboutBoxServices280 }
    function AddPluginInfo(const ATitle, ADescription: string;
      const AImage: TGraphicArray; AIsUnRegistered: Boolean = False;
      const ALicenseStatus: string = '';
      const ASKUName: string = ''): Integer; overload;
    function AddProductInfo(const ADialogTitle, ACopyright, ATitle,
      ADescription: string; AAboutImage: HBITMAP;
      const AProductImage: TGraphicArray; AIsUnRegistered: Boolean = False;
      const ALicenseStatus: string = ''; const ASKUName: string = '';
      AAboutImageAlphaFormat: TOTAAlphaFormat = otaafIgnored)
      : Integer; overload;
  end;

// Refusal state: the report callback, and the recorded refusals as the keys
// of a sorted list that drops duplicates.
var
  RefusalHandler: TServiceRefused = nil;
  RefusedServices: TStringList = nil;

type
  // One entry of the GUID-to-name table the refusal report is written from.
  TKnownService = record
    Guid: string;
    Name: string;
  end;


  // One main-menu sub-item packages anchor their entries to: the component
  // names of the parent menu and of the item, and the item's caption.
  TIdeMenuAnchor = record
    Menu: string;
    Item: string;
    Caption: string;
  end;

const
  // Message returned in the ErrorMessage parameter of the remote profile
  // operations that report one; displayed unchanged by callers that show it.
  RemoteRefusal = 'this designer has no remote profile support';

  // GUID-to-name table for the refusal report; a GUID that is not listed is
  // still reported, without a name. All but IOTAProjectManager are served,
  // and the entries remain because a package can ask for a version of one of
  // these interfaces that this stub does not implement.
  KnownServices: array [0..8] of TKnownService = (
    (Guid: '{29E893DB-DD9A-4CEA-B2EE-57532E01A9B9}';
      Name: 'IOTAMessageServices'),
    (Guid: '{88EAA6AC-B8C0-42F7-9C00-E5D31B815998}';
      Name: 'INTAEnvironmentOptionsServices'),
    (Guid: '{F8CAF8D5-D263-11D2-ABD8-00C04FB16FB3}';
      Name: 'IOTAKeyboardServices'),
    (Guid: '{587EAFAE-B8B2-4007-A233-BE09052BB67A}';
      Name: 'IOTADebuggerServices'),
    (Guid: '{BC86D71D-8A31-4921-A27F-5D32DC3A9A4F}';
      Name: 'IOTARemoteProfileServices160'),
    (Guid: '{51DC9F09-3DF5-4FB2-8DC1-A9BA137FA6BD}';
      Name: 'IOTADataExplorerService'),
    (Guid: '{66C2DF99-87FD-41D9-9894-21D14D256F7A}';
      Name: 'IVisualizationService'),
    (Guid: '{B142EF92-0A91-4614-A72A-CE46F9C88B7B}';
      Name: 'IOTAProjectManager'),
    (Guid: '{68C486EF-C079-4D40-B462-2C0DD21FE342}';
      Name: 'IOTACompileServices'));

  // Component names of the IDE main menu's top-level items, which is how a
  // package addresses them.
  IdeMenuNames: array [0..9] of string = (
    'FileMenu', 'EditMenu', 'SearchMenu', 'ViewMenu', 'ProjectMenu',
    'RunMenu', 'ComponentMenu', 'ToolsMenu', 'WindowMenu', 'HelpMenu');

  // Sub-items packages insert their own entries next to. A package looks one
  // up by name and inserts at its index in the parent; a name that is missing
  // leaves that index at -1, where TMenuItem.Insert raises rather than
  // appending.
  IdeMenuAnchors: array [0..1] of TIdeMenuAnchor = (
    (Menu: 'ProjectMenu'; Item: 'ProjectOptionsItem'; Caption: 'Options'),
    (Menu: 'ToolsMenu'; Item: 'ToolsToolsItem'; Caption: 'Tools'));


function ServiceDisplayName(const AIID: TGUID): string;
var
  I: Integer;
begin
  Result := GUIDToString(AIID);
  for I := Low(KnownServices) to High(KnownServices) do
    if SameText(KnownServices[I].Guid, Result) then
      Exit(KnownServices[I].Name + ' ' + Result);
end;

procedure NoteRefusal(const AIID: TGUID; const AHow: string);
var
  Service, Key: string;
begin
  if RefusedServices = nil then
    Exit;
  Service := ServiceDisplayName(AIID);
  Key := AHow + ' ' + Service;
  if RefusedServices.IndexOf(Key) >= 0 then
    Exit;
  RefusedServices.Add(Key);
  if Assigned(RefusalHandler) then
    RefusalHandler(Service, AHow);
end;

function RefusedIdeServices: TArray<string>;
var
  I: Integer;
begin
  Result := [];
  if RefusedServices = nil then
    Exit;
  SetLength(Result, RefusedServices.Count);
  for I := 0 to RefusedServices.Count - 1 do
    Result[I] := RefusedServices[I];
end;

procedure ResetIdeServiceRefusals;
begin
  if RefusedServices <> nil then
    RefusedServices.Clear;
end;

procedure InstallIdeServicesStub(AOnRefused: TServiceRefused = nil);
begin
  if BorlandIDEServices <> nil then
    Exit;
  RefusalHandler := AOnRefused;
  RefusedServices := TStringList.Create;
  RefusedServices.Sorted := True;
  RefusedServices.Duplicates := dupIgnore;
  BorlandIDEServices := TStubIdeServices.Create;
  if SplashScreenServices = nil then
    SplashScreenServices := TStubSplashScreen.Create;
end;

{ TStubMessageGroup }

constructor TStubMessageGroup.Create(const AName: string);
begin
  inherited Create;
  FName := AName;
  FCanClose := True;
end;

function TStubMessageGroup.GetGroupName: string;
begin
  Result := FName;
end;

function TStubMessageGroup.GetAutoScroll: Boolean;
begin
  Result := FAutoScroll;
end;

procedure TStubMessageGroup.SetAutoScroll(Value: Boolean);
begin
  FAutoScroll := Value;
end;

function TStubMessageGroup.GetCanClose: Boolean;
begin
  Result := FCanClose;
end;

procedure TStubMessageGroup.SetCanClose(Value: Boolean);
begin
  FCanClose := Value;
end;

{ TStubMessageServices }

constructor TStubMessageServices.Create;
begin
  inherited Create;
  FGroup := TStubMessageGroup.Create('Build');
end;

procedure TStubMessageServices.AddCustomMessage(
  const CustomMsg: IOTACustomMessage);
begin
end;

procedure TStubMessageServices.AddCustomMessage(
  const CustomMsg: IOTACustomMessage;
  const MessageGroupIntf: IOTAMessageGroup);
begin
end;

function TStubMessageServices.AddCustomMessage(
  const CustomMsg: IOTACustomMessage; Parent: Pointer): Pointer;
begin
  Result := nil;
end;

function TStubMessageServices.AddCustomMessagePtr(
  const CustomMsg: IOTACustomMessage;
  const MessageGroupIntf: IOTAMessageGroup): Pointer;
begin
  Result := nil;
end;

procedure TStubMessageServices.AddTitleMessage(const MessageStr: string);
begin
end;

procedure TStubMessageServices.AddTitleMessage(const MessageStr: string;
  const MessageGroupIntf: IOTAMessageGroup);
begin
end;

procedure TStubMessageServices.AddToolMessage(const FileName, MessageStr,
  PrefixStr: string; LineNumber, ColumnNumber: Integer);
begin
end;

procedure TStubMessageServices.AddToolMessage(const FileName, MessageStr,
  PrefixStr: string; LineNumber, ColumnNumber: Integer; Parent: Pointer;
  out LineRef: Pointer);
begin
  LineRef := nil;
end;

procedure TStubMessageServices.AddToolMessage(const FileName, MessageStr,
  PrefixStr: string; LineNumber, ColumnNumber: Integer; Parent: Pointer;
  out LineRef: Pointer; const MessageGroupIntf: IOTAMessageGroup);
begin
  LineRef := nil;
end;

procedure TStubMessageServices.AddCompilerMessage(const FileName, MessageStr,
  ToolName: string; Kind: TOTAMessageKind; LineNumber, ColumnNumber: Integer;
  Parent: Pointer; out LineRef: Pointer);
begin
  LineRef := nil;
end;

procedure TStubMessageServices.AddCompilerMessage(const FileName, MessageStr,
  ToolName: string; Kind: TOTAMessageKind; LineNumber, ColumnNumber: Integer;
  Parent: Pointer; out LineRef: Pointer; HelpKeyword: string);
begin
  LineRef := nil;
end;

procedure TStubMessageServices.AddCompilerMessage(const FileName, MessageStr,
  ToolName: string; Kind: TOTAMessageKind; LineNumber, ColumnNumber: Integer;
  Parent: Pointer; out LineRef: Pointer; HelpContext: Integer);
begin
  LineRef := nil;
end;

procedure TStubMessageServices.AddWideCompilerMessage(const FileName,
  MessageStr, ToolName: WideString; Kind: TOTAMessageKind;
  LineNumber, ColumnNumber: Integer; Parent: Pointer; out LineRef: Pointer);
begin
  LineRef := nil;
end;

procedure TStubMessageServices.AddWideCompilerMessage(const FileName,
  MessageStr, ToolName: WideString; Kind: TOTAMessageKind;
  LineNumber, ColumnNumber: Integer; Parent: Pointer; out LineRef: Pointer;
  HelpKeyword: WideString);
begin
  LineRef := nil;
end;

procedure TStubMessageServices.AddWideCompilerMessage(const FileName,
  MessageStr, ToolName: WideString; Kind: TOTAMessageKind;
  LineNumber, ColumnNumber: Integer; Parent: Pointer; out LineRef: Pointer;
  HelpContext: Integer);
begin
  LineRef := nil;
end;

procedure TStubMessageServices.AddWideTitleMessage(
  const MessageStr: WideString);
begin
end;

procedure TStubMessageServices.AddWideTitleMessage(
  const MessageStr: WideString; const MessageGroupIntf: IOTAMessageGroup);
begin
end;

procedure TStubMessageServices.AddWideToolMessage(const FileName, MessageStr,
  PrefixStr: WideString; LineNumber, ColumnNumber: Integer);
begin
end;

procedure TStubMessageServices.AddWideToolMessage(const FileName, MessageStr,
  PrefixStr: WideString; LineNumber, ColumnNumber: Integer; Parent: Pointer;
  out LineRef: Pointer);
begin
  LineRef := nil;
end;

procedure TStubMessageServices.AddWideToolMessage(const FileName, MessageStr,
  PrefixStr: WideString; LineNumber, ColumnNumber: Integer; Parent: Pointer;
  out LineRef: Pointer; const MessageGroupIntf: IOTAMessageGroup);
begin
  LineRef := nil;
end;

function TStubMessageServices.AddNotifier(
  const ANotifier: IOTAMessageNotifier): Integer;
begin
  Result := 0;
end;

procedure TStubMessageServices.RemoveNotifier(Index: Integer);
begin
end;

function TStubMessageServices.AddMessageGroup(
  const GroupName: string): IOTAMessageGroup;
begin
  Result := FGroup;
end;

function TStubMessageServices.AddWideMessageGroup(
  const GroupName: WideString): IOTAMessageGroup;
begin
  Result := FGroup;
end;

function TStubMessageServices.GetGroup(
  const GroupName: string): IOTAMessageGroup;
begin
  Result := FGroup;
end;

function TStubMessageServices.GetWideGroup(
  const GroupName: WideString): IOTAMessageGroup;
begin
  Result := FGroup;
end;

function TStubMessageServices.GetMessageGroupCount: Integer;
begin
  Result := 0;
end;

function TStubMessageServices.GetMessageGroup(
  Index: Integer): IOTAMessageGroup;
begin
  Result := nil;
end;

procedure TStubMessageServices.ClearAllMessages;
begin
end;

procedure TStubMessageServices.ClearCompilerMessages;
begin
end;

procedure TStubMessageServices.ClearSearchMessages;
begin
end;

procedure TStubMessageServices.ClearToolMessages;
begin
end;

procedure TStubMessageServices.ClearToolMessages(
  const MessageGroupIntf: IOTAMessageGroup);
begin
end;

procedure TStubMessageServices.ClearMessageGroup(
  const MessageGroupIntf: IOTAMessageGroup);
begin
end;

procedure TStubMessageServices.RemoveMessageGroup(
  const MessageGroupIntf: IOTAMessageGroup);
begin
end;

procedure TStubMessageServices.ShowMessageView(
  const MessageGroupIntf: IOTAMessageGroup);
begin
end;

procedure TStubMessageServices.NextMessage(GoForward: Boolean);
begin
end;

procedure TStubMessageServices.NextErrorMessage(GoForward, ErrorsOnly: Boolean);
begin
end;

{ TStubKeyboardServices }

function TStubKeyboardServices.AddKeyboardBinding(
  const KeyBinding: IOTAKeyboardBinding): Integer;
begin
  Result := 0;
end;

procedure TStubKeyboardServices.RemoveKeyboardBinding(Index: Integer);
begin
end;

function TStubKeyboardServices.GetCurrentPlayback: IOTARecord;
begin
  Result := nil;
end;

function TStubKeyboardServices.GetCurrentRecord: IOTARecord;
begin
  Result := nil;
end;

function TStubKeyboardServices.GetEditorServices: IOTAEditorServices;
begin
  Result := nil;
end;

function TStubKeyboardServices.GetKeysProcessed: LongWord;
begin
  Result := 0;
end;

function TStubKeyboardServices.NewRecordObject(
  out ARecord: IOTARecord): Boolean;
begin
  ARecord := nil;
  Result := False;
end;

procedure TStubKeyboardServices.PausePlayback;
begin
end;

procedure TStubKeyboardServices.PauseRecord;
begin
end;

procedure TStubKeyboardServices.ResumePlayback;
begin
end;

procedure TStubKeyboardServices.ResumeRecord;
begin
end;

procedure TStubKeyboardServices.PopKeyboard(const Keyboard: string);
begin
end;

function TStubKeyboardServices.PushKeyboard(const Keyboard: string): string;
begin
  Result := '';
end;

procedure TStubKeyboardServices.RestartKeyboardServices;
begin
end;

procedure TStubKeyboardServices.SetPlaybackObject(const ARecord: IOTARecord);
begin
end;

procedure TStubKeyboardServices.SetRecordObject(const ARecord: IOTARecord);
begin
end;

function TStubKeyboardServices.LookupKeyBinding(const Keys: array of TShortCut;
  out BindingRec: TKeyBindingRec; const KeyBoard: string): Boolean;
begin
  BindingRec := Default (TKeyBindingRec);
  Result := False;
end;

function TStubKeyboardServices.GetNextBindingRec(
  var BindingRec: TKeyBindingRec): Boolean;
begin
  Result := False;
end;

function TStubKeyboardServices.CallKeyBindingProc(
  const BindingRec: TKeyBindingRec): TKeyBindingResult;
begin
  Result := krUnhandled;
end;

{ TStubCompileServices }

function TStubCompileServices.AddNotifier(
  Notifier: IOTACompileNotifier): Integer;
begin
  Result := 0;
end;

procedure TStubCompileServices.RemoveNotifier(Index: Integer);
begin
end;

function TStubCompileServices.CancelBackgroundCompile(
  Prompt: Boolean): Boolean;
begin
  Result := True;
end;

function TStubCompileServices.CompileProjects(Projects: array of IOTAProject;
  CompileMode: TOTACompileMode; Wait, ClearMessages: Boolean): TOTACompileResult;
begin
  Result := crOTAFailed;
end;

procedure TStubCompileServices.DisableBackgroundCompilation;
begin
end;

procedure TStubCompileServices.EnableBackgroundCompilation;
begin
end;

function TStubCompileServices.IsBackgroundCompileActive: Boolean;
begin
  Result := False;
end;

{ TStubDebuggerServices }

function TStubDebuggerServices.AddNotifier(
  const Notifier: IOTADebuggerNotifier): Integer;
begin
  Result := 0;
end;

procedure TStubDebuggerServices.RemoveNotifier(Index: Integer);
begin
end;

procedure TStubDebuggerServices.AttachProcess(Pid: Integer;
  const RemoteHost: string);
begin
end;

procedure TStubDebuggerServices.AttachProcess(Pid: Integer;
  PauseAfterAttach, DetachOnReset: Boolean; const RemoteHost: string);
begin
end;

procedure TStubDebuggerServices.CreateProcess(const ExeName, Args: string;
  const RemoteHost: string);
begin
end;

procedure TStubDebuggerServices.EnumerateRunningProcesses(
  Callback: TEnumerateProcessesCallback; Param: Pointer;
  const HostName: string);
begin
end;

function TStubDebuggerServices.GetAddressBkptCount: Integer;
begin
  Result := 0;
end;

function TStubDebuggerServices.GetAddressBkpt(
  Index: Integer): IOTAAddressBreakpoint;
begin
  Result := nil;
end;

function TStubDebuggerServices.GetSourceBkptCount: Integer;
begin
  Result := 0;
end;

function TStubDebuggerServices.GetSourceBkpt(
  Index: Integer): IOTASourceBreakpoint;
begin
  Result := nil;
end;

function TStubDebuggerServices.GetModuleBkptCount: Integer;
begin
  Result := 0;
end;

function TStubDebuggerServices.GetModuleBkpt(Index: Integer): string;
begin
  Result := '';
end;

function TStubDebuggerServices.GetCurrentProcess: IOTAProcess;
begin
  Result := nil;
end;

procedure TStubDebuggerServices.SetCurrentProcess(const Process: IOTAProcess);
begin
end;

function TStubDebuggerServices.GetProcessCount: Integer;
begin
  Result := 0;
end;

function TStubDebuggerServices.GetProcess(Index: Integer): IOTAProcess;
begin
  Result := nil;
end;

procedure TStubDebuggerServices.LogString(const LogStr: string);
begin
end;

procedure TStubDebuggerServices.LogString(const LogStr: string;
  LogItemType: TLogItemType);
begin
end;

function TStubDebuggerServices.NewAddressBreakpoint(Address, Length: LongWord;
  AccessType: TOTAAccessType; const AProcess: IOTAProcess): IOTABreakpoint;
begin
  Result := nil;
end;

function TStubDebuggerServices.NewAddressBreakpoint(Address: TOTAAddress;
  Length: LongWord; AccessType: TOTAAccessType;
  const AProcess: IOTAProcess): IOTABreakpoint;
begin
  Result := nil;
end;

function TStubDebuggerServices.NewModuleBreakpoint(const ModuleName: string;
  const AProcess: IOTAProcess): IOTABreakpoint;
begin
  Result := nil;
end;

procedure TStubDebuggerServices.NewModuleBreakpoint(const ModuleName: string);
begin
end;

function TStubDebuggerServices.NewSourceBreakpoint(const FileName: string;
  LineNumber: Integer; const AProcess: IOTAProcess): IOTABreakpoint;
begin
  Result := nil;
end;

procedure TStubDebuggerServices.RemoveModuleBreakpoint(
  const ModuleName: string);
begin
end;

procedure TStubDebuggerServices.RemoveBreakpoint(
  const Breakpoint: IOTABreakpoint);
begin
end;

procedure TStubDebuggerServices.RegisterDebugVisualizer(
  const Visualizer: IOTADebuggerVisualizer);
begin
end;

procedure TStubDebuggerServices.UnregisterDebugVisualizer(
  const Visualizer: IOTADebuggerVisualizer);
begin
end;

procedure TStubDebuggerServices.ProcessDebugEvents;
begin
end;

{ TStubRemoteProfileServices }

function TStubRemoteProfileServices.GetProfileCount(
  const PlatformName: string): Integer;
begin
  Result := 0;
end;

function TStubRemoteProfileServices.GetProfile(const PlatformName: string;
  Index: Integer): IOTARemoteProfile;
begin
  Result := nil;
end;

function TStubRemoteProfileServices.GetProfile(
  const ProfileName: string): IOTARemoteProfile;
begin
  Result := nil;
end;

function TStubRemoteProfileServices.AddProfile(const Name: string;
  const PlatformName: string; const HostName: string; PortNumber: Integer;
  const Credential: TOTARemoteProfileCredential; const SystemRoot: string;
  const Paths: TOTARemoteProfilePathArray;
  IsDefault: Boolean): IOTARemoteProfile;
begin
  Result := nil;
end;

procedure TStubRemoteProfileServices.EditProfile(const Name: string);
begin
end;

procedure TStubRemoteProfileServices.RemoveProfile(
  const Profile: IOTARemoteProfile);
begin
end;

function TStubRemoteProfileServices.GetDefaultForPlatform(
  const PlatformName: string): IOTARemoteProfile;
begin
  Result := nil;
end;

procedure TStubRemoteProfileServices.SetAsDefaultForPlatform(
  const Profile: IOTARemoteProfile);
begin
end;

procedure TStubRemoteProfileServices.BeginOperation(
  const Profile: IOTARemoteProfile);
begin
end;

procedure TStubRemoteProfileServices.EndOperation(
  const Profile: IOTARemoteProfile);
begin
end;

function TStubRemoteProfileServices.TestConnection(
  const Profile: IOTARemoteProfile; out ErrorMessage: string;
  ConnectionCallBack: IOTAConnectionCallback): Boolean;
begin
  ErrorMessage := RemoteRefusal;
  Result := False;
end;

function TStubRemoteProfileServices.GetProfileFiles(
  const Profile: IOTARemoteProfile; OverwriteControl: TOTAFileOverwriteControl;
  ConnectionCallback: IOTAConnectionCallback;
  ProgressCallback: TOTAGetProfileFilesProgressCallback): Boolean;
begin
  Result := False;
end;

function TStubRemoteProfileServices.GetProfileFilesWithProgress(
  const Profile: IOTARemoteProfile): Boolean;
begin
  Result := False;
end;

function TStubRemoteProfileServices.GetFileInfo(
  const Profile: IOTARemoteProfile; const Path: string;
  out LastWriteTime: TDateTime; out Size: Int64): Boolean;
begin
  LastWriteTime := 0;
  Size := 0;
  Result := False;
end;

function TStubRemoteProfileServices.GetRemoteFileInfo(
  const Profile: IOTARemoteProfile; const Path: string;
  out LastWriteTime: TDateTime; out Size: Int64;
  ConnectionCallBack: IOTAConnectionCallback): Boolean;
begin
  LastWriteTime := 0;
  Size := 0;
  Result := False;
end;

function TStubRemoteProfileServices.PutFiles(const Profile: IOTARemoteProfile;
  const Files: TOTAPutFileArray; OverwriteControl: TOTAFileOverwriteControl;
  ConnectionCallback: IOTAConnectionCallback;
  ProgressCallback: TOTAGetProfileFilesProgressCallback): Boolean;
begin
  Result := False;
end;

function TStubRemoteProfileServices.PutFilesWithProgress(
  const Profile: IOTARemoteProfile; const Files: TOTAPutFileArray): Boolean;
begin
  Result := False;
end;

function TStubRemoteProfileServices.RemoveRemoteFiles(
  const Profile: IOTARemoteProfile; const Files: TStringDynArray;
  ConnectionCallback: IOTAConnectionCallback;
  ProgressCallback: TOTAGetProfileFilesProgressCallback): Boolean;
begin
  Result := False;
end;

function TStubRemoteProfileServices.RemoveRemoteFilesWithProgress(
  const Profile: IOTARemoteProfile; const Files: TStringDynArray): Boolean;
begin
  Result := False;
end;

function TStubRemoteProfileServices.BrowseRemoteFileSystem(
  const Profile: IOTARemoteProfile; const Path: string; Attributes: Integer;
  IncludeTimeStamp: Boolean;
  ConnectionCallBack: IOTAConnectionCallback): TOTARemoteFileInfoArray;
begin
  Result := nil;
end;

function TStubRemoteProfileServices.RemoteDirectoryExists(
  const Profile: IOTARemoteProfile; const Directory: string;
  ConnectionCallBack: IOTAConnectionCallback): Boolean;
begin
  Result := False;
end;

function TStubRemoteProfileServices.GetRemoteBaseDirectory(
  const Profile: IOTARemoteProfile;
  ConnectionCallBack: IOTAConnectionCallback): string;
begin
  Result := '';
end;

function TStubRemoteProfileServices.ExpandPath(
  const Profile: IOTARemoteProfile; const Path: string;
  ConnectionCallBack: IOTAConnectionCallback): string;
begin
  Result := Path;
end;

function TStubRemoteProfileServices.ExpandAllPaths(
  const Profile: IOTARemoteProfile; const Paths: string;
  ConnectionCallBack: IOTAConnectionCallback): string;
begin
  Result := Paths;
end;

function TStubRemoteProfileServices.CreateSymLink(
  const Profile: IOTARemoteProfile; const LinkPath: string;
  const TargetPath: string;
  ConnectionCallBack: IOTAConnectionCallback): Boolean;
begin
  Result := False;
end;

function TStubRemoteProfileServices.Run(const Profile: IOTARemoteProfile;
  const PathUnderScratchDir: string; const ExeName: string;
  const Params: string; const Launcher: string; const WorkingDir: string;
  const EnvList: TStrings; const UserName: string; out ErrorMessage: string;
  ConnectionCallback: IOTAConnectionCallback): Boolean;
begin
  ErrorMessage := RemoteRefusal;
  Result := False;
end;

function TStubRemoteProfileServices.StartRemoteDebugger(
  const Profile: IOTARemoteProfile; const UserName: string;
  const ProcessType: TOTAProcessType; out DebuggerId: Integer;
  out DebuggerPort: Integer; out ErrorMessage: string;
  ConnectionCallback: IOTAConnectionCallback): Boolean;
begin
  DebuggerId := 0;
  DebuggerPort := 0;
  ErrorMessage := RemoteRefusal;
  Result := False;
end;

function TStubRemoteProfileServices.GetEnvironmentVariables(
  const Profile: IOTARemoteProfile;
  ConnectionCallBack: IOTAConnectionCallback): TStringDynArray;
begin
  Result := nil;
end;

function TStubRemoteProfileServices.ExecuteNewProfileWizard(
  const InitialPlatform: string;
  RestrictToInitialPlatform: Boolean): IOTARemoteProfile;
begin
  Result := nil;
end;

function TStubRemoteProfileServices.ShowSelectProfileDialog(
  const PlatformName: string): IOTARemoteProfile;
begin
  Result := nil;
end;

function TStubRemoteProfileServices.CanDeployProject(
  const Project: IOTAProject; const Profile: IOTARemoteProfile): Boolean;
begin
  Result := False;
end;

function TStubRemoteProfileServices.DeployProject(const Project: IOTAProject;
  const Profile: IOTARemoteProfile; Configuration: string;
  PlatformName: string; ClearMessages: Boolean): Boolean;
begin
  Result := False;
end;

function TStubRemoteProfileServices.EnsureProfileForCompile(
  const Project: IOTAProject; const PlatformName: string;
  var ErrorMessage: string): TOTARemoteProfileStatus;
begin
  ErrorMessage := RemoteRefusal;
  Result := orpsNotAssigned;
end;

function TStubRemoteProfileServices.EnsureProfileForRun(
  const Project: IOTAProject;
  var ErrorMessage: string): TOTARemoteProfileStatus;
begin
  ErrorMessage := RemoteRefusal;
  Result := orpsNotAssigned;
end;

function TStubRemoteProfileServices.AddNotifier(
  const Notifier: IOTARemoteProfileNotifier): Integer;
begin
  Result := 0;
end;

procedure TStubRemoteProfileServices.RemoveNotifier(Index: Integer);
begin
end;

{ TStubDataExplorerService }

procedure TStubDataExplorerService.DeleteGroup(const AGroupNum: Integer);
begin
end;

procedure TStubDataExplorerService.RegisterRootNode(
  ARootItem: IOTADataExplorerItem);
begin
end;

procedure TStubDataExplorerService.UnregisterRootNode(
  ARootItem: IOTADataExplorerItem);
begin
end;

function TStubDataExplorerService.GetRootNodes: TArray<IOTADataExplorerItem>;
begin
  Result := nil;
end;

procedure TStubDataExplorerService.RefreshNode(AIdentity: TObject;
  AItem: IOTADataExplorerItem; AChildren: Boolean);
begin
end;

procedure TStubDataExplorerService.DeleteNode(AIdentity: TObject);
begin
end;

procedure TStubDataExplorerService.SelectNewChildNode(
  AParentIdentity: TObject; AItem: IOTADataExplorerItem; const AName: string);
begin
end;

procedure TStubDataExplorerService.RefreshChildNode(AParentIdentity: TObject;
  AItem: IOTADataExplorerItem; const AName: string; AChildren: Boolean);
begin
end;

function TStubDataExplorerService.AddImages(
  const Images: TCustomImageList): Integer;
begin
  Result := 0;
end;

procedure TStubDataExplorerService.AddTab(const ATabCaption: string;
  AFrameClass: TFrameClass; AFrameCreatedProc: TProc<TFrame>);
begin
end;

procedure TStubDataExplorerService.RenameTab(const AOldCaption,
  ANewCaption: string);
begin
end;

procedure TStubDataExplorerService.RemoveTab(const ATabCaption: string);
begin
end;

function TStubDataExplorerService.HasTab(const ATabCaption: string): Boolean;
begin
  Result := False;
end;

procedure TStubDataExplorerService.ActivateTab(const ATabCaption: string);
begin
end;

procedure TStubDataExplorerService.ObjInspectorSelect(const AObj: TPersistent);
begin
end;

{ TStubVisualizationService }

procedure TStubVisualizationService.DeleteGroup(const AGroupNum: Integer);
begin
end;

procedure TStubVisualizationService.RegisterDrawingControl(
  const ADrawing: IInterface);
begin
end;

procedure TStubVisualizationService.UnregisterDrawingControl(
  const ADrawing: IInterface);
begin
end;

function TStubVisualizationService.GetDrawingControl: IVGDrawing;
begin
  Result := nil;
end;

procedure TStubVisualizationService.FocusDrawing;
begin
end;

procedure TStubVisualizationService.RegisterGraphHandler(
  const AGraphHandler: IVGHandler);
begin
end;

procedure TStubVisualizationService.UnregisterGraphHandler(
  const AGraphHandler: IVGHandler);
begin
end;

function TStubVisualizationService.ActiveGraph: IVGHandler;
begin
  Result := nil;
end;

procedure TStubVisualizationService.ActivateGraph(
  const AGraphHandlerId: string);
begin
end;

procedure TStubVisualizationService.ClearActiveGraph;
begin
end;

function TStubVisualizationService.GetGraphIds: TArray<string>;
begin
  Result := nil;
end;

procedure TStubVisualizationService.ActivateModule(const AModule: IVGModule);
begin
end;

function TStubVisualizationService.ActiveModel: IVGModel;
begin
  Result := nil;
end;

function TStubVisualizationService.VGDirToLBDir(
  const ALinkDir: TVGDirection): string;
begin
  Result := '';
end;

function TStubVisualizationService.VGElementKindToLBPropertyValue(
  const AElementKind: TVGElementKind): string;
begin
  Result := '';
end;

function TStubVisualizationService.GetActive: Boolean;
begin
  Result := False;
end;

procedure TStubVisualizationService.SetActive(AValue: Boolean);
begin
end;

{ TStubIdeServices }

procedure TStubIdeServices.RegisterAddInOptions(
  const AddInOptions: INTAAddInOptions);
begin
end;

procedure TStubIdeServices.UnregisterAddInOptions(
  const AddInOptions: INTAAddInOptions);
begin
end;

constructor TStubIdeServices.Create;
begin
  inherited Create;
  FPalette := TStubPaletteServices.Create;
  FProjectStorage := TStubProjectFileStorage.Create;
  FGalleryCategories := TStubGalleryCategories.Create;
  FMessages := TStubMessageServices.Create;
  FKeyboard := TStubKeyboardServices.Create;
  FCompile := TStubCompileServices.Create;
  FDebugger := TStubDebuggerServices.Create;
  FRemoteProfiles := TStubRemoteProfileServices.Create;
  FDataExplorer := TStubDataExplorerService.Create;
  FVisualization := TStubVisualizationService.Create;
  FIdeUi := TComponent.Create(nil);
  FMainMenu := TMainMenu.Create(FIdeUi);
  BuildIdeMenu;
  FActionList := TActionList.Create(FIdeUi);
  FImageList := TImageList.Create(FIdeUi);
  FToolBars := TStringList.Create;
  FToolBars.CaseSensitive := False;
  FToolBars.Sorted := True;
  FToolBars.Duplicates := dupIgnore;
end;

destructor TStubIdeServices.Destroy;
begin
  FToolBars.Free;
  FIdeUi.Free;
  inherited Destroy;
end;

{ TStubProjectFileStorage }

function TStubProjectFileStorage.AddNotifier(
  const ANotifier: IOTAProjectFileStorageNotifier): Integer;
begin
  Result := 0;
end;

procedure TStubProjectFileStorage.RemoveNotifier(Index: Integer);
begin
end;

function TStubProjectFileStorage.GetNotifierCount: Integer;
begin
  Result := 0;
end;

function TStubProjectFileStorage.GetNotifier(
  Index: Integer): IOTAProjectFileStorageNotifier;
begin
  Result := nil;
end;

function TStubProjectFileStorage.AddNewSection(const ProjectOrGroup: IOTAModule;
  SectionName: string; LocalProjectFile: Boolean): IXMLNode;
begin
  Result := nil;
end;

function TStubProjectFileStorage.GetProjectStorageNode(
  const ProjectOrGroup: IOTAModule; const NodeName: string;
  LocalProjectFile: Boolean): IXMLNode;
begin
  Result := nil;
end;

{ TStubGalleryCategory }

constructor TStubGalleryCategory.Create(const AIDString, ADisplayName: string;
  const AParent: IOTAGalleryCategory);
begin
  inherited Create;
  FIDString := AIDString;
  FDisplayName := ADisplayName;
  FParent := AParent;
end;

function TStubGalleryCategory.GetDisplayName: string;
begin
  Result := FDisplayName;
end;

function TStubGalleryCategory.GetIDString: string;
begin
  Result := FIDString;
end;

function TStubGalleryCategory.GetParent: IOTAGalleryCategory;
begin
  Result := FParent;
end;

{ TStubGalleryCategories }

function TStubGalleryCategories.FindCategory(
  const IDString: string): IOTAGalleryCategory;
var
  Category: IOTAGalleryCategory;
begin
  for Category in FCategories do
    if SameText(Category.IDString, IDString) then
      Exit(Category);
  Result := nil;
end;

function TStubGalleryCategories.AddCategory(const IDString, DisplayName: string;
  IconHandle: Integer): IOTAGalleryCategory;
begin
  Result := AddCategory(nil, IDString, DisplayName, IconHandle);
end;

function TStubGalleryCategories.AddCategory(
  const ParentCategory: IOTAGalleryCategory; const IDString,
  DisplayName: string; IconHandle: Integer): IOTAGalleryCategory;
begin
  Result := TStubGalleryCategory.Create(IDString, DisplayName, ParentCategory);
  FCategories := FCategories + [Result];
end;

procedure TStubGalleryCategories.DeleteCategory(
  const Category: IOTAGalleryCategory);
var
  I: Integer;
begin
  for I := High(FCategories) downto 0 do
    if FCategories[I] = Category then
      Delete(FCategories, I, 1);
end;

procedure TStubSplashScreen.AddPluginBitmap(const ACaption: string;
  ABitmap: HBITMAP; AIsUnRegistered: Boolean; const ALicenseStatus: string;
  const ASKUName: string);
begin
end;

procedure TStubSplashScreen.AddProductBitmap(const ACaption: string;
  ABitmap: HBITMAP; IsUnRegistered: Boolean; const ALicenseStatus: string;
  const ASKUName: string);
begin
end;

procedure TStubSplashScreen.ShowProductSplash(ABitmap: HBITMAP);
begin
end;

procedure TStubSplashScreen.StatusMessage(const StatusMessage: string);
begin
end;

procedure TStubSplashScreen.SetProductIcon(AIcon: HICON);
begin
end;

procedure TStubSplashScreen.AddPluginBitmap(const Caption: string;
  const AImageArray: TGraphicArray; AIsUnRegistered: Boolean;
  const ALicenseStatus: string; const ASKUName: string);
begin
end;

procedure TStubSplashScreen.AddProductBitmap(const Caption: string;
  const AImageArray: TGraphicArray; AIsUnRegistered: Boolean;
  const ALicenseStatus: string; const ASKUName: string);
begin
end;

function TStubIdeServices.QueryInterface(const IID: TGUID; out Obj): HResult;
begin
  Result := inherited QueryInterface(IID, Obj);
  if Result <> S_OK then
    NoteRefusal(IID, 'an interface cast');
end;

// Supports(Self, ...) resolves through TObject.GetInterface, which does not
// reach the QueryInterface above, so these three record their own refusals.
function TStubIdeServices.SupportsService(const Service: TGUID): Boolean;
begin
  Result := Supports(Self, Service);
  if not Result then
    NoteRefusal(Service, 'SupportsService');
end;

function TStubIdeServices.GetService(const Service: TGUID): IInterface;
begin
  if not Supports(Self, Service, Result) then
    NoteRefusal(Service, 'GetService');
end;

function TStubIdeServices.GetService(const Service: TGUID; out Svc): Boolean;
begin
  Result := Supports(Self, Service, Svc);
  if not Result then
    NoteRefusal(Service, 'GetService');
end;

function TStubIdeServices.AddWizard(const AWizard: IOTAWizard): Integer;
begin
  Result := 0;
end;

procedure TStubIdeServices.RemoveWizard(Index: Integer);
begin
end;

function TStubIdeServices.GetPersonalityCount: Integer;
begin
  Result := 0;
end;

function TStubIdeServices.GetPersonality(Index: Integer): string;
begin
  Result := '';
end;

function TStubIdeServices.AddPersonality(const APersonality: string): Integer;
begin
  Result := 0;
end;

procedure TStubIdeServices.RemovePersonality(const APersonality: string);
begin
end;

procedure TStubIdeServices.AddPersonalityTrait(const APersonality: string;
  const ATraitGUID: TGUID; const ATrait: IInterface);
begin
end;

procedure TStubIdeServices.RemovePersonalityTrait(const APersonality: string;
  const ATraitGUID: TGUID);
begin
end;

procedure TStubIdeServices.AddFileType(const APersonality, AFileType: string);
begin
end;

procedure TStubIdeServices.RemoveFileType(const APersonality, AFileType: string);
begin
end;

procedure TStubIdeServices.AddFileExtensions(const APersonality, AFileType,
  AFileExtensions: string);
begin
end;

procedure TStubIdeServices.RemoveFileExtensions(const APersonality, AFileType,
  AFileExtensions: string);
begin
end;

procedure TStubIdeServices.AddFileTrait(const APersonality, AFileType: string;
  const ATraitGUID: TGUID; const ATrait: IInterface);
begin
end;

procedure TStubIdeServices.RemoveFileTrait(const APersonality,
  AFileType: string; const ATraitGUID: TGUID);
begin
end;

function TStubIdeServices.GetCurrentPersonality: string;
begin
  Result := '';
end;

procedure TStubIdeServices.SetCurrentPersonality(const APersonality: string);
begin
end;

function TStubIdeServices.GetFileTrait(const APersonality, AFileName: string;
  const ATraitGUID: TGUID; SearchDefault: Boolean): IInterface;
begin
  Result := nil;
end;

function TStubIdeServices.GetFileTrait(const AFileName: string;
  const ATraitGUID: TGUID; SearchDefault: Boolean): IInterface;
begin
  Result := nil;
end;

function TStubIdeServices.GetFileTrait(const APersonality, AFileName: string;
  const ATraitGUID: TGUID): IInterface;
begin
  Result := nil;
end;

function TStubIdeServices.GetFileTrait(const AFileName: string;
  const ATraitGUID: TGUID): IInterface;
begin
  Result := nil;
end;

function TStubIdeServices.GetTrait(const APersonality: string;
  const ATraitGUID: TGUID): IInterface;
begin
  Result := nil;
end;

function TStubIdeServices.GetTrait(const ATraitGUID: TGUID): IInterface;
begin
  Result := nil;
end;

function TStubIdeServices.SupportsFileTrait(const APersonality,
  AFileName: string; const ATraitGUID: TGUID;
  SearchDefault: Boolean): Boolean;
begin
  Result := False;
end;

function TStubIdeServices.SupportsFileTrait(const AFileName: string;
  const ATraitGUID: TGUID; SearchDefault: Boolean): Boolean;
begin
  Result := False;
end;

function TStubIdeServices.SupportsFileTrait(const APersonality,
  AFileName: string; const ATraitGUID: TGUID): Boolean;
begin
  Result := False;
end;

function TStubIdeServices.SupportsFileTrait(const AFileName: string;
  const ATraitGUID: TGUID): Boolean;
begin
  Result := False;
end;

function TStubIdeServices.SupportsTrait(const APersonality: string;
  const ATraitGUID: TGUID): Boolean;
begin
  Result := False;
end;

function TStubIdeServices.SupportsTrait(const ATraitGUID: TGUID): Boolean;
begin
  Result := False;
end;

function TStubIdeServices.PromptUserForPersonality(const ATraitGUID: TGUID;
  const Prompt: string): Boolean;
begin
  Result := False;
end;

function TStubIdeServices.GetFilePersonality(const AFileName: string): string;
begin
  Result := '';
end;

function TStubIdeServices.FindFileTrait(const AFileName: string;
  const ATraitGUID: TGUID): IInterface;
begin
  Result := nil;
end;

function TStubIdeServices.PersonalityExists(const APersonality: string): Boolean;
begin
  Result := False;
end;

function TStubIdeServices.GetPersonalityId(const APersonality: string): Integer;
begin
  Result := -1;
end;

{$IF CompilerVersion >= 36.0}
function TStubIdeServices.ColorFor(ITC: TIDEThemeColors): TColor;
const
  Colors: array [TIDEThemeColors] of TColor = (clBlue, clRed, clYellow, clGreen,
    clPurple, clGray, TColor($000080FF));
begin
  Result := Colors[ITC];
end;

function TStubIdeServices.GetThemeAwareColor(ITC: TIDEThemeColors): TColor;
begin
  Result := ColorFor(ITC);
end;

function TStubIdeServices.GetDarkColor(ITC: TIDEThemeColors): TColor;
begin
  Result := ColorFor(ITC);
end;

function TStubIdeServices.GetGenericColor(ITC: TIDEThemeColors): TColor;
begin
  Result := ColorFor(ITC);
end;

function TStubIdeServices.GetLightColor(ITC: TIDEThemeColors): TColor;
begin
  Result := ColorFor(ITC);
end;

procedure TStubIdeServices.SetupTitleBar(AForm: TCustomForm;
  ATitleBar: TTitleBarPanel; InsertRootPanel: Boolean);
begin
end;

function TStubIdeServices.MessageDlg(const Msg: string; DlgType: TMsgDlgType;
  Buttons: TMsgDlgButtons; HelpCtx: Longint): Integer;
begin
  Result := Vcl.Dialogs.MessageDlg(Msg, DlgType, Buttons, HelpCtx);
end;

function TStubIdeServices.MessageDlg(const Msg: string; DlgType: TMsgDlgType;
  Buttons: TMsgDlgButtons; HelpCtx: Longint; DefaultButton: TMsgDlgBtn): Integer;
begin
  Result := Vcl.Dialogs.MessageDlg(Msg, DlgType, Buttons, HelpCtx, DefaultButton);
end;

function TStubIdeServices.InputBox(const ACaption, APrompt,
  ADefault: string): string;
begin
  Result := Vcl.Dialogs.InputBox(ACaption, APrompt, ADefault);
end;

function TStubIdeServices.InputQuery(const ACaption: string;
  const APrompts: array of string; var AValues: array of string;
  const CloseQueryFunc: TInputCloseQueryFunc): Boolean;
begin
  Result := Vcl.Dialogs.InputQuery(ACaption, APrompts, AValues, CloseQueryFunc);
end;

function TStubIdeServices.InputQuery(const ACaption: string;
  const APrompts: array of string; var AValues: array of string;
  const CloseQueryEvent: TInputCloseQueryEvent; Context: TObject): Boolean;
begin
  Result := Vcl.Dialogs.InputQuery(ACaption, APrompts, AValues, CloseQueryEvent,
    Context);
end;

function TStubIdeServices.InputQuery(const ACaption, APrompt: string;
  var Value: string): Boolean;
begin
  Result := Vcl.Dialogs.InputQuery(ACaption, APrompt, Value);
end;

procedure TStubIdeServices.ShowMessage(const Msg: string);
begin
  Vcl.Dialogs.ShowMessage(Msg);
end;
{$IFEND}

function TStubIdeServices.AddFileSystem(FileSystem: IOTAFileSystem): Integer;
begin
  Result := -1;
end;

function TStubIdeServices.CloseAll: Boolean;
begin
  Result := True;
end;

function TStubIdeServices.CreateModule(const Creator: IOTACreator): IOTAModule;
begin
  Result := nil;
end;

function TStubIdeServices.CurrentModule: IOTAModule;
begin
  Result := nil;
end;

function TStubIdeServices.FindFileSystem(const Name: string): IOTAFileSystem;
begin
  Result := nil;
end;

function TStubIdeServices.FindFormModule(const FormName: string): IOTAModule;
begin
  Result := nil;
end;

function TStubIdeServices.FindModule(const FileName: string): IOTAModule;
begin
  Result := nil;
end;

function TStubIdeServices.GetModuleCount: Integer;
begin
  Result := 0;
end;

function TStubIdeServices.GetModule(Index: Integer): IOTAModule;
begin
  Result := nil;
end;

procedure TStubIdeServices.GetNewModuleAndClassName(const Prefix: string;
  var UnitIdent, ClassName, FileName: string);
begin
  UnitIdent := '';
  ClassName := '';
  FileName := '';
end;

function TStubIdeServices.NewModule: Boolean;
begin
  Result := False;
end;

procedure TStubIdeServices.RemoveFileSystem(Index: Integer);
begin
end;

function TStubIdeServices.SaveAll: Boolean;
begin
  Result := True;
end;

function TStubIdeServices.GetMainProjectGroup: IOTAProjectGroup;
begin
  Result := nil;
end;

function TStubIdeServices.OpenModule(const FileName: string): IOTAModule;
begin
  Result := nil;
end;

function TStubIdeServices.GetActiveProject: IOTAProject;
begin
  Result := nil;
end;

const
  // Registry root reported by GetBaseRegistryKey; this program's own key
  // rather than the IDE's, and never empty, which would put a package's
  // settings directly under HKCU.
  OwnBaseRegistryKey = 'Software\VallentaStudio\Designer';

function TStubIdeServices.AddNotifier(const Notifier: IOTAIDENotifier): Integer;
begin
  Result := -1;
end;

procedure TStubIdeServices.RemoveNotifier(Index: Integer);
begin
end;

function TStubIdeServices.GetBaseRegistryKey: string;
begin
  Result := OwnBaseRegistryKey;
end;

function TStubIdeServices.GetProductIdentifier: string;
begin
  Result := 'VallentaStudio';
end;

function TStubIdeServices.GetParentHandle: HWND;
begin
  Result := Application.Handle;
end;

function TStubIdeServices.GetEnvironmentOptions: IOTAEnvironmentOptions;
begin
  Result := nil;
end;

function TStubIdeServices.GetActiveDesignerType: string;
begin
  Result := 'dfm';
end;

function TStubIdeServices.GetRootDirectory: string;
begin
  Result := IdeRootDirectory;
end;

function TStubIdeServices.GetBinDirectory: string;
begin
  Result := IdeBinDirectory;
end;

function TStubIdeServices.GetTemplateDirectory: string;
begin
  Result := IdeBinDirectory;
end;

function TStubIdeServices.GetApplicationDataDirectory: string;
begin
  Result := GetEnvironmentVariable('APPDATA');
end;

function TStubIdeServices.GetLocalApplicationDataDirectory: string;
begin
  Result := GetEnvironmentVariable('LOCALAPPDATA');
end;

function TStubIdeServices.GetIDEPreferredUILanguages: string;
begin
  Result := '';
end;

function TStubIdeServices.GetStartupDirectory: string;
begin
  Result := '';
end;

function TStubIdeServices.IsProject(const FileName: string): Boolean;
begin
  Result := False;
end;

function TStubIdeServices.IsProjectGroup(const FileName: string): Boolean;
begin
  Result := False;
end;

function TStubIdeServices.SaveStream(const Stream: IStream): string;
begin
  Result := '';
end;

function TStubIdeServices.ExpandRootMacro(const S: string): string;
begin
  Result := ExpandPackagePath(S);
end;

procedure TStubIdeServices.BuildIdeMenu;
var
  Name: string;
  Anchor: TIdeMenuAnchor;
  Menu, Item: TMenuItem;
begin
  for Name in IdeMenuNames do
  begin
    Item := TMenuItem.Create(FMainMenu);
    Item.Name := Name;
    Item.Caption := Copy(Name, 1, Length(Name) - Length('Menu'));
    FMainMenu.Items.Add(Item);
  end;
  for Anchor in IdeMenuAnchors do
  begin
    Menu := FMainMenu.FindComponent(Anchor.Menu) as TMenuItem;
    if Menu = nil then
      Continue;
    // The separator keeps the anchor off index 0: a package that inserts
    // ahead of the anchor computes index - 1, and TMenuItem.Insert raises
    // at -1.
    Item := TMenuItem.Create(FMainMenu);
    Item.Caption := '-';
    Menu.Add(Item);
    Item := TMenuItem.Create(FMainMenu);
    Item.Name := Anchor.Item;
    Item.Caption := Anchor.Caption;
    Menu.Add(Item);
  end;
end;

function TStubIdeServices.ToolBarNamed(const AName: string): TToolBar;
var
  Index: Integer;
begin
  if FToolBars.Find(AName, Index) then
    Exit(TToolBar(FToolBars.Objects[Index]));
  Result := TToolBar.Create(FIdeUi);
  FToolBars.AddObject(AName, Result);
end;

function TStubIdeServices.GetMainMenu: TMainMenu;
begin
  Result := FMainMenu;
end;

function TStubIdeServices.GetActionList: TCustomActionList;
begin
  Result := FActionList;
end;

function TStubIdeServices.GetImageList: TCustomImageList;
begin
  Result := FImageList;
end;

function TStubIdeServices.GetToolBar(const ToolBarName: string): TToolBar;
begin
  Result := ToolBarNamed(ToolBarName);
end;

function TStubIdeServices.AddMasked(Image: TBitmap;
  MaskColor: TColor): Integer;
begin
  Result := -1;
end;

function TStubIdeServices.AddMasked(Image: TBitmap; MaskColor: TColor;
  const Ident: string): Integer;
begin
  Result := -1;
end;

function TStubIdeServices.AddImages(AImages: TCustomImageList): Integer;
begin
  Result := -1;
end;

function TStubIdeServices.AddImages(AImages: TCustomImageList;
  const Ident: string): Integer;
begin
  Result := -1;
end;

function TStubIdeServices.AddImage(const AImageName: string;
  const AImage: TGraphicArray): Integer;
begin
  Result := -1;
end;

procedure TStubIdeServices.AddActionMenu(const Name: string;
  NewAction: TCustomAction; NewItem: TMenuItem; InsertAfter: Boolean;
  InsertAsChild: Boolean);
begin
  if (NewAction <> nil) and (NewAction.ActionList = nil) then
    NewAction.ActionList := FActionList;
  // TMenuItem.Insert raises on an item that already has a parent, so an item
  // that has one is left where it is and stays the caller's to free.
  if (NewItem <> nil) and (NewItem.Parent = nil) then
    FMainMenu.Items.Add(NewItem);
end;

function TStubIdeServices.NewToolbar(const Name, Caption: string;
  const ReferenceToolBar: string; InsertBefore: Boolean): TToolbar;
begin
  Result := ToolBarNamed(Name);
  Result.Caption := Caption;
end;

function TStubIdeServices.AddToolButton(const ToolBarName,
  ButtonName: string; AAction: TCustomAction; const IsDivider: Boolean;
  const ReferenceButton: string; InsertBefore: Boolean): TControl;
begin
  // Left unparented: setting Parent would create the window handle of a
  // toolbar that is never displayed.
  Result := TToolButton.Create(ToolBarNamed(ToolBarName));
end;

procedure TStubIdeServices.UpdateMenuAccelerators(Menu: TMenu);
begin
end;

procedure TStubIdeServices.ReadToolbar(AOwner: TComponent;
  AParent: TWinControl; const AName: string; var AToolBar: TWinControl;
  const ASubKey: string; AStream: TStream; DefaultToolbar: Boolean);
begin
  if AToolBar = nil then
    AToolBar := TToolBar.Create(AOwner);
end;

procedure TStubIdeServices.WriteToolbar(AToolbar: TWinControl;
  const AName: string; const ASubkey: string; AStream: TStream);
begin
end;

function TStubIdeServices.CustomizeToolbar(
  const AToolbars: array of TWinControl;
  const ANotifier: INTACustomizeToolbarNotifier; AButtonOwner: TComponent;
  AActionList: TCustomActionList; AButtonsOnly: Boolean): TComponent;
begin
  Result := nil;
end;

procedure TStubIdeServices.CloseCustomize;
begin
end;

procedure TStubIdeServices.ToolbarModified(AToolbar: TWinControl);
begin
end;

function TStubIdeServices.RegisterToolbarNotifier(
  const ANotifier: IOTANotifier): Integer;
begin
  Result := 0;
end;

procedure TStubIdeServices.UnregisterToolbarNotifier(Index: Integer);
begin
end;

procedure TStubIdeServices.MenuBeginUpdate;
begin
end;

procedure TStubIdeServices.MenuEndUpdate;
begin
end;

procedure TStubIdeServices.RegisterDockableForm(
  const CustomDockableForm: INTACustomDockableForm);
begin
end;

procedure TStubIdeServices.UnregisterDockableForm(
  const CustomDockableForm: INTACustomDockableForm);
begin
end;

function TStubIdeServices.CreateDockableForm(
  const CustomDockableForm: INTACustomDockableForm): TCustomForm;
begin
  Result := nil;
end;

{$IF CompilerVersion >= 36.0}
function TStubIdeServices.CreateDockableFormEx(
  const CustomDockableForm: INTACustomDockableForm;
  Titlebar: Boolean): TCustomForm;
begin
  Result := nil;
end;
{$IFEND}

function TStubIdeServices.AddPluginInfo(const ATitle,
  ADescription: string; AImage: HBITMAP; AIsUnRegistered: Boolean;
  const ALicenseStatus: string; const ASKUName: string): Integer;
begin
  Result := 0;
end;

function TStubIdeServices.AddPluginInfo(const ATitle,
  ADescription: string; AImage: HBITMAP; AIsUnRegistered: Boolean;
  const ALicenseStatus: string; const ASKUName: string;
  AAlphaFormat: TOTAAlphaFormat): Integer;
begin
  Result := 0;
end;

function TStubIdeServices.AddPluginInfo(const ATitle,
  ADescription: string; const AImage: TGraphicArray;
  AIsUnRegistered: Boolean; const ALicenseStatus: string;
  const ASKUName: string): Integer;
begin
  Result := 0;
end;

function TStubIdeServices.AddProductInfo(const ADialogTitle, ACopyright,
  ATitle, ADescription: string; AAboutImage, AProductImage: HBITMAP;
  AIsUnRegistered: Boolean; const ALicenseStatus: string;
  const ASKUName: string): Integer;
begin
  Result := 0;
end;

function TStubIdeServices.AddProductInfo(const ADialogTitle, ACopyright,
  ATitle, ADescription: string; AAboutImage, AProductImage: HBITMAP;
  AIsUnRegistered: Boolean; const ALicenseStatus: string;
  const ASKUName: string; AAboutImageAlphaFormat: TOTAAlphaFormat;
  AProductImageAlphaFormat: TOTAAlphaFormat): Integer;
begin
  Result := 0;
end;

function TStubIdeServices.AddProductInfo(const ADialogTitle, ACopyright,
  ATitle, ADescription: string; AAboutImage: HBITMAP;
  const AProductImage: TGraphicArray; AIsUnRegistered: Boolean;
  const ALicenseStatus: string; const ASKUName: string;
  AAboutImageAlphaFormat: TOTAAlphaFormat): Integer;
begin
  Result := 0;
end;

procedure TStubIdeServices.RemovePluginInfo(Index: Integer);
begin
end;

procedure TStubIdeServices.RemoveProductInfo(Index: Integer);
begin
end;

procedure TStubPaletteServices.SetSelectedTool(const Value: IOTABasePaletteItem);
begin
end;

function TStubPaletteServices.GetBaseGroup: IOTAPaletteGroup;
begin
  Result := nil;
end;

function TStubPaletteServices.GetSelectedTool: IOTABasePaletteItem;
begin
  Result := nil;
end;

function TStubPaletteServices.AddNotifier(
  const Notifier: IOTAPaletteNotifier): Integer;
begin
  Result := -1;
end;

procedure TStubPaletteServices.RemoveNotifier(const Index: Integer);
begin
end;

procedure TStubPaletteServices.BeginUpdate;
begin
end;

procedure TStubPaletteServices.EndUpdate;
begin
end;

procedure TStubPaletteServices.ItemAdded(const Group: IOTAPaletteGroup;
  const Item: IOTABasePaletteItem);
begin
end;

procedure TStubPaletteServices.ItemRemoved(const Group: IOTAPaletteGroup;
  const Item: IOTABasePaletteItem);
begin
end;

procedure TStubPaletteServices.Modified;
begin
end;

function TStubPaletteServices.RegisterDragAcceptor(
  const Acceptor: IOTAPaletteDragAcceptor): Integer;
begin
  Result := -1;
end;

procedure TStubPaletteServices.UnRegisterDragAcceptor(const Index: Integer);
begin
end;

function TStubPaletteServices.GetDragAcceptors: IInterfaceList;
begin
  Result := TInterfaceList.Create;
end;

function TStubPaletteServices.RegisterColorScheme(
  const ColorScheme: IOTAPaletteColorScheme): Integer;
begin
  Result := -1;
end;

procedure TStubPaletteServices.UnRegisterColorScheme(const Index: Integer);
begin
end;

function TStubPaletteServices.GetColorSchemes: IInterfaceList;
begin
  Result := TInterfaceList.Create;
end;

procedure TStubPaletteServices.AddPaletteState(const State: string);
begin
end;

procedure TStubPaletteServices.RemovePaletteState(const State: string);
begin
end;

procedure TStubPaletteServices.AddPaletteDesignerState(const State: string);
begin
end;

function TStubPaletteServices.ContainsPaletteState(const State: string): Boolean;
begin
  Result := False;
end;

function TStubPaletteServices.GetPaletteState: string;
begin
  Result := '';
end;

procedure TStubPaletteServices.SetImageCollection(const AValue: TImageCollection);
begin
end;

function TStubPaletteServices.GetImageCollection: TImageCollection;
begin
  Result := nil;
end;

initialization

finalization
  // The stub outlives this finalization through BorlandIDEServices; a refusal
  // after this point is dropped by NoteRefusal's nil check on the list.
  RefusalHandler := nil;
  FreeAndNil(RefusedServices);

end.
