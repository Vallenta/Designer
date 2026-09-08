// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Shell.MainWindow;

// Window of one open form file: palette, design surface, object inspector and
// messages pane, plus the menu and actions that operate on them. Holds the
// loaded document, its designer, undo history, code coupling, pending renames
// and document log; all but the coupling are freed with the window. Main
// thread only.
//
// UseSessions must run before the first open call; the code coupling is built
// with the document and stays absent without a session registry. Closing sets
// caFree and fires OnDocumentClosing once; no reference to the window may be
// held past that event.

interface

uses
  Winapi.Messages,
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.ExtCtrls,
  Vcl.StdCtrls,
  Vcl.Menus,
  Vcl.ActnList,
  System.Actions,
  Vallenta.FormEditor.Shell.AlignDialogs,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Core.Sessions,
  Vallenta.FormEditor.Core.Coupling,
  Vallenta.FormEditor.Surface.FormDesigner,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Surface.IconCanvas,
  Vallenta.FormEditor.Surface.Tiles,
  Vallenta.FormEditor.Streaming.RootClassifier,
  Vallenta.FormEditor.Palette.Frame,
  Vallenta.FormEditor.Inspector.Frame,
  Vallenta.FormEditor.Shell.MessagesFrame,
  Vallenta.FormEditor.Shell.Layout,
  Vallenta.FormEditor.Surface.Undo;

const
  // Undo and redo are posted, not called: a restore replaces the designer and
  // must not run inside its own message handling.
  WM_PERFORMUNDO = WM_APP + 1;
  WM_PERFORMREDO = WM_APP + 2;

  // FKeptVersion while the recovery journal holds no copy. Must differ from 0,
  // the version of an unchanged document, so that a recovered document does
  // not read as already copied.
  NothingKept = -1;

type
  // Window of one open form file. One instance per open document, created by
  // Shell.Core.
  TMainDesignerForm = class(TForm)
    MessagesZone: TPanel;
    MessagesSplitter: TSplitter;
    PaletteZone: TPanel;
    PaletteSplitter: TSplitter;
    InspectorZone: TPanel;
    InspectorSplitter: TSplitter;
    DesignSurfaceBox: TScrollBox;
    MainMenu: TMainMenu;
    FileMenu: TMenuItem;
    FileSaveItem: TMenuItem;
    FileSeparator: TMenuItem;
    FileCloseItem: TMenuItem;
    EditMenu: TMenuItem;
    EditUndoItem: TMenuItem;
    EditRedoItem: TMenuItem;
    EditClipboardSeparator: TMenuItem;
    EditCutItem: TMenuItem;
    EditCopyItem: TMenuItem;
    EditPasteItem: TMenuItem;
    EditSeparator: TMenuItem;
    EditBringToFrontItem: TMenuItem;
    EditSendToBackItem: TMenuItem;
    EditOrderSeparator: TMenuItem;
    EditAlignItem: TMenuItem;
    EditSizeItem: TMenuItem;
    EditTabOrderItem: TMenuItem;
    EditCreationOrderItem: TMenuItem;
    ViewMenu: TMenuItem;
    ViewPaletteItem: TMenuItem;
    ViewInspectorItem: TMenuItem;
    ViewMessagesItem: TMenuItem;
    ToolsMenu: TMenuItem;
    ToolsPackagesItem: TMenuItem;
    ActionList: TActionList;
    SaveAction: TAction;
    UndoAction: TAction;
    RedoAction: TAction;
    CutAction: TAction;
    CopyAction: TAction;
    PasteAction: TAction;
    BringToFrontAction: TAction;
    SendToBackAction: TAction;
    AlignAction: TAction;
    SizeAction: TAction;
    TabOrderAction: TAction;
    CreationOrderAction: TAction;
    CloseWindowAction: TAction;
    TogglePaletteAction: TAction;
    ToggleInspectorAction: TAction;
    ToggleMessagesAction: TAction;
    PackagesAction: TAction;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
    procedure FormActivate(Sender: TObject);
    procedure CloseWindowActionExecute(Sender: TObject);
    procedure SaveActionExecute(Sender: TObject);
    procedure UndoActionExecute(Sender: TObject);
    procedure RedoActionExecute(Sender: TObject);
    procedure CutActionExecute(Sender: TObject);
    procedure CopyActionExecute(Sender: TObject);
    procedure PasteActionExecute(Sender: TObject);
    procedure BringToFrontActionExecute(Sender: TObject);
    procedure SendToBackActionExecute(Sender: TObject);
    procedure AlignActionExecute(Sender: TObject);
    procedure SizeActionExecute(Sender: TObject);
    procedure TabOrderActionExecute(Sender: TObject);
    procedure CreationOrderActionExecute(Sender: TObject);
    procedure TogglePaletteActionExecute(Sender: TObject);
    procedure ToggleInspectorActionExecute(Sender: TObject);
    procedure ToggleMessagesActionExecute(Sender: TObject);
    procedure PackagesActionExecute(Sender: TObject);
    procedure ActionListUpdate(Action: TBasicAction; var Handled: Boolean);
  private
    FLog: TDesignLog;
    FSessionLog: TDesignLog;
    FOnDocumentChanged: TNotifyEvent;
    FOnDocumentClosing: TNotifyEvent;
    FOnDocumentActivated: TNotifyEvent;
    FOnDocumentSaved: TNotifyEvent;
    FOnDocumentDirtyChanged: TNotifyEvent;
    // Dirty state last reported through OnDocumentDirtyChanged. UpdateCaption
    // runs on every caption rebuild, the event only on a change.
    FReportedDirty: Boolean;
    FClosingSaid: Boolean;
    FDesigner: TFormDesigner;
    FDocument: TDesignDocument;
    FRootKind: TDesignRootClass;
    FIconSurface: TIconSurface;
    FFileName: string;
    FPalette: TPaletteFrame;
    FInspector: TInspectorFrame;
    FMessages: TMessagesFrame;
    // Banner above the design surface, shown while the document is guarded
    // read-only. FGuardLifted survives an undo rebuild, which reloads the
    // document and would otherwise guard it again.
    FGuardBanner: TPanel;
    FGuardLabel: TLabel;
    FGuardButton: TButton;
    FGuardLifted: Boolean;
    FUndoStack: TUndoStack;
    FSurfaceMenu: TPopupMenu;
    FVersion: Integer;
    FKeptVersion: Integer;
    FSettled: Boolean;
    FSourceFiles: TArray<TSourceFile>;
    FSessions: TSessionRegistry;
    // The same coupling twice: as the object, for the calls outside
    // ICodeCoupling, and as an interface reference. A pending request holds a
    // reference too, so the object can outlive this window.
    FCouplingObject: TDocumentCoupling;
    FCoupling: ICodeCoupling;
    FCodeCouplingAvailable: Boolean;
    // Renames awaiting an answer. Held here rather than in the designer,
    // which an undo restore replaces while an answer is still due.
    FRenames: TRenameRegister;
    // True inside the modal move/size loop; RenewInputMapping is skipped per
    // step there and run once on exit.
    FInSizeMove: Boolean;
    procedure BeginCoupling;
    procedure EndCoupling;
    procedure SettleFields;
    function CurrentStep: Integer;
    procedure HandlerCreated(AStep: Integer; const AHandler: TCreatedHandler);
    function StartRename(AKind: TRenameKind; const AOldName, ANewName: string;
      const AMethods: TArray<TMethodRename>): string;
    function RenameInFlight(const AName: string): Boolean;
    function ApplyRename(AKind: TRenameKind; const AOldName, ANewName: string;
      const AMethods: TArray<TMethodRename>;
      const ANewClassName: string): Boolean;
    function CreatedHandlers: TArray<TCreatedHandler>;
    procedure DropStep(AStep: Integer);
    procedure RenameSettled(Sender: TObject);
    procedure StepUndone(Sender: TObject; const AHandler: TCreatedHandler);
    procedure StepRedone(Sender: TObject; const AHandler: TCreatedHandler);
    function AskCoupling: Boolean;
    procedure SetCodeCouplingAvailable(AValue: Boolean);
    procedure DocumentComponentsChanged(Sender: TObject);
    procedure BuildPanes;
    function CurrentLayout: TDesignerLayout;
    function OwnsItsSize: Boolean;
    procedure RestoreLayout;
    procedure KeepLayout;
    procedure ToggleZone(Zone: TPanel; Splitter: TSplitter);
    procedure BuildDocument(ALoader: TFormLoader);
    procedure HoldPanesStill(AHold: Boolean);
    procedure PresentDocument(const AState: TLoadedFormState);
    procedure ReleaseDocument;
    procedure CloseDocument;
    procedure UpdateCaption;
    procedure ShowGuardBanner(const AUnresolved: TArray<string>);
    procedure HideGuardBanner;
    procedure GuardLiftClick(Sender: TObject);
    procedure SayClosing;
    procedure DesignerDirtyChanged(Sender: TObject);
    procedure DesignerSaved(Sender: TObject);
    procedure DesignerModified(Sender: TObject);
    procedure DesignerSaveRequested(Sender: TObject);
    procedure DesignerUndoRequested(Sender: TObject);
    procedure DesignerRedoRequested(Sender: TObject);
    function CaptureDocument(Sender: TObject): TDocumentSnapshot;
    procedure RestoreDocument(Sender: TObject; ASnapshot: TDocumentSnapshot);
    procedure PerformUndo(var Message: TMessage); message WM_PERFORMUNDO;
    procedure PerformRedo(var Message: TMessage); message WM_PERFORMREDO;
    procedure WMEnterSizeMove(var Message: TMessage); message WM_ENTERSIZEMOVE;
    procedure WMExitSizeMove(var Message: TMessage); message WM_EXITSIZEMOVE;
    procedure WMWindowPosChanged(var Message: TWMWindowPosChanged);
      message WM_WINDOWPOSCHANGED;
    procedure RenewInputMapping;
    procedure UpdateActionStates;
    procedure DesignerContextMenu(Sender: TObject);
    procedure SurfaceVerbClicked(Sender: TObject);
    procedure SurfaceDeleteClicked(Sender: TObject);
  protected
    // Sets WndParent to 0 and adds WS_EX_APPWINDOW, giving each document its
    // own taskbar button. The main form is never shown
    procedure CreateParams(var Params: TCreateParams); override;
  public
    // ASessionLog is the process-wide log shown in the messages pane beside
    // this window's own; it is stored before the panes are built.
    constructor CreateFor(AOwner: TComponent; ASessionLog: TDesignLog);
    // Sets the session registry requests are routed through. Must be called
    // before the first open; the code coupling is built with the document.
    procedure UseSessions(ASessions: TSessionRegistry);
    // Loads a form file into the surface, replacing any open document.
    // AFileName is stored as given; callers pass an absolute path. AQuietly
    // suppresses the error message box; the failure is still logged.
    procedure OpenDesignFile(const AFileName: string; AQuietly: Boolean);
    // Loads ARecoveryFile, the recovery journal's copy of AFileName. The
    // document saves to AFileName and resolves ancestors and frames from its
    // directory. ARootClassName and ARootKind come from the recovery note;
    // the document is marked dirty, no state in its history being on disk.
    procedure OpenRecovered(const AFileName, ARecoveryFile,
      ARootClassName: string; ARootKind: TDesignRootClass);
    // Writes the document to APath through the regular save pipeline without
    // touching the dirty flag, the log or any dialog; failures raise.
    procedure WriteDocumentTo(const APath: string);
    // Prompts for unsaved changes exactly as a window close does. False when
    // the prompt was cancelled or the save failed; True with no document.
    function MayClose: Boolean;
    // True while the document has unsaved changes.
    function IsDirty: Boolean;
    // True when the recovery journal is behind: unsaved changes exist, they
    // differ from the last copy taken, and no gesture is in flight.
    function NeedsKeeping: Boolean;
    // Records that the journal's copy matches the current document version.
    // Call only after a successful write; a failed one must leave
    // NeedsKeeping True so that the next attempt repeats it.
    procedure MarkKept;
    // Records that the unsaved changes were answered for. The core drops the
    // document's recovery copy when a settled window closes.
    procedure MarkSettled;
    // True once MarkSettled ran.
    property Settled: Boolean read FSettled;
    // Form files this document draws on besides its own: ancestor forms and
    // frame files, each an absolute path. Empty while no document is loaded.
    property SourceFiles: TArray<TSourceFile> read FSourceFiles;
    // Class name the form file declares, not the design stub's; empty while
    // no document is loaded.
    function RootClassName: string;
    // Root classification: form, frame, or data module.
    property RootKind: TDesignRootClass read FRootKind;
    // Form file of the open document, as the caller passed it; empty while no
    // document is loaded.
    property FileName: string read FFileName;
    // Log of this document; freed with the window.
    property Log: TDesignLog read FLog;
    // Designer of the open document; nil while none is loaded.
    property Designer: TFormDesigner read FDesigner;
    // True while an editor session reaches this document, as the core last
    // routed it; ICodeCoupling.Available re-answers that per request. A change
    // is logged and refreshes the inspector rows; turning True also resumes
    // the field ledger.
    property CodeCouplingAvailable: Boolean read FCodeCouplingAvailable
      write SetCodeCouplingAvailable;
    // Fired on every caption rebuild, so after any change to the file name,
    // the read-only guard or the dirty state.
    property OnDocumentChanged: TNotifyEvent read FOnDocumentChanged
      write FOnDocumentChanged;
    // Fired exactly once, before the window is destroyed.
    property OnDocumentClosing: TNotifyEvent read FOnDocumentClosing
      write FOnDocumentClosing;
    // Fired when this window became the active one.
    property OnDocumentActivated: TNotifyEvent read FOnDocumentActivated
      write FOnDocumentActivated;
    // Fired after the document was written to its file. Separate from the
    // dirty change, which cannot tell a save from an undo back to the saved
    // depth.
    property OnDocumentSaved: TNotifyEvent read FOnDocumentSaved
      write FOnDocumentSaved;
    // Fired only when the dirty state actually changed, an undo restore
    // included: a restore installs a new designer whose flag never moved.
    property OnDocumentDirtyChanged: TNotifyEvent read FOnDocumentDirtyChanged
      write FOnDocumentDirtyChanged;
  end;

implementation

{$R *.dfm}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Math,
  System.UITypes,
  Vcl.Dialogs,
  Vallenta.FormEditor.Core.Settings,
  Vallenta.FormEditor.Packages.ManagerDialog;

const
  // Registry key below the settings root; one layout for all windows.
  LayoutSettingsKey = 'Layout';

  // Room a restored pane leaves for what it sits beside, in design-time
  // pixels; RestoreLayout scales each through ScaleValue.
  MinSurfaceWidth = 240;
  MinSurfaceHeight = 160;
  MinTabsHeight = 120;
  // Lower bound for a pane itself, applied even when no room is left.
  MinPaneSize = 40;

procedure TMainDesignerForm.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  if not (csDesigning in ComponentState) then
  begin
    Params.WndParent := 0;
    Params.ExStyle := Params.ExStyle or WS_EX_APPWINDOW;
  end;
end;

constructor TMainDesignerForm.CreateFor(AOwner: TComponent;
  ASessionLog: TDesignLog);
begin
  // Before the inherited constructor: FormCreate runs from it and BuildPanes
  // reads this field.
  FSessionLog := ASessionLog;
  inherited Create(AOwner);
end;

procedure TMainDesignerForm.UseSessions(ASessions: TSessionRegistry);
begin
  FSessions := ASessions;
end;

procedure TMainDesignerForm.BeginCoupling;
begin
  if (FSessions = nil) or (FFileName = '') then
    Exit;
  FCouplingObject := TDocumentCoupling.Create(FSessions);
  FCoupling := FCouplingObject;
  FCouplingObject.FileName := FFileName;
  FCouplingObject.Log := FLog;
  FCouplingObject.OnCurrentStep := CurrentStep;
  FCouplingObject.OnHandlerCreated := HandlerCreated;
  FCouplingObject.OnHandlerRoster := CreatedHandlers;
  FCouplingObject.OnRenamed := FRenames.Answered;
end;

function TMainDesignerForm.StartRename(AKind: TRenameKind;
  const AOldName, ANewName: string;
  const AMethods: TArray<TMethodRename>): string;
begin
  Result := FRenames.Start(FCoupling, AKind, AOldName, ANewName, AMethods);
end;

function TMainDesignerForm.RenameInFlight(const AName: string): Boolean;
begin
  Result := FRenames.InFlight(AName);
end;

function TMainDesignerForm.ApplyRename(AKind: TRenameKind;
  const AOldName, ANewName: string;
  const AMethods: TArray<TMethodRename>;
  const ANewClassName: string): Boolean;
var
  Pair: TMethodRename;
begin
  // Recorded before and regardless of the apply: the editor already renamed
  // the method when it answered, and a mark left at the old name makes the
  // next Resume recreate that method beside the renamed one.
  if FUndoStack <> nil then
    for Pair in AMethods do
      FUndoStack.RenameCreatedHandler(Pair.OldName, Pair.NewName);
  Result := (FDesigner <> nil) and
    FDesigner.ApplyRename(AKind, AOldName, ANewName, AMethods, ANewClassName);
  if Result and (ANewClassName <> '') and (FCouplingObject <> nil) then
    FCouplingObject.RootClass := FDesigner.RootClassName;
end;

procedure TMainDesignerForm.DropStep(AStep: Integer);
begin
  if FUndoStack <> nil then
    FUndoStack.DropStep(AStep);
end;

procedure TMainDesignerForm.RenameSettled(Sender: TObject);
begin
  if FInspector <> nil then
    FInspector.RefreshRows;
end;

function TMainDesignerForm.CurrentStep: Integer;
begin
  Result := 0;
  if FUndoStack <> nil then
    Result := FUndoStack.LastStep;
end;

procedure TMainDesignerForm.HandlerCreated(AStep: Integer;
  const AHandler: TCreatedHandler);
begin
  if FUndoStack <> nil then
    FUndoStack.MarkCreatedHandler(AStep, AHandler);
end;

function TMainDesignerForm.CreatedHandlers: TArray<TCreatedHandler>;
begin
  Result := nil;
  if FUndoStack <> nil then
    Result := FUndoStack.CreatedHandlers;
end;

procedure TMainDesignerForm.StepUndone(Sender: TObject;
  const AHandler: TCreatedHandler);
begin
  if FCoupling <> nil then
    FCoupling.RemoveHandler(AHandler.Method);
end;

procedure TMainDesignerForm.StepRedone(Sender: TObject;
  const AHandler: TCreatedHandler);
begin
  if FCoupling <> nil then
    FCoupling.EnsureHandler(AHandler.Component, AHandler.Event,
      AHandler.Method, AHandler.Signature);
end;

procedure TMainDesignerForm.EndCoupling;
begin
  // Close runs before the references drop: a pending answer holds the object
  // too and must find the document marked closed.
  if FCouplingObject <> nil then
    FCouplingObject.Close;
  FCouplingObject := nil;
  FCoupling := nil;
end;

procedure TMainDesignerForm.SettleFields;
begin
  if (FCouplingObject = nil) or (FDesigner = nil) then
    Exit;
  FCouplingObject.Settle(FDesigner.DesignedFields);
end;

procedure TMainDesignerForm.DocumentComponentsChanged(Sender: TObject);
begin
  SettleFields;
end;

function TMainDesignerForm.AskCoupling: Boolean;
begin
  Result := FCodeCouplingAvailable;
end;

procedure TMainDesignerForm.SetCodeCouplingAvailable(AValue: Boolean);
begin
  if AValue = FCodeCouplingAvailable then
    Exit;
  FCodeCouplingAvailable := AValue;
  if AValue then
  begin
    FLog.Add(lsInfo, 'VS Code is attached - events can be edited and the ' +
      'form''s fields are kept in sync with its unit');
    if (FCouplingObject <> nil) and (FDesigner <> nil) then
      FCouplingObject.Resume(FDesigner.DesignedFields);
  end
  else
    FLog.Add(lsWarn, 'VS Code disconnected - code coupling is off until it ' +
      'reconnects');
  if FInspector <> nil then
    FInspector.RefreshRows;
end;

procedure TMainDesignerForm.FormCreate(Sender: TObject);
begin
  FLog := TDesignLog.Create;
  FRenames := TRenameRegister.Create;
  FRenames.Log := FLog;
  FRenames.OnCurrentStep := CurrentStep;
  FRenames.OnDropStep := DropStep;
  FRenames.OnApply := ApplyRename;
  FRenames.OnSettled := RenameSettled;
  FUndoStack := TUndoStack.Create;
  FUndoStack.OnCapture := CaptureDocument;
  FUndoStack.OnRestore := RestoreDocument;
  FUndoStack.OnStepUndone := StepUndone;
  FUndoStack.OnStepRedone := StepRedone;
  FSurfaceMenu := TPopupMenu.Create(Self);
  BuildPanes;
  RestoreLayout;
  UpdateCaption;
end;

procedure TMainDesignerForm.FormDestroy(Sender: TObject);
begin
  // Before anything is torn down: the sizes are read off the panes and the
  // window handle.
  if FInspector <> nil then
    KeepLayout;
  // Also here: a window freed outright, as the core ends them, never runs
  // FormClose.
  SayClosing;
  if FUndoStack <> nil then
    CloseDocument;
  // Also here: CloseDocument above is skipped after a failed construction.
  EndCoupling;
  FUndoStack.Free;
  FRenames.Free;
  if FPalette <> nil then
    FPalette.DropDynamicItems;
  if FMessages <> nil then
    FMessages.Attach(nil, nil);
  FLog.Free;
end;

procedure TMainDesignerForm.BuildPanes;
begin
  FPalette := TPaletteFrame.Create(Self);
  FPalette.Parent := PaletteZone;
  FPalette.Align := alClient;
  FPalette.Log := FLog;

  FInspector := TInspectorFrame.Create(Self);
  FInspector.Parent := InspectorZone;
  FInspector.Align := alClient;

  FMessages := TMessagesFrame.Create(Self);
  FMessages.Parent := MessagesZone;
  FMessages.Align := alClient;
  FMessages.Attach(FSessionLog, FLog);
end;

function TMainDesignerForm.CurrentLayout: TDesignerLayout;
var
  Placement: TWindowPlacement;
begin
  Result.PaletteWidth := PaletteZone.Width;
  Result.InspectorWidth := InspectorZone.Width;
  Result.InspectorTreeHeight := FInspector.TreeHeight;
  Result.MessagesHeight := MessagesZone.Height;
  Result.WindowWidth := Width;
  Result.WindowHeight := Height;
  Result.WindowMaximized := WindowState = wsMaximized;
  if not HandleAllocated then
    Exit;
  Placement.length := SizeOf(Placement);
  if not GetWindowPlacement(Handle, Placement) then
    Exit;
  Result.WindowWidth := Placement.rcNormalPosition.Width;
  Result.WindowHeight := Placement.rcNormalPosition.Height;
  // A minimized window reports SW_SHOWMINIMIZED; what it restores to is in
  // Placement.flags.
  Result.WindowMaximized := (Placement.showCmd = SW_SHOWMAXIMIZED) or
    ((Placement.showCmd = SW_SHOWMINIMIZED) and
     ((Placement.flags and WPF_RESTORETOMAXIMIZED) <> 0));
end;

function TMainDesignerForm.OwnsItsSize: Boolean;
begin
  Result := (Parent = nil) and (ParentWindow = 0);
end;

procedure TMainDesignerForm.RestoreLayout;
var
  Store: TLayoutStore;
  Layout: TDesignerLayout;

  function Fitted(AWanted, ARoom: Integer): Integer;
  begin
    Result := Min(AWanted, Max(ScaleValue(MinPaneSize), ARoom));
  end;

begin
  Store := TLayoutStore.Create(SettingsKey(LayoutSettingsKey));
  try
    Layout := Store.Load(CurrentLayout, CurrentPPI);
    if Store.LastError <> '' then
      FLog.AddFmt(lsWarn, 'the kept window layout could not be read (%s) - ' +
        'the panes start where the designer puts them', [Store.LastError]);
  finally
    Store.Free;
  end;
  if OwnsItsSize then
  begin
    Width := Min(Layout.WindowWidth, Screen.WorkAreaWidth);
    Height := Min(Layout.WindowHeight, Screen.WorkAreaHeight);
    if Layout.WindowMaximized then
      WindowState := wsMaximized;
  end;
  PaletteZone.Width := Fitted(Layout.PaletteWidth,
    Width - ScaleValue(MinSurfaceWidth));
  InspectorZone.Width := Fitted(Layout.InspectorWidth,
    Width - PaletteZone.Width - ScaleValue(MinSurfaceWidth));
  MessagesZone.Height := Fitted(Layout.MessagesHeight,
    Height - ScaleValue(MinSurfaceHeight));
  FInspector.TreeHeight := Fitted(Layout.InspectorTreeHeight,
    Height - MessagesZone.Height - ScaleValue(MinTabsHeight));
end;

procedure TMainDesignerForm.KeepLayout;
var
  Store: TLayoutStore;
  Layout, Kept: TDesignerLayout;
begin
  Layout := CurrentLayout;
  Store := TLayoutStore.Create(SettingsKey(LayoutSettingsKey));
  try
    if not OwnsItsSize then
    begin
      Kept := Store.Load(Layout, CurrentPPI);
      Layout.WindowWidth := Kept.WindowWidth;
      Layout.WindowHeight := Kept.WindowHeight;
      Layout.WindowMaximized := Kept.WindowMaximized;
    end;
    Store.Save(Layout, CurrentPPI);
    if Store.LastError <> '' then
      FLog.AddFmt(lsWarn, 'the window layout could not be kept: %s',
        [Store.LastError]);
  finally
    Store.Free;
  end;
end;

// WM_SETREDRAW goes to the zones, not to the window: a message dialog must
// still paint over a window that repaints normally.
procedure TMainDesignerForm.HoldPanesStill(AHold: Boolean);
const
  Painting: array [Boolean] of WPARAM = (1, 0);

  procedure Hold(AZone: TWinControl);
  begin
    if not AZone.HandleAllocated then
      Exit;
    SendMessage(AZone.Handle, WM_SETREDRAW, Painting[AHold], 0);
    if not AHold then
      RedrawWindow(AZone.Handle, nil, 0,
        RDW_INVALIDATE or RDW_ERASE or RDW_ALLCHILDREN);
  end;

begin
  Hold(DesignSurfaceBox);
  Hold(InspectorZone);
end;

procedure TMainDesignerForm.ReleaseDocument;
begin
  if FPalette <> nil then
    FPalette.Attach(nil);
  if FInspector <> nil then
    FInspector.Attach(nil);
  if FIconSurface <> nil then
    FIconSurface.Attach(nil);
  // The designer is freed before the host form that holds its hook.
  FreeAndNil(FDesigner);
  FreeAndNil(FIconSurface);
  FreeDesignDocument(FDocument);
end;

procedure TMainDesignerForm.CloseDocument;
begin
  ReleaseDocument;
  EndCoupling;
  FRenames.Clear;
  FUndoStack.Clear;
  FSourceFiles := nil;
  FFileName := '';
  FGuardLifted := False;
  HideGuardBanner;
  FVersion := 0;
  FKeptVersion := NothingKept;
  FSettled := False;
end;

procedure TMainDesignerForm.PresentDocument(const AState: TLoadedFormState);
begin
  case FRootKind of
    drForm:
      EmbedDesignedForm(FDocument.HostForm, DesignSurfaceBox, AState);
    drFrame:
      EmbedDesignedFrame(FDocument, DesignSurfaceBox);
    drDataModule:
      begin
        FIconSurface := TIconSurface.Create(Self);
        FIconSurface.Parent := DesignSurfaceBox;
        FIconSurface.SizeFor(TDataModule(FDocument.Root));
        FIconSurface.Attach(FDesigner);
      end;
  end;
end;

// Windows refreshes the region it routes mouse input through on a region set
// or a resize, but not on a pure move; SWP_FRAMECHANGED re-applies it.
procedure TMainDesignerForm.RenewInputMapping;

  procedure Renew(AWindow: HWND);
  begin
    SetWindowPos(AWindow, 0, 0, 0, 0, 0, SWP_FRAMECHANGED or SWP_NOMOVE or
      SWP_NOSIZE or SWP_NOZORDER or SWP_NOACTIVATE or SWP_NOOWNERZORDER);
  end;

begin
  Renew(Handle);
  if (FDocument.HostForm <> nil) and FDocument.HostForm.HandleAllocated then
    Renew(FDocument.HostForm.Handle);
end;

procedure TMainDesignerForm.WMEnterSizeMove(var Message: TMessage);
begin
  FInSizeMove := True;
  inherited;
end;

procedure TMainDesignerForm.WMExitSizeMove(var Message: TMessage);
begin
  FInSizeMove := False;
  inherited;
  RenewInputMapping;
end;

procedure TMainDesignerForm.WMWindowPosChanged(var Message: TWMWindowPosChanged);
begin
  inherited;
  // The renewal passes SWP_NOMOVE, so it cannot re-enter here.
  if FInSizeMove or not HandleAllocated or not IsWindowVisible(Handle) then
    Exit;
  if ((Message.WindowPos^.flags and SWP_NOMOVE) = 0) or
     ((Message.WindowPos^.flags and SWP_SHOWWINDOW) <> 0) then
    RenewInputMapping;
end;

procedure TMainDesignerForm.BuildDocument(ALoader: TFormLoader);
begin
  FRootKind := ALoader.RootKind;
  FDocument := CreateDesignDocument(FRootKind);
  // The designer must exist before streaming: design-time scaling reads the
  // design PPI from it while the root's properties are streamed.
  FDesigner := TFormDesigner.Create(FDocument.HostForm, FDocument.Root, FLog);
  FDesigner.UndoStack := FUndoStack;
  FDesigner.OnDirtyChanged := DesignerDirtyChanged;
  FDesigner.OnSaved := DesignerSaved;
  FDesigner.OnModified := DesignerModified;
  FDesigner.OnSaveRequest := DesignerSaveRequested;
  FDesigner.OnUndoRequest := DesignerUndoRequested;
  FDesigner.OnRedoRequest := DesignerRedoRequested;
  FDesigner.OnContextMenu := DesignerContextMenu;
  FDesigner.OnComponentsChanged := DocumentComponentsChanged;
  FDesigner.OnCouplingQuery := AskCoupling;
  FDesigner.OnRenameRequest := StartRename;
  FDesigner.OnRenameQuery := RenameInFlight;
  FDesigner.CodeCoupling := FCoupling;
  ALoader.StreamInto(FDocument.Root);
  FDesigner.AttachLoaded(FFileName, ALoader.ExtractEventMap,
    ALoader.ExtractPreserved, ALoader.ExtractFrames, ALoader.ExtractAncestor,
    ALoader.LoadedState);
  FDesigner.AdoptLinkedModules(ALoader.ExtractLinkedModules);
  // Guarded before the inspector attaches, so that its grids come up
  // read-only; a save could otherwise drop the lines the load left unresolved.
  if (Length(ALoader.UnresolvedReferences) > 0) and not FGuardLifted then
  begin
    FDesigner.GuardReadOnly;
    ShowGuardBanner(ALoader.UnresolvedReferences);
  end
  else
    HideGuardBanner;
  FSourceFiles := ALoader.SourceFiles;
  PresentDocument(ALoader.LoadedState);
  // After PresentDocument: a data module's placeholders are parented onto the
  // icon canvas, which exists only from there on.
  FDesigner.ShowPlaceholders;
  FDesigner.BeginEditing;
  FInspector.Attach(FDesigner);
  FPalette.Attach(FDesigner);
  if FCouplingObject = nil then
    Exit;
  FCouplingObject.RootClass := FDesigner.RootClassName;
  // Seeds the ledger of a document opened into an already-coupled window,
  // where the coupling flag does not move. The baseline check keeps an undo
  // rebuild from reseeding it.
  if FCodeCouplingAvailable and not FCouplingObject.Ledger.HasBaseline then
    FCouplingObject.Resume(FDesigner.DesignedFields);
end;

procedure TMainDesignerForm.OpenDesignFile(const AFileName: string;
  AQuietly: Boolean);
var
  Loader: TFormLoader;
begin
  CloseDocument;
  FFileName := AFileName;
  BeginCoupling;
  Loader := TFormLoader.Create(FLog);
  try
    try
      Loader.Prepare(AFileName);
      BuildDocument(Loader);
      FDesigner.LogDpi;
    except
      on E: Exception do
      begin
        FLog.AddFmt(lsError, '%s: %s', [E.ClassName, E.Message]);
        if not AQuietly then
          MessageDlg(E.Message, mtError, [mbOK], 0);
        CloseDocument;
      end;
    end;
  finally
    Loader.Free;
  end;
  UpdateCaption;
end;

procedure TMainDesignerForm.OpenRecovered(const AFileName, ARecoveryFile,
  ARootClassName: string; ARootKind: TDesignRootClass);
var
  Loader: TFormLoader;
  State: TLoadedFormState;
begin
  CloseDocument;
  FFileName := AFileName;
  BeginCoupling;
  State := Default(TLoadedFormState);
  State.RootClassName := ARootClassName;
  State.RootKind := ARootKind;
  Loader := TFormLoader.Create(FLog);
  try
    try
      FLog.AddFmt(lsInfo, 'recovering %s from an earlier session''s copy',
        [AFileName]);
      Loader.PrepareRecovered(ARecoveryFile, State, AFileName);
      BuildDocument(Loader);
      FDesigner.LogDpi;
      // Dirty from the start: no state in the history matches the file on
      // disk, so an undo to the bottom must not read as saved.
      FUndoStack.MarkNeverSaved;
      FDesigner.MarkDirty(True);
    except
      on E: Exception do
      begin
        FLog.AddFmt(lsError, '%s: %s', [E.ClassName, E.Message]);
        MessageDlg(Format('%s could not be recovered:'#13#10'%s',
          [ExtractFileName(AFileName), E.Message]), mtError, [mbOK], 0);
        CloseDocument;
      end;
    end;
  finally
    Loader.Free;
  end;
  UpdateCaption;
end;

procedure TMainDesignerForm.WriteDocumentTo(const APath: string);
begin
  FDesigner.WriteTo(APath);
end;

function TMainDesignerForm.RootClassName: string;
begin
  Result := '';
  if FDesigner <> nil then
    Result := FDesigner.RootClassName;
end;

function TMainDesignerForm.NeedsKeeping: Boolean;
begin
  Result := IsDirty and (FKeptVersion <> FVersion) and
    not FDesigner.GestureInFlight;
end;

procedure TMainDesignerForm.MarkKept;
begin
  FKeptVersion := FVersion;
end;

procedure TMainDesignerForm.MarkSettled;
begin
  FSettled := True;
end;

procedure TMainDesignerForm.ShowGuardBanner(const AUnresolved: TArray<string>);
const
  BannerFace = TColor($006BC7F2); // amber (BGR)
  BannerText = TColor($00203040);
var
  Modules: TStringList;
  Reference: string;
  Dot: Integer;
begin
  if FGuardBanner = nil then
  begin
    FGuardBanner := TPanel.Create(Self);
    FGuardBanner.Parent := DesignSurfaceBox.Parent;
    FGuardBanner.Align := alTop;
    FGuardBanner.Height :=
      MulDiv(32, Screen.PixelsPerInch, USER_DEFAULT_SCREEN_DPI);
    FGuardBanner.BevelOuter := bvNone;
    FGuardBanner.ParentBackground := False;
    FGuardBanner.Color := BannerFace;
    // A VCL style must not repaint the alert color.
    FGuardBanner.StyleElements := [];
    FGuardButton := TButton.Create(Self);
    FGuardButton.Parent := FGuardBanner;
    FGuardButton.Caption := 'Edit anyway';
    FGuardButton.Align := alRight;
    FGuardButton.AlignWithMargins := True;
    FGuardButton.Margins.SetBounds(4, 4, 4, 4);
    FGuardButton.Width :=
      MulDiv(90, Screen.PixelsPerInch, USER_DEFAULT_SCREEN_DPI);
    FGuardButton.OnClick := GuardLiftClick;
    FGuardLabel := TLabel.Create(Self);
    FGuardLabel.Parent := FGuardBanner;
    FGuardLabel.Align := alClient;
    FGuardLabel.AlignWithMargins := True;
    FGuardLabel.Margins.SetBounds(8, 0, 8, 0);
    FGuardLabel.Layout := tlCenter;
    FGuardLabel.EllipsisPosition := epEndEllipsis;
    FGuardLabel.Font.Color := BannerText;
    FGuardLabel.StyleElements := [];
  end;
  Modules := TStringList.Create;
  try
    Modules.CaseSensitive := False;
    Modules.Duplicates := dupIgnore;
    Modules.Sorted := True;
    for Reference in AUnresolved do
    begin
      Dot := Pos('.', Reference);
      if Dot > 1 then
        Modules.Add(Copy(Reference, 1, Dot - 1));
    end;
    FGuardLabel.Caption := Format('Read-only: %d reference(s) into %s did ' +
      'not resolve. Editing is off so a save cannot drop them - see Messages.',
      [Length(AUnresolved), string.Join(', ', Modules.ToStringArray)]);
  finally
    Modules.Free;
  end;
  FGuardBanner.Visible := True;
end;

procedure TMainDesignerForm.HideGuardBanner;
begin
  if FGuardBanner <> nil then
    FGuardBanner.Visible := False;
end;

procedure TMainDesignerForm.GuardLiftClick(Sender: TObject);
begin
  FGuardLifted := True;
  if FDesigner <> nil then
    FDesigner.LiftGuard;
  HideGuardBanner;
  if FInspector <> nil then
    FInspector.RefreshRows;
  UpdateCaption;
end;

procedure TMainDesignerForm.UpdateCaption;
var
  Title: string;
begin
  if FFileName = '' then
    Title := 'Vallenta Designer'
  else
  begin
    Title := Format('%s [%s] - Vallenta Designer',
      [ExtractFileName(FFileName), RootKindName(FRootKind)]);
    if (FDesigner <> nil) and FDesigner.Guarded then
      Title := Title + ' [read-only]';
    if IsDirty then
      Title := Title + ' *';
  end;
  Caption := Title;
  if Assigned(FOnDocumentChanged) then
    FOnDocumentChanged(Self);
  if IsDirty <> FReportedDirty then
  begin
    FReportedDirty := IsDirty;
    if Assigned(FOnDocumentDirtyChanged) then
      FOnDocumentDirtyChanged(Self);
  end;
end;

function TMainDesignerForm.IsDirty: Boolean;
begin
  Result := (FDesigner <> nil) and FDesigner.Dirty;
end;

function TMainDesignerForm.MayClose: Boolean;
begin
  Result := (FDesigner = nil) or FDesigner.ConfirmClose;
end;

procedure TMainDesignerForm.DesignerDirtyChanged(Sender: TObject);
begin
  UpdateCaption;
end;

// Idempotent: a menu close runs FormClose and the destruction after it, and
// the same document must not be reported twice.
procedure TMainDesignerForm.SayClosing;
begin
  if FClosingSaid then
    Exit;
  FClosingSaid := True;
  if Assigned(FOnDocumentClosing) then
    FOnDocumentClosing(Self);
end;

// Settle runs before OnDocumentSaved: the session must hold the field changes
// before the save is announced.
procedure TMainDesignerForm.DesignerSaved(Sender: TObject);
begin
  if (FCouplingObject <> nil) and (FDesigner <> nil) and
     (FCouplingObject.Settle(FDesigner.DesignedFields) = soUncoupled) then
    FLog.Add(lsWarn, 'saved without code coupling - the form fields are ' +
      'synchronized when VS Code reconnects');
  if Assigned(FOnDocumentSaved) then
    FOnDocumentSaved(Self);
end;

procedure TMainDesignerForm.DesignerModified(Sender: TObject);
begin
  Inc(FVersion);
end;

procedure TMainDesignerForm.DesignerSaveRequested(Sender: TObject);
begin
  SaveAction.Execute;
end;

// A component editor verb named '-' is the separator convention and is added
// to the menu unchanged.
procedure TMainDesignerForm.DesignerContextMenu(Sender: TObject);
var
  Verbs: TArray<string>;
  I: Integer;
  Item, ControlMenu: TMenuItem;
  At: TPoint;

  function Added(const ACaption: string): TMenuItem;
  begin
    Result := TMenuItem.Create(FSurfaceMenu);
    Result.Caption := ACaption;
    FSurfaceMenu.Items.Add(Result);
  end;

  procedure AddedUnder(AParent: TMenuItem; AAction: TBasicAction);
  var
    Entry: TMenuItem;
  begin
    Entry := TMenuItem.Create(FSurfaceMenu);
    Entry.Action := AAction;
    AParent.Add(Entry);
  end;

begin
  if FDesigner = nil then
    Exit;
  FSurfaceMenu.Items.Clear;
  Verbs := FDesigner.ComponentVerbs;
  for I := 0 to High(Verbs) do
  begin
    Item := Added(Verbs[I]);
    Item.Tag := I;
    Item.OnClick := SurfaceVerbClicked;
  end;
  if Length(Verbs) > 0 then
    Added('-');
  Added('').Action := CutAction;
  Added('').Action := CopyAction;
  Added('').Action := PasteAction;
  Added('-');
  ControlMenu := Added('Control');
  AddedUnder(ControlMenu, BringToFrontAction);
  AddedUnder(ControlMenu, SendToBackAction);
  Added('-');
  Added('').Action := AlignAction;
  Added('').Action := SizeAction;
  Added('').Action := TabOrderAction;
  Added('').Action := CreationOrderAction;
  Added('-');
  Item := Added('Delete');
  Item.OnClick := SurfaceDeleteClicked;
  // The action states are otherwise refreshed on idle, and on a fast
  // right-click no idle cycle runs between the press that selects and this
  // menu.
  UpdateActionStates;
  At := Mouse.CursorPos;
  FSurfaceMenu.Popup(At.X, At.Y);
end;

procedure TMainDesignerForm.CutActionExecute(Sender: TObject);
begin
  if FDesigner <> nil then
    FDesigner.CutSelection;
end;

procedure TMainDesignerForm.CopyActionExecute(Sender: TObject);
begin
  if FDesigner <> nil then
    FDesigner.CopySelection;
end;

procedure TMainDesignerForm.PasteActionExecute(Sender: TObject);
begin
  if FDesigner <> nil then
    FDesigner.PasteFromClipboard;
end;

procedure TMainDesignerForm.BringToFrontActionExecute(Sender: TObject);
begin
  if FDesigner <> nil then
    FDesigner.RestackSelection(zsToFront);
end;

procedure TMainDesignerForm.SendToBackActionExecute(Sender: TObject);
begin
  if FDesigner <> nil then
    FDesigner.RestackSelection(zsToBack);
end;

procedure TMainDesignerForm.SurfaceVerbClicked(Sender: TObject);
begin
  if FDesigner <> nil then
    FDesigner.RunComponentVerb((Sender as TMenuItem).Tag);
end;

procedure TMainDesignerForm.SurfaceDeleteClicked(Sender: TObject);
begin
  if FDesigner <> nil then
    FDesigner.DeleteSelection;
end;

procedure TMainDesignerForm.DesignerUndoRequested(Sender: TObject);
begin
  PostMessage(Handle, WM_PERFORMUNDO, 0, 0);
end;

procedure TMainDesignerForm.DesignerRedoRequested(Sender: TObject);
begin
  PostMessage(Handle, WM_PERFORMREDO, 0, 0);
end;

procedure TMainDesignerForm.PerformUndo(var Message: TMessage);
begin
  FUndoStack.Undo;
end;

procedure TMainDesignerForm.PerformRedo(var Message: TMessage);
begin
  FUndoStack.Redo;
end;

// A step is recorded before its edit is applied, so a failed capture must not
// abort the edit; it is logged and returns nil, which the history discards.
function TMainDesignerForm.CaptureDocument(Sender: TObject): TDocumentSnapshot;
begin
  Result := nil;
  if FDesigner = nil then
    Exit;
  try
    Result := FDesigner.CaptureSnapshot;
  except
    on E: Exception do
      FLog.AddFmt(lsError, 'this step cannot be undone - recording the ' +
        'document state failed: %s: %s', [E.ClassName, E.Message]);
  end;
end;

// The document is rebuilt rather than patched in place: only a fresh stub at
// class defaults reverts a property the image does not mention.
procedure TMainDesignerForm.RestoreDocument(Sender: TObject;
  ASnapshot: TDocumentSnapshot);
var
  Loader: TFormLoader;
  State: TLoadedFormState;
begin
  if (FDesigner = nil) or (ASnapshot = nil) then
    Exit;
  State := FDesigner.LoadedState;
  Loader := TFormLoader.Create(FLog);
  try
    try
      Loader.PrepareFromSnapshot(ASnapshot.Data, State, FFileName);
      // The hold is released in the finally before any failure is reported,
      // so the message dialog paints over panes that repaint again.
      HoldPanesStill(True);
      try
        ReleaseDocument;
        BuildDocument(Loader);
        // AdoptPreserved frees the model it replaces; the snapshot must keep
        // its own for a later restore.
        FDesigner.AdoptPreserved(ASnapshot.Preserved.Clone);
        FDesigner.SelectComponent(FDesigner.ComponentNamed(ASnapshot.SelectionName));
        FDesigner.MarkDirty(FUndoStack.IsDirty);
      finally
        HoldPanesStill(False);
      end;
      // A restore does not reach DesignerModified, so the version counter is
      // advanced here.
      Inc(FVersion);
    except
      on E: Exception do
      begin
        FLog.AddFmt(lsError, 'the document could not be restored: %s: %s',
          [E.ClassName, E.Message]);
        MessageDlg(E.Message, mtError, [mbOK], 0);
        CloseDocument;
      end;
    end;
  finally
    Loader.Free;
  end;
  UpdateCaption;
  SettleFields;
end;

procedure TMainDesignerForm.SaveActionExecute(Sender: TObject);
begin
  if (FDesigner <> nil) and FDesigner.Save then
    FUndoStack.MarkSaved;
end;

procedure TMainDesignerForm.UndoActionExecute(Sender: TObject);
begin
  if FDesigner <> nil then
    FDesigner.RequestUndo;
end;

procedure TMainDesignerForm.RedoActionExecute(Sender: TObject);
begin
  if FDesigner <> nil then
    FDesigner.RequestRedo;
end;

procedure TMainDesignerForm.AlignActionExecute(Sender: TObject);
var
  Horizontal: TAlignHorizontal;
  Vertical: TAlignVertical;
begin
  if (FDesigner <> nil) and ExecuteAlignDialog(Horizontal, Vertical) then
    FDesigner.AlignSelection(Horizontal, Vertical);
end;

procedure TMainDesignerForm.SizeActionExecute(Sender: TObject);
var
  MatchWidth, MatchHeight: TSizeMatch;
begin
  if (FDesigner <> nil) and ExecuteSizeDialog(MatchWidth, MatchHeight) then
    FDesigner.SizeSelection(MatchWidth, MatchHeight);
end;

function TabOrderContainer(ADesigner: TFormDesigner): TWinControl;
var
  Selected: TComponent;
begin
  Selected := ADesigner.Selected;
  if (Selected is TWinControl) and (csAcceptsControls in
    TWinControl(Selected).ControlStyle) then
    Result := TWinControl(Selected)
  else if (Selected is TControl) and (TControl(Selected).Parent <> nil) then
    Result := TControl(Selected).Parent
  else if ADesigner.Root is TWinControl then
    Result := TWinControl(ADesigner.Root)
  else
    Result := nil;
end;

procedure TMainDesignerForm.TabOrderActionExecute(Sender: TObject);
var
  Container: TWinControl;
  Child: TControl;
  Items, Order: TArray<TComponent>;
  Swapped: TComponent;
  I, J: Integer;
begin
  if FDesigner = nil then
    Exit;
  Container := TabOrderContainer(FDesigner);
  if Container = nil then
    Exit;
  for I := 0 to Container.ControlCount - 1 do
  begin
    Child := Container.Controls[I];
    if (Child is TWinControl) and (Child.Owner = FDesigner.Root) then
      Items := Items + [Child];
  end;
  // Container.Controls is in parenting order, not tab order.
  for I := 1 to High(Items) do
    for J := I downto 1 do
      if TWinControl(Items[J]).TabOrder < TWinControl(Items[J - 1]).TabOrder then
      begin
        Swapped := Items[J];
        Items[J] := Items[J - 1];
        Items[J - 1] := Swapped;
      end;
  if Length(Items) < 2 then
  begin
    FLog.AddFmt(lsInfo, '%s contains no components to order', [Container.Name]);
    Exit;
  end;
  if ExecuteOrderDialog('Tab Order',
    Format('The order the controls in %s are tabbed through:', [Container.Name]),
    Items, Order) then
    FDesigner.ApplyTabOrder(Order);
end;

procedure TMainDesignerForm.CreationOrderActionExecute(Sender: TObject);
var
  Component: TComponent;
  Items, Order: TArray<TComponent>;
  I: Integer;
begin
  if FDesigner = nil then
    Exit;
  for I := 0 to FDesigner.Root.ComponentCount - 1 do
  begin
    Component := FDesigner.Root.Components[I];
    if IsNonVisual(Component) then
      Items := Items + [Component];
  end;
  if Length(Items) < 2 then
  begin
    FLog.Add(lsInfo, 'fewer than two nonvisual components - there is no ' +
      'creation order to edit');
    Exit;
  end;
  if ExecuteOrderDialog('Creation Order',
    'The order the components without a window are created in:', Items, Order) then
    FDesigner.ApplyCreationOrder(Order);
end;

procedure TMainDesignerForm.CloseWindowActionExecute(Sender: TObject);
begin
  Close;
end;

procedure TMainDesignerForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := MayClose;
end;

// Close only posts the release, so the window lives on until that message is
// dispatched. Listeners are told here, not at destruction: an open arriving in
// between must not find this document and reveal a window that is already
// closing.
procedure TMainDesignerForm.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  Action := caFree;
  // FormCloseQuery let this through, so the unsaved changes were answered for.
  MarkSettled;
  SayClosing;
end;

procedure TMainDesignerForm.FormActivate(Sender: TObject);
begin
  if Assigned(FOnDocumentActivated) then
    FOnDocumentActivated(Self);
end;

procedure TMainDesignerForm.ToggleZone(Zone: TPanel; Splitter: TSplitter);
begin
  Zone.Visible := not Zone.Visible;
  Splitter.Visible := Zone.Visible;
end;

procedure TMainDesignerForm.TogglePaletteActionExecute(Sender: TObject);
begin
  ToggleZone(PaletteZone, PaletteSplitter);
end;

procedure TMainDesignerForm.ToggleInspectorActionExecute(Sender: TObject);
begin
  ToggleZone(InspectorZone, InspectorSplitter);
end;

procedure TMainDesignerForm.ToggleMessagesActionExecute(Sender: TObject);
begin
  ToggleZone(MessagesZone, MessagesSplitter);
end;

procedure TMainDesignerForm.PackagesActionExecute(Sender: TObject);
begin
  if ExecutePackageManager then
    FLog.Add(lsInfo, 'the package settings were written - they take effect ' +
      'the next time the designer starts (after Exit in the tray menu)');
end;

procedure TMainDesignerForm.ActionListUpdate(Action: TBasicAction;
  var Handled: Boolean);
begin
  UpdateActionStates;
end;

procedure TMainDesignerForm.UpdateActionStates;
begin
  SaveAction.Enabled := IsDirty;
  UndoAction.Enabled := (FDesigner <> nil) and FUndoStack.CanUndo;
  RedoAction.Enabled := (FDesigner <> nil) and FUndoStack.CanRedo;
  CopyAction.Enabled := (FDesigner <> nil) and FDesigner.CanCopySelection;
  CutAction.Enabled := CopyAction.Enabled and (FDesigner <> nil) and
    not FDesigner.Guarded;
  PasteAction.Enabled := (FDesigner <> nil) and FDesigner.CanPaste;
  AlignAction.Enabled := (FDesigner <> nil) and (FDesigner.SelectionCount > 1);
  SizeAction.Enabled := AlignAction.Enabled;
  BringToFrontAction.Enabled := (FDesigner <> nil) and
    FDesigner.CanRestackSelection;
  SendToBackAction.Enabled := BringToFrontAction.Enabled;
  TabOrderAction.Enabled := FDesigner <> nil;
  CreationOrderAction.Enabled := FDesigner <> nil;
  TogglePaletteAction.Checked := PaletteZone.Visible;
  ToggleInspectorAction.Checked := InspectorZone.Visible;
  ToggleMessagesAction.Checked := MessagesZone.Visible;
end;

end.
