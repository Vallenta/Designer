// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.DesignHitTest;

// Design-time mouse routing of TFormDesigner: which messages IsDesignMsg
// takes for the designer, which are left to the control because it answers
// CM_DESIGNHITTEST nonzero or holds the mouse capture, and which component
// a click resolves to. Also covers the parent of the selection chrome, the
// load-time Modified report and the read-only guard.
//
// ClickTarget resolves a click from the cursor position, so the tests that
// pin geometry-based hit testing move the system cursor and restore it
// afterwards; an interactive desktop session is required.

interface

uses
  DUnitX.TestFramework;

type
  // Mouse routing, click targets and the conditions that refuse an edit;
  // each test builds one design document, and the routing tests drive the
  // designer through its IDesignerHook.
  [TestFixture]
  TDesignHitTestTests = class
  public
    [Test]
    procedure AClaimedSpotLeavesTheMouseWithTheControl;
    [Test]
    procedure AnUnclaimedSpotKeepsTheMouseWithTheDesigner;
    [Test]
    procedure ACapturedControlKeepsItsGestureWithoutAClaim;
    [Test]
    procedure AClickOnADesignedControlSelectsIt;
    [Test]
    procedure AClickOnAnInnerWindowSelectsTheDesignedControl;
    [Test]
    procedure AClickOnADisabledControlSelectsIt;
    [Test]
    procedure ATileUnderAControlKeepsItsClick;
    [Test]
    procedure SelectingAToolBarChildLendsTheBarNoChrome;
    [Test]
    procedure AModifiedDuringTheLoadIsNotAnEdit;
    [Test]
    procedure AGuardedDesignerTakesNoEdits;
  end;

implementation

uses
  Winapi.Windows,
  Winapi.Messages,
  System.Types,
  System.Classes,
  System.SysUtils,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.ComCtrls,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Streaming.RootClassifier,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Surface.Tiles,
  Vallenta.FormEditor.Surface.TileLayer,
  Vallenta.FormEditor.Surface.FormDesigner;

type
  TComponentAccess = class(TComponent);

  // Designed control that answers CM_DESIGNHITTEST from FClaims, as a grid
  // site does over its column headers.
  TClaimingControl = class(TWinControl)
  private
    FClaims: Boolean;
    procedure CMDesignHitTest(var Message: TCMDesignHitTest);
      message CM_DESIGNHITTEST;
  end;

  // One built design document: a claiming control on the host form and an
  // inner window inside it that the root does not own. Hook is the
  // interface the VCL routes a control's messages through.
  TMessageSession = record
    Document: TDesignDocument;
    Log: TDesignLog;
    Designer: TFormDesigner;
    Control: TClaimingControl;
    Inner: TClaimingControl;
    Hook: IDesignerHook;
    procedure Build;
    procedure Release;
  end;

procedure TClaimingControl.CMDesignHitTest(var Message: TCMDesignHitTest);
begin
  Message.Result := Ord(FClaims);
end;

procedure TMessageSession.Build;
begin
  Log := TDesignLog.Create;
  Document := CreateDesignDocument(drForm);
  Designer := TFormDesigner.Create(Document.HostForm, Document.Root, Log);
  Control := TClaimingControl.Create(Document.Root);
  Control.Parent := Document.HostForm;
  Control.SetBounds(10, 10, 100, 50);
  Inner := TClaimingControl.Create(nil);
  Inner.Parent := Control;
  Inner.SetBounds(1, 1, 98, 48);
  TComponentAccess(Document.Root).SetDesigning(True);
  TComponentAccess(Inner).SetDesigning(True);
  if not Supports(Designer, IDesignerHook, Hook) then
    raise Exception.Create('the designer answers no IDesignerHook');
end;

procedure TMessageSession.Release;
begin
  // Cleared before the designer is freed: the interface is not reference
  // counted, so the record's finalization would call _Release on a freed
  // object.
  Hook := nil;
  FreeAndNil(Designer);
  FreeDesignDocument(Document);
  FreeAndNil(Log);
end;

function MouseMessage(AMsg: Cardinal): TMessage;
begin
  Result := Default(TMessage);
  Result.Msg := AMsg;
  Result.WParam := MK_LBUTTON;
  Result.LParam := 5 or (5 shl 16);
end;

{ TDesignHitTestTests }

procedure TDesignHitTestTests.AClaimedSpotLeavesTheMouseWithTheControl;
var
  Session: TMessageSession;
  Press, Move: TMessage;
begin
  Session.Build;
  try
    Session.Control.FClaims := True;
    Press := MouseMessage(WM_LBUTTONDOWN);
    Assert.IsFalse(Session.Hook.IsDesignMsg(Session.Control, Press),
      'a claimed mouse press was taken by the designer');
    Move := MouseMessage(WM_MOUSEMOVE);
    Assert.IsFalse(Session.Hook.IsDesignMsg(Session.Control, Move),
      'a claimed mouse move was taken by the designer');
  finally
    Session.Release;
  end;
end;

procedure TDesignHitTestTests.AnUnclaimedSpotKeepsTheMouseWithTheDesigner;
var
  Session: TMessageSession;
  Move: TMessage;
begin
  Session.Build;
  try
    Move := MouseMessage(WM_MOUSEMOVE);
    Assert.IsTrue(Session.Hook.IsDesignMsg(Session.Control, Move),
      'an unclaimed mouse move was left to the control');
  finally
    Session.Release;
  end;
end;

procedure TDesignHitTestTests.ACapturedControlKeepsItsGestureWithoutAClaim;
var
  Session: TMessageSession;
  Move: TMessage;
begin
  Session.Build;
  try
    SetCapture(Session.Control.Handle);
    try
      Move := MouseMessage(WM_MOUSEMOVE);
      Assert.IsFalse(Session.Hook.IsDesignMsg(Session.Control, Move),
        'a move during the control''s own capture was taken by the designer');
    finally
      ReleaseCapture;
    end;
  finally
    Session.Release;
  end;
end;

procedure TDesignHitTestTests.AClickOnADesignedControlSelectsIt;
var
  Session: TMessageSession;
  Press: TMessage;
begin
  Session.Build;
  try
    Press := MouseMessage(WM_RBUTTONDOWN);
    Assert.IsTrue(Session.Hook.IsDesignMsg(Session.Control, Press),
      'an unclaimed press on a designed control was left to it');
    Assert.AreSame(Session.Control, Session.Designer.Selected,
      'the click did not select the designed control');
  finally
    Session.Release;
  end;
end;

procedure TDesignHitTestTests.AClickOnAnInnerWindowSelectsTheDesignedControl;
var
  Session: TMessageSession;
  Press: TMessage;
begin
  Session.Build;
  try
    Press := MouseMessage(WM_RBUTTONDOWN);
    Assert.IsTrue(Session.Hook.IsDesignMsg(Session.Inner, Press),
      'an unclaimed press on an inner window was left to it');
    Assert.AreSame(Session.Control, Session.Designer.Selected,
      'the click selected the inner window rather than the designed control');
  finally
    Session.Release;
  end;
end;

// A control with csNeedsDesignDisabledState and Enabled = False keeps a
// truly disabled window while designing, so Windows delivers the click to
// the form and only geometry finds the control.
procedure TDesignHitTestTests.AClickOnADisabledControlSelectsIt;
var
  Session: TMessageSession;
  Press: TMessage;
  Button: TButton;
  Saved, Spot: TPoint;
begin
  Session.Build;
  try
    Button := TButton.Create(Session.Document.Root);
    Button.Parent := Session.Document.HostForm;
    Button.SetBounds(120, 10, 100, 50);
    Button.Enabled := False;
    Assert.IsFalse(IsWindowEnabled(Button.Handle),
      'the premise: such a window is truly disabled even while designing');
    GetCursorPos(Saved);
    Spot := Session.Document.HostForm.ClientToScreen(Point(130, 20));
    SetCursorPos(Spot.X, Spot.Y);
    try
      Press := MouseMessage(WM_RBUTTONDOWN);
      Assert.IsTrue(Session.Hook.IsDesignMsg(Session.Document.HostForm, Press),
        'the press that Windows hands to the form was left unhandled');
      Assert.AreSame(Button, Session.Designer.Selected,
        'the click did not select the disabled control');
    finally
      SetCursorPos(Saved.X, Saved.Y);
    end;
  finally
    Session.Release;
  end;
end;

// A TToolBar turns every window inserted into it into a toolbar item with a
// slot of its own, so the selection chrome is parented into the host window
// rather than into the parent of the selected control.
procedure TDesignHitTestTests.SelectingAToolBarChildLendsTheBarNoChrome;
var
  Session: TMessageSession;
  Bar: TToolBar;
  Child: TButton;
  Buttons, Windows: Integer;
begin
  Session.Build;
  try
    Bar := TToolBar.Create(Session.Document.Root);
    Bar.Parent := Session.Document.HostForm;
    Bar.SetBounds(0, 100, 400, 28);
    Child := TButton.Create(Session.Document.Root);
    Child.Parent := Bar;
    Buttons := Bar.ButtonCount;
    Windows := Bar.ControlCount;
    Session.Designer.SelectComponent(Child);
    Assert.AreEqual(Windows, Bar.ControlCount,
      'the selection chrome was parented into the toolbar');
    Assert.AreEqual(Buttons, Bar.ButtonCount,
      'the toolbar made items for the selection chrome');
  finally
    Session.Release;
  end;
end;

// BeginEditing marks the end of the load; a Modified report before it does
// not dirty the document.
procedure TDesignHitTestTests.AModifiedDuringTheLoadIsNotAnEdit;
var
  Session: TMessageSession;
begin
  Session.Build;
  try
    Session.Hook.Modified;
    Assert.IsFalse(Session.Designer.Dirty,
      'a load-time Modified dirtied the document');
    Session.Designer.BeginEditing;
    Session.Hook.Modified;
    Assert.IsTrue(Session.Designer.Dirty,
      'an edit after BeginEditing must dirty the document');
  finally
    Session.Release;
  end;
end;

// BeginEditing runs first, so the Modified report would dirty the document
// if the guard were not refusing it.
procedure TDesignHitTestTests.AGuardedDesignerTakesNoEdits;
var
  Session: TMessageSession;
  Components: Integer;
begin
  Session.Build;
  try
    Session.Designer.BeginEditing;
    Session.Designer.GuardReadOnly;
    Session.Hook.Modified;
    Assert.IsFalse(Session.Designer.Dirty,
      'a guarded document must not turn dirty');
    Session.Designer.SelectComponent(Session.Control);
    Components := Session.Document.Root.ComponentCount;
    Session.Designer.DeleteSelection;
    Assert.AreEqual(Components, Session.Document.Root.ComponentCount,
      'a guarded document must not lose components');
    Session.Designer.LiftGuard;
    Session.Hook.Modified;
    Assert.IsTrue(Session.Designer.Dirty,
      'after the lift an edit must dirty the document again');
  finally
    Session.Release;
  end;
end;

// The tile layer answers HTTRANSPARENT and its window region is cut from
// the drawn tile pixels, so a press over a tile reaches the control
// underneath and the designer resolves the tile from the cursor position.
procedure TDesignHitTestTests.ATileUnderAControlKeepsItsClick;
var
  Session: TMessageSession;
  Cover: TPanel;
  Covered: TComponent;
  Layer: TTileLayer;
  Host: TCustomForm;
  Region: HRGN;
  Spot, Saved, Aim: TPoint;
  Press: TMessage;
  I: Integer;
begin
  Session.Build;
  try
    Host := Session.Document.HostForm;
    Cover := TPanel.Create(Session.Document.Root);
    Cover.Parent := Host;
    Cover.SetBounds(0, 0, 300, 120);
    Covered := TComponent.Create(Session.Document.Root);
    Covered.Name := 'Ticker';
    SetTilePosition(Covered, 40, 40);
    // SelectComponent syncs the tile layer and raises it: the panel window
    // has to exist before that, and the second sync undoes BringToFront.
    Assert.IsTrue(Cover.Handle <> 0, 'the premise: the panel has a window');
    Session.Designer.SelectComponent(nil);
    Cover.BringToFront;
    Session.Designer.SelectComponent(nil);

    Layer := nil;
    for I := 0 to Host.ControlCount - 1 do
      if Host.Controls[I] is TTileLayer then
        Layer := TTileLayer(Host.Controls[I]);
    Assert.IsNotNull(Layer, 'the document put no tile layer on its host');
    Assert.IsTrue(GetWindow(Host.Handle, GW_CHILD) = Layer.Handle,
      'a designed control got above the tile layer');

    Region := CreateRectRgn(0, 0, 0, 0);
    try
      Assert.IsTrue(GetWindowRgn(Layer.Handle, Region) <> ERROR,
        'the tile layer carries no region');
      Spot := TileGlyphBounds(Covered).CenterPoint;
      Spot.Offset(-Layer.Left, -Layer.Top);
      Assert.IsTrue(PtInRegion(Region, Spot.X, Spot.Y),
        'the covered glyph is no part of the layer');
      Spot := TileGlyphBounds(Covered).CenterPoint;
      Spot.Offset(-Layer.Left + TileGlyphSize, -Layer.Top);
      Assert.IsFalse(PtInRegion(Region, Spot.X, Spot.Y),
        'the layer claims the surface beside a tile');
    finally
      DeleteObject(Region);
    end;

    GetCursorPos(Saved);
    Aim := Host.ClientToScreen(TileGlyphBounds(Covered).CenterPoint);
    SetCursorPos(Aim.X, Aim.Y);
    try
      Press := MouseMessage(WM_RBUTTONDOWN);
      Assert.IsTrue(Session.Hook.IsDesignMsg(Cover, Press),
        'the press on the control under the tile was left to it');
      Assert.AreSame(Covered, Session.Designer.Selected,
        'the click selected the control covering the tile');
    finally
      SetCursorPos(Saved.X, Saved.Y);
    end;
  finally
    Session.Release;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TDesignHitTestTests);

end.
