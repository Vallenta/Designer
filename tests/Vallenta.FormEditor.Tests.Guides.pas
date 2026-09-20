// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.Guides;

// Alignment guides: the segments AlignmentGuides computes, the offsets
// PullToGuides reports, the keys that arm the guide lines on the designer,
// the reach of a guide into another container, and the edge a move snaps
// onto. The snap cases move the system cursor and restore it afterwards; an
// interactive desktop session is required.

interface

uses
  DUnitX.TestFramework;

type
  // Guide geometry, the designer's arming keys, and the move snap. The
  // designer cases build one design document each and drive it through its
  // IDesignerHook.
  [TestFixture]
  TGuideTests = class
  public
    [Test]
    procedure TwoRectanglesSharingTheLeftEdgeGiveOneVerticalSegment;
    [Test]
    procedure RectanglesSharingNoEdgeGiveNoSegment;
    [Test]
    procedure ThreeRectanglesSharingTheLeftEdgeGiveOneSegmentSpanningAll;
    [Test]
    procedure ASharedRightEdgeLiesOnTheLastColumn;
    [Test]
    procedure SharedTopAndBottomEdgesGiveTwoHorizontalSegments;
    [Test]
    procedure ANeighbourWithTheSameBoundsGivesFourSegmentsInOrder;
    [Test]
    procedure AnEdgeWithinReachReportsTheOffsetOntoIt;
    [Test]
    procedure AnEdgeBeyondReachReportsNothing;
    [Test]
    procedure AnEdgeAlreadyAlignedReportsAZeroOffset;
    [Test]
    procedure TheNearerOfTwoEdgesWins;
    [Test]
    procedure AtEqualDistanceTheLeftEdgeWins;
    [Test]
    procedure OnlyTheAskedEdgesAreMeasured;
    [Test]
    procedure TheAxesAreMeasuredIndependently;
    [Test]
    procedure ShiftShowsAGuideAlongASharedEdge;
    [Test]
    procedure ReleasingShiftHidesTheGuides;
    [Test]
    procedure ABareAltPressArmsTheGuidesAndItsReleaseIsSwallowed;
    [Test]
    procedure AnAltReleaseWithoutAnArmedPressPassesOn;
    [Test]
    procedure LosingTheFocusHidesTheGuides;
    [Test]
    procedure AMouseMoveWithTheKeyUpHidesTheGuides;
    [Test]
    procedure TheGuidesFollowTheSelection;
    [Test]
    procedure TheRootWearsNoGuides;
    [Test]
    procedure ACreationDragHidesTheGuidesUntilItEnds;
    [Test]
    procedure AKeyboardNudgeShowsTheGuidesUntilTheNextInput;
    [Test]
    procedure AGuideReachesAControlInsideAnotherContainer;
    [Test]
    procedure AControlsOwnChildrenAreNoNeighbours;
    [Test]
    procedure AControlOnAnInactivePageIsNoNeighbour;
    [Test]
    procedure AMoveSnapsOntoAnEdgeInsideAnotherContainer;
    [Test]
    procedure AMoveEndingWithinReachOfASiblingEdgeDropsOnIt;
    [Test]
    procedure AMoveEndingBeyondReachDropsOnTheGrid;
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
  Vallenta.FormEditor.Palette.Model,
  Vallenta.FormEditor.Surface.Guides,
  Vallenta.FormEditor.Surface.FormDesigner;

type
  TComponentAccess = class(TComponent);

  // One built design document: Aligned and Partner share their left edge,
  // Apart shares no edge with either, and AddContainer adds Panel with Inner
  // inside it. Hook is the interface the VCL routes a control's messages
  // through.
  TGuideSession = record
    Document: TDesignDocument;
    Log: TDesignLog;
    Designer: TFormDesigner;
    Aligned: TButton;
    Partner: TButton;
    Apart: TButton;
    Panel: TPanel;
    Inner: TButton;
    Hook: IDesignerHook;
    procedure Build;
    procedure Release;
    // Adds Panel at ALeft/ATop, 200 by 100, and Inner inside it at
    // AInnerLeft/AInnerTop in the panel's client space, 50 by 20.
    procedure AddContainer(ALeft, ATop, AInnerLeft, AInnerTop: Integer);
    // Sends a key message for AKey through the hook and returns whether the
    // designer took it.
    function Key(AMessage: Cardinal; AKey: Word): Boolean;
    // Sends a message without parameters through the hook, from ASender.
    function Send(AMessage: Cardinal; ASender: TControl): Boolean;
  end;

procedure TGuideSession.Build;
begin
  Log := TDesignLog.Create;
  Document := CreateDesignDocument(drForm);
  Designer := TFormDesigner.Create(Document.HostForm, Document.Root, Log);
  Aligned := TButton.Create(Document.Root);
  Aligned.Parent := Document.HostForm;
  Aligned.SetBounds(24, 24, 120, 25);
  Partner := TButton.Create(Document.Root);
  Partner.Parent := Document.HostForm;
  Partner.SetBounds(24, 72, 240, 23);
  Apart := TButton.Create(Document.Root);
  Apart.Parent := Document.HostForm;
  Apart.SetBounds(200, 150, 50, 20);
  TComponentAccess(Document.Root).SetDesigning(True);
  if not Supports(Designer, IDesignerHook, Hook) then
    raise Exception.Create('the designer answers no IDesignerHook');
end;

procedure TGuideSession.AddContainer(ALeft, ATop, AInnerLeft, AInnerTop: Integer);
begin
  Panel := TPanel.Create(Document.Root);
  Panel.Parent := Document.HostForm;
  Panel.SetBounds(ALeft, ATop, 200, 100);
  Inner := TButton.Create(Document.Root);
  Inner.Parent := Panel;
  Inner.SetBounds(AInnerLeft, AInnerTop, 50, 20);
end;

procedure TGuideSession.Release;
begin
  // Cleared before the designer is freed: the interface is not reference
  // counted, so the record's finalization would call _Release on a freed
  // object.
  Hook := nil;
  FreeAndNil(Designer);
  FreeDesignDocument(Document);
  FreeAndNil(Log);
end;

function TGuideSession.Key(AMessage: Cardinal; AKey: Word): Boolean;
var
  Msg: TMessage;
begin
  Msg := Default(TMessage);
  Msg.Msg := AMessage;
  Msg.WParam := AKey;
  Result := Hook.IsDesignMsg(Document.HostForm, Msg);
end;

function TGuideSession.Send(AMessage: Cardinal; ASender: TControl): Boolean;
var
  Msg: TMessage;
begin
  Msg := Default(TMessage);
  Msg.Msg := AMessage;
  Result := Hook.IsDesignMsg(ASender, Msg);
end;

function Segment(AAxis: TGuideAxis; APosition, AStart, AFinish: Integer): TGuideSegment;
begin
  Result.Axis := AAxis;
  Result.Position := APosition;
  Result.Start := AStart;
  Result.Finish := AFinish;
end;

procedure AssertSegment(const AExpected, AActual: TGuideSegment;
  const AWhat: string);
begin
  Assert.IsTrue(AExpected = AActual, Format('%s: expected %d/%d/%d/%d, got %d/%d/%d/%d',
    [AWhat, Ord(AExpected.Axis), AExpected.Position, AExpected.Start,
    AExpected.Finish, Ord(AActual.Axis), AActual.Position, AActual.Start,
    AActual.Finish]));
end;

{ TGuideTests }

procedure TGuideTests.TwoRectanglesSharingTheLeftEdgeGiveOneVerticalSegment;
var
  Guides: TArray<TGuideSegment>;
begin
  Guides := AlignmentGuides(TRect.Create(24, 24, 144, 49),
    [TRect.Create(24, 72, 264, 95)]);
  Assert.AreEqual(1, Length(Guides), 'one shared edge gives one segment');
  AssertSegment(Segment(gaVertical, 24, 24, 95), Guides[0], 'the left guide');
end;

procedure TGuideTests.RectanglesSharingNoEdgeGiveNoSegment;
begin
  Assert.AreEqual(0, Length(AlignmentGuides(TRect.Create(24, 24, 144, 49),
    [TRect.Create(200, 150, 250, 170), TRect.Create(25, 23, 145, 50)])),
    'a segment was computed for edges that differ');
end;

procedure TGuideTests.ThreeRectanglesSharingTheLeftEdgeGiveOneSegmentSpanningAll;
var
  Guides: TArray<TGuideSegment>;
begin
  Guides := AlignmentGuides(TRect.Create(24, 72, 264, 95),
    [TRect.Create(24, 104, 209, 193), TRect.Create(24, 24, 144, 49)]);
  Assert.AreEqual(1, Length(Guides), 'three rectangles on one edge give one segment');
  AssertSegment(Segment(gaVertical, 24, 24, 193), Guides[0],
    'the segment spanning the topmost top to the bottommost bottom');
end;

procedure TGuideTests.ASharedRightEdgeLiesOnTheLastColumn;
var
  Guides: TArray<TGuideSegment>;
begin
  Guides := AlignmentGuides(TRect.Create(24, 24, 144, 49),
    [TRect.Create(40, 72, 144, 95)]);
  Assert.AreEqual(1, Length(Guides), 'a shared right edge gives one segment');
  AssertSegment(Segment(gaVertical, 143, 24, 95), Guides[0],
    'the right guide, one column inside the exclusive edge');
end;

procedure TGuideTests.SharedTopAndBottomEdgesGiveTwoHorizontalSegments;
var
  Guides: TArray<TGuideSegment>;
begin
  Guides := AlignmentGuides(TRect.Create(24, 24, 144, 49),
    [TRect.Create(160, 24, 200, 40), TRect.Create(170, 30, 260, 49)]);
  Assert.AreEqual(2, Length(Guides), 'a shared top and a shared bottom give two segments');
  AssertSegment(Segment(gaHorizontal, 24, 24, 200), Guides[0], 'the top guide');
  AssertSegment(Segment(gaHorizontal, 48, 24, 260), Guides[1], 'the bottom guide');
end;

procedure TGuideTests.ANeighbourWithTheSameBoundsGivesFourSegmentsInOrder;
var
  Guides: TArray<TGuideSegment>;
begin
  Guides := AlignmentGuides(TRect.Create(10, 20, 110, 70),
    [TRect.Create(10, 20, 110, 70)]);
  Assert.AreEqual(4, Length(Guides), 'four shared edges give four segments');
  AssertSegment(Segment(gaVertical, 10, 20, 70), Guides[0], 'left');
  AssertSegment(Segment(gaVertical, 109, 20, 70), Guides[1], 'right');
  AssertSegment(Segment(gaHorizontal, 20, 10, 110), Guides[2], 'top');
  AssertSegment(Segment(gaHorizontal, 69, 10, 110), Guides[3], 'bottom');
end;

procedure TGuideTests.AnEdgeWithinReachReportsTheOffsetOntoIt;
var
  Pull: TGuidePull;
begin
  Pull := PullToGuides(TRect.Create(41, 8, 161, 33),
    [TRect.Create(43, 100, 100, 125)], AllGuideEdges, 4);
  Assert.IsTrue(Pull.OnX, 'an edge two pixels away is within reach');
  Assert.AreEqual(2, Pull.DX, 'the offset onto the edge');
  Assert.IsFalse(Pull.OnY, 'no horizontal edge lies within reach');
  Assert.AreEqual(0, Pull.DY, 'an axis without an edge reports no offset');
end;

procedure TGuideTests.AnEdgeBeyondReachReportsNothing;
var
  Pull: TGuidePull;
begin
  Pull := PullToGuides(TRect.Create(41, 8, 161, 33),
    [TRect.Create(46, 100, 100, 125)], AllGuideEdges, 4);
  Assert.IsFalse(Pull.OnX, 'an edge five pixels away is beyond a reach of four');
  Assert.AreEqual(0, Pull.DX, 'an axis without an edge reports no offset');
end;

procedure TGuideTests.AnEdgeAlreadyAlignedReportsAZeroOffset;
var
  Pull: TGuidePull;
begin
  Pull := PullToGuides(TRect.Create(24, 8, 144, 33),
    [TRect.Create(24, 100, 100, 125)], AllGuideEdges, 4);
  Assert.IsTrue(Pull.OnX, 'an edge already aligned is within reach');
  Assert.AreEqual(0, Pull.DX, 'the aligned edge needs no offset');
end;

procedure TGuideTests.TheNearerOfTwoEdgesWins;
var
  Pull: TGuidePull;
begin
  Pull := PullToGuides(TRect.Create(41, 8, 161, 33),
    [TRect.Create(38, 100, 100, 125), TRect.Create(42, 200, 100, 225)],
    AllGuideEdges, 4);
  Assert.AreEqual(1, Pull.DX, 'the edge one pixel away won over the one three away');
end;

procedure TGuideTests.AtEqualDistanceTheLeftEdgeWins;
var
  Pull: TGuidePull;
begin
  // The left edge is two pixels short of 43, the right edge two pixels past
  // 159: the same distance in opposite directions.
  Pull := PullToGuides(TRect.Create(41, 8, 161, 33),
    [TRect.Create(43, 100, 159, 125)], AllGuideEdges, 4);
  Assert.AreEqual(2, Pull.DX, 'the left edge did not win the tie');
end;

procedure TGuideTests.OnlyTheAskedEdgesAreMeasured;
var
  Pull: TGuidePull;
begin
  Pull := PullToGuides(TRect.Create(41, 8, 161, 33),
    [TRect.Create(43, 100, 100, 125)], [geRight], 4);
  Assert.IsFalse(Pull.OnX, 'a left-edge match was reported for a right-edge query');
end;

procedure TGuideTests.TheAxesAreMeasuredIndependently;
var
  Pull: TGuidePull;
begin
  Pull := PullToGuides(TRect.Create(41, 8, 161, 33),
    [TRect.Create(200, 11, 300, 40)], AllGuideEdges, 4);
  Assert.IsFalse(Pull.OnX, 'no vertical edge lies within reach');
  Assert.IsTrue(Pull.OnY, 'the top edge three pixels away is within reach');
  Assert.AreEqual(3, Pull.DY, 'the offset onto the top edge');
end;

procedure TGuideTests.ShiftShowsAGuideAlongASharedEdge;
var
  Session: TGuideSession;
begin
  Session.Build;
  try
    Session.Designer.SelectComponent(Session.Aligned);
    Assert.AreEqual(0, Session.Designer.GuideCount, 'no guide before a key is pressed');
    Assert.IsTrue(Session.Key(WM_KEYDOWN, VK_SHIFT), 'the Shift press was left to the control');
    Assert.AreEqual(1, Session.Designer.GuideCount, 'the shared left edge shows no guide');
  finally
    Session.Release;
  end;
end;

procedure TGuideTests.ReleasingShiftHidesTheGuides;
var
  Session: TGuideSession;
begin
  Session.Build;
  try
    Session.Designer.SelectComponent(Session.Aligned);
    Session.Key(WM_KEYDOWN, VK_SHIFT);
    Session.Key(WM_KEYUP, VK_SHIFT);
    Assert.AreEqual(0, Session.Designer.GuideCount, 'the guides outlived the key');
  finally
    Session.Release;
  end;
end;

procedure TGuideTests.ABareAltPressArmsTheGuidesAndItsReleaseIsSwallowed;
var
  Session: TGuideSession;
begin
  Session.Build;
  try
    Session.Designer.SelectComponent(Session.Aligned);
    Assert.IsTrue(Session.Key(WM_SYSKEYDOWN, VK_MENU), 'the Alt press was passed on');
    Assert.AreEqual(1, Session.Designer.GuideCount, 'Alt did not show the guides');
    Assert.IsTrue(Session.Key(WM_SYSKEYUP, VK_MENU),
      'the Alt release was passed on, which focuses the menu bar');
    Assert.AreEqual(0, Session.Designer.GuideCount, 'the guides outlived the key');
  finally
    Session.Release;
  end;
end;

procedure TGuideTests.AnAltReleaseWithoutAnArmedPressPassesOn;
var
  Session: TGuideSession;
begin
  Session.Build;
  try
    Session.Designer.SelectComponent(Session.Aligned);
    Assert.IsFalse(Session.Key(WM_SYSKEYUP, VK_MENU),
      'an Alt release that armed nothing was swallowed');
  finally
    Session.Release;
  end;
end;

procedure TGuideTests.LosingTheFocusHidesTheGuides;
var
  Session: TGuideSession;
begin
  Session.Build;
  try
    Session.Designer.SelectComponent(Session.Aligned);
    Session.Key(WM_KEYDOWN, VK_SHIFT);
    Session.Key(WM_SYSKEYDOWN, VK_MENU);
    Session.Send(WM_KILLFOCUS, Session.Document.HostForm);
    Assert.AreEqual(0, Session.Designer.GuideCount, 'the guides outlived the focus');
    Assert.IsFalse(Session.Key(WM_SYSKEYUP, VK_MENU),
      'the focus loss left Alt armed, so its release was still swallowed');
  finally
    Session.Release;
  end;
end;

// The press arrives as a message here while the physical key is up, which
// is what a release delivered elsewhere looks like to the designer.
procedure TGuideTests.AMouseMoveWithTheKeyUpHidesTheGuides;
var
  Session: TGuideSession;
begin
  Session.Build;
  try
    Session.Designer.SelectComponent(Session.Aligned);
    Session.Key(WM_KEYDOWN, VK_SHIFT);
    Assert.AreEqual(1, Session.Designer.GuideCount, 'the premise: the guides are shown');
    Session.Send(WM_MOUSEMOVE, Session.Document.HostForm);
    Assert.AreEqual(0, Session.Designer.GuideCount,
      'a mouse move with the key up left the guides shown');
  finally
    Session.Release;
  end;
end;

procedure TGuideTests.TheGuidesFollowTheSelection;
var
  Session: TGuideSession;
begin
  Session.Build;
  try
    Session.Designer.SelectComponent(Session.Aligned);
    Session.Key(WM_KEYDOWN, VK_SHIFT);
    Session.Designer.SelectComponent(Session.Apart);
    Assert.AreEqual(0, Session.Designer.GuideCount,
      'a control sharing no edge shows a guide');
    Session.Designer.SelectComponent(Session.Partner);
    Assert.AreEqual(1, Session.Designer.GuideCount,
      'the guide did not return with an aligned selection');
  finally
    Session.Release;
  end;
end;

procedure TGuideTests.TheRootWearsNoGuides;
var
  Session: TGuideSession;
begin
  Session.Build;
  try
    Session.Designer.SelectComponent(Session.Document.Root);
    Session.Key(WM_SYSKEYDOWN, VK_MENU);
    Assert.AreEqual(0, Session.Designer.GuideCount, 'the root has no siblings to align with');
    Assert.IsTrue(Session.Key(WM_SYSKEYUP, VK_MENU),
      'a bare Alt release on the root was passed on to the menu bar');
  finally
    Session.Release;
  end;
end;

// The guides belong to the primary, which a creation drag leaves selected;
// they are hidden while the new rectangle is dragged out and return once the
// gesture ends.
procedure TGuideTests.ACreationDragHidesTheGuidesUntilItEnds;
var
  Session: TGuideSession;
  Item: TPaletteItem;
  Saved, Spot: TPoint;
begin
  Session.Build;
  Item := TPaletteItem.Create(TButton, False);
  try
    Session.Designer.SelectComponent(Session.Aligned);
    Session.Key(WM_KEYDOWN, VK_SHIFT);
    Assert.AreEqual(1, Session.Designer.GuideCount, 'the premise: the guides are shown');
    Session.Designer.ArmCreation(Item);
    GetCursorPos(Saved);
    Spot := Session.Document.HostForm.ClientToScreen(Point(300, 30));
    SetCursorPos(Spot.X, Spot.Y);
    try
      Session.Send(WM_LBUTTONDOWN, Session.Document.HostForm);
      Assert.AreEqual(1, Session.Designer.GuideCount,
        'the press, which focuses the host, dropped the guides');
      SetCursorPos(Spot.X + 40, Spot.Y + 40);
      Session.Send(WM_MOUSEMOVE, Session.Document.HostForm);
      Assert.AreEqual(0, Session.Designer.GuideCount,
        'the guides stayed up while a rectangle was dragged out');
      Session.Key(WM_KEYDOWN, VK_ESCAPE);
    finally
      ReleaseCapture;
      SetCursorPos(Saved.X, Saved.Y);
    end;
    Assert.AreEqual(1, Session.Designer.GuideCount,
      'the guides did not return after the creation was cancelled');
  finally
    Session.Release;
    Item.Free;
  end;
end;

// Two grid steps take Aligned's left edge from 8 to 24, Partner's edge. The
// line shows once the edges meet and stays past the key release, until a
// mouse press on the surface or a selection change.
procedure TGuideTests.AKeyboardNudgeShowsTheGuidesUntilTheNextInput;
var
  Session: TGuideSession;
  Saved, Spot: TPoint;
begin
  Session.Build;
  try
    Session.Aligned.SetBounds(8, 8, 120, 25);
    Session.Designer.SelectComponent(Session.Aligned);
    Session.Key(WM_KEYDOWN, VK_RIGHT);
    Assert.AreEqual(16, Session.Aligned.Left, 'the premise: a nudge moves one grid step');
    Assert.AreEqual(0, Session.Designer.GuideCount, 'a guide with no edge shared');
    Session.Key(WM_KEYDOWN, VK_RIGHT);
    Assert.AreEqual(1, Session.Designer.GuideCount, 'the nudge onto the edge showed no guide');
    Session.Key(WM_KEYUP, VK_RIGHT);
    Assert.AreEqual(1, Session.Designer.GuideCount, 'the key release took the guide away');
    GetCursorPos(Saved);
    Spot := Session.Document.HostForm.ClientToScreen(Point(30, 20));
    SetCursorPos(Spot.X, Spot.Y);
    try
      Session.Send(WM_LBUTTONDOWN, Session.Aligned);
      Session.Send(WM_LBUTTONUP, Session.Aligned);
    finally
      ReleaseCapture;
      SetCursorPos(Saved.X, Saved.Y);
    end;
    Assert.AreEqual(0, Session.Designer.GuideCount, 'a mouse press left the nudge guide up');
    Session.Key(WM_KEYDOWN, VK_LEFT);
    Session.Key(WM_KEYDOWN, VK_RIGHT);
    Assert.AreEqual(1, Session.Designer.GuideCount, 'the premise: nudged back onto the edge');
    Session.Designer.SelectComponent(Session.Apart);
    Assert.AreEqual(0, Session.Designer.GuideCount, 'a selection change left the nudge guide up');
  finally
    Session.Release;
  end;
end;

// Partner is moved away first, so the only left edge at 24 is Inner's, which
// sits four pixels into a panel at 20; the second check moves Inner off the
// edge and re-selects, which recomputes the lines.
procedure TGuideTests.AGuideReachesAControlInsideAnotherContainer;
var
  Session: TGuideSession;
begin
  Session.Build;
  try
    Session.Partner.Left := 300;
    Session.AddContainer(20, 100, 4, 10);
    Session.Designer.SelectComponent(Session.Aligned);
    Session.Key(WM_KEYDOWN, VK_SHIFT);
    Assert.AreEqual(1, Session.Designer.GuideCount,
      'the control inside the panel gave no guide');
    Session.Inner.Left := 5;
    Session.Designer.SelectComponent(Session.Aligned);
    Assert.AreEqual(0, Session.Designer.GuideCount,
      'the guide did not come from the control inside the panel');
  finally
    Session.Release;
  end;
end;

// Inner sits at the panel's own top-left corner, so it shares two edges with
// the panel; as the panel's child it is not measured.
procedure TGuideTests.AControlsOwnChildrenAreNoNeighbours;
var
  Session: TGuideSession;
begin
  Session.Build;
  try
    Session.AddContainer(100, 100, 0, 0);
    Session.Designer.SelectComponent(Session.Panel);
    Session.Key(WM_KEYDOWN, VK_SHIFT);
    Assert.AreEqual(0, Session.Designer.GuideCount,
      'a control''s own child was measured as a neighbour');
  finally
    Session.Release;
  end;
end;

// The designer does not show an inactive page, so a control on it is not a
// neighbour until its page is brought to the front.
procedure TGuideTests.AControlOnAnInactivePageIsNoNeighbour;
var
  Session: TGuideSession;
  Pages: TPageControl;
  Front, Back: TTabSheet;
  Hidden: TButton;
  Origin: TPoint;
begin
  Session.Build;
  try
    Session.Partner.Left := 300;
    Pages := TPageControl.Create(Session.Document.Root);
    Pages.Parent := Session.Document.HostForm;
    Pages.SetBounds(100, 100, 200, 100);
    Front := TTabSheet.Create(Session.Document.Root);
    Front.PageControl := Pages;
    Back := TTabSheet.Create(Session.Document.Root);
    Back.PageControl := Pages;
    Pages.ActivePage := Front;
    Hidden := TButton.Create(Session.Document.Root);
    Hidden.Parent := Back;
    Origin := Session.Document.HostForm.ScreenToClient(Back.ClientToScreen(Point(0, 0)));
    Hidden.SetBounds(24 - Origin.X, 10, 50, 20);
    Session.Designer.SelectComponent(Session.Aligned);
    Session.Key(WM_KEYDOWN, VK_SHIFT);
    Assert.AreEqual(0, Session.Designer.GuideCount,
      'a control on an inactive page gave a guide');
    Pages.ActivePage := Back;
    Session.Designer.SelectComponent(Session.Aligned);
    Assert.AreEqual(1, Session.Designer.GuideCount,
      'the control on the page brought to the front gave no guide');
  finally
    Session.Release;
  end;
end;

// Aligned is dragged 33 px to the right from its left edge at 8, which puts
// the unsnapped edge at 41. The only edge within reach is Inner's, at root
// x 43 inside a panel at 30; the panel's own edges are farther away.
procedure TGuideTests.AMoveSnapsOntoAnEdgeInsideAnotherContainer;
var
  Session: TGuideSession;
  Saved, Spot: TPoint;
begin
  Session.Build;
  try
    Session.Aligned.SetBounds(8, 8, 120, 25);
    Session.Partner.Left := 300;
    Session.AddContainer(30, 100, 13, 10);
    GetCursorPos(Saved);
    Spot := Session.Document.HostForm.ClientToScreen(Point(20, 20));
    SetCursorPos(Spot.X, Spot.Y);
    try
      Session.Send(WM_LBUTTONDOWN, Session.Aligned);
      SetCursorPos(Spot.X + 33, Spot.Y);
      Session.Send(WM_MOUSEMOVE, Session.Aligned);
      Session.Send(WM_LBUTTONUP, Session.Aligned);
    finally
      ReleaseCapture;
      SetCursorPos(Saved.X, Saved.Y);
    end;
    Assert.AreEqual(43, Session.Aligned.Left,
      'the drop did not land on the edge inside the panel');
  finally
    Session.Release;
  end;
end;

// Aligned is dragged 33 px to the right from its left edge at 8, which puts
// the unsnapped edge at 41: two pixels from Partner's edge at 43, and one
// from the grid line at 40.
procedure TGuideTests.AMoveEndingWithinReachOfASiblingEdgeDropsOnIt;
var
  Session: TGuideSession;
  Saved, Spot: TPoint;
begin
  Session.Build;
  try
    Session.Aligned.SetBounds(8, 8, 120, 25);
    Session.Partner.SetBounds(43, 100, 120, 25);
    GetCursorPos(Saved);
    Spot := Session.Document.HostForm.ClientToScreen(Point(20, 20));
    SetCursorPos(Spot.X, Spot.Y);
    try
      Session.Send(WM_LBUTTONDOWN, Session.Aligned);
      SetCursorPos(Spot.X + 33, Spot.Y);
      Session.Send(WM_MOUSEMOVE, Session.Aligned);
      Session.Send(WM_LBUTTONUP, Session.Aligned);
    finally
      ReleaseCapture;
      SetCursorPos(Saved.X, Saved.Y);
    end;
    Assert.AreEqual(43, Session.Aligned.Left, 'the drop did not land on the sibling''s edge');
    Assert.AreEqual(8, Session.Aligned.Top, 'the other axis was moved');
  finally
    Session.Release;
  end;
end;

procedure TGuideTests.AMoveEndingBeyondReachDropsOnTheGrid;
var
  Session: TGuideSession;
  Saved, Spot: TPoint;
begin
  Session.Build;
  try
    Session.Aligned.SetBounds(8, 8, 120, 25);
    Session.Partner.SetBounds(50, 100, 120, 25);
    GetCursorPos(Saved);
    Spot := Session.Document.HostForm.ClientToScreen(Point(20, 20));
    SetCursorPos(Spot.X, Spot.Y);
    try
      Session.Send(WM_LBUTTONDOWN, Session.Aligned);
      SetCursorPos(Spot.X + 33, Spot.Y);
      Session.Send(WM_MOUSEMOVE, Session.Aligned);
      Session.Send(WM_LBUTTONUP, Session.Aligned);
    finally
      ReleaseCapture;
      SetCursorPos(Saved.X, Saved.Y);
    end;
    Assert.AreEqual(40, Session.Aligned.Left, 'the drop did not land on the grid');
  finally
    Session.Release;
  end;
end;

end.
