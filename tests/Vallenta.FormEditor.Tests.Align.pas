// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.Align;

// Covers the group commands of TFormDesigner: AlignSelection, SizeSelection
// and the predicates the shell and the alignment palette enable them from.
// The cases read the live controls rather than a saved file, positions and
// extents being properties the form file holds directly.
//
// Each case starts the process-wide designer session and builds a
// TAlignSession over a fixture. basic_form.dfm holds three controls of the
// form with no Align between them; nested_panels.dfm holds the aligned ones
// and two containers.

interface

uses
  DUnitX.TestFramework;

type
  // Align and size over a loaded document: the actions, what the commands
  // refuse to write, the predicates and one undo step.
  [TestFixture]
  TAlignTests = class
  public
    [Test]
    procedure LeftSidesLineUpWithTheLeftmost;
    [Test]
    procedure RightSidesLineUpWithTheRightmost;
    [Test]
    procedure TopsLineUpWithTheTopmost;
    [Test]
    procedure BottomsLineUpWithTheBottommost;
    [Test]
    procedure CentersLineUpWithTheCenterOfTheSelection;
    [Test]
    procedure TheOrderTheSelectionWasBuiltInDoesNotMatter;
    [Test]
    procedure CenterInWindowUsesTheContainer;
    [Test]
    procedure SpaceEquallyKeepsTheOutermostTwo;
    [Test]
    procedure AnAlignedControlKeepsItsPosition;
    [Test]
    procedure AnAlignedControlStillSetsTheExtent;
    [Test]
    procedure AControlInAnotherContainerIsLeftAlone;
    [Test]
    procedure AnAlignThatMovesNothingLeavesTheDocumentClean;
    [Test]
    procedure TheGroupComesBackInOneStep;
    [Test]
    procedure SameHeightIsTakenWhereSameWidthIsRefused;
    [Test]
    procedure AGuardedDocumentTakesNoAlign;
    [Test]
    procedure ALoneControlOffersTheCenteringActionsOnly;
    [Test]
    procedure ASelectionSpanningContainersReachesOneContainer;
    [Test]
    procedure SpaceEquallyWaitsForAThirdControl;
    [Test]
    procedure NudgingAnAlignedControlLeavesTheDocumentClean;
    [Test]
    procedure ANewSelectionSaysTheCommandsChanged;
    [Test]
    procedure TheGuardSaysTheCommandsChanged;
  end;

implementation

uses
  Winapi.Windows,
  System.Classes,
  System.Types,
  System.SysUtils,
  System.StrUtils,
  Vcl.Controls,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Surface.FormDesigner,
  Vallenta.FormEditor.Surface.Undo,
  Vallenta.FormEditor.Tests.Environment;

const
  // basic_form.dfm holds Button1, Edit1 and Memo1 as children of the form,
  // at the bounds these name. Every one of them starts at Left 24, which is
  // what makes an align to the left sides the case that writes nothing.
  Fixture = 'basic_form.dfm';
  ButtonBounds: TRect = (Left: 24; Top: 24; Right: 144; Bottom: 49);
  EditBounds: TRect = (Left: 24; Top: 72; Right: 264; Bottom: 95);
  MemoBounds: TRect = (Left: 24; Top: 104; Right: 209; Bottom: 193);
  FormClientWidth = 360;

  // nested_panels.dfm: TopPanel is alTop on the form and holds TitleLabel,
  // ClientPanel is alClient and holds SidePanel (alRight) beside InnerEdit.
  NestedFixture = 'nested_panels.dfm';

  // Upper bound on CheckSynchronize rounds; a queued call can queue another.
  PumpRounds = 32;

type
  // One fixture form loaded into a designer, with an undo stack wired to it.
  TAlignSession = class
  private
    FLog: TDesignLog;
    FFileName: string;
    FDocument: TDesignDocument;
    FDesigner: TFormDesigner;
    FUndo: TUndoStack;
    FCommands: Integer;
    procedure CommandsChanged(Sender: TObject);
    procedure Build(ALoader: TFormLoader);
    procedure Release;
    function CaptureDocument(Sender: TObject): TDocumentSnapshot;
    procedure RestoreDocument(Sender: TObject; ASnapshot: TDocumentSnapshot);
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    // Runs the calls the designer queued through TThread.ForceQueue.
    procedure Beat;
    // Selects the named components; the one named last becomes the primary
    // and is what the group commands measure against.
    procedure Select(const ANames: array of string);
    // The named control of the current document. Looked up on each call: an
    // undo restore rebuilds the document and replaces every instance in it.
    function Control(const AName: string): TControl;
    // Bounds of the named control.
    function Bounds(const AName: string): TRect;
    // True when any log entry of severity lsWarn holds ASubstring.
    function WarnedAbout(const ASubstring: string): Boolean;
    // Counts the designer's OnCommandsChanged from the call of Watch on.
    procedure Watch;
    property Commands: Integer read FCommands;
    procedure StepBack;
    property Designer: TFormDesigner read FDesigner;
    property Undo: TUndoStack read FUndo;
  end;

procedure TurnThePump;
var
  Round: Integer;
begin
  Round := 0;
  while CheckSynchronize and (Round < PumpRounds) do
    Inc(Round);
end;

constructor TAlignSession.Create(const AFileName: string);
var
  Loader: TFormLoader;
begin
  inherited Create;
  FFileName := AFileName;
  FLog := TDesignLog.Create;
  FUndo := TUndoStack.Create;
  FUndo.OnCapture := CaptureDocument;
  FUndo.OnRestore := RestoreDocument;
  Loader := TFormLoader.Create(FLog);
  try
    Loader.Prepare(AFileName);
    Build(Loader);
  finally
    Loader.Free;
  end;
end;

destructor TAlignSession.Destroy;
begin
  Release;
  TurnThePump;
  FUndo.Free;
  FLog.Free;
  inherited Destroy;
end;

procedure TAlignSession.Build(ALoader: TFormLoader);
begin
  FDocument := CreateDesignDocument(ALoader.RootKind);
  FDesigner := TFormDesigner.Create(FDocument.HostForm, FDocument.Root, FLog);
  FDesigner.UndoStack := FUndo;
  ALoader.StreamInto(FDocument.Root);
  FDesigner.AttachLoaded(FFileName, ALoader.ExtractEventMap,
    ALoader.ExtractPreserved, ALoader.ExtractFrames, ALoader.ExtractAncestor,
    ALoader.LoadedState);
  FDesigner.ShowPlaceholders;
  FDesigner.BeginEditing;
end;

procedure TAlignSession.Release;
begin
  // Freed before the document: the preserved placeholders are parented into
  // the document and would be freed a second time if it went first.
  FreeAndNil(FDesigner);
  FreeDesignDocument(FDocument);
end;

function TAlignSession.CaptureDocument(Sender: TObject): TDocumentSnapshot;
begin
  Result := FDesigner.CaptureSnapshot;
end;

procedure TAlignSession.RestoreDocument(Sender: TObject;
  ASnapshot: TDocumentSnapshot);
var
  Loader: TFormLoader;
  State: TLoadedFormState;
begin
  State := FDesigner.LoadedState;
  Loader := TFormLoader.Create(FLog);
  try
    Loader.PrepareFromSnapshot(ASnapshot.Data, State, FFileName);
    Release;
    Build(Loader);
    FDesigner.AdoptPreserved(ASnapshot.Preserved.Clone);
    FDesigner.SelectComponent(FDesigner.ComponentNamed(ASnapshot.SelectionName));
    FDesigner.MarkDirty(FUndo.IsDirty);
  finally
    Loader.Free;
  end;
end;

procedure TAlignSession.Beat;
begin
  TurnThePump;
end;

procedure TAlignSession.CommandsChanged(Sender: TObject);
begin
  Inc(FCommands);
end;

procedure TAlignSession.Watch;
begin
  FCommands := 0;
  FDesigner.OnCommandsChanged := CommandsChanged;
end;

procedure TAlignSession.Select(const ANames: array of string);
var
  Chosen: TArray<TComponent>;
  Name: string;
begin
  Chosen := nil;
  for Name in ANames do
    Chosen := Chosen + [FDesigner.ComponentNamed(Name)];
  FDesigner.SelectMany(Chosen);
end;

function TAlignSession.Control(const AName: string): TControl;
var
  Found: TComponent;
begin
  Found := FDesigner.ComponentNamed(AName);
  if not (Found is TControl) then
    raise Exception.CreateFmt('%s is no control of %s', [AName, FFileName]);
  Result := TControl(Found);
end;

function TAlignSession.Bounds(const AName: string): TRect;
begin
  Result := Control(AName).BoundsRect;
end;

function TAlignSession.WarnedAbout(const ASubstring: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FLog.Count - 1 do
    if (FLog[I].Severity = lsWarn) and ContainsText(FLog[I].Text, ASubstring) then
      Exit(True);
end;

procedure TAlignSession.StepBack;
begin
  FUndo.Undo;
  Beat;
end;

function RectText(const ARect: TRect): string;
begin
  Result := Format('(%d,%d %dx%d)', [ARect.Left, ARect.Top, ARect.Width,
    ARect.Height]);
end;

// Assert has no overload for a record, and a generic one names neither
// rectangle in its message.
procedure AssertSameBounds(const AExpected, AActual: TRect;
  const AMessage: string);
begin
  Assert.IsTrue(AExpected = AActual, Format('%s: expected %s, found %s',
    [AMessage, RectText(AExpected), RectText(AActual)]));
end;

{ TAlignTests }

// The fixture puts every control at one left side, so the case moves one
// first and then aligns to the side the other two still share. The control it
// moved is the primary, which is what an align measured against before it
// measured the selection.
procedure TAlignTests.LeftSidesLineUpWithTheLeftmost;
var
  Session: TAlignSession;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(Fixture));
  try
    Session.Control('Button1').Left := ButtonBounds.Left + 76;
    Session.Select(['Edit1', 'Memo1', 'Button1']);
    Session.Designer.AlignSelection(ahLeft, avNone);
    Session.Beat;
    Assert.AreEqual(ButtonBounds.Left, Session.Bounds('Button1').Left,
      'the button did not come back to the leftmost side in the selection');
    Assert.AreEqual(ButtonBounds.Left, Session.Bounds('Memo1').Left,
      'the memo did not keep the leftmost side in the selection');
  finally
    Session.Free;
  end;
end;

// Selected with the narrowest control last, so the primary is not the one
// holding the rightmost edge.
procedure TAlignTests.RightSidesLineUpWithTheRightmost;
var
  Session: TAlignSession;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Edit1', 'Memo1', 'Button1']);
    Session.Designer.AlignSelection(ahRight, avNone);
    Session.Beat;
    Assert.AreEqual(EditBounds.Right, Session.Bounds('Button1').Right,
      'the button did not take the rightmost side in the selection');
    Assert.AreEqual(EditBounds.Right, Session.Bounds('Memo1').Right,
      'the memo did not take the rightmost side in the selection');
    Assert.AreEqual(EditBounds.Right, Session.Bounds('Edit1').Right,
      'the control holding the rightmost side was moved');
    Assert.AreEqual(ButtonBounds.Top, Session.Bounds('Button1').Top,
      'a horizontal align moved the button vertically');
    Assert.IsTrue(Session.Designer.Dirty,
      'an align that moved two controls left the document clean');
  finally
    Session.Free;
  end;
end;

// Selected with the lowest control last: the topmost edge belongs to the
// button, which was selected first.
procedure TAlignTests.TopsLineUpWithTheTopmost;
var
  Session: TAlignSession;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Button1', 'Edit1', 'Memo1']);
    Session.Designer.AlignSelection(ahNone, avTop);
    Session.Beat;
    Assert.AreEqual(ButtonBounds.Top, Session.Bounds('Edit1').Top,
      'the edit did not take the topmost edge in the selection');
    Assert.AreEqual(ButtonBounds.Top, Session.Bounds('Memo1').Top,
      'the memo did not take the topmost edge in the selection');
    Assert.AreEqual(ButtonBounds.Top, Session.Bounds('Button1').Top,
      'the control holding the topmost edge was moved');
    Assert.AreEqual(ButtonBounds.Left, Session.Bounds('Button1').Left,
      'a vertical align moved the button horizontally');
  finally
    Session.Free;
  end;
end;

procedure TAlignTests.BottomsLineUpWithTheBottommost;
var
  Session: TAlignSession;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Memo1', 'Button1']);
    Session.Designer.AlignSelection(ahNone, avBottom);
    Session.Beat;
    Assert.AreEqual(MemoBounds.Bottom, Session.Bounds('Button1').Bottom,
      'the button did not take the bottommost edge in the selection');
    Assert.AreEqual(MemoBounds.Bottom, Session.Bounds('Memo1').Bottom,
      'the control holding the bottommost edge was moved');
  finally
    Session.Free;
  end;
end;

// Aligning to the extent gives one answer whatever the order; aligning to the
// control selected last gives two.
procedure TAlignTests.TheOrderTheSelectionWasBuiltInDoesNotMatter;
var
  Session: TAlignSession;
  Both, Reversed: Integer;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Button1', 'Memo1']);
    Session.Designer.AlignSelection(ahNone, avBottom);
    Session.Beat;
    Both := Session.Bounds('Button1').Bottom;
    Session.StepBack;
    Session.Select(['Memo1', 'Button1']);
    Session.Designer.AlignSelection(ahNone, avBottom);
    Session.Beat;
    Reversed := Session.Bounds('Button1').Bottom;
    Assert.AreEqual(Both, Reversed,
      'the order the selection was built in decided where the button landed');
  finally
    Session.Free;
  end;
end;

// The two controls share a left side and the edit is the wider, so the edit
// spans the selection on its own and its center is the center of it. Both are
// of even width, so the centers meet exactly; an odd width lands half a pixel
// away whatever the command does. The button is the primary, which decided
// the center before the selection did.
procedure TAlignTests.CentersLineUpWithTheCenterOfTheSelection;
var
  Session: TAlignSession;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Edit1', 'Button1']);
    Session.Designer.AlignSelection(ahCenters, avNone);
    Session.Beat;
    Assert.AreEqual(EditBounds.CenterPoint.X,
      Session.Bounds('Button1').CenterPoint.X,
      'the button''s center did not line up with the selection''s');
    Assert.AreEqual(EditBounds.Left, Session.Bounds('Edit1').Left,
      'the control spanning the selection was moved');
    Assert.AreEqual(ButtonBounds.Top, Session.Bounds('Button1').Top,
      'a horizontal align moved the button vertically');
  finally
    Session.Free;
  end;
end;

// The action centers in the container each control sits in rather than
// against the primary, so it moves the primary as well.
procedure TAlignTests.CenterInWindowUsesTheContainer;
var
  Session: TAlignSession;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(Fixture));
  try
    Assert.AreEqual(FormClientWidth, Session.Control('Button1').Parent.ClientWidth,
      'the premise: the fixture form is as wide as the case measures against');
    Session.Select(['Button1', 'Edit1']);
    Session.Designer.AlignSelection(ahCenterInWindow, avNone);
    Session.Beat;
    Assert.AreEqual((FormClientWidth - ButtonBounds.Width) div 2,
      Session.Bounds('Button1').Left, 'the button was not centered');
    Assert.AreEqual((FormClientWidth - EditBounds.Width) div 2,
      Session.Bounds('Edit1').Left, 'the primary was not centered');
  finally
    Session.Free;
  end;
end;

// The outermost two keep their place and the gaps between all three come out
// equal, so the result does not depend on the order things were selected in.
procedure TAlignTests.SpaceEquallyKeepsTheOutermostTwo;
var
  Session: TAlignSession;
  First, Second: Integer;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Memo1', 'Edit1', 'Button1']);
    Session.Designer.AlignSelection(ahNone, avSpaceEqually);
    Session.Beat;
    Assert.AreEqual(ButtonBounds.Top, Session.Bounds('Button1').Top,
      'the topmost control was moved');
    Assert.AreEqual(MemoBounds.Top, Session.Bounds('Memo1').Top,
      'the bottommost control was moved');
    First := Session.Bounds('Edit1').Top - ButtonBounds.Bottom;
    Second := MemoBounds.Top - Session.Bounds('Edit1').Bottom;
    Assert.AreEqual(First, Second, 'the two gaps came out unequal');
  finally
    Session.Free;
  end;
end;

// SidePanel is alRight: its parent writes its position, so the align leaves
// it alone rather than writing a position the next layout pass undoes.
procedure TAlignTests.AnAlignedControlKeepsItsPosition;
var
  Session: TAlignSession;
  Before: TRect;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(NestedFixture));
  try
    Before := Session.Bounds('SidePanel');
    Session.Select(['SidePanel', 'InnerEdit']);
    Session.Designer.AlignSelection(ahLeft, avNone);
    Session.Beat;
    AssertSameBounds(Before, Session.Bounds('SidePanel'),
      'the aligned control was moved');
    Assert.IsTrue(Session.WarnedAbout('Align property'),
      'nothing was said about the control the command left alone');
    Assert.IsFalse(Session.Designer.Dirty,
      'an align that wrote nothing dirtied the document');
  finally
    Session.Free;
  end;
end;

// Refused as a target, counted in the extent: a control its parent positions
// is a fixed edge of the selection, and the topmost edge is the topmost edge
// whether or not the control holding it can follow. Selected first here, so
// it is not the primary either.
procedure TAlignTests.AnAlignedControlStillSetsTheExtent;
var
  Session: TAlignSession;
  Fixed: TRect;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(NestedFixture));
  try
    Fixed := Session.Bounds('SidePanel');
    Session.Select(['SidePanel', 'InnerEdit']);
    Session.Designer.AlignSelection(ahNone, avTop);
    Session.Beat;
    Assert.AreEqual(Fixed.Top, Session.Bounds('InnerEdit').Top,
      'the edit did not take the topmost edge, which the aligned panel holds');
    AssertSameBounds(Fixed, Session.Bounds('SidePanel'),
      'the aligned control was moved');
  finally
    Session.Free;
  end;
end;

// TitleLabel sits in TopPanel and the primary in ClientPanel. Left and Top
// are read in the container's own coordinates, so aligning across two of them
// would line up numbers rather than what the eye sees.
procedure TAlignTests.AControlInAnotherContainerIsLeftAlone;
var
  Session: TAlignSession;
  Before: TRect;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(NestedFixture));
  try
    Before := Session.Bounds('TitleLabel');
    Session.Select(['TitleLabel', 'InnerEdit']);
    Session.Designer.AlignSelection(ahLeft, avTop);
    Session.Beat;
    AssertSameBounds(Before, Session.Bounds('TitleLabel'),
      'a control in another container was moved');
    Assert.IsTrue(Session.WarnedAbout('different container'),
      'nothing was said about the control in the other container');
  finally
    Session.Free;
  end;
end;

// Every control in the fixture starts at Left 24, so this align has nothing
// to write.
procedure TAlignTests.AnAlignThatMovesNothingLeavesTheDocumentClean;
var
  Session: TAlignSession;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(Fixture));
  try
    Assert.AreEqual(ButtonBounds.Left, EditBounds.Left,
      'the premise: the fixture holds the controls at one left side');
    Session.Select(['Button1', 'Memo1', 'Edit1']);
    Session.Designer.AlignSelection(ahLeft, avNone);
    Session.Beat;
    Assert.IsFalse(Session.Designer.Dirty,
      'an align that moved nothing dirtied the document');
    Assert.IsFalse(Session.Undo.CanUndo,
      'an align that moved nothing left a step to come back to');
  finally
    Session.Free;
  end;
end;

procedure TAlignTests.TheGroupComesBackInOneStep;
var
  Session: TAlignSession;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Button1', 'Memo1', 'Edit1']);
    Session.Designer.AlignSelection(ahNone, avTop);
    Session.Beat;
    Assert.IsTrue(Session.Undo.CanUndo,
      'an align left no step to come back to');
    Session.StepBack;
    Assert.AreEqual(ButtonBounds.Top, Session.Bounds('Button1').Top,
      'the step back did not put the button back');
    Assert.AreEqual(MemoBounds.Top, Session.Bounds('Memo1').Top,
      'the step back did not put the memo back');
    Assert.IsFalse(Session.Undo.CanUndo,
      'the align cost more than one step to come back from');
  finally
    Session.Free;
  end;
end;

// An alTop control keeps its own height and takes one; its width is the
// container's to write. The Align is assigned here rather than held in a
// fixture, the property being the whole of what the rule reads.
procedure TAlignTests.SameHeightIsTakenWhereSameWidthIsRefused;
var
  Session: TAlignSession;
  Width: Integer;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(Fixture));
  try
    Session.Control('Edit1').Align := alTop;
    Width := Session.Bounds('Edit1').Width;
    Session.Select(['Button1', 'Edit1', 'Memo1']);
    Session.Designer.SizeSelection(smFromPrimary, smFromPrimary);
    Session.Beat;
    Assert.AreEqual(MemoBounds.Height, Session.Bounds('Edit1').Height,
      'the aligned control did not take the height it keeps for itself');
    Assert.AreEqual(Width, Session.Bounds('Edit1').Width,
      'the aligned control took a width its container writes');
    Assert.AreEqual(MemoBounds.Width, Session.Bounds('Button1').Width,
      'the unaligned control did not take the primary''s width');
    Assert.IsTrue(Session.WarnedAbout('Align property'),
      'nothing was said about the dimension the command left alone');
  finally
    Session.Free;
  end;
end;

procedure TAlignTests.AGuardedDocumentTakesNoAlign;
var
  Session: TAlignSession;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(Fixture));
  try
    Session.Designer.GuardReadOnly;
    Session.Select(['Button1', 'Memo1', 'Edit1']);
    Assert.IsFalse(Session.Designer.CanAlignSelection,
      'a guarded document offered an align');
    Assert.IsFalse(Session.Designer.CanAlign(ahCenterInWindow, avNone),
      'a guarded document offered the action with the smallest demand');
    Assert.IsFalse(Session.Designer.CanSizeSelection,
      'a guarded document offered a size');
    Session.Designer.AlignSelection(ahRight, avNone);
    Session.Beat;
    AssertSameBounds(ButtonBounds, Session.Bounds('Button1'),
      'a guarded document was aligned');
  finally
    Session.Free;
  end;
end;

// The centering actions measure against the container rather than against
// another control, so one control is all they need; everything else waits for
// a second.
procedure TAlignTests.ALoneControlOffersTheCenteringActionsOnly;
var
  Session: TAlignSession;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Button1']);
    Assert.IsTrue(Session.Designer.CanAlign(ahCenterInWindow, avNone),
      'a lone control was not offered centering in its container');
    Assert.IsTrue(Session.Designer.CanAlign(ahNone, avCenterInWindow),
      'a lone control was not offered centering vertically');
    Assert.IsFalse(Session.Designer.CanAlign(ahLeft, avNone),
      'a lone control was offered an align against a reference');
    Assert.IsFalse(Session.Designer.CanAlign(ahNone, avTop),
      'a lone control was offered an align against a reference');
    Assert.IsFalse(Session.Designer.CanSizeSelection,
      'a lone control was offered a size');
    Assert.IsTrue(Session.Designer.CanAlignSelection,
      'a lone control was offered no align action at all');
  finally
    Session.Free;
  end;
end;

// The primary's container holds one member of this selection, so nothing can
// be aligned against a reference - but that member can still be centered.
procedure TAlignTests.ASelectionSpanningContainersReachesOneContainer;
var
  Session: TAlignSession;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(NestedFixture));
  try
    Session.Select(['TitleLabel', 'InnerEdit']);
    Assert.IsFalse(Session.Designer.CanAlign(ahLeft, avNone),
      'a selection with one control in the primary''s container offered an ' +
      'align against a reference');
    Assert.IsTrue(Session.Designer.CanAlign(ahCenterInWindow, avNone),
      'the one control in the primary''s container was not offered ' +
      'centering');
  finally
    Session.Free;
  end;
end;

// SpaceEqually spreads the gaps between the outermost two over what lies
// between them, and below three controls there is nothing between them.
procedure TAlignTests.SpaceEquallyWaitsForAThirdControl;
var
  Session: TAlignSession;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Button1', 'Edit1']);
    Assert.IsFalse(Session.Designer.CanAlign(ahNone, avSpaceEqually),
      'two controls were offered a space-equally that writes nothing');
    Session.Select(['Button1', 'Edit1', 'Memo1']);
    Assert.IsTrue(Session.Designer.CanAlign(ahNone, avSpaceEqually),
      'three controls were not offered a space-equally');
  finally
    Session.Free;
  end;
end;

// The same rule outside the group commands: a drag or a nudge writes the
// bounds and reads them back, so the position its parent restores is no edit.
procedure TAlignTests.NudgingAnAlignedControlLeavesTheDocumentClean;
var
  Session: TAlignSession;
  Before: TRect;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(NestedFixture));
  try
    Before := Session.Bounds('TopPanel');
    Session.Select(['TopPanel']);
    Session.Designer.NudgeSelection(VK_DOWN, []);
    Session.Beat;
    AssertSameBounds(Before, Session.Bounds('TopPanel'),
      'the aligned control was nudged out of its container''s layout');
    Assert.IsFalse(Session.Designer.Dirty,
      'a nudge that moved nothing dirtied the document');
    Assert.IsFalse(Session.Undo.CanUndo,
      'a nudge that moved nothing left a step to come back to');
  finally
    Session.Free;
  end;
end;

// The strip that shows what the selection allows cannot refresh on the
// action-update cycle: a form initiates its top-most menu items on idle and
// nothing else, so an always-visible view of these answers never hears of a
// new selection without this.
procedure TAlignTests.ANewSelectionSaysTheCommandsChanged;
var
  Session: TAlignSession;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Button1']);
    Session.Watch;
    Session.Select(['Button1', 'Edit1']);
    Assert.IsTrue(Session.Commands > 0,
      'a new selection said nothing about the commands it allows');
    Assert.IsTrue(Session.Designer.CanAlign(ahLeft, avNone),
      'the premise: the new selection allows an align it did not before');
  finally
    Session.Free;
  end;
end;

procedure TAlignTests.TheGuardSaysTheCommandsChanged;
var
  Session: TAlignSession;
begin
  BeginDesignerSession;
  Session := TAlignSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Button1', 'Edit1']);
    Session.Watch;
    Session.Designer.GuardReadOnly;
    Assert.AreEqual(1, Session.Commands,
      'the guard going up said nothing about the commands it refuses');
    Session.Designer.LiftGuard;
    Assert.AreEqual(2, Session.Commands,
      'the guard coming down said nothing about the commands it allows');
  finally
    Session.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TAlignTests);

end.
