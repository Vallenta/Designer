// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.Rename;

// Covers the designer side of component, root and handler renames: what the
// designer refuses before a request goes out, what the request carries, and
// what an answer applies to the document. The wire the request travels on is
// covered by Tests.Protocol.
//
// Each case drives a real TFormDesigner over a fixture form file, with the
// undo stack and the rename register wired to it as TMainDesignerForm wires
// them. The ICodeCoupling implementation is a stub that holds the field
// ledger, records requests and answers only when a case calls for it, so a
// row waiting for an answer is reachable.

interface

uses
  DUnitX.TestFramework;

type
  // Component, root and handler renames, and the object inspector's Name row.
  [TestFixture]
  TRenameTests = class
  public
    [Test]
    procedure ATypedNameGoesOutWithTheHandlersNamedAfterTheComponent;
    [Test]
    procedure ARowWaitsUntilTheNameIsAnsweredFor;
    [Test]
    procedure ANameNoUnitCouldDeclareNeverLeavesTheDesigner;
    [Test]
    procedure ANameSomethingElseAlreadyHasNeverLeavesTheDesigner;
    [Test]
    procedure ANameAPreservedBlockOwnsNeverLeavesTheDesigner;
    [Test]
    procedure AComponentTheFormIsBuiltOnNeverLeavesTheDesigner;
    [Test]
    procedure ADocumentWithNoEditorRefusesBeforeAnythingIsSent;
    [Test]
    procedure ARenameThatCouldNotBeSentLeavesNothingWaiting;
    [Test]
    procedure AnAnsweredRenameMovesTheComponentAndItsHandler;
    [Test]
    procedure AnAnsweredRenameLeavesTheHandlerNobodyNamedAfterIt;
    [Test]
    procedure TheRootsOwnNameIsWhatARootRenameMoves;
    [Test]
    procedure TheClassFollowsWhenTheEditorSaysItRenamedIt;
    [Test]
    procedure TheLedgerKeepsTheFieldUnderItsNewName;
    [Test]
    procedure ARefusalTakesBackTheStepItWasRecordedUnderAndWritesTheSameBytes;
    [Test]
    procedure ARefusalTakesBackItsOwnStepAndNotWhateverIsOnTop;
    [Test]
    procedure AnAnsweredRenameKeepsTheStepItWasRecordedUnder;
    [Test]
    procedure ARenameOfSomethingTheDocumentNoLongerHoldsIsAStepThatDidNotHappen;
    [Test]
    procedure AHandlerRenameMovesTheMapAndNoComponent;
    [Test]
    procedure DeletingAComponentIsNotARenameAndIsNotRefused;
    [Test]
    procedure TheFrameworksOwnNamingMomentsAreNotRefused;
    [Test]
    procedure AFormWhoseUnitDeclaresNoneOfItIsStillRenamedHere;
    [Test]
    procedure AnAnswerResolvesItsOwnRenameAndNotAnother;
    [Test]
    procedure BothRowSourcesCallTheNameARowOfItsOwn;
    [Test]
    procedure BothRowSourcesRefuseTheNameWithNoEditorAttached;
    [Test]
    procedure BothRowSourcesRefuseTheNameWhileOneIsOnItsWay;
    [Test]
    procedure ANameRowIsWrittenByAskingRatherThanBySetting;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.IOUtils,
  System.TypInfo,
  Vcl.Forms,
  DesignIntf,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Core.FieldLedger,
  Vallenta.FormEditor.Core.Coupling,
  Vallenta.FormEditor.Streaming.EventNames,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Inspector.PropertyModel,
  Vallenta.FormEditor.Surface.FormDesigner,
  Vallenta.FormEditor.Surface.Undo,
  Vallenta.FormEditor.Tests.Environment;

const
  // EventButton's OnClick and EventEdit's OnChange carry IDE-style handler
  // names: a rename of EventButton moves its handler, and EventEdit's
  // handler is unrelated and must stay unchanged.
  WiredFixture = 'event_handlers.dfm';
  WiredButton = 'EventButton';
  WiredHandler = 'EventButtonClick';
  // A form built on another one; BaseButton's field is declared in the
  // ancestor's unit.
  InheritedFixture = 'vfi_child.dfm';
  InheritedComponent = 'BaseButton';
  // Holds blocks of classes no loaded package registers; their names are
  // reserved for the saved text.
  PreservedFixture = 'preserved_unknown.dfm';

type
  // Stands in for the code editor behind ICodeCoupling: records the rename
  // requests and answers them when a case calls for it. NoteRenamed moves the
  // key in a real TFieldLedger, Available reports True, and the remaining
  // methods do nothing.
  TStubEditor = class(TInterfacedObject, ICodeCoupling)
  private
    FAsked: TStringList;
    FTokens: TList<Integer>;
    FLedger: TFieldLedger;
    FRefusesToSend: string;
    FOnRenamed: TRenameAnswered;
  public
    constructor Create;
    destructor Destroy; override;
    { ICodeCoupling }
    function Available: Boolean;
    procedure ListMethods(ARequest: Integer; const ASignature: TEventSignature;
      const AWhen: TMethodListCallback);
    procedure EnsureHandler(const AComponent, AEvent, AMethod: string;
      const ASignature: TEventSignature);
    procedure RemoveHandler(const AMethod: string);
    procedure GotoHandler(const AMethod: string);
    function RenameComponent(AToken: Integer; AKind: TRenameKind;
      const AOldName, ANewName: string;
      const AMethods: TArray<TMethodRename>): string;
    procedure NoteRenamed(const AOldName, ANewName: string);
    // The most recent request as one line, and '(nothing)' when no request
    // was recorded.
    function Asked: string;
    function Count: Integer;
    // Answers the request made at AOrdinal, one-based. ANewClassName names the
    // class the editor renamed with the root; empty when it renamed none.
    procedure Answer(AOrdinal: Integer; AOk: Boolean; const AReason: string;
      const ANewClassName: string = '');
    // Answers with PrimaryRenamed False and ASkipped as the methods the unit
    // declares none of; both are informational, not a refusal.
    procedure AnswerWithNothingToMove(AOrdinal: Integer;
      const ASkipped: TArray<string>);
    property Ledger: TFieldLedger read FLedger;
    // Refusal text RenameComponent returns instead of recording the request;
    // empty lets requests through.
    property RefusesToSend: string read FRefusesToSend write FRefusesToSend;
    property OnRenamed: TRenameAnswered read FOnRenamed write FOnRenamed;
  end;

  // One loaded document with the undo stack, the rename register and the stub
  // editor wired to it as TMainDesignerForm wires the real ones.
  TRenameSession = class
  private
    FLog: TDesignLog;
    FFileName: string;
    FWritten: string;
    FDocument: TDesignDocument;
    FDesigner: TFormDesigner;
    FUndo: TUndoStack;
    FRenames: TRenameRegister;
    FEditor: TStubEditor;
    FCoupling: ICodeCoupling;
    FCoupled: Boolean;
    FSettled: Integer;
    FFellBack: Boolean;
    procedure Watch(Sender: TObject; const AEntry: TDesignLogEntry);
    procedure Build(ALoader: TFormLoader);
    procedure Release;
    function CaptureDocument(Sender: TObject): TDocumentSnapshot;
    procedure RestoreDocument(Sender: TObject; ASnapshot: TDocumentSnapshot);
    function CurrentStep: Integer;
    function Coupled: Boolean;
    function StartRename(AKind: TRenameKind; const AOldName, ANewName: string;
      const AMethods: TArray<TMethodRename>): string;
    function RenameInFlight(const AName: string): Boolean;
    function ApplyRename(AKind: TRenameKind; const AOldName, ANewName: string;
      const AMethods: TArray<TMethodRename>;
      const ANewClassName: string): Boolean;
    procedure DropStep(AStep: Integer);
    procedure Settled(Sender: TObject);
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    // Renames through the inspector's grid write bracket: an undo entry is
    // pushed before the request and dropped again when the designer refuses
    // outright. Returns the refusal text, empty when the request went out.
    function TypeIntoTheNameRow(const AComponent, ANewName: string): string;
    // Records one unrelated history step, so an answer arriving later has a
    // newer entry above its own.
    procedure MoveSomething;
    // The named component, or the root when AName is the root's own name.
    function ComponentNamed(const AName: string): TComponent;
    function WiredName(const AComponent, AEvent: string): string;
    // The Name row of AComponent, built into AModel. AFromEditors builds from
    // the hosted property editors rather than from type information, and
    // raises when that build fell back to type information.
    function RowsFor(const AComponent: string; AFromEditors: Boolean;
      AModel: TPropertyModel): TPropertyRow;
    // Saves the document to a temporary file and returns the text written.
    function WrittenFile: string;
    property Designer: TFormDesigner read FDesigner;
    property Undo: TUndoStack read FUndo;
    property Editor: TStubEditor read FEditor;
    property Renames: TRenameRegister read FRenames;
    // Named Notes because DUnitX's class helper for TObject declares Log.
    property Notes: TDesignLog read FLog;
    // Whether an editor is attached; answers the designer's coupling query.
    property Coupling: Boolean read FCoupled write FCoupled;
    property Settles: Integer read FSettled;
  end;

{ TStubEditor }

constructor TStubEditor.Create;
begin
  inherited Create;
  FAsked := TStringList.Create;
  FTokens := TList<Integer>.Create;
  FLedger := TFieldLedger.Create;
end;

destructor TStubEditor.Destroy;
begin
  FLedger.Free;
  FTokens.Free;
  FAsked.Free;
  inherited Destroy;
end;

function TStubEditor.Available: Boolean;
begin
  Result := True;
end;

procedure TStubEditor.ListMethods(ARequest: Integer;
  const ASignature: TEventSignature; const AWhen: TMethodListCallback);
begin
end;

procedure TStubEditor.EnsureHandler(const AComponent, AEvent, AMethod: string;
  const ASignature: TEventSignature);
begin
end;

procedure TStubEditor.RemoveHandler(const AMethod: string);
begin
end;

procedure TStubEditor.GotoHandler(const AMethod: string);
begin
end;

function TStubEditor.RenameComponent(AToken: Integer; AKind: TRenameKind;
  const AOldName, ANewName: string;
  const AMethods: TArray<TMethodRename>): string;
var
  Line: string;
  Pair: TMethodRename;
begin
  Result := FRefusesToSend;
  if Result <> '' then
    Exit;
  Line := Format('%d:%s->%s', [Ord(AKind), AOldName, ANewName]);
  for Pair in AMethods do
    Line := Line + Format(' [%s->%s]', [Pair.OldName, Pair.NewName]);
  FAsked.Add(Line);
  FTokens.Add(AToken);
end;

procedure TStubEditor.NoteRenamed(const AOldName, ANewName: string);
begin
  FLedger.RenameKey(AOldName, ANewName);
end;

function TStubEditor.Asked: string;
begin
  if FAsked.Count = 0 then
    Exit('(nothing)');
  Result := FAsked[FAsked.Count - 1];
end;

function TStubEditor.Count: Integer;
begin
  Result := FAsked.Count;
end;

procedure TStubEditor.Answer(AOrdinal: Integer; AOk: Boolean;
  const AReason: string; const ANewClassName: string);
var
  Answer: TRenameAnswer;
begin
  Answer := Default(TRenameAnswer);
  Answer.Token := FTokens[AOrdinal - 1];
  Answer.Ok := AOk;
  Answer.Reason := AReason;
  Answer.PrimaryRenamed := True;
  Answer.NewClassName := ANewClassName;
  if Assigned(FOnRenamed) then
    FOnRenamed(Answer);
end;

procedure TStubEditor.AnswerWithNothingToMove(AOrdinal: Integer;
  const ASkipped: TArray<string>);
var
  Answer: TRenameAnswer;
begin
  Answer := Default(TRenameAnswer);
  Answer.Token := FTokens[AOrdinal - 1];
  Answer.Ok := True;
  Answer.PrimaryRenamed := False;
  Answer.SkippedMethods := ASkipped;
  if Assigned(FOnRenamed) then
    FOnRenamed(Answer);
end;

{ TRenameSession }

constructor TRenameSession.Create(const AFileName: string);
var
  Loader: TFormLoader;
begin
  inherited Create;
  FFileName := AFileName;
  FWritten := TPath.Combine(TPath.GetTempPath,
    'vsfe_rename_' + TPath.GetFileName(AFileName));
  FCoupled := True;
  FLog := TDesignLog.Create;
  FLog.AddListener(Watch);
  FUndo := TUndoStack.Create;
  FUndo.OnCapture := CaptureDocument;
  FUndo.OnRestore := RestoreDocument;
  FEditor := TStubEditor.Create;
  FCoupling := FEditor;
  FRenames := TRenameRegister.Create;
  FRenames.Log := FLog;
  FRenames.OnCurrentStep := CurrentStep;
  FRenames.OnDropStep := DropStep;
  FRenames.OnApply := ApplyRename;
  FRenames.OnSettled := Settled;
  FEditor.OnRenamed := FRenames.Answered;
  Loader := TFormLoader.Create(FLog);
  try
    Loader.Prepare(AFileName);
    Build(Loader);
  finally
    Loader.Free;
  end;
  // Baselined as TDocumentCoupling.Resume baselines a document on first
  // attach; without it a moved ledger key reads as a new field.
  FEditor.Ledger.Baseline(FDesigner.DesignedFields);
end;

destructor TRenameSession.Destroy;
begin
  Release;
  // Drains the closures the designer left in TThread.ForceQueue; each holds
  // an interface reference captured from the designer until the queue is
  // emptied.
  while CheckSynchronize do
    ;
  FRenames.Free;
  FCoupling := nil;
  FUndo.Free;
  FLog.Free;
  DeleteFile(FWritten);
  inherited Destroy;
end;

// Matches the wording TPropertyModel.NoteFallback writes; a change to that
// message disables the fallback guard in RowsFor without failing a case.
procedure TRenameSession.Watch(Sender: TObject; const AEntry: TDesignLogEntry);
begin
  if Pos('the hosted editors did not describe', AEntry.Text) > 0 then
    FFellBack := True;
end;

// A restore calls this again, so the undo stack and the rename register are
// held outside the designer and outlive it.
procedure TRenameSession.Build(ALoader: TFormLoader);
begin
  FDocument := CreateDesignDocument(ALoader.RootKind);
  FDesigner := TFormDesigner.Create(FDocument.HostForm, FDocument.Root, FLog);
  FDesigner.UndoStack := FUndo;
  FDesigner.OnCouplingQuery := Coupled;
  FDesigner.OnRenameRequest := StartRename;
  FDesigner.OnRenameQuery := RenameInFlight;
  FDesigner.CodeCoupling := FCoupling;
  ALoader.StreamInto(FDocument.Root);
  FDesigner.AttachLoaded(FFileName, ALoader.ExtractEventMap,
    ALoader.ExtractPreserved, ALoader.ExtractFrames, ALoader.ExtractAncestor,
    ALoader.LoadedState);
  FDesigner.ShowPlaceholders;
  FDesigner.BeginEditing;
end;

procedure TRenameSession.Release;
begin
  // The designer is freed first: it frees the preserved model's placeholders,
  // which the document's containers would otherwise free as their children.
  FreeAndNil(FDesigner);
  FreeDesignDocument(FDocument);
end;

function TRenameSession.CaptureDocument(Sender: TObject): TDocumentSnapshot;
begin
  Result := FDesigner.CaptureSnapshot;
end;

procedure TRenameSession.RestoreDocument(Sender: TObject;
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
    FDesigner.MarkDirty(FUndo.IsDirty);
  finally
    Loader.Free;
  end;
end;

function TRenameSession.CurrentStep: Integer;
begin
  Result := FUndo.LastStep;
end;

function TRenameSession.Coupled: Boolean;
begin
  Result := FCoupled;
end;

function TRenameSession.StartRename(AKind: TRenameKind;
  const AOldName, ANewName: string;
  const AMethods: TArray<TMethodRename>): string;
begin
  Result := FRenames.Start(FCoupling, AKind, AOldName, ANewName, AMethods);
end;

function TRenameSession.RenameInFlight(const AName: string): Boolean;
begin
  Result := FRenames.InFlight(AName);
end;

function TRenameSession.ApplyRename(AKind: TRenameKind;
  const AOldName, ANewName: string;
  const AMethods: TArray<TMethodRename>;
  const ANewClassName: string): Boolean;
begin
  Result := (FDesigner <> nil) and
    FDesigner.ApplyRename(AKind, AOldName, ANewName, AMethods, ANewClassName);
end;

procedure TRenameSession.DropStep(AStep: Integer);
begin
  FUndo.DropStep(AStep);
end;

procedure TRenameSession.Settled(Sender: TObject);
begin
  Inc(FSettled);
end;

function TRenameSession.TypeIntoTheNameRow(const AComponent,
  ANewName: string): string;
begin
  FDesigner.BeginGridEdit;
  FDesigner.PushUndo(uoProperty);
  try
    Result := FDesigner.BeginRename(ComponentNamed(AComponent), ANewName);
  finally
    FDesigner.EndGridEdit;
  end;
  if Result <> '' then
    FDesigner.DropUndo;
end;

procedure TRenameSession.MoveSomething;
begin
  FDesigner.PushUndo(uoMove);
  FDesigner.NotifyEdited;
end;

function TRenameSession.ComponentNamed(const AName: string): TComponent;
begin
  if SameText(AName, FDesigner.Root.Name) then
    Exit(FDesigner.Root);
  Result := FDesigner.ComponentNamed(AName);
end;

function TRenameSession.WiredName(const AComponent, AEvent: string): string;
var
  Method: TMethod;
begin
  Method := GetMethodProp(ComponentNamed(AComponent), AEvent);
  Result := FDesigner.EventMap.NameFor(Method);
end;

function TRenameSession.RowsFor(const AComponent: string;
  AFromEditors: Boolean; AModel: TPropertyModel): TPropertyRow;
var
  Designer: IDesigner;
  Row: TPropertyRow;
begin
  Result := nil;
  Designer := nil;
  if AFromEditors then
    Designer := FDesigner.HostDesigner;
  FFellBack := False;
  AModel.Log := FLog;
  AModel.CodeCoupling := FCoupling;
  AModel.CouplingQuery := Coupled;
  AModel.Rename := FDesigner;
  AModel.BuildMany([ComponentNamed(AComponent)], FDesigner.Root,
    FDesigner.EventMap, False, Designer);
  if AFromEditors and FFellBack then
    raise Exception.Create('the hosted editors described nothing, so this run ' +
      'held type information against itself');
  for Row in AModel.Rows do
    if SameText(Row.Name, 'Name') then
      Exit(Row);
end;

function TRenameSession.WrittenFile: string;
begin
  FDesigner.WriteTo(FWritten);
  Result := TFile.ReadAllText(FWritten);
end;

{ TRenameTests }

procedure TRenameTests.ATypedNameGoesOutWithTheHandlersNamedAfterTheComponent;
var
  Session: TRenameSession;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Assert.AreEqual('', Session.TypeIntoTheNameRow(WiredButton, 'SaveButton'),
      'a name nothing was wrong with was refused');
    Assert.AreEqual('0:EventButton->SaveButton [EventButtonClick->SaveButtonClick]',
      Session.Editor.Asked,
      'the request did not carry the component and the handler named after it');
  finally
    Session.Free;
  end;
end;

// The component keeps its old name until the answer arrives, and a second
// rename of it is refused while the first is in flight.
procedure TRenameTests.ARowWaitsUntilTheNameIsAnsweredFor;
var
  Session: TRenameSession;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Session.TypeIntoTheNameRow(WiredButton, 'SaveButton');
    Assert.IsTrue(Session.Designer.RenameInFlight(
      Session.ComponentNamed(WiredButton)), 'the row was not left waiting');
    Assert.AreEqual(WiredButton, Session.ComponentNamed(WiredButton).Name, False,
      'the component was renamed before anybody had agreed to it');
    Assert.AreNotEqual('', Session.TypeIntoTheNameRow(WiredButton, 'OtherName'),
      'a second name was taken while the first was still on its way');
    Assert.AreEqual(1, Session.Editor.Count,
      'the second name was sent as well');
    Session.Editor.Answer(1, True, '');
    Assert.IsFalse(Session.Designer.RenameInFlight(
      Session.ComponentNamed('SaveButton')),
      'the row was still waiting after the answer');
  finally
    Session.Free;
  end;
end;

procedure TRenameTests.ANameNoUnitCouldDeclareNeverLeavesTheDesigner;
var
  Session: TRenameSession;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Assert.Contains(Session.TypeIntoTheNameRow(WiredButton, '2Save'),
      'not a name a unit could declare',
      'a name no unit could declare was not refused in those words');
    Assert.Contains(Session.TypeIntoTheNameRow(WiredButton, ''),
      'has to have a name', 'an empty name was not refused');
    Assert.AreEqual(0, Session.Editor.Count,
      'a name the designer itself refuses was sent anyway');
  finally
    Session.Free;
  end;
end;

// A collision is decided by instance, so a case-only respelling of a
// component's own name is a rename rather than a collision.
procedure TRenameTests.ANameSomethingElseAlreadyHasNeverLeavesTheDesigner;
var
  Session: TRenameSession;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Assert.Contains(Session.TypeIntoTheNameRow(WiredButton, 'EventEdit'),
      'already the name of something',
      'a name another component has was not refused');
    Assert.AreEqual(0, Session.Editor.Count, 'it was sent anyway');
    Assert.AreEqual('', Session.TypeIntoTheNameRow(WiredButton, 'eventbutton'),
      'a component was refused its own name in another spelling');
  finally
    Session.Free;
  end;
end;

// A preserved block keeps its name in the saved file, so the designer refuses
// that name for the same reason UniqueName skips it.
procedure TRenameTests.ANameAPreservedBlockOwnsNeverLeavesTheDesigner;
var
  Session: TRenameSession;
  Reserved: string;
begin
  Session := TRenameSession.Create(FixtureFile(PreservedFixture));
  try
    Reserved := Session.Designer.Preserved.Pieces[0].ComponentName;
    Assert.AreNotEqual('', Reserved, 'the fixture kept nothing verbatim');
    Assert.AreNotEqual('',
      Session.TypeIntoTheNameRow(Session.Designer.Root.Name, Reserved),
      'a name a preserved block owns was accepted');
    Assert.AreEqual(0, Session.Editor.Count, 'it was sent anyway');
  finally
    Session.Free;
  end;
end;

// The field of an inherited component is declared in the ancestor's unit,
// which this document does not write.
procedure TRenameTests.AComponentTheFormIsBuiltOnNeverLeavesTheDesigner;
var
  Session: TRenameSession;
begin
  Session := TRenameSession.Create(FixtureFile(InheritedFixture));
  try
    Assert.Contains(
      Session.TypeIntoTheNameRow(InheritedComponent, 'OtherButton'),
      'built on', 'an inherited component was not refused in those words');
    Assert.AreEqual(0, Session.Editor.Count,
      'a component of the ancestor was sent to be renamed');
  finally
    Session.Free;
  end;
end;

procedure TRenameTests.ADocumentWithNoEditorRefusesBeforeAnythingIsSent;
var
  Session: TRenameSession;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Session.Coupling := False;
    Assert.Contains(Session.TypeIntoTheNameRow(WiredButton, 'SaveButton'),
      'no editor is attached',
      'an uncoupled document did not refuse in the interim words');
    Assert.AreEqual(0, Session.Editor.Count, 'it was sent anyway');
  finally
    Session.Free;
  end;
end;

// A session can detach between the row being offered and the name being
// typed, so RenameComponent refuses the send. The refusal is returned
// synchronously and no answer follows.
procedure TRenameTests.ARenameThatCouldNotBeSentLeavesNothingWaiting;
var
  Session: TRenameSession;
  Step: Integer;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Step := Session.Undo.LastStep;
    Session.Editor.RefusesToSend := 'VS Code is not attached to this document';
    Assert.AreEqual('VS Code is not attached to this document',
      Session.TypeIntoTheNameRow(WiredButton, 'SaveButton'), False,
      'a rename that could not be sent did not say so to what asked for it');
    Assert.AreEqual(0, Session.Renames.Count,
      'a request that never went out was written down as waiting for an answer');
    Assert.AreEqual(Step, Session.Undo.LastStep,
      'the entry recorded for it was not given back');
    Assert.IsFalse(Session.Designer.RenameInFlight(
      Session.ComponentNamed(WiredButton)), 'the row was left waiting');
    Assert.IsFalse(Session.Designer.Dirty,
      'a rename that never went out marked the document as changed');
    Assert.AreEqual(0, Session.Settles,
      'the rows were rebuilt underneath the write that was still running');
  finally
    Session.Free;
  end;
end;

procedure TRenameTests.AnAnsweredRenameMovesTheComponentAndItsHandler;
var
  Session: TRenameSession;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Session.TypeIntoTheNameRow(WiredButton, 'SaveButton');
    Session.Editor.Answer(1, True, '');
    Assert.IsNotNull(Session.ComponentNamed('SaveButton'),
      'the component did not take the new name');
    Assert.IsNull(Session.ComponentNamed(WiredButton),
      'the component still answers to the old name');
    Assert.AreEqual('SaveButtonClick',
      Session.WiredName('SaveButton', 'OnClick'),
      'the handler named after the component did not move with it');
    Assert.IsTrue(Session.Designer.Dirty,
      'a document that was renamed was not marked as changed');
  finally
    Session.Free;
  end;
end;

procedure TRenameTests.AnAnsweredRenameLeavesTheHandlerNobodyNamedAfterIt;
var
  Session: TRenameSession;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Session.TypeIntoTheNameRow(WiredButton, 'SaveButton');
    Session.Editor.Answer(1, True, '');
    Assert.AreEqual('EventEditChange', Session.WiredName('EventEdit', 'OnChange'),
      'another component''s handler was renamed as well');
  finally
    Session.Free;
  end;
end;

// A root rename moves the object name the form file carries and leaves the
// declared class name alone, since this answer names no new class.
procedure TRenameTests.TheRootsOwnNameIsWhatARootRenameMoves;
var
  Session: TRenameSession;
  DeclaredClass: string;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    DeclaredClass := Session.Designer.RootClassName;
    Assert.AreEqual('', Session.TypeIntoTheNameRow('EventForm', 'MainForm'),
      'the root was refused its own rename');
    Assert.AreEqual('1:EventForm->MainForm', Session.Editor.Asked,
      'a root rename did not say it was one');
    Session.Editor.Answer(1, True, '');
    Assert.AreEqual('MainForm', Session.Designer.Root.Name, False,
      'the root did not take the new name');
    Assert.AreEqual(DeclaredClass, Session.Designer.RootClassName, False,
      'renaming the root renamed the class it declares');
    Assert.Contains(Session.WrittenFile, 'object MainForm: ' + DeclaredClass,
      'the saved file does not carry the root''s new name');
  finally
    Session.Free;
  end;
end;

// The saved header must name the class the unit declares, so the class name
// the answer carries is adopted and written.
procedure TRenameTests.TheClassFollowsWhenTheEditorSaysItRenamedIt;
var
  Session: TRenameSession;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Assert.AreEqual('', Session.TypeIntoTheNameRow('EventForm', 'MainForm'),
      'the root was refused its own rename');
    Session.Editor.Answer(1, True, '', 'TMainForm');
    Assert.AreEqual('TMainForm', Session.Designer.RootClassName, False,
      'the class the editor renamed was not adopted');
    Assert.Contains(Session.WrittenFile, 'object MainForm: TMainForm',
      'the saved file does not carry the renamed class');
  finally
    Session.Free;
  end;
end;

// A rename moves the ledger key in place, so the next settle point reports no
// field change rather than a removal plus an addition.
procedure TRenameTests.TheLedgerKeepsTheFieldUnderItsNewName;
var
  Session: TRenameSession;
  Before: Integer;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Before := Session.Editor.Ledger.Count;
    Session.TypeIntoTheNameRow(WiredButton, 'SaveButton');
    Session.Editor.Answer(1, True, '');
    Assert.AreEqual(Before, Session.Editor.Ledger.Count,
      'the ledger gained or lost an entry over a rename');
    Assert.AreEqual(0,
      Length(Session.Editor.Ledger.Diff(Session.Designer.DesignedFields)),
      'the next settle point would report the rename as a field change');
  finally
    Session.Free;
  end;
end;

// The history entry is recorded before the request goes out, so a refusal has
// one to take back; the refusal still fires the settle point.
procedure TRenameTests.ARefusalTakesBackTheStepItWasRecordedUnderAndWritesTheSameBytes;
var
  Session: TRenameSession;
  Before: string;
  Depth: Integer;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Before := Session.WrittenFile;
    Depth := Session.Undo.LastStep;
    Session.TypeIntoTheNameRow(WiredButton, 'SaveButton');
    Assert.AreNotEqual(Depth, Session.Undo.LastStep,
      'the step was not recorded before the request went out');
    Session.Editor.Answer(1, False, 'a field named SaveButton already exists');
    Assert.AreEqual(Depth, Session.Undo.LastStep,
      'the entry recorded for a step that did not happen was left behind');
    Assert.AreEqual(WiredButton, Session.ComponentNamed(WiredButton).Name, False,
      'the component was renamed although the rename was refused');
    Assert.AreEqual('EventButtonClick',
      Session.WiredName(WiredButton, 'OnClick'),
      'the handler was renamed although the rename was refused');
    Assert.AreEqual(Before, Session.WrittenFile, False,
      'a refused rename moved something in the saved file');
    Assert.AreEqual(1, Session.Settles,
      'nothing was told that the row had stopped waiting');
  finally
    Session.Free;
  end;
end;

// Editing continues while an answer travels, so the entry is dropped by step
// number rather than from the top of the history.
procedure TRenameTests.ARefusalTakesBackItsOwnStepAndNotWhateverIsOnTop;
var
  Session: TRenameSession;
  Newest: Integer;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Session.TypeIntoTheNameRow(WiredButton, 'SaveButton');
    Session.MoveSomething;
    Newest := Session.Undo.LastStep;
    Session.Editor.Answer(1, False, 'no');
    Assert.AreEqual(Newest, Session.Undo.LastStep,
      'the refusal took back the newest step instead of its own');
  finally
    Session.Free;
  end;
end;

procedure TRenameTests.AnAnsweredRenameKeepsTheStepItWasRecordedUnder;
var
  Session: TRenameSession;
  Step: Integer;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Session.TypeIntoTheNameRow(WiredButton, 'SaveButton');
    Step := Session.Undo.LastStep;
    Session.Editor.Answer(1, True, '');
    Assert.AreEqual(Step, Session.Undo.LastStep,
      'a rename that happened left nothing to come back to');
    Session.Undo.Undo;
    Assert.IsNotNull(Session.ComponentNamed(WiredButton),
      'taking the step back did not bring the old name with it');
  finally
    Session.Free;
  end;
end;

// An answer naming a component this document no longer holds is not applied:
// its history entry is dropped and the mismatch is written to the log.
procedure TRenameTests.ARenameOfSomethingTheDocumentNoLongerHoldsIsAStepThatDidNotHappen;
var
  Session: TRenameSession;
  Step: Integer;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Step := Session.Undo.LastStep;
    Session.TypeIntoTheNameRow('EventEdit', 'SaveEdit');
    // Renaming by hand leaves nothing under the name the answer carries, the
    // state an undo while the answer travelled produces.
    Session.ComponentNamed('EventEdit').Name := 'RenamedByHand';
    Session.Editor.Answer(1, True, '');
    Assert.AreEqual(Step, Session.Undo.LastStep,
      'the entry for a rename that could not be applied was left behind');
    Assert.IsTrue(Session.Notes.Count > 0, 'nothing was said about it');
  finally
    Session.Free;
  end;
end;

procedure TRenameTests.AHandlerRenameMovesTheMapAndNoComponent;
var
  Session: TRenameSession;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Assert.AreEqual('',
      Session.Designer.BeginMethodRename(WiredHandler, 'StoreAll'),
      'a handler this form is wired to was refused');
    Assert.AreEqual('2:EventButtonClick->StoreAll [EventButtonClick->StoreAll]',
      Session.Editor.Asked, 'a handler rename named a primary symbol');
    Session.Editor.Answer(1, True, '');
    Assert.AreEqual('StoreAll', Session.WiredName(WiredButton, 'OnClick'),
      'the map did not take the new name');
    Assert.AreEqual(WiredButton, Session.ComponentNamed(WiredButton).Name, False,
      'a handler rename renamed a component as well');
    Assert.AreNotEqual('',
      Session.Designer.BeginMethodRename('NotWiredAnywhere', 'StoreAll'),
      'a method this form knows nothing about was sent to be renamed');
  finally
    Session.Free;
  end;
end;

// Deletion reaches ValidateRename through System.Classes RemoveComponent,
// which passes an empty new name from inside the destructor; a refusal there
// would raise EComponentError out of a half-finished destruction.
procedure TRenameTests.DeletingAComponentIsNotARenameAndIsNotRefused;
var
  Session: TRenameSession;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Session.Designer.SelectComponent(Session.ComponentNamed('EventEdit'));
    Session.Designer.DeleteSelection;
    Assert.IsNull(Session.ComponentNamed('EventEdit'),
      'the component was still there after being deleted');
    Assert.AreEqual(0, Session.Editor.Count,
      'deleting a component asked the editor to rename something');
  finally
    Session.Free;
  end;
end;

// RemoveComponent reports an empty new name and InsertComponent an empty
// current name; both pass unchecked, since a refusal would raise out of VCL
// machinery. A rename onto a taken name still raises EComponentError.
procedure TRenameTests.TheFrameworksOwnNamingMomentsAreNotRefused;
var
  Session: TRenameSession;
  Component: TComponent;
  Hook: IDesignerHook;
  Refused: Boolean;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Component := Session.ComponentNamed(WiredButton);
    Hook := Session.Designer;
    Hook.ValidateRename(Component, WiredButton, '');
    Hook.ValidateRename(Component, '', 'Whatever');
    Refused := False;
    try
      Hook.ValidateRename(Component, WiredButton, 'EventEdit');
    except
      on EComponentError do
        Refused := True;
    end;
    Assert.IsTrue(Refused, 'a name another component holds was not refused');
  finally
    Session.Free;
  end;
end;

// PrimaryRenamed False and skipped methods are informational: the unit
// declared no field or method to move, and the form-file rename still holds.
procedure TRenameTests.AFormWhoseUnitDeclaresNoneOfItIsStillRenamedHere;
var
  Session: TRenameSession;
  Step: Integer;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Session.TypeIntoTheNameRow(WiredButton, 'SaveButton');
    Step := Session.Undo.LastStep;
    Session.Editor.AnswerWithNothingToMove(1, [WiredHandler]);
    Assert.IsNotNull(Session.ComponentNamed('SaveButton'),
      'a component whose unit declares no field for it was not renamed');
    Assert.AreEqual('SaveButtonClick',
      Session.WiredName('SaveButton', 'OnClick'),
      'the handler named after it did not move with it');
    Assert.AreEqual(Step, Session.Undo.LastStep,
      'the step was taken back although the rename happened');
    Assert.IsTrue(Session.Notes.Count > 0,
      'nothing was said about the unit declaring none of it');
  finally
    Session.Free;
  end;
end;

procedure TRenameTests.AnAnswerResolvesItsOwnRenameAndNotAnother;
var
  Session: TRenameSession;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  try
    Session.TypeIntoTheNameRow(WiredButton, 'SaveButton');
    Session.TypeIntoTheNameRow('EventEdit', 'SaveEdit');
    Assert.AreEqual(2, Session.Renames.Count, 'both renames are not in flight');
    Session.Editor.Answer(2, True, '');
    Assert.AreEqual(1, Session.Renames.Count,
      'answering the second resolved something else as well');
    Assert.IsNotNull(Session.ComponentNamed('SaveEdit'),
      'the answer was applied to the wrong rename');
    Assert.IsNotNull(Session.ComponentNamed(WiredButton),
      'the rename nobody answered was applied anyway');
  finally
    Session.Free;
  end;
end;

{ TRenameTests: the two row sources }

// The Name row is built from two sources - type information and the hosted
// property editors - and each answers for a prkName row separately, so a
// change to one can leave the other behind.
procedure TRenameTests.BothRowSourcesCallTheNameARowOfItsOwn;
var
  Session: TRenameSession;
  Plain, Hosted: TPropertyModel;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  Plain := TPropertyModel.Create;
  Hosted := TPropertyModel.Create;
  try
    Assert.AreEqual(Ord(prkName),
      Ord(Session.RowsFor(WiredButton, False, Plain).Kind),
      'type information does not describe the name as a name');
    Assert.AreEqual(Ord(prkName),
      Ord(Session.RowsFor(WiredButton, True, Hosted).Kind),
      'the hosted editors do not describe the name as a name');
  finally
    Hosted.Free;
    Plain.Free;
    Session.Free;
  end;
end;

procedure TRenameTests.BothRowSourcesRefuseTheNameWithNoEditorAttached;
var
  Session: TRenameSession;
  Plain, Hosted: TPropertyModel;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  Plain := TPropertyModel.Create;
  Hosted := TPropertyModel.Create;
  try
    Assert.IsTrue(Session.RowsFor(WiredButton, False, Plain).CanEdit,
      'a coupled document refused its own name from type information');
    Assert.IsTrue(Session.RowsFor(WiredButton, True, Hosted).CanEdit,
      'a coupled document refused its own name from the hosted editors');
    Session.Coupling := False;
    Assert.IsFalse(Session.RowsFor(WiredButton, False, Plain).CanEdit,
      'an uncoupled document offered the name from type information');
    Assert.IsFalse(Session.RowsFor(WiredButton, True, Hosted).CanEdit,
      'an uncoupled document offered the name from the hosted editors');
  finally
    Hosted.Free;
    Plain.Free;
    Session.Free;
  end;
end;

procedure TRenameTests.BothRowSourcesRefuseTheNameWhileOneIsOnItsWay;
var
  Session: TRenameSession;
  Plain, Hosted: TPropertyModel;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  Plain := TPropertyModel.Create;
  Hosted := TPropertyModel.Create;
  try
    Session.TypeIntoTheNameRow(WiredButton, 'SaveButton');
    Assert.IsFalse(Session.RowsFor(WiredButton, False, Plain).CanEdit,
      'type information offered a name that is already being changed');
    Assert.IsFalse(Session.RowsFor(WiredButton, True, Hosted).CanEdit,
      'the hosted editors offered a name that is already being changed');
    Assert.IsTrue(Session.RowsFor(WiredButton, False, Plain).Waiting,
      'the row does not report itself as waiting');
    Session.Editor.Answer(1, True, '');
    Assert.IsTrue(Session.RowsFor('SaveButton', False, Plain).CanEdit,
      'the row was still refused after the answer');
  finally
    Hosted.Free;
    Plain.Free;
    Session.Free;
  end;
end;

procedure TRenameTests.ANameRowIsWrittenByAskingRatherThanBySetting;
var
  Session: TRenameSession;
  Model: TPropertyModel;
  Row: TPropertyRow;
begin
  Session := TRenameSession.Create(FixtureFile(WiredFixture));
  Model := TPropertyModel.Create;
  try
    Row := Session.RowsFor(WiredButton, True, Model);
    Assert.IsTrue(Row.SetValueText('SaveButton'),
      'the row would not take a name nothing was wrong with');
    Assert.AreEqual(WiredButton, Session.ComponentNamed(WiredButton).Name, False,
      'the row wrote the name into the component itself');
    Assert.AreEqual('0:EventButton->SaveButton [EventButtonClick->SaveButtonClick]',
      Session.Editor.Asked, 'the row did not ask for the rename it was given');
    Assert.IsTrue(Row.Waiting, 'the row is not waiting for the answer');
    // A second component, because the first is still waiting for its answer
    // and would be refused for that reason instead.
    Row := Session.RowsFor('EventEdit', False, Model);
    Assert.IsFalse(Row.SetValueText('2Save'),
      'a name no unit could declare was taken');
    Assert.Contains(Row.LastError, 'not a name a unit could declare',
      'and it was refused without saying why');
  finally
    Model.Free;
    Session.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TRenameTests);

end.
