// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.MainMenu;

// A TMainMenu on a designed form: its component editor's verbs, its Items row,
// the form after the menu designer gave the menu an item, and keys typed in
// the menu designer. The editors come from the IDE's menu designer package,
// hosted when the designer session loads the packages. Verb and value texts
// follow the language of the package resources and are not compared.
//
// The menu designer selects an item only once Windows activates its window,
// so the cases opening it need this process to be allowed into the foreground;
// while another program takes keyboard input they fail with "menu designer
// active: False". Keys are posted to this process's windows only.

interface

uses
  DUnitX.TestFramework;

type
  // Component editor verbs and inspector rows of a TMainMenu.
  [TestFixture]
  TMainMenuTests = class
  public
    // The context menu of a selected main menu offers at least one verb.
    [Test]
    procedure AMainMenuOffersAContextMenuVerb;
    // The Items row of a main menu opens a dialog and does not expand.
    [Test]
    procedure TheItemsRowOfAMainMenuOpensADialog;
    // A menu item added in the menu designer is drawn as no icon tile.
    [Test]
    procedure AMenuItemFromTheMenuDesignerStandsAsNoTile;
    // A main menu given an item in the menu designer shows as the menu bar of
    // the designed form, between its caption and its client area.
    [Test]
    procedure AMenuFromTheMenuDesignerShowsAsTheFormsMenuBar;
    // Keys typed in the menu designer edit the preselected Caption row in the
    // inspector, and Enter writes the caption and returns the focus to the
    // menu designer.
    [Test]
    procedure TypingInTheMenuDesignerEditsTheCaptionInTheInspector;
    // A key typed after Enter starts a fresh edit, and Escape discards it and
    // returns the focus to the menu designer.
    [Test]
    procedure AKeyAfterEnterStartsAFreshEditAndEscapeDiscardsIt;
    // A key typed on a read-only document opens no editor and leaves the focus
    // on the menu designer.
    [Test]
    procedure AKeyOnAReadOnlyDocumentOpensNoEditor;
    // A key handed over while the current row takes no free text opens no
    // editor and leaves the focus where it was.
    [Test]
    procedure AKeyOnAListOnlyRowOpensNoEditor;
    // The menu designer stays in front of the document window while the
    // inspector's editor takes the typed keys.
    [Test]
    procedure TheMenuDesignerStaysInFrontWhileTyping;
  end;

implementation

uses
  Winapi.Windows,
  Winapi.Messages,
  System.Classes,
  System.SysUtils,
  System.Types,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Graphics,
  Vcl.StdCtrls,
  Vcl.Menus,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Streaming.RootClassifier,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Surface.FormDesigner,
  Vallenta.FormEditor.Surface.Tiles,
  Vallenta.FormEditor.Surface.Undo,
  Vallenta.FormEditor.Palette.Model,
  Vallenta.FormEditor.Inspector.PropertyModel,
  Vallenta.FormEditor.Inspector.Grid,
  Vallenta.FormEditor.Inspector.Frame,
  Vallenta.FormEditor.Tests.Environment;

const
  // Rounds of message and synchronize pumping after a step. A round empties
  // the message queue, and a handled message may post another.
  SettleRounds = 8;
  // Width from the left end of the menu bar within which the caption of its
  // first item is drawn, in pixels.
  FirstItemReach = 60;

type
  TComponentAccess = class(TComponent);

  // A form root in design mode holding one main menu with one item, the menu
  // selected. The root is put into design mode before the menu is created, so
  // the menu inherits csDesigning as a loaded one does.
  TMenuSession = record
    Document: TDesignDocument;
    Log: TDesignLog;
    Designer: TFormDesigner;
    Menu: TMainMenu;
    procedure Build;
    procedure Release;
  end;

  // Top-level window standing in for the document window. WS_EX_NOACTIVATE
  // keeps showing it from taking the activation; the inspector's typed edits
  // still activate it when their editor takes the focus.
  THostWindow = class(TForm)
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  end;

  // TInspectorFrame for a console process, where Application has no window:
  // a frame without a parent takes Application.Handle as its parent window, so
  // the window passed to CreateParented is used instead while its resource
  // loads.
  TShownInspectorFrame = class(TInspectorFrame)
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  end;

  // blank_form.dfm loaded and embedded in a shown window as the document
  // window embeds it. OpenMenuDesigner repeats a user's first steps: a main
  // menu placed by the palette's double-click gesture and the menu designer
  // opened through the context-menu verb. BuildMenu then captions the item
  // selected by the menu designer through the inspector's write bracket.
  TShownMenuDocument = class
  private
    FLog: TDesignLog;
    FUndo: TUndoStack;
    FHost: THostWindow;
    FDocument: TDesignDocument;
    FDesigner: TFormDesigner;
    FPaletteItem: TPaletteItem;
    FInspector: TInspectorFrame;
    FOpened: TArray<TCustomForm>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure OpenMenuDesigner;
    procedure BuildMenu(const ACaption: string);
    // An object inspector in the shown window, attached to the designer.
    function AttachInspector: TInspectorFrame;
    // The window opened by OpenMenuDesigner that holds an active control;
    // nil before OpenMenuDesigner.
    function MenuDesignerWindow: TCustomForm;
    // The main menu placed by OpenMenuDesigner; nil before it.
    function Menu: TMainMenu;
    // The window standing in for the document window.
    function HostWindow: TCustomForm;
    // Whether the menu designer window is this thread's active window and
    // whether this process holds the foreground window, for failure messages.
    function ActivationState: string;
    // Distance from the top of the designed form's window to the top of its
    // client area, in pixels.
    function ClientTop: Integer;
    // The band reserved for the menu bar above the client area, as shown by
    // the window after a frame repaint: as wide as the client area and
    // SM_CYMENU pixels tall, 32 bits per pixel. The caller frees it.
    function MenuBand: TBitmap;
    property Document: TDesignDocument read FDocument;
    property Designer: TFormDesigner read FDesigner;
  end;

procedure TMenuSession.Build;
var
  Item: TMenuItem;
begin
  BeginDesignerSession;
  Log := TDesignLog.Create;
  Document := CreateDesignDocument(drForm);
  Designer := TFormDesigner.Create(Document.HostForm, Document.Root, Log);
  TComponentAccess(Document.Root).SetDesigning(True);
  Menu := TMainMenu.Create(Document.Root);
  Menu.Name := 'MainMenu1';
  Item := TMenuItem.Create(Document.Root);
  Item.Name := 'File1';
  Item.Caption := '&File';
  Menu.Items.Add(Item);
  Designer.SelectComponent(Menu);
end;

procedure TMenuSession.Release;
begin
  FreeAndNil(Designer);
  FreeDesignDocument(Document);
  FreeAndNil(Log);
end;

procedure THostWindow.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.ExStyle := Params.ExStyle or WS_EX_NOACTIVATE;
end;

procedure TShownInspectorFrame.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  if (Parent = nil) and (ParentWindow <> 0) then
    Params.WndParent := ParentWindow;
end;

procedure Settle;
var
  Round: Integer;
begin
  for Round := 1 to SettleRounds do
  begin
    Application.ProcessMessages;
    CheckSynchronize;
  end;
end;

function OpenForms: TArray<TCustomForm>;
var
  I: Integer;
begin
  Result := [];
  for I := 0 to Screen.CustomFormCount - 1 do
    Result := Result + [Screen.CustomForms[I]];
end;

function IsAmong(AForm: TCustomForm; const AForms: TArray<TCustomForm>): Boolean;
var
  Form: TCustomForm;
begin
  for Form in AForms do
    if Form = AForm then
      Exit(True);
  Result := False;
end;

function RowNamed(AModel: TPropertyModel; const AName: string): TPropertyRow;
var
  Row: TPropertyRow;
begin
  for Row in AModel.Rows do
    if SameText(Row.Name, AName) then
      Exit(Row);
  Result := nil;
end;

function RowNames(AModel: TPropertyModel): string;
var
  Row: TPropertyRow;
begin
  Result := '';
  for Row in AModel.Rows do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + Row.Name;
  end;
end;

// The grid of AInspector's Properties tab.
function PropertyGridOf(AInspector: TInspectorFrame): TPropertyGrid;
var
  I: Integer;
begin
  for I := 0 to AInspector.ComponentCount - 1 do
    if (AInspector.Components[I] is TPropertyGrid) and
      (TPropertyGrid(AInspector.Components[I]).Parent =
      AInspector.PropertiesTab) then
      Exit(TPropertyGrid(AInspector.Components[I]));
  Result := nil;
end;

// The text editor shown by AGrid over its value column; nil while none is
// open.
function OpenEditorOf(AGrid: TPropertyGrid): TEdit;
var
  I: Integer;
begin
  for I := 0 to AGrid.ControlCount - 1 do
    if (AGrid.Controls[I] is TEdit) and AGrid.Controls[I].Visible then
      Exit(TEdit(AGrid.Controls[I]));
  Result := nil;
end;

// True when AUpper lies above ALower in the z-order of top-level windows.
function IsAbove(AUpper, ALower: HWND): Boolean;
var
  Window: HWND;
begin
  Window := GetWindow(ALower, GW_HWNDPREV);
  while Window <> 0 do
  begin
    if Window = AUpper then
      Exit(True);
    Window := GetWindow(Window, GW_HWNDPREV);
  end;
  Result := False;
end;

// True when AItem or a menu item below it carries ACaption.
function HoldsCaption(AItem: TMenuItem; const ACaption: string): Boolean;
var
  I: Integer;
begin
  if AItem.Caption = ACaption then
    Exit(True);
  for I := 0 to AItem.Count - 1 do
    if HoldsCaption(AItem.Items[I], ACaption) then
      Exit(True);
  Result := False;
end;

procedure TypeKey(AWindow: TCustomForm; AKey: Char);
begin
  PostMessage(AWindow.ActiveControl.Handle, WM_CHAR, Ord(AKey), 0);
  Settle;
end;

procedure PressKey(AControl: TWinControl; AKey: Word);
begin
  PostMessage(AControl.Handle, WM_KEYDOWN, AKey, 0);
  Settle;
end;

// Name and class of every component of ARoot drawn as an icon tile.
function TileNames(ARoot: TComponent): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to ARoot.ComponentCount - 1 do
    if IsNonVisual(ARoot.Components[I]) then
    begin
      if Result <> '' then
        Result := Result + ', ';
      Result := Result + ARoot.Components[I].Name + ': ' +
        ARoot.Components[I].ClassName;
    end;
end;

{ TShownMenuDocument }

constructor TShownMenuDocument.Create;
var
  Loader: TFormLoader;
  Surface: TScrollBox;
  FileName: string;
begin
  inherited Create;
  BeginDesignerSession;
  FileName := FixtureFile('blank_form.dfm');
  FLog := TDesignLog.Create;
  FUndo := TUndoStack.Create;
  FPaletteItem := TPaletteItem.Create(TMainMenu, False);
  FHost := THostWindow.CreateNew(nil);
  FHost.SetBounds(0, 0, 900, 700);
  Surface := TScrollBox.Create(FHost);
  Surface.Parent := FHost;
  Surface.Align := alClient;
  Loader := TFormLoader.Create(FLog);
  try
    Loader.Prepare(FileName);
    FDocument := CreateDesignDocument(Loader.RootKind);
    FDesigner := TFormDesigner.Create(FDocument.HostForm, FDocument.Root, FLog);
    FDesigner.UndoStack := FUndo;
    Loader.StreamInto(FDocument.Root);
    FDesigner.AttachLoaded(FileName, Loader.ExtractEventMap,
      Loader.ExtractPreserved, Loader.ExtractFrames, Loader.ExtractAncestor,
      Loader.LoadedState);
    EmbedDesignedForm(FDocument.HostForm, Surface, Loader.LoadedState);
  finally
    Loader.Free;
  end;
  FDesigner.ShowPlaceholders;
  FDesigner.BeginEditing;
  FHost.Visible := True;
  SetWindowPos(FHost.Handle, HWND_BOTTOM, 0, 0, 0, 0,
    SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  Settle;
end;

destructor TShownMenuDocument.Destroy;
var
  Form: TCustomForm;
begin
  if FInspector <> nil then
  begin
    FInspector.Attach(nil);
    FreeAndNil(FInspector);
  end;
  for Form in FOpened do
    if IsAmong(Form, OpenForms) then
      Form.Close;
  Settle;
  // The designer is freed first: it holds the preserved model whose
  // placeholders the document also parents and would otherwise free twice.
  FreeAndNil(FDesigner);
  FreeDesignDocument(FDocument);
  FHost.Free;
  Settle;
  FPaletteItem.Free;
  FUndo.Free;
  FLog.Free;
  inherited Destroy;
end;

procedure TShownMenuDocument.OpenMenuDesigner;
var
  Before: TArray<TCustomForm>;
  Form: TCustomForm;
  Selected: TArray<TPersistent>;
begin
  FDesigner.CreateCentered(FPaletteItem);
  Settle;
  Assert.IsNotNull(Menu, 'the palette placed no TMainMenu');
  FDesigner.SelectComponent(Menu);
  Before := OpenForms;
  FDesigner.RunComponentVerb(0);
  Settle;
  for Form in OpenForms do
    if not IsAmong(Form, Before) then
      FOpened := FOpened + [Form];
  Assert.IsTrue(Length(FOpened) > 0, 'the menu designer verb opened no window');
  Assert.IsNotNull(MenuDesignerWindow,
    'the menu designer window has no active control');
  Assert.IsTrue(GetActiveWindow = MenuDesignerWindow.Handle,
    'the menu designer is not the active window after opening; ' +
    ActivationState);
  Selected := FDesigner.SelectedPersistents;
  Assert.IsTrue((Length(Selected) = 1) and (Selected[0] is TMenuItem),
    'the menu designer selected no menu item; ' + ActivationState);
end;

function TShownMenuDocument.ActivationState: string;
var
  Foreground: HWND;
  Process: DWORD;
begin
  Foreground := GetForegroundWindow;
  GetWindowThreadProcessId(Foreground, Process);
  Result := Format('menu designer active: %s, foreground window in this ' +
    'process: %s', [BoolToStr((MenuDesignerWindow <> nil) and
    (GetActiveWindow = MenuDesignerWindow.Handle), True),
    BoolToStr(Process = GetCurrentProcessId, True)]);
end;

procedure TShownMenuDocument.BuildMenu(const ACaption: string);
var
  Selected: TArray<TPersistent>;
  Model: TPropertyModel;
  Row: TPropertyRow;
  Applied: Boolean;
begin
  OpenMenuDesigner;
  Selected := FDesigner.SelectedPersistents;
  Model := TPropertyModel.Create;
  try
    Model.Log := FLog;
    Model.BuildMany(Selected, FDocument.Root, FDesigner.EventMap, False,
      FDesigner.HostDesigner);
    Row := RowNamed(Model, 'Caption');
    Assert.IsNotNull(Row, 'the selected menu item has no Caption row');
    FDesigner.BeginGridEdit;
    FDesigner.PushUndo(uoProperty);
    Applied := Row.SetValueText(ACaption);
    FDesigner.EndGridEdit;
    FDesigner.NotifyEdited;
    Assert.IsTrue(Applied, 'the Caption row refused ' + ACaption);
  finally
    Model.Free;
  end;
  Settle;
end;

function TShownMenuDocument.AttachInspector: TInspectorFrame;
begin
  FInspector := TShownInspectorFrame.CreateParented(FHost.Handle);
  FInspector.Parent := FHost;
  FInspector.Align := alRight;
  FInspector.Width := 320;
  FInspector.Attach(FDesigner);
  Settle;
  Result := FInspector;
end;

function TShownMenuDocument.MenuDesignerWindow: TCustomForm;
var
  Form: TCustomForm;
begin
  for Form in FOpened do
    if Form.ActiveControl <> nil then
      Exit(Form);
  Result := nil;
end;

function TShownMenuDocument.HostWindow: TCustomForm;
begin
  Result := FHost;
end;

function TShownMenuDocument.Menu: TMainMenu;
var
  I: Integer;
begin
  for I := 0 to FDocument.Root.ComponentCount - 1 do
    if FDocument.Root.Components[I] is TMainMenu then
      Exit(TMainMenu(FDocument.Root.Components[I]));
  Result := nil;
end;

function TShownMenuDocument.ClientTop: Integer;
var
  Frame: TRect;
begin
  GetWindowRect(FDocument.HostForm.Handle, Frame);
  Result := FDocument.HostForm.ClientOrigin.Y - Frame.Top;
end;

function TShownMenuDocument.MenuBand: TBitmap;
var
  Window: HWND;
  Frame: TRect;
  Origin: TPoint;
  Source: HDC;
begin
  Window := FDocument.HostForm.Handle;
  RedrawWindow(Window, nil, 0, RDW_FRAME or RDW_INVALIDATE or RDW_UPDATENOW);
  Settle;
  GetWindowRect(Window, Frame);
  Origin := FDocument.HostForm.ClientOrigin;
  Result := TBitmap.Create;
  Result.PixelFormat := pf32bit;
  Result.SetSize(FDocument.HostForm.ClientWidth, GetSystemMetrics(SM_CYMENU));
  // A window DC reads the window's own surface, so a window covering the
  // host does not reach the copy.
  Source := GetWindowDC(Window);
  try
    BitBlt(Result.Canvas.Handle, 0, 0, Result.Width, Result.Height, Source,
      Origin.X - Frame.Left, Origin.Y - Frame.Top - Result.Height, SRCCOPY);
  finally
    ReleaseDC(Window, Source);
  end;
end;

// Color of the pixel at X, Y of ABitmap, which holds 32 bits per pixel.
function PixelAt(ABitmap: TBitmap; X, Y: Integer): TColor;
var
  Value: Cardinal;
begin
  Value := PCardinal(PByte(ABitmap.ScanLine[Y]) + X * SizeOf(Cardinal))^;
  Result := RGB((Value shr 16) and $FF, (Value shr 8) and $FF, Value and $FF);
end;

// True when every pixel of ABitmap inside AArea has the same value. ABitmap
// holds 32 bits per pixel; AArea excludes its right and bottom edges.
function IsUniform(ABitmap: TBitmap; const AArea: TRect): Boolean;
var
  X, Y: Integer;
  Row: PByte;
  First: Cardinal;
begin
  Row := ABitmap.ScanLine[AArea.Top];
  First := PCardinal(Row + AArea.Left * SizeOf(Cardinal))^;
  for Y := AArea.Top to AArea.Bottom - 1 do
  begin
    Row := ABitmap.ScanLine[Y];
    for X := AArea.Left to AArea.Right - 1 do
      if PCardinal(Row + X * SizeOf(Cardinal))^ <> First then
        Exit(False);
  end;
  Result := True;
end;

{ TMainMenuTests }

procedure TMainMenuTests.AMainMenuOffersAContextMenuVerb;
var
  Session: TMenuSession;
  Verbs: TArray<string>;
begin
  Session.Build;
  try
    Verbs := Session.Designer.ComponentVerbs;
    Assert.IsTrue(Length(Verbs) > 0,
      'the component editor of a TMainMenu offers no verb');
  finally
    Session.Release;
  end;
end;

procedure TMainMenuTests.TheItemsRowOfAMainMenuOpensADialog;
var
  Session: TMenuSession;
  Model: TPropertyModel;
  Items: TPropertyRow;
begin
  Session.Build;
  Model := TPropertyModel.Create;
  try
    Model.Log := Session.Log;
    Model.BuildMany([TPersistent(Session.Menu)], Session.Document.Root,
      Session.Designer.EventMap, False, Session.Designer.HostDesigner);
    Items := RowNamed(Model, 'Items');
    Assert.IsNotNull(Items,
      'the inspector shows no Items row for a TMainMenu; rows: ' +
      RowNames(Model));
    Assert.IsTrue(Items.HasDialog,
      'the Items row of a TMainMenu opens no dialog');
    Assert.IsFalse(Items.Expandable,
      'the Items row of a TMainMenu expands into the properties of a ' +
      'TMenuItem');
  finally
    Model.Free;
    Session.Release;
  end;
end;

procedure TMainMenuTests.AMenuItemFromTheMenuDesignerStandsAsNoTile;
var
  Session: TShownMenuDocument;
  Component: TComponent;
  I: Integer;
begin
  Session := TShownMenuDocument.Create;
  try
    Session.BuildMenu('test');
    for I := 0 to Session.Document.Root.ComponentCount - 1 do
    begin
      Component := Session.Document.Root.Components[I];
      Assert.IsFalse((Component is TMenuItem) and IsNonVisual(Component),
        Format('the menu item %s is drawn as an icon tile; tiles: %s',
        [Component.Name, TileNames(Session.Document.Root)]));
    end;
  finally
    Session.Free;
  end;
end;

procedure TMainMenuTests.AMenuFromTheMenuDesignerShowsAsTheFormsMenuBar;
var
  Session: TShownMenuDocument;
  Before: Integer;
  Band: TBitmap;
  Found: TColor;
begin
  Session := TShownMenuDocument.Create;
  try
    Before := Session.ClientTop;
    Session.BuildMenu('test');
    Assert.IsTrue(Session.ClientTop > Before,
      Format('the designed form reserves no menu bar: its client area starts ' +
      '%d px below its window top before and %d px after; Menu assigned: %s',
      [Before, Session.ClientTop,
       BoolToStr(Session.Document.HostForm.Menu <> nil, True)]));
    Band := Session.MenuBand;
    try
      Assert.IsTrue(IsUniform(Band, Rect(Band.Width * 3 div 4, 1,
        Band.Width - 2, Band.Height - 1)),
        'the menu bar is not painted: the right end of its band shows what ' +
        'lay beneath it');
      // The form background and the menu bar share one system color on some
      // Windows versions, so the color alone cannot tell an unpainted band.
      Found := PixelAt(Band, Band.Width - 3, Band.Height div 2);
      Assert.IsTrue(Found = ColorToRGB(clMenuBar),
        Format('the menu bar band is not in the menu bar color: $%.6x ' +
        'instead of $%.6x', [Found, ColorToRGB(clMenuBar)]));
      Assert.IsFalse(IsUniform(Band, Rect(1, 1, FirstItemReach,
        Band.Height - 1)), 'the menu bar shows no caption for its first item');
    finally
      Band.Free;
    end;
  finally
    Session.Free;
  end;
end;

procedure TMainMenuTests.TypingInTheMenuDesignerEditsTheCaptionInTheInspector;
var
  Session: TShownMenuDocument;
  Grid: TPropertyGrid;
  Window: TCustomForm;
  Editor: TEdit;
begin
  Session := TShownMenuDocument.Create;
  try
    Grid := PropertyGridOf(Session.AttachInspector);
    Session.OpenMenuDesigner;
    Window := Session.MenuDesignerWindow;
    // Both keys reach the menu designer before its first request is served,
    // as they do when typing fast.
    PostMessage(Window.ActiveControl.Handle, WM_CHAR, Ord('x'), 0);
    PostMessage(Window.ActiveControl.Handle, WM_CHAR, Ord('y'), 0);
    Settle;
    Editor := OpenEditorOf(Grid);
    Assert.IsNotNull(Editor, 'the inspector opened no editor for the typed keys');
    Assert.IsTrue(SameText(Grid.Model[Grid.Row].Name, 'Caption'),
      'the typed keys went to the ' + Grid.Model[Grid.Row].Name +
      ' row instead of Caption');
    Assert.AreEqual('xy', Editor.Text,
      'the inspector''s editor does not hold the typed keys');
    Assert.IsTrue(GetFocus = Editor.Handle,
      'the inspector''s editor does not hold the keyboard focus; ' +
      Session.ActivationState);
    PressKey(Editor, VK_RETURN);
    Assert.IsTrue(Session.Menu.Items.Count > 0, 'the menu holds no item');
    Assert.AreEqual('xy', Session.Menu.Items[0].Caption,
      'Enter did not write the caption');
    Assert.IsTrue(GetActiveWindow = Window.Handle,
      'the focus did not return to the menu designer; ' +
      Session.ActivationState);
  finally
    Session.Free;
  end;
end;

procedure TMainMenuTests.AKeyAfterEnterStartsAFreshEditAndEscapeDiscardsIt;
var
  Session: TShownMenuDocument;
  Grid: TPropertyGrid;
  Window: TCustomForm;
  Editor: TEdit;
begin
  Session := TShownMenuDocument.Create;
  try
    Grid := PropertyGridOf(Session.AttachInspector);
    Session.OpenMenuDesigner;
    Window := Session.MenuDesignerWindow;
    TypeKey(Window, 'x');
    Editor := OpenEditorOf(Grid);
    Assert.IsNotNull(Editor, 'the inspector opened no editor for the first key');
    PressKey(Editor, VK_RETURN);
    Assert.AreEqual('x', Session.Menu.Items[0].Caption,
      'Enter did not write the first caption');
    TypeKey(Window, 'z');
    Editor := OpenEditorOf(Grid);
    Assert.IsNotNull(Editor, 'the inspector opened no editor for the key ' +
      'typed after Enter; ' + Session.ActivationState);
    Assert.AreEqual('z', Editor.Text,
      'the key typed after Enter did not start a fresh edit');
    PressKey(Editor, VK_ESCAPE);
    Assert.IsNull(OpenEditorOf(Grid), 'Escape left the editor open');
    Assert.IsFalse(HoldsCaption(Session.Menu.Items, 'z'),
      'Escape wrote the typed text');
    Assert.IsTrue(GetActiveWindow = Window.Handle,
      'the focus did not return to the menu designer after Escape; ' +
      Session.ActivationState);
  finally
    Session.Free;
  end;
end;

procedure TMainMenuTests.AKeyOnAReadOnlyDocumentOpensNoEditor;
var
  Session: TShownMenuDocument;
  Inspector: TInspectorFrame;
  Grid: TPropertyGrid;
  Window: TCustomForm;
begin
  Session := TShownMenuDocument.Create;
  try
    Inspector := Session.AttachInspector;
    Grid := PropertyGridOf(Inspector);
    Session.OpenMenuDesigner;
    Window := Session.MenuDesignerWindow;
    Session.Designer.GuardReadOnly;
    Inspector.RefreshRows;
    TypeKey(Window, 'x');
    Assert.IsNull(OpenEditorOf(Grid),
      'a read-only document opened an editor for a typed key');
    Assert.IsTrue(GetActiveWindow = Window.Handle,
      'a refused key moved the focus off the menu designer; ' +
      Session.ActivationState);
  finally
    Session.Free;
  end;
end;

procedure TMainMenuTests.AKeyOnAListOnlyRowOpensNoEditor;
var
  Session: TShownMenuDocument;
  Grid: TPropertyGrid;
  Focused: HWND;
begin
  Session := TShownMenuDocument.Create;
  try
    Grid := PropertyGridOf(Session.AttachInspector);
    Session.OpenMenuDesigner;
    Assert.IsTrue(Grid.SelectRowNamed('Checked'),
      'the menu item shows no Checked row');
    Focused := GetFocus;
    Session.Designer.HostDesigner.ModalEdit('x', nil);
    Settle;
    Assert.IsNull(OpenEditorOf(Grid),
      'a list-only row opened a text editor for a typed key');
    Assert.IsTrue(GetFocus = Focused,
      'a refused key moved the keyboard focus');
  finally
    Session.Free;
  end;
end;

procedure TMainMenuTests.TheMenuDesignerStaysInFrontWhileTyping;
var
  Session: TShownMenuDocument;
  Grid: TPropertyGrid;
  Window: TCustomForm;
begin
  Session := TShownMenuDocument.Create;
  try
    Grid := PropertyGridOf(Session.AttachInspector);
    Session.OpenMenuDesigner;
    Window := Session.MenuDesignerWindow;
    Assert.IsTrue(IsAbove(Window.Handle, Session.HostWindow.Handle),
      'the menu designer opened behind the document window');
    TypeKey(Window, 'x');
    Assert.IsNotNull(OpenEditorOf(Grid),
      'the inspector opened no editor for the typed key');
    Assert.IsTrue(IsAbove(Window.Handle, Session.HostWindow.Handle),
      'the document window came in front of the menu designer when the ' +
      'inspector''s editor took the typed key');
  finally
    Session.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TMainMenuTests);

end.
