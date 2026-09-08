// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Shell.Core;

// The resident designer process: holds the document windows, the process-wide
// session log, the session registry and the recovery journal, and stays
// running with the packages loaded after its last window closed. It is never
// shown and is reached through its tray icon; the tray Exit item and the
// orphan watch are the two paths that end the message loop.
//
// Main thread only: the listener's connection threads reach the session
// handlers through TThread.Synchronize. Shutdown must run after the message
// loop ends - unloading the packages from inside a handler would tear down
// the loop that dispatched it.

interface

uses
  System.Types,
  System.Classes,
  System.Generics.Collections,
  Vcl.Forms,
  Vcl.ExtCtrls,
  Vcl.Menus,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Core.Recovery,
  Vallenta.FormEditor.Core.SingleInstance,
  Vallenta.FormEditor.Core.Sessions,
  Vallenta.FormEditor.Shell.MainWindow,
  Vallenta.FormEditor.Shell.RecoveryDialog;

type
  // Application main form, created with CreateNew and never shown. Creates and
  // frees the document windows, the session registry and the recovery journal.
  TDesignerCore = class(TForm)
  private
    FSessionLog: TDesignLog;
    FWindows: TList<TMainDesignerForm>;
    FTray: TTrayIcon;
    FMenu: TPopupMenu;
    FInFront: TMainDesignerForm;
    FSweeping: Boolean;
    FShutDown: Boolean;
    FListener: TCoreListener;
    FSessions: TSessionRegistry;
    FEnding: Boolean;
    FJournal: TRecoveryJournal;
    FKeeper: TTimer;
    FOfferBeat: TTimer;
    FSessionBeat: TTimer;
    FServeStart: Boolean;
    FOrphan: TOrphanWatch;
    FOrphanBeats: Integer;
    function RoutedOpen(const AFileName: string;
      out AReason: string): TOpenOutcome;
    function OpenFor(ASession: Integer; const AFileName: string;
      out AReason: string): TOpenOutcome;
    function SessionAttached(const ADetails: TAttachDetails;
      const AOutbox: ISessionOutbox; out AReason: string): Integer;
    function SessionRequested(ASession: Integer; const ACommand: string;
      AMessage: TWireMessage; var AFields: TWireFields;
      out AReason: string): Boolean;
    procedure SessionAnswered(ASession: Integer; AMessage: TWireMessage);
    procedure SessionEnded(ASession: Integer);
    function SessionOpen(ASession: Integer; const AFileName: string;
      var AFields: TWireFields; out AReason: string): Boolean;
    function SessionFocus(const AFileName: string; out AReason: string): Boolean;
    function SessionClose(const AFileName: string; out AReason: string): Boolean;
    function SessionReload(const AFileName: string; out AReason: string): Boolean;
    procedure SessionTick(Sender: TObject);
    procedure OrphanTick;
    procedure RefreshCoupling;
    procedure Announce(AWindow: TMainDesignerForm; const AEvent: string;
      const AFields: TWireFields);
    procedure AnnounceOpened(AWindow: TMainDesignerForm);
    procedure ListenerFailed(Sender: TObject);
    procedure ListenerComplained(Sender: TObject; const AReason: string);
    procedure StopListening;
    procedure StartKeeping;
    procedure KeeperTick(Sender: TObject);
    function RefreshJournal(AWindow: TMainDesignerForm): Boolean;
    procedure OfferTick(Sender: TObject);
    procedure OfferRecovery;
    procedure CarryOutRecovery(const AEntry: TRecoveryEntry;
      AChoice: TRecoveryChoice; out AReason: string);
    function NewWindow: TMainDesignerForm;
    function Adopt(var AWindow: TMainDesignerForm): Boolean;
    procedure NoteRelatedDocuments(ANewcomer: TMainDesignerForm);
    function RecoverDocument(const AEntry: TRecoveryEntry;
      out AReason: string): TMainDesignerForm;
    procedure BuildTray;
    procedure MenuPopup(Sender: TObject);
    procedure DocumentClicked(Sender: TObject);
    procedure ExitClicked(Sender: TObject);
    procedure TrayDoubleClicked(Sender: TObject);
    procedure DocumentActivated(Sender: TObject);
    procedure DocumentChanged(Sender: TObject);
    procedure DocumentDirtyChanged(Sender: TObject);
    procedure DocumentSaved(Sender: TObject);
    procedure DocumentClosing(Sender: TObject);
    function StatusLine: string;
    function DialogIsOpen: Boolean;
    function WindowHolding(const AFileName: string): TMainDesignerForm;
    function FrontWindowBounds(out ABounds: TRect): Boolean;
    procedure Reveal(AWindow: TMainDesignerForm);
    procedure ShowStatus;
    procedure LetGoOfEveryWindow;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Opens AFileName in its own window, or reveals the window already holding
    // it; the name is expanded and matched case-insensitively. Nil when the
    // load failed or the designer is closing. AQuietly suppresses the error
    // message box.
    function OpenDocument(const AFileName: string;
      AQuietly: Boolean = False): TMainDesignerForm;
    // Asks every window whether it may close, then frees them all. One refusal
    // aborts and leaves every window open, including those already asked; a
    // call made while a sweep is running returns False without asking.
    function CloseEveryDocument: Boolean;
    // Publishes the request handlers on AListener and starts serving; only the
    // holder of the single-instance claim may pass one, since two servers must
    // never answer to one pipe name. A connection made before this call waits
    // for a bounded time instead of being refused at once. Shutdown frees
    // AListener; the caller must not free it after this call.
    procedure TakeHandovers(AListener: TCoreListener);
    // Stops the listener, frees every document, unloads the packages and
    // releases the single-instance claim, in that order so nothing names a
    // package class during the unload. Runs after the message loop ends;
    // repeated calls do nothing.
    procedure Shutdown;
    // Process-wide log, shown in every window's messages pane together with
    // that document's own log; freed with the core, after the last window.
    property SessionLog: TDesignLog read FSessionLog;
    // True when the process was started with --serve rather than with a form
    // file; set before the message loop starts. A --serve core that never had
    // a session ends itself once idle, a plain start does not.
    property ServeStarted: Boolean read FServeStart write FServeStart;
  end;

var
  // The one core of this process; nil until the project file creates it.
  DesignerCore: TDesignerCore;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.StrUtils,
  System.UITypes,
  Vcl.Dialogs,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Streaming.RootClassifier,
  Vallenta.FormEditor.DesignTime.Environment,
  Vallenta.FormEditor.Core.Settings,
  Vallenta.FormEditor.Packages.Host;

const
  // Settings sub-key, timer intervals and limits of the core; OfferDelay and
  // SessionBeat are in milliseconds.
  RecoverySettingsKey = 'Recovery';
  OfferDelay = 500;
  SessionBeat = 1000;
  // Session beats between two orphan checks.
  OrphanEvery = 10;
  // Entry limit for the session log; only info lines are dropped, oldest
  // first, so warnings and errors can hold the count above it.
  SessionLogLimit = 2000;

constructor TDesignerCore.Create(AOwner: TComponent);
begin
  // CreateNew, not Create: this form has no DFM resource to load.
  inherited CreateNew(AOwner);
  FSessionLog := TDesignLog.Create;
  FSessionLog.Limit := SessionLogLimit;
  FWindows := TList<TMainDesignerForm>.Create;
  // Must exist before TakeHandovers and before the first window; both use it.
  FSessions := TSessionRegistry.Create;
  FSessions.Log := FSessionLog;
  BuildTray;
  UseWindowBounds(FrontWindowBounds);
  ReportInto(FSessionLog);
  FSessionLog.AddFmt(lsInfo, 'the inspector reads its rows from %s',
    [IfThen(HostedEditors, 'the editors of the loaded packages',
     'type information')]);
  StartKeeping;
  // The recovery offer must run from a timer: a dialog opened here would block
  // the file this start-up is opening, and a queued call can be dispatched by
  // an already-open modal loop, nesting the dialog inside it.
  FOfferBeat := TTimer.Create(Self);
  FOfferBeat.Interval := OfferDelay;
  FOfferBeat.OnTimer := OfferTick;
  FOfferBeat.Enabled := True;
  // Separate from the journal timer, which the settings can disable entirely;
  // pending session requests must expire either way.
  FSessionBeat := TTimer.Create(Self);
  FSessionBeat.Interval := SessionBeat;
  FSessionBeat.OnTimer := SessionTick;
  FSessionBeat.Enabled := True;
end;

destructor TDesignerCore.Destroy;
begin
  UseWindowBounds(nil);
  // Nothing may report into a log that is about to be freed.
  ReportInto(nil);
  // A Windows session end destroys the main form without running the normal
  // exit path, so the teardown is repeated here; Shutdown is idempotent.
  Shutdown;
  FJournal.Free;
  FWindows.Free;
  // Freed only after Shutdown stopped the listener: its threads marshal calls
  // into this object.
  FSessions.Free;
  // Freed after every window: a messages frame detaches from the log it
  // renders when destroyed.
  FSessionLog.Free;
  inherited Destroy;
end;

procedure TDesignerCore.LetGoOfEveryWindow;
var
  Window: TMainDesignerForm;
begin
  // Each window leaves the list before it is freed: a window whose closing
  // notification never fires would otherwise keep this loop running.
  while (FWindows <> nil) and (FWindows.Count > 0) do
  begin
    Window := FWindows.Last;
    FWindows.Delete(FWindows.Count - 1);
    Window.Free;
  end;
end;

procedure TDesignerCore.BuildTray;
var
  Source: HICON;
begin
  FMenu := TPopupMenu.Create(Self);
  FMenu.OnPopup := MenuPopup;
  FTray := TTrayIcon.Create(Self);
  FTray.PopupMenu := FMenu;
  FTray.OnDblClick := TrayDoubleClicked;
  // TTrayIcon destroys the handle it is given, so a copy is assigned; the
  // application icon's and the system icon's own handles must not be handed
  // over. Must be set before Visible, which is when the icon is read.
  Source := Application.Icon.Handle;
  if Source = 0 then
    Source := LoadIcon(0, IDI_APPLICATION);
  FTray.Icon.Handle := CopyIcon(Source);
  ShowStatus;
  FTray.Visible := True;
end;

function TDesignerCore.StatusLine: string;
var
  Unsaved, I: Integer;
begin
  if FWindows.Count = 0 then
    Exit('Vallenta Designer - no forms open');
  Unsaved := 0;
  for I := 0 to FWindows.Count - 1 do
    if FWindows[I].IsDirty then
      Inc(Unsaved);
  Result := Format('Vallenta Designer - %d form(s) open, %d unsaved',
    [FWindows.Count, Unsaved]);
end;

procedure TDesignerCore.ShowStatus;
begin
  FTray.Hint := StatusLine;
end;

function TDesignerCore.DialogIsOpen: Boolean;
var
  I: Integer;
begin
  if Application.ModalLevel > 0 then
    Exit(True);
  // Application.ModalLevel counts ShowModal only; a common dialog (colour,
  // font) merely disables the windows it blocks.
  for I := 0 to FWindows.Count - 1 do
    if FWindows[I].HandleAllocated and not IsWindowEnabled(FWindows[I].Handle) then
      Exit(True);
  Result := False;
end;

procedure TDesignerCore.MenuPopup(Sender: TObject);
var
  I: Integer;
  Window: TMainDesignerForm;
  Item: TMenuItem;

  function Added(const ACaption: string): TMenuItem;
  begin
    Result := TMenuItem.Create(FMenu);
    Result.Caption := ACaption;
    FMenu.Items.Add(Result);
  end;

begin
  FMenu.Items.Clear;
  Added(StatusLine).Enabled := False;
  // The tray menu opens during a modal dialog as well, the tray having no
  // window a modal could disable; Exit would then free documents whose dialogs
  // are still on the stack.
  if DialogIsOpen then
  begin
    Added('-');
    Added('a dialog is open').Enabled := False;
    Exit;
  end;
  if FWindows.Count > 0 then
  begin
    Added('-');
    for I := 0 to FWindows.Count - 1 do
    begin
      Window := FWindows[I];
      // '&' is doubled so a file name is not rendered as an accelerator.
      Item := Added(StringReplace(ExtractFileName(Window.FileName), '&', '&&',
        [rfReplaceAll]) + IfThen(Window.IsDirty, ' *', ''));
      // Tag holds the window, not a list index: the menu loop pumps messages,
      // so the list can change while the menu is open.
      Item.Tag := NativeInt(Window);
      Item.OnClick := DocumentClicked;
    end;
  end;
  Added('-');
  Added('Exit').OnClick := ExitClicked;
end;

procedure TDesignerCore.Reveal(AWindow: TMainDesignerForm);
begin
  if AWindow.WindowState = wsMinimized then
    AWindow.WindowState := wsNormal;
  AWindow.Show;
  // SetForegroundWindow raises the window only while this process is
  // foreground-eligible: after a tray click, or a granted foreground right.
  SetForegroundWindow(AWindow.Handle);
end;

procedure TDesignerCore.DocumentClicked(Sender: TObject);
var
  Window: TMainDesignerForm;
begin
  Window := TMainDesignerForm(Pointer((Sender as TMenuItem).Tag));
  // The window can have been freed while the menu was open, so the pointer is
  // checked against the list before it is used.
  if FWindows.IndexOf(Window) >= 0 then
    Reveal(Window);
end;

procedure TDesignerCore.TrayDoubleClicked(Sender: TObject);
begin
  if DialogIsOpen then
    Exit;
  if FInFront <> nil then
    Reveal(FInFront)
  else if FWindows.Count > 0 then
    Reveal(FWindows.Last);
end;

procedure TDesignerCore.ExitClicked(Sender: TObject);
var
  WasEnding: Boolean;
  Agreed: Boolean;
begin
  // FEnding is set before the confirmation dialogs, which pump messages: an
  // open arriving meanwhile must be refused. The previous value is restored on
  // refusal, so a second click during the first cannot clear it.
  WasEnding := FEnding;
  FEnding := True;
  // Assigned before the try: locals are uninitialized and the finally reads
  // it on an exception.
  Agreed := False;
  try
    Agreed := CloseEveryDocument;
  finally
    if not Agreed then
      FEnding := WasEnding;
  end;
  if not Agreed then
    Exit;
  StopListening;
  Application.Terminate;
end;

function TDesignerCore.WindowHolding(const AFileName: string): TMainDesignerForm;
var
  I: Integer;
begin
  for I := 0 to FWindows.Count - 1 do
    if SameText(FWindows[I].FileName, AFileName) then
      Exit(FWindows[I]);
  Result := nil;
end;

function TDesignerCore.FrontWindowBounds(out ABounds: TRect): Boolean;
begin
  Result := FInFront <> nil;
  if Result then
    ABounds := FInFront.BoundsRect;
end;

function TDesignerCore.NewWindow: TMainDesignerForm;
begin
  Result := TMainDesignerForm.CreateFor(Application, FSessionLog);
  // Before any open: the coupling ledger must exist from the document's first
  // component.
  Result.UseSessions(FSessions);
  Result.OnDocumentChanged := DocumentChanged;
  Result.OnDocumentClosing := DocumentClosing;
  Result.OnDocumentActivated := DocumentActivated;
  Result.OnDocumentDirtyChanged := DocumentDirtyChanged;
  Result.OnDocumentSaved := DocumentSaved;
  FWindows.Add(Result);
end;

function TDesignerCore.Adopt(var AWindow: TMainDesignerForm): Boolean;
begin
  Result := AWindow.FileName <> '';
  if not Result then
  begin
    FWindows.Remove(AWindow);
    FreeAndNil(AWindow);
    Exit;
  end;
  AWindow.Show;
  NoteRelatedDocuments(AWindow);
  ShowStatus;
  // The opened event is emitted here and in SessionAttached only, there for a
  // session that was not yet attached; a second one would report an opening
  // that never happened.
  AnnounceOpened(AWindow);
  RefreshCoupling;
end;

procedure TDesignerCore.RefreshCoupling;
var
  I: Integer;
  Window: TMainDesignerForm;
begin
  for I := 0 to FWindows.Count - 1 do
  begin
    Window := FWindows[I];
    Window.CodeCouplingAvailable := (Window.FileName <> '') and
      (FSessions.RouteFor(Window.FileName) <> nil);
  end;
end;

procedure TDesignerCore.Announce(AWindow: TMainDesignerForm;
  const AEvent: string; const AFields: TWireFields);
begin
  if AWindow.FileName <> '' then
    FSessions.EmitEvent(AWindow.FileName, AEvent, AFields);
end;

procedure TDesignerCore.AnnounceOpened(AWindow: TMainDesignerForm);
begin
  Announce(AWindow, OpenedEvent, [WireText(ClassField, AWindow.RootClassName),
    WireText(KindField, RootKindName(AWindow.RootKind))]);
end;

procedure TDesignerCore.NoteRelatedDocuments(ANewcomer: TMainDesignerForm);
var
  I, J: Integer;
  Other: TMainDesignerForm;

  procedure Announce(ABuilt, ASource: TMainDesignerForm; AKind: TSourceKind);
  const
    Independently = ' - the two windows are independent: a change in one ' +
      'appears in the other only after it is saved and the other is reopened';
  var
    Reader, Source: string;
  begin
    case AKind of
      skFrame:
        begin
          Reader := 'this document contains the frame declared in %s, which ' +
            'is open in its own window';
          Source := 'this document declares a frame used by %s, which is ' +
            'open in its own window';
        end;
    else
      Reader := 'this document is built on %s, which is open in its own ' +
        'window';
      Source := 'this document is the ancestor of %s, which is open in its ' +
        'own window';
    end;
    ABuilt.Log.AddFmt(lsInfo, Reader + Independently,
      [ExtractFileName(ASource.FileName)]);
    ASource.Log.AddFmt(lsInfo, Source + Independently,
      [ExtractFileName(ABuilt.FileName)]);
  end;

begin
  for I := 0 to FWindows.Count - 1 do
  begin
    Other := FWindows[I];
    if Other = ANewcomer then
      Continue;
    for J := 0 to High(ANewcomer.SourceFiles) do
      if SameText(ANewcomer.SourceFiles[J].FileName, Other.FileName) then
        Announce(ANewcomer, Other, ANewcomer.SourceFiles[J].Kind);
    for J := 0 to High(Other.SourceFiles) do
      if SameText(Other.SourceFiles[J].FileName, ANewcomer.FileName) then
        Announce(Other, ANewcomer, Other.SourceFiles[J].Kind);
  end;
end;

function TDesignerCore.OpenDocument(const AFileName: string;
  AQuietly: Boolean): TMainDesignerForm;
var
  FullName: string;
begin
  if FEnding or FSweeping or FShutDown then
  begin
    FSessionLog.AddFmt(lsWarn, '%s was not opened: the designer is closing',
      [AFileName]);
    Exit(nil);
  end;
  FullName := ExpandFileName(AFileName);
  Result := WindowHolding(FullName);
  if Result <> nil then
  begin
    Reveal(Result);
    Exit;
  end;
  Result := NewWindow;
  Result.OpenDesignFile(FullName, AQuietly);
  Adopt(Result);
end;

procedure TDesignerCore.DocumentActivated(Sender: TObject);
begin
  FInFront := Sender as TMainDesignerForm;
end;

procedure TDesignerCore.DocumentChanged(Sender: TObject);
begin
  RefreshJournal(Sender as TMainDesignerForm);
  ShowStatus;
end;

procedure TDesignerCore.DocumentDirtyChanged(Sender: TObject);
var
  Window: TMainDesignerForm;
begin
  Window := Sender as TMainDesignerForm;
  Announce(Window, DirtyEvent, [WireFlag(DirtyField, Window.IsDirty)]);
end;

procedure TDesignerCore.DocumentSaved(Sender: TObject);
begin
  Announce(Sender as TMainDesignerForm, SavedEvent, nil);
end;

procedure TDesignerCore.DocumentClosing(Sender: TObject);
var
  Window: TMainDesignerForm;
begin
  Window := Sender as TMainDesignerForm;
  // Emitted before ForgetDocument: the opener record it drops is what routes
  // this event.
  Announce(Window, ClosedEvent, nil);
  FSessions.ForgetDocument(Window.FileName);
  // The recovery copy is deleted only for a document that was settled or
  // clean; a window torn down without asking leaves its copy for the next
  // core to offer.
  if (FJournal <> nil) and (Window.FileName <> '') and
     (Window.Settled or not Window.IsDirty) then
    FJournal.Forget(Window.FileName);
  FWindows.Remove(Window);
  if FInFront = Window then
    FInFront := nil;
  ShowStatus;
end;

function TDesignerCore.CloseEveryDocument: Boolean;
var
  Asked: TArray<TMainDesignerForm>;
  Window: TMainDesignerForm;
begin
  if FSweeping then
    Exit(False);
  FSweeping := True;
  try
    // A copy is iterated: the confirmation dialog pumps messages, so windows
    // can leave the list meanwhile. None can join, opens being refused while
    // FSweeping is set.
    Asked := FWindows.ToArray;
    for Window in Asked do
    begin
      if FWindows.IndexOf(Window) < 0 then
        Continue;
      Reveal(Window);
      if not Window.MayClose then
        Exit(False);
    end;
    // Marked only after every window agreed: an aborted sweep must leave the
    // changes of the earlier windows undecided.
    for Window in Asked do
      if FWindows.IndexOf(Window) >= 0 then
        Window.MarkSettled;
    // Freed, not closed: Close only posts the release, and the shutdown that
    // follows cannot wait on the message loop.
    LetGoOfEveryWindow;
    Result := True;
  finally
    FSweeping := False;
  end;
end;

procedure TDesignerCore.TakeHandovers(AListener: TCoreListener);
var
  Handlers: TCoreHandlers;
begin
  FListener := AListener;
  FListener.OnFailed := ListenerFailed;
  FListener.OnComplaint := ListenerComplained;
  Handlers.Open := RoutedOpen;
  Handlers.Attach := SessionAttached;
  Handlers.Request := SessionRequested;
  Handlers.Answer := SessionAnswered;
  Handlers.Ended := SessionEnded;
  FListener.ServeWith(Handlers);
  FSessionLog.Add(lsInfo, 'the handover listener is running - a later ' +
    'designer start hands its file to this instance, and an editor can attach');
end;

procedure TDesignerCore.ListenerFailed(Sender: TObject);
begin
  FSessionLog.AddFmt(lsError, 'the handover listener failed: %s',
    [TCoreListener(Sender).Failure]);
end;

procedure TDesignerCore.ListenerComplained(Sender: TObject;
  const AReason: string);
begin
  FSessionLog.Add(lsWarn, AReason);
end;

procedure TDesignerCore.StopListening;
begin
  if FListener = nil then
    Exit;
  // A listener that will not stop is leaked, not freed: its thread may still
  // be inside the object.
  if FListener.Stop then
    FreeAndNil(FListener)
  else
  begin
    FSessionLog.Add(lsWarn, 'the handover listener did not stop and is left ' +
      'running - the next designer start may find its pipe still open');
    FListener.OnFailed := nil;
    FListener := nil;
  end;
end;

function TDesignerCore.RoutedOpen(const AFileName: string;
  out AReason: string): TOpenOutcome;
begin
  // Session 0: a handover belongs to no session, so no opener is recorded.
  Result := OpenFor(0, AFileName, AReason);
end;

function TDesignerCore.OpenFor(ASession: Integer; const AFileName: string;
  out AReason: string): TOpenOutcome;
var
  FullName: string;
  Already, Window: TMainDesignerForm;
begin
  AReason := '';
  if DialogIsOpen then
    AReason := 'the designer is waiting on a dialog'
  else if FEnding or FSweeping or FShutDown then
    AReason := 'the designer is closing';
  if AReason <> '' then
  begin
    FSessionLog.AddFmt(lsWarn, '%s was not opened: %s', [AFileName, AReason]);
    Exit(ooRefused);
  end;
  FullName := ExpandFileName(AFileName);
  Already := WindowHolding(FullName);
  // Recorded before the open: the opened event is emitted during the open and
  // is routed by this record. It survives a failed load; a retry rewrites it.
  if ASession <> 0 then
    FSessions.NoteOpener(FullName, ASession);
  Window := OpenDocument(FullName, True);
  if Window = nil then
  begin
    Result := ooRefused;
    AReason := 'the file could not be loaded - see the designer''s messages';
  end
  else
  begin
    if Window = Already then
    begin
      Result := ooFocused;
      // Recording the opener can be the moment the document becomes coupled:
      // it may have been opened from the command line before any session
      // attached.
      RefreshCoupling;
    end
    else
      Result := ooOpened;
    Reveal(Window);
  end;
end;

function TDesignerCore.SessionAttached(const ADetails: TAttachDetails;
  const AOutbox: ISessionOutbox; out AReason: string): Integer;
var
  Session: TDesignSession;
  I: Integer;
begin
  AReason := '';
  if FEnding or FSweeping or FShutDown then
  begin
    AReason := 'the designer is closing';
    Exit(0);
  end;
  Session := FSessions.Attach(ADetails, AOutbox);
  Result := Session.Id;
  RefreshCoupling;
  // Documents opened while no session was attached reached no client; those
  // now routing to this session are announced once, here.
  for I := 0 to FWindows.Count - 1 do
    if (FWindows[I].FileName <> '') and
       (FSessions.RouteFor(FWindows[I].FileName) = Session) then
      AnnounceOpened(FWindows[I]);
  FSessionLog.AddFmt(lsInfo, '%s attached (session %d, process %d) for %s',
    [Trim(IfThen(Session.Client <> '', Session.Client, 'an editor') + ' ' +
     Session.ClientVersion), Session.Id, Session.ClientPid,
     IfThen(Length(Session.Workspaces) > 0,
       string.Join('; ', Session.Workspaces), 'no workspace')]);
end;

function TDesignerCore.SessionRequested(ASession: Integer;
  const ACommand: string; AMessage: TWireMessage; var AFields: TWireFields;
  out AReason: string): Boolean;
var
  FullName: string;
begin
  AReason := '';
  if DialogIsOpen then
    AReason := 'the designer is waiting on a dialog'
  else if FEnding or FSweeping or FShutDown then
    AReason := 'the designer is closing';
  if AReason <> '' then
    Exit(False);
  FullName := ExpandFileName(AMessage.TextOf(FileField));
  if SameText(ACommand, OpenCommand) then
    Result := SessionOpen(ASession, FullName, AFields, AReason)
  else if SameText(ACommand, FocusCommand) then
    Result := SessionFocus(FullName, AReason)
  else if SameText(ACommand, CloseCommand) then
    Result := SessionClose(FullName, AReason)
  else if SameText(ACommand, ReloadCommand) then
    Result := SessionReload(FullName, AReason)
  else
  begin
    AReason := Format('the designer has no handler for "%s"', [ACommand]);
    Result := False;
  end;
end;

procedure TDesignerCore.SessionAnswered(ASession: Integer;
  AMessage: TWireMessage);
begin
  FSessions.Answered(ASession, AMessage);
end;

procedure TDesignerCore.SessionEnded(ASession: Integer);
begin
  FSessions.Detach(ASession);
  RefreshCoupling;
  FSessionLog.AddFmt(lsInfo, 'session %d ended', [ASession]);
end;

function TDesignerCore.SessionOpen(ASession: Integer; const AFileName: string;
  var AFields: TWireFields; out AReason: string): Boolean;
var
  Outcome: TOpenOutcome;
begin
  Outcome := OpenFor(ASession, AFileName, AReason);
  Result := Outcome <> ooRefused;
  if not Result then
    Exit;
  SetLength(AFields, 1);
  AFields[0] := WireFlag(FocusedField, Outcome = ooFocused);
end;

function TDesignerCore.SessionFocus(const AFileName: string;
  out AReason: string): Boolean;
var
  Window: TMainDesignerForm;
begin
  Window := WindowHolding(AFileName);
  Result := Window <> nil;
  if Result then
    Reveal(Window)
  else
    AReason := 'not open';
end;

function TDesignerCore.SessionClose(const AFileName: string;
  out AReason: string): Boolean;
var
  Window: TMainDesignerForm;
begin
  Window := WindowHolding(AFileName);
  if Window = nil then
  begin
    AReason := 'not open';
    Exit(False);
  end;
  Reveal(Window);
  Result := Window.MayClose;
  if not Result then
  begin
    AReason := 'cancelled by the user';
    Exit;
  end;
  // Freed, not closed: Close only posts the release, and the answer to this
  // request must state that the document is gone.
  Window.MarkSettled;
  Window.Free;
end;

function TDesignerCore.SessionReload(const AFileName: string;
  out AReason: string): Boolean;
var
  Window: TMainDesignerForm;
begin
  Window := WindowHolding(AFileName);
  if Window = nil then
  begin
    AReason := 'not open';
    Exit(False);
  end;
  if Window.IsDirty then
  begin
    AReason := 'the document has unsaved changes';
    Exit(False);
  end;
  Window.OpenDesignFile(AFileName, True);
  Result := Window.FileName <> '';
  if not Result then
    AReason := 'the file could not be loaded - see the designer''s messages';
end;

procedure TDesignerCore.SessionTick(Sender: TObject);
begin
  if FShutDown then
    Exit;
  FSessions.Beat;
  Inc(FOrphanBeats);
  if FOrphanBeats < OrphanEvery then
    Exit;
  FOrphanBeats := 0;
  OrphanTick;
end;

procedure TDesignerCore.OrphanTick;
var
  Inputs: TOrphanInputs;
  Verdict: TOrphanVerdict;
begin
  if FEnding or FSweeping then
    Exit;
  Inputs.HadSession := FSessions.EverAttached;
  Inputs.Sessions := FSessions.Count;
  Inputs.Windows := FWindows.Count;
  Inputs.ServeStart := FServeStart;
  Inputs.Now := GetTickCount64;
  Verdict := EvaluateOrphan(Inputs, FOrphan);
  FOrphan := Verdict.Watch;
  case Verdict.Action of
    oaArm:
      FSessionLog.AddFmt(lsInfo, 'no editor is attached and no form is open; ' +
        'this designer ends in %d second(s) unless one of them arrives',
        [Integer((Verdict.Watch.Deadline - Inputs.Now) div MSecsPerSec)]);
    oaEnd:
      // Never while a dialog is open; the deadline stays passed, so the next
      // beat repeats the verdict.
      if not DialogIsOpen then
      begin
        // Only the message loop ends here; the teardown belongs to Shutdown,
        // which runs after it.
        FEnding := True;
        StopListening;
        Application.Terminate;
      end;
  end;
end;

procedure TDesignerCore.StartKeeping;
var
  Seconds: Integer;
begin
  Seconds := RecoveryInterval(SettingsKey(RecoverySettingsKey));
  if Seconds = 0 then
  begin
    FSessionLog.Add(lsInfo, 'unsaved work is not copied for recovery - ' +
      'disabled in the settings');
    Exit;
  end;
  FJournal := TRecoveryJournal.Create;
  if not FJournal.Active then
  begin
    FSessionLog.AddFmt(lsWarn, 'unsaved work cannot be copied for recovery: %s',
      [FJournal.Failure]);
    Exit;
  end;
  FKeeper := TTimer.Create(Self);
  FKeeper.Interval := Seconds * MSecsPerSec;
  FKeeper.OnTimer := KeeperTick;
  FKeeper.Enabled := True;
  FSessionLog.AddFmt(lsInfo, 'unsaved work is copied every %d second(s) into %s',
    [Seconds, FJournal.Folder]);
end;

procedure TDesignerCore.KeeperTick(Sender: TObject);
var
  I: Integer;
begin
  // Not while a dialog is open: a modal loop still fires this timer, and
  // streaming a document mid-edit would copy a state it never held.
  if FShutDown or FEnding or FSweeping or DialogIsOpen then
    Exit;
  for I := 0 to FWindows.Count - 1 do
    RefreshJournal(FWindows[I]);
end;

// True when this session holds the window's unsaved state, which is the only
// case in which another session's copy of the same document may be dropped. A
// clean document counts as held; without a journal nothing is held.
function TDesignerCore.RefreshJournal(AWindow: TMainDesignerForm): Boolean;
var
  Failure: string;
begin
  if AWindow.FileName = '' then
    Exit(True);
  if (FJournal = nil) or not FJournal.Active then
    Exit(not AWindow.IsDirty);
  if not AWindow.IsDirty then
  begin
    FJournal.Forget(AWindow.FileName);
    Exit(True);
  end;
  if not AWindow.NeedsKeeping then
    Exit(True);
  Result := FJournal.Keep(AWindow.FileName, AWindow.RootClassName,
    AWindow.RootKind, AWindow.WriteDocumentTo, Failure);
  // MarkKept only on success: a failed copy leaves NeedsKeeping set, so a
  // transient failure such as a sharing violation is retried at the next beat.
  if Result then
    AWindow.MarkKept
  else
    FSessionLog.AddFmt(lsWarn, 'the unsaved changes to %s could not be copied ' +
      'for recovery: %s', [AWindow.FileName, Failure]);
end;

function TDesignerCore.RecoverDocument(const AEntry: TRecoveryEntry;
  out AReason: string): TMainDesignerForm;
var
  FullName: string;
  Reused: Boolean;
begin
  AReason := '';
  FullName := ExpandFileName(AEntry.SourceFile);
  Result := WindowHolding(FullName);
  Reused := Result <> nil;
  if not Reused then
    Result := NewWindow
  // A dirty window is left alone: its changes and the copy are two later
  // versions of the same file, with no rule to choose between them.
  else if Result.IsDirty then
  begin
    AReason := Format('%s is already open with changes of its own',
      [ExtractFileName(FullName)]);
    FSessionLog.AddFmt(lsWarn, '%s - the earlier session''s recovery copy ' +
      'was kept, not opened', [AReason]);
    Exit(nil);
  end;
  Result.OpenRecovered(FullName, AEntry.CopyFile, AEntry.RootClassName,
    AEntry.RootKind);
  // A reused window is never freed on failure, unlike the new one Adopt frees;
  // it was clean, so the state on disk is loaded back into it instead.
  if Reused then
  begin
    if Result.FileName <> '' then
      Exit;
    Result.OpenDesignFile(FullName, True);
    AReason := Format('%s could not be read back - see the messages',
      [ExtractFileName(FullName)]);
    Exit(nil);
  end;
  if not Adopt(Result) then
    AReason := Format('%s could not be read back - see the messages',
      [ExtractFileName(FullName)]);
end;

procedure TDesignerCore.OfferTick(Sender: TObject);
begin
  if FShutDown or FEnding or FSweeping or DialogIsOpen then
    Exit;
  FOfferBeat.Enabled := False;
  OfferRecovery;
end;

procedure TDesignerCore.CarryOutRecovery(const AEntry: TRecoveryEntry;
  AChoice: TRecoveryChoice; out AReason: string);
var
  Window: TMainDesignerForm;
begin
  AReason := '';
  if AChoice = rcDiscard then
  begin
    DropRecovered(AEntry);
    FSessionLog.AddFmt(lsInfo, 'the recovery copy of %s from an earlier ' +
      'session was deleted', [AEntry.SourceFile]);
    Exit;
  end;
  Window := RecoverDocument(AEntry, AReason);
  if Window = nil then
    Exit;
  FSessionLog.AddFmt(lsInfo, '%s was recovered to its state of %s; the ' +
    'document is unsaved', [AEntry.SourceFile,
    DateTimeToStr(AEntry.CapturedAt)]);
  // The earlier session's copy is dropped only once this session's journal
  // holds one of its own; until then the entry is the only copy left.
  if RefreshJournal(Window) then
    DropRecovered(AEntry)
  else
    AReason := Format('%s was recovered, but no copy of it could be kept - the ' +
      'earlier session''s stays and will be offered again',
      [ExtractFileName(AEntry.SourceFile)]);
end;

procedure TDesignerCore.OfferRecovery;
var
  Entries, Chosen: TArray<TRecoveryEntry>;
  Choice: TRecoveryChoice;
  Entry: TRecoveryEntry;
  Reason, Said: string;
begin
  try
    Entries := RecoverableDocuments;
  except
    on E: Exception do
    begin
      FSessionLog.AddFmt(lsWarn, 'the recovery folder could not be read: %s: %s',
        [E.ClassName, E.Message]);
      Exit;
    end;
  end;
  if Length(Entries) = 0 then
    Exit;
  FSessionLog.AddFmt(lsInfo, 'an earlier session ended with %d form(s) unsaved',
    [Length(Entries)]);
  Choice := ExecuteRecoveryDialog(Entries, Chosen);
  Said := '';
  // The dialog must close before any recovery runs: recovering replaces a
  // window's contents, which its modal loop has disabled while it is open.
  for Entry in Chosen do
  begin
    CarryOutRecovery(Entry, Choice, Reason);
    if Reason <> '' then
    begin
      if Said <> '' then
        Said := Said + sLineBreak;
      Said := Said + Reason;
    end;
  end;
  if Length(Chosen) < Length(Entries) then
    FSessionLog.AddFmt(lsInfo, '%d of them were left undecided - their ' +
      'copies are kept and offered again at the next start',
      [Length(Entries) - Length(Chosen)]);
  if Said <> '' then
    MessageDlg(Said, mtWarning, [mbOK], 0);
end;

procedure TDesignerCore.Shutdown;
var
  I: Integer;
begin
  if FShutDown then
    Exit;
  FShutDown := True;
  // Before the documents go, and before the log it reports through is freed;
  // its threads marshal calls into this object.
  StopListening;
  if FKeeper <> nil then
    FKeeper.Enabled := False;
  if FOfferBeat <> nil then
    FOfferBeat.Enabled := False;
  if FSessionBeat <> nil then
    FSessionBeat.Enabled := False;
  // Hidden before the unload: a fault during it would otherwise leave a tray
  // icon behind for a dead process.
  if FTray <> nil then
    FTray.Visible := False;
  LetGoOfEveryWindow;
  // Frees windows no longer in the list, whose posted release never ran;
  // nothing alive may name a package class when the unload starts.
  for I := Screen.FormCount - 1 downto 0 do
    if Screen.Forms[I] is TMainDesignerForm then
      Screen.Forms[I].Free;
  // After every window closed and its copy was dropped: the folder stays when
  // copies remain, for the next core to offer.
  if FJournal <> nil then
    FJournal.Release;
  // Only after the last window: registry entries, palettes and documents name
  // package classes.
  UnloadAll;
  // Last: a released single-instance name lets a new core start, which must
  // not happen while this one is still tearing down.
  ReleaseCore;
end;

end.

