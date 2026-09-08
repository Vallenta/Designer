// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.ZOrder;

// Covers TFormDesigner.RestackSelection and CanRestackSelection: bring to
// front, send to back, a group step, a step that moves nothing, a guarded
// document, the root, and undo and redo. A control's z-order is its index
// among its parent's children, which is the order the form file lists them in
// and which no property records, so every case reads a saved file.
//
// Each case starts the process-wide designer session and builds a
// TZOrderSession over basic_form.dfm. WrittenFile saves to one temp file
// named after the fixture and returns that path at every call, so a case
// comparing two saves copies the first aside.

interface

uses
  DUnitX.TestFramework;

type
  // Z-order steps on a loaded document, the cases that refuse one, and the
  // undo and redo of a step.
  [TestFixture]
  TZOrderTests = class
  public
    [Test]
    procedure AControlBroughtToTheFrontIsWrittenLast;
    [Test]
    procedure AControlSentToTheBackIsWrittenFirst;
    [Test]
    procedure AGroupKeepsItsOwnOrderWhileItTravels;
    [Test]
    procedure AControlAlreadyAtThatEndLeavesTheDocumentClean;
    [Test]
    procedure AGuardedDocumentKeepsItsOrder;
    [Test]
    procedure TheRootIsNoControlToRestack;
    [Test]
    procedure TheStepBackPutsTheOrderBack;
    [Test]
    procedure TheStepForwardPutsTheOrderBackAgain;
  end;

implementation

uses
  System.Classes,
  System.SysUtils,
  System.StrUtils,
  System.IOUtils,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Surface.FormDesigner,
  Vallenta.FormEditor.Surface.Undo,
  Vallenta.FormEditor.Tests.Environment;

const
  // basic_form.dfm holds Button1, Edit1 and Memo1 as children of the form,
  // in the order Stacked names them.
  Fixture = 'basic_form.dfm';
  Stacked: array [0 .. 2] of string = ('Button1', 'Edit1', 'Memo1');
  WrittenAsLoaded = 'Button1,Edit1,Memo1';
  // Upper bound on CheckSynchronize rounds; a queued call can queue another.
  PumpRounds = 32;

type
  // One fixture form loaded into a designer, with an undo stack wired to it.
  TZOrderSession = class
  private
    FLog: TDesignLog;
    FFileName: string;
    FWritten: string;
    FDocument: TDesignDocument;
    FDesigner: TFormDesigner;
    FUndo: TUndoStack;
    procedure Build(ALoader: TFormLoader);
    procedure Release;
    function CaptureDocument(Sender: TObject): TDocumentSnapshot;
    procedure RestoreDocument(Sender: TObject; ASnapshot: TDocumentSnapshot);
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    // Runs the calls the designer queued through TThread.ForceQueue.
    procedure Beat;
    // Selects the named components.
    procedure Select(const ANames: array of string);
    // Saves the document to the session's temp file and returns its path;
    // the path is the same at every call.
    function WrittenFile: string;
    // The Stacked controls in the order the written file lists them, comma
    // separated; saves the document first.
    function WrittenOrder: string;
    procedure StepBack;
    procedure StepForward;
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

constructor TZOrderSession.Create(const AFileName: string);
var
  Loader: TFormLoader;
begin
  inherited Create;
  FFileName := AFileName;
  FWritten := TPath.Combine(TPath.GetTempPath, 'vsfe_zorder_' +
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

destructor TZOrderSession.Destroy;
begin
  Release;
  TurnThePump;
  FUndo.Free;
  FLog.Free;
  DeleteFile(FWritten);
  inherited Destroy;
end;

procedure TZOrderSession.Build(ALoader: TFormLoader);
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

procedure TZOrderSession.Release;
begin
  // Freed before the document: the preserved placeholders are parented into
  // the document and would be freed a second time if it went first.
  FreeAndNil(FDesigner);
  FreeDesignDocument(FDocument);
end;

function TZOrderSession.CaptureDocument(Sender: TObject): TDocumentSnapshot;
begin
  Result := FDesigner.CaptureSnapshot;
end;

procedure TZOrderSession.RestoreDocument(Sender: TObject;
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

procedure TZOrderSession.Beat;
begin
  TurnThePump;
end;

procedure TZOrderSession.Select(const ANames: array of string);
var
  Chosen: TArray<TComponent>;
  Name: string;
begin
  Chosen := nil;
  for Name in ANames do
    Chosen := Chosen + [FDesigner.ComponentNamed(Name)];
  FDesigner.SelectMany(Chosen);
end;

function TZOrderSession.WrittenFile: string;
begin
  FDesigner.WriteTo(FWritten);
  Result := FWritten;
end;

function TZOrderSession.WrittenOrder: string;
var
  Lines: TStringList;
  Line, Found: string;
  I: Integer;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(WrittenFile);
    for I := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[I]);
      if not StartsText('object ', Line) then
        Continue;
      Found := Trim(Copy(Line, Length('object ') + 1, MaxInt));
      Found := Copy(Found, 1, Pos(':', Found) - 1);
      if not MatchText(Found, Stacked) then
        Continue;
      if Result <> '' then
        Result := Result + ',';
      Result := Result + Found;
    end;
  finally
    Lines.Free;
  end;
end;

procedure TZOrderSession.StepBack;
begin
  FUndo.Undo;
  Beat;
end;

procedure TZOrderSession.StepForward;
begin
  FUndo.Redo;
  Beat;
end;

// Copies ASource to a temp file kept as a baseline; a further WrittenFile
// call overwrites the path it returned before.
function Kept(const ASource, AName: string): string;
begin
  Result := TPath.Combine(TPath.GetTempPath, 'vsfe_zorder_kept_' + AName);
  TFile.Copy(ASource, Result, True);
end;

{ TZOrderTests }

procedure TZOrderTests.AControlBroughtToTheFrontIsWrittenLast;
var
  Session: TZOrderSession;
begin
  BeginDesignerSession;
  Session := TZOrderSession.Create(FixtureFile(Fixture));
  try
    Assert.AreEqual(WrittenAsLoaded, Session.WrittenOrder,
      'the premise: the file lists the controls as the fixture holds them');
    Session.Select(['Button1']);
    Session.Designer.RestackSelection(zsToFront);
    Session.Beat;
    Assert.AreEqual('Edit1,Memo1,Button1', Session.WrittenOrder,
      'the control brought to the front was not written last');
    Assert.IsTrue(Session.Designer.Dirty,
      'a z-order step left the document clean');
  finally
    Session.Free;
  end;
end;

procedure TZOrderTests.AControlSentToTheBackIsWrittenFirst;
var
  Session: TZOrderSession;
begin
  BeginDesignerSession;
  Session := TZOrderSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Memo1']);
    Session.Designer.RestackSelection(zsToBack);
    Session.Beat;
    Assert.AreEqual('Memo1,Button1,Edit1', Session.WrittenOrder,
      'the control sent to the back was not written first');
  finally
    Session.Free;
  end;
end;

// Selected in reverse of the file order: a step orders the moved controls by
// sibling index, so the selection order does not reach the file.
procedure TZOrderTests.AGroupKeepsItsOwnOrderWhileItTravels;
var
  Session: TZOrderSession;
begin
  BeginDesignerSession;
  Session := TZOrderSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Memo1', 'Button1']);
    Session.Designer.RestackSelection(zsToBack);
    Session.Beat;
    Assert.AreEqual('Button1,Memo1,Edit1', Session.WrittenOrder,
      'the group did not keep its own order at the back');
  finally
    Session.Free;
  end;
end;

// Memo1 is the last child in the fixture and so already at the front.
procedure TZOrderTests.AControlAlreadyAtThatEndLeavesTheDocumentClean;
var
  Session: TZOrderSession;
begin
  BeginDesignerSession;
  Session := TZOrderSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Memo1']);
    Session.Designer.RestackSelection(zsToFront);
    Session.Beat;
    Assert.AreEqual(WrittenAsLoaded, Session.WrittenOrder,
      'a step that moved nothing changed the file');
    Assert.IsFalse(Session.Designer.Dirty,
      'a step that moved nothing dirtied the document');
    Assert.IsFalse(Session.Undo.CanUndo,
      'a step that moved nothing left a step to come back to');
  finally
    Session.Free;
  end;
end;

procedure TZOrderTests.AGuardedDocumentKeepsItsOrder;
var
  Session: TZOrderSession;
begin
  BeginDesignerSession;
  Session := TZOrderSession.Create(FixtureFile(Fixture));
  try
    Session.Designer.GuardReadOnly;
    Session.Select(['Button1']);
    Assert.IsFalse(Session.Designer.CanRestackSelection,
      'a guarded document offered a z-order step');
    Session.Designer.RestackSelection(zsToFront);
    Session.Beat;
    Assert.AreEqual(WrittenAsLoaded, Session.WrittenOrder,
      'a guarded document was restacked');
  finally
    Session.Free;
  end;
end;

// SelectComponent(nil) selects the root, which the designer never counts
// among the controls a step moves.
procedure TZOrderTests.TheRootIsNoControlToRestack;
var
  Session: TZOrderSession;
begin
  BeginDesignerSession;
  Session := TZOrderSession.Create(FixtureFile(Fixture));
  try
    Session.Designer.SelectComponent(nil);
    Assert.IsFalse(Session.Designer.CanRestackSelection,
      'the root alone offered a z-order step');
    Session.Designer.RestackSelection(zsToBack);
    Session.Beat;
    Assert.AreEqual(WrittenAsLoaded, Session.WrittenOrder,
      'a step on the root changed the file');
  finally
    Session.Free;
  end;
end;

// Compares whole saved files against a copy taken before the step, so a
// restore that changed anything besides the order fails here as well.
procedure TZOrderTests.TheStepBackPutsTheOrderBack;
var
  Session: TZOrderSession;
  Before, Where: string;
begin
  BeginDesignerSession;
  Session := TZOrderSession.Create(FixtureFile(Fixture));
  try
    Session.Beat;
    Before := Kept(Session.WrittenFile, 'before.dfm');
    try
      Session.Select(['Button1']);
      Session.Designer.RestackSelection(zsToFront);
      Session.Beat;
      Assert.IsFalse(SameBytes(Before, Session.WrittenFile, Where),
        'the case moved nothing, so it measures nothing');
      Assert.IsTrue(Session.Undo.CanUndo,
        'a z-order step left no step to come back to');
      Session.StepBack;
      Assert.IsTrue(SameBytes(Before, Session.WrittenFile, Where),
        'the step back did not put the order back: ' + Where);
    finally
      DeleteFile(Before);
    end;
  finally
    Session.Free;
  end;
end;

procedure TZOrderTests.TheStepForwardPutsTheOrderBackAgain;
var
  Session: TZOrderSession;
begin
  BeginDesignerSession;
  Session := TZOrderSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Button1']);
    Session.Designer.RestackSelection(zsToFront);
    Session.Beat;
    Session.StepBack;
    Assert.AreEqual(WrittenAsLoaded, Session.WrittenOrder,
      'the step back did not put the order back');
    Assert.IsTrue(Session.Undo.CanRedo,
      'the step taken back left nothing to do again');
    Session.StepForward;
    Assert.AreEqual('Edit1,Memo1,Button1', Session.WrittenOrder,
      'the step done again did not bring the control back to the front');
    Assert.IsTrue(Session.Undo.CanUndo,
      'the step done again left nothing to come back to');
    Assert.IsTrue(Session.Designer.Dirty,
      'the step done again left the document clean');
  finally
    Session.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TZOrderTests);

end.
