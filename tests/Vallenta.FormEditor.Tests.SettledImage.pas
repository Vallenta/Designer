// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.SettledImage;

// The settled image: the document snapshot TFormDesigner captures after the
// last completed step and pushes as an undo entry when a change is reported
// only after it was applied, the way a hosted design window reports one. The
// cases check the undo stack, the dirty flag, GestureInFlight, tab orders and
// the bytes a save writes.
//
// TDesignSession replaces the document window: it calls CheckSynchronize for
// the designer's deferred calls, which the message loop delivers in the
// running program, and rebuilds the document on restore as TMainDesignerForm
// does. Every case calls BeginDesignerSession; every file written to the temp
// directory is deleted again by the case or the session that wrote it.

interface

uses
  DUnitX.TestFramework;

type
  // Covers the undo entries built from the settled image, and the grid-edit
  // bracket and size gesture that each suppress an undo entry. Also covers
  // the dirty and gesture-in-flight flags, and the designer chrome a save
  // sinks out of the tab order.
  [TestFixture]
  TSettledImageTests = class
  public
    [Test]
    procedure AChangeNobodyAnnouncedBecomesAStepToComeBackTo;
    [Test]
    procedure TenChangesAreTenSteps;
    [Test]
    procedure AChangeReportedInsideAGridWriteIsNotRecordedTwice;
    [Test]
    procedure AChangeAfterAnOrdinaryEditComesBackToThatEdit;
    [Test]
    procedure TakingTheChangeBackLeavesTheDocumentClean;
    [Test]
    procedure ADocumentThatHasSettledStillWritesTheSameBytes;
    [Test]
    procedure AControlAddedWhileTheHandlesAreUpKeepsItsOwnTabOrder;
    [Test]
    procedure AControlAddedWhileAGroupIsOutlinedKeepsItsOwnTabOrder;
    [Test]
    procedure DraggingTheFramesBorderIsAGestureInFlight;
    [Test]
    procedure AChangeAfterAFrameDragIsStillRecorded;
  end;

implementation

uses
  Winapi.Messages,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.TypInfo,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Surface.FormDesigner,
  Vallenta.FormEditor.Surface.Undo,
  Vallenta.FormEditor.Tests.Environment;

const
  // Fixture form, and the component and property the cases change. The
  // caption is stored in the form file, so a change to it shows in the
  // compared bytes.
  Fixture = 'basic_form.dfm';
  ChangedComponent = 'Button1';
  ChangedProperty = 'Caption';
  // Upper bound on pump rounds. A deferred call may queue another - a
  // Modified report queues a settle - so the pump runs until the queue
  // drains; the bound only stops a runaway loop.
  PumpRounds = 32;

type
  // One loaded document with the designer and the undo history wired
  // together as the shell window wires them, and the designer's deferred
  // calls pumped explicitly instead of by a message loop.
  TDesignSession = class
  private
    FLog: TDesignLog;
    FFileName: string;
    FDocument: TDesignDocument;
    FDesigner: TFormDesigner;
    FUndo: TUndoStack;
    FWritten: string;
    procedure SendDesignMsg(AMessage: Cardinal; AWidth, AHeight: Integer);
    procedure Build(ALoader: TFormLoader);
    procedure Release;
    function CaptureDocument(Sender: TObject): TDocumentSnapshot;
    procedure RestoreDocument(Sender: TObject; ASnapshot: TDocumentSnapshot);
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    // Delivers the designer's deferred calls, in at most PumpRounds rounds of
    // CheckSynchronize.
    procedure Beat;
    // Writes the property and then reports it through the hosted designer, as
    // a design window does; no grid-edit bracket surrounds the write.
    procedure ChangeOutOfBand(const AValue: string);
    // Writes the property inside a grid-edit bracket, with the undo entry
    // pushed before the write, as the object inspector does.
    procedure ChangeThroughTheGrid(const AValue: string);
    // WM_ENTERSIZEMOVE, WM_SIZE and WM_EXITSIZEMOVE through IsDesignMsg, as
    // Windows' modal sizing loop sends them while the root form's own border
    // is dragged.
    procedure EnterFrameDrag;
    procedure DragFrameWider(APixels: Integer);
    procedure LeaveFrameDrag;
    procedure StepBack;
    // Writes the document through the save pipeline to this session's own
    // temp file and returns its path. Every call reuses that one path, which
    // is deleted when the session is freed.
    function WrittenFile: string;
    // The changed component's Caption and the root form's client width, read
    // from the document currently on the surface. A restore builds a new
    // document, so no component reference survives StepBack.
    function ChangedCaption: string;
    function RootClientWidth: Integer;
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

constructor TDesignSession.Create(const AFileName: string);
var
  Loader: TFormLoader;
begin
  inherited Create;
  FFileName := AFileName;
  FWritten := TPath.Combine(TPath.GetTempPath, 'vsfe_settled_' +
    TPath.GetFileName(AFileName));
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

destructor TDesignSession.Destroy;
begin
  Release;
  // Drains what the designer left queued; its alive flag is already clear, so
  // the queued closures return without touching the freed designer.
  TurnThePump;
  FUndo.Free;
  FLog.Free;
  DeleteFile(FWritten);
  inherited Destroy;
end;

procedure TDesignSession.Build(ALoader: TFormLoader);
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
  // A control is selected, not the root: grab handles are shown only for a
  // control and are windows in the parent's tab list, so captures sink chrome.
  FDesigner.SelectComponent(FDesigner.Root.FindComponent(ChangedComponent));
end;

procedure TDesignSession.Release;
begin
  // The designer is freed first: it holds the preserved model whose
  // placeholders the document also parents and would otherwise free twice.
  FreeAndNil(FDesigner);
  FreeDesignDocument(FDocument);
end;

function TDesignSession.CaptureDocument(Sender: TObject): TDocumentSnapshot;
begin
  Result := FDesigner.CaptureSnapshot;
end;

procedure TDesignSession.RestoreDocument(Sender: TObject;
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

procedure TDesignSession.Beat;
begin
  TurnThePump;
end;

procedure TDesignSession.ChangeOutOfBand(const AValue: string);
begin
  SetStrProp(FDesigner.Root.FindComponent(ChangedComponent), ChangedProperty,
    AValue);
  FDesigner.HostDesigner.Modified;
  Beat;
end;

procedure TDesignSession.ChangeThroughTheGrid(const AValue: string);
begin
  FDesigner.BeginGridEdit;
  FDesigner.PushUndo(uoProperty);
  SetStrProp(FDesigner.Root.FindComponent(ChangedComponent), ChangedProperty,
    AValue);
  FDesigner.EndGridEdit;
  FDesigner.NotifyEdited;
  Beat;
end;

procedure TDesignSession.SendDesignMsg(AMessage: Cardinal;
  AWidth, AHeight: Integer);
var
  Message: TMessage;
begin
  Message := Default(TMessage);
  Message.Msg := AMessage;
  TWMSize(Message).Width := AWidth;
  TWMSize(Message).Height := AHeight;
  FDocument.HostForm.Designer.IsDesignMsg(FDocument.HostForm, Message);
end;

procedure TDesignSession.EnterFrameDrag;
begin
  SendDesignMsg(WM_ENTERSIZEMOVE, 0, 0);
end;

procedure TDesignSession.DragFrameWider(APixels: Integer);
var
  Root: TCustomForm;
begin
  Root := FDocument.HostForm;
  Root.ClientWidth := Root.ClientWidth + APixels;
  SendDesignMsg(WM_SIZE, Root.ClientWidth, Root.ClientHeight);
  // Windows' modal sizing loop delivers queued calls while it still holds the
  // mouse, so the pump runs inside the drag rather than after it.
  Beat;
end;

procedure TDesignSession.LeaveFrameDrag;
begin
  SendDesignMsg(WM_EXITSIZEMOVE, 0, 0);
  Beat;
end;

procedure TDesignSession.StepBack;
begin
  FUndo.Undo;
  Beat;
end;

function TDesignSession.WrittenFile: string;
begin
  FDesigner.WriteTo(FWritten);
  Result := FWritten;
end;

function TDesignSession.ChangedCaption: string;
begin
  Result := GetStrProp(FDesigner.Root.FindComponent(ChangedComponent),
    ChangedProperty);
end;

function TDesignSession.RootClientWidth: Integer;
begin
  Result := FDocument.HostForm.ClientWidth;
end;

// Copies ASource to a temp file of its own. WrittenFile reuses a single path
// that the next write overwrites, so a comparison copy cannot be kept there.
function Kept(const ASource, AName: string): string;
begin
  Result := TPath.Combine(TPath.GetTempPath, 'vsfe_settled_kept_' + AName);
  TFile.Copy(ASource, Result, True);
end;

procedure TSettledImageTests.AChangeNobodyAnnouncedBecomesAStepToComeBackTo;
var
  Session: TDesignSession;
  Before, Where: string;
begin
  BeginDesignerSession;
  Session := TDesignSession.Create(FixtureFile(Fixture));
  try
    Session.Beat;
    Before := Kept(Session.WrittenFile, 'before.dfm');
    try
      Session.ChangeOutOfBand('changed from a design window');
      Assert.IsFalse(SameBytes(Before, Session.WrittenFile, Where),
        'the case changed nothing, so it measures nothing');
      Assert.IsTrue(Session.Undo.CanUndo,
        'a change made outside the window left no step to come back to');
      Session.StepBack;
      Assert.IsTrue(SameBytes(Before, Session.WrittenFile, Where),
        'the step back did not give the document back: ' + Where);
      Assert.IsFalse(Session.Undo.CanUndo,
        'one change left more than one step behind it');
    finally
      DeleteFile(Before);
    end;
  finally
    Session.Free;
  end;
end;

procedure TSettledImageTests.TenChangesAreTenSteps;
const
  Changes = 10;
var
  Session: TDesignSession;
  Before, Where: string;
  I: Integer;
begin
  BeginDesignerSession;
  Session := TDesignSession.Create(FixtureFile(Fixture));
  try
    Session.Beat;
    Before := Kept(Session.WrittenFile, 'ten.dfm');
    try
      for I := 1 to Changes do
        Session.ChangeOutOfBand(Format('change %d', [I]));
      for I := 1 to Changes do
      begin
        Assert.IsTrue(Session.Undo.CanUndo,
          Format('%d changes left fewer than %d steps', [Changes, Changes]));
        Session.StepBack;
      end;
      Assert.IsFalse(Session.Undo.CanUndo,
        Format('%d changes left more than %d steps', [Changes, Changes]));
      Assert.IsTrue(SameBytes(Before, Session.WrittenFile, Where),
        'stepping back through all of them did not give the document back: ' +
        Where);
    finally
      DeleteFile(Before);
    end;
  finally
    Session.Free;
  end;
end;

// A property editor opened from a grid row reports through the same Modified
// call, inside a bracket the row already pushed an undo entry for. A second
// entry would take two presses of Ctrl+Z to undo one edit.
procedure TSettledImageTests.AChangeReportedInsideAGridWriteIsNotRecordedTwice;
var
  Session: TDesignSession;
  Before, Where: string;
begin
  BeginDesignerSession;
  Session := TDesignSession.Create(FixtureFile(Fixture));
  try
    Session.Beat;
    Before := Kept(Session.WrittenFile, 'bracketed.dfm');
    try
      Session.Designer.BeginGridEdit;
      Session.Designer.PushUndo(uoProperty);
      SetStrProp(Session.Designer.Root.FindComponent(ChangedComponent),
        ChangedProperty, 'written through a row');
      Session.Designer.HostDesigner.Modified;
      Session.Designer.EndGridEdit;
      Session.Designer.NotifyEdited;
      Session.Beat;
      Assert.IsTrue(Session.Undo.CanUndo, 'the row recorded no step at all');
      Session.StepBack;
      Assert.IsTrue(SameBytes(Before, Session.WrittenFile, Where),
        'one press did not undo one edit: ' + Where);
      Assert.IsFalse(Session.Undo.CanUndo,
        'a change reported inside a grid write was recorded a second time');
    finally
      DeleteFile(Before);
    end;
  finally
    Session.Free;
  end;
end;

// The settled image has to be refreshed after a grid edit; a stale image
// would take that edit back along with the change reported afterwards.
procedure TSettledImageTests.AChangeAfterAnOrdinaryEditComesBackToThatEdit;
var
  Session: TDesignSession;
  Before, Edited, Where: string;
begin
  BeginDesignerSession;
  Session := TDesignSession.Create(FixtureFile(Fixture));
  try
    Session.Beat;
    Before := Kept(Session.WrittenFile, 'ordinary_before.dfm');
    try
      Session.ChangeThroughTheGrid('written through a row');
      Edited := Kept(Session.WrittenFile, 'ordinary_edited.dfm');
      try
        Session.ChangeOutOfBand('changed from a design window');
        Session.StepBack;
        Assert.IsTrue(SameBytes(Edited, Session.WrittenFile, Where),
          'the step back reached past the edit before it: ' + Where);
        Session.StepBack;
        Assert.IsTrue(SameBytes(Before, Session.WrittenFile, Where),
          'the second step back did not reach the document as it was opened: ' +
          Where);
      finally
        DeleteFile(Edited);
      end;
    finally
      DeleteFile(Before);
    end;
  finally
    Session.Free;
  end;
end;

procedure TSettledImageTests.TakingTheChangeBackLeavesTheDocumentClean;
var
  Session: TDesignSession;
begin
  BeginDesignerSession;
  Session := TDesignSession.Create(FixtureFile(Fixture));
  try
    Session.Beat;
    Assert.IsFalse(Session.Designer.Dirty,
      'a document nobody has edited arrived unsaved');
    Session.ChangeOutOfBand('changed from a design window');
    Assert.IsTrue(Session.Designer.Dirty,
      'a change made outside the window left the document looking saved');
    Session.StepBack;
    Assert.IsFalse(Session.Designer.Dirty,
      'taking the change back left the document looking unsaved');
  finally
    Session.Free;
  end;
end;

// The first settle streams the document for its snapshot, with the grab
// handles up; a save afterwards must still produce the fixture's bytes.
procedure TSettledImageTests.ADocumentThatHasSettledStillWritesTheSameBytes;
var
  Session: TDesignSession;
  Source, Where: string;
begin
  BeginDesignerSession;
  Source := FixtureFile(Fixture);
  Session := TDesignSession.Create(Source);
  try
    Session.Beat;
    Assert.IsTrue(SameBytes(Source, Session.WrittenFile, Where),
      'a document that settled no longer writes what it was opened from: ' +
      Where);
  finally
    Session.Free;
  end;
end;

// The eight grab handles are windows in their parent's tab list, so a control
// parented while they are up counts them. WrittenFile sinks the chrome after
// the control was parented, so the tab order is read only after it has run.
procedure TSettledImageTests.AControlAddedWhileTheHandlesAreUpKeepsItsOwnTabOrder;
const
  // Three controls in the fixture, so a fourth one lands at tab order 3.
  ExpectedOrder = 3;
var
  Session: TDesignSession;
  Added: TButton;
  Written: string;
begin
  BeginDesignerSession;
  Session := TDesignSession.Create(FixtureFile(Fixture));
  try
    Session.Beat;
    Added := TButton.Create(Session.Designer.Root);
    Added.Name := 'AddedButton';
    Added.Parent := TWinControl(Session.Designer.Root);
    Written := TFile.ReadAllText(Session.WrittenFile);
    Assert.AreEqual(ExpectedOrder, Integer(Added.TabOrder),
      'the control keeps a tab order that counts the designer''s own chrome');
    Assert.IsTrue(Written.Contains(Format('TabOrder = %d', [ExpectedOrder])),
      'the file does not hold the tab order the document''s own controls make');
  finally
    Session.Free;
  end;
end;

// The same for the outlines: grab handles are shown around the primary of a
// multi-selection only; every other member is outlined by four windows, which
// stay parented for as long as the multi-selection holds.
procedure TSettledImageTests.AControlAddedWhileAGroupIsOutlinedKeepsItsOwnTabOrder;
const
  ExpectedOrder = 3;
var
  Session: TDesignSession;
  Root: TComponent;
  Added: TButton;
begin
  BeginDesignerSession;
  Session := TDesignSession.Create(FixtureFile(Fixture));
  try
    Session.Beat;
    Root := Session.Designer.Root;
    Session.Designer.SelectMany([Root.FindComponent(ChangedComponent),
      Root.FindComponent('Edit1')]);
    Added := TButton.Create(Root);
    Added.Name := 'AddedButton';
    Added.Parent := TWinControl(Root);
    Session.WrittenFile;
    Assert.AreEqual(ExpectedOrder, Integer(Added.TabOrder),
      'the control keeps a tab order that counts the outline of a second selection');
  finally
    Session.Free;
  end;
end;

// Grab handles are not shown for a form root, so it is resized by its own
// window frame, in Windows' modal sizing loop rather than in a designer drag.
// Undo, snapshot capture and the recovery journal all wait on GestureInFlight.
procedure TSettledImageTests.DraggingTheFramesBorderIsAGestureInFlight;
var
  Session: TDesignSession;
begin
  BeginDesignerSession;
  Session := TDesignSession.Create(FixtureFile(Fixture));
  try
    Session.Beat;
    Assert.IsFalse(Session.Designer.GestureInFlight,
      'a document nobody is touching reported a gesture in flight');
    Session.EnterFrameDrag;
    Assert.IsTrue(Session.Designer.GestureInFlight,
      'dragging the frame is not seen as a gesture, so everything that has to ' +
      'stand still while the mouse is held would run in the middle of it');
    Session.LeaveFrameDrag;
    Assert.IsFalse(Session.Designer.GestureInFlight,
      'the gesture was never let go of');
  finally
    Session.Free;
  end;
end;

// A size gesture suspends the settled image, so the end of the drag has to
// queue a new one; otherwise the next change reported from a design window
// finds a stale image and is not recorded.
procedure TSettledImageTests.AChangeAfterAFrameDragIsStillRecorded;
var
  Session: TDesignSession;
  Dragged: Integer;
  Before: string;
begin
  BeginDesignerSession;
  Session := TDesignSession.Create(FixtureFile(Fixture));
  try
    Session.Beat;
    Session.EnterFrameDrag;
    Session.DragFrameWider(40);
    Assert.IsTrue(Session.Designer.Dirty,
      'the frame drag did not reach the document as a change');
    Session.LeaveFrameDrag;
    Dragged := Session.RootClientWidth;
    Before := Session.ChangedCaption;
    Session.ChangeOutOfBand('changed after the drag');
    Session.StepBack;
    // Compared on two values, not the bytes: Edit1's Anchors include akRight,
    // so the widened form writes an ExplicitWidth line a restore does not.
    Assert.AreEqual(Before, Session.ChangedCaption,
      'the step back did not take back the change made outside the window');
    Assert.AreEqual(Dragged, Session.RootClientWidth,
      'the step back reached past that change and undid the frame drag as well');
    Assert.IsTrue(Session.Undo.CanUndo,
      'the change and the drag before it went in as one step');
  finally
    Session.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSettledImageTests);

end.
