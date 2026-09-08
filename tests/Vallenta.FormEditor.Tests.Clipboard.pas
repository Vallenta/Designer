// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.Clipboard;

// Copy, cut and paste of components: the fragment text a copy writes, the
// document a paste produces, and the span scanner a paste splits its text
// with. A document case starts the process-wide designer session and builds a
// TClipboardSession over a fixture form file; a scanner case runs on text
// alone.
//
// An undo step rebuilds the document and the designer, so a component
// reference taken before StepBack is stale afterwards. WrittenText saves to a
// temp file named after the fixture, which the session deletes when it is
// freed.

interface

uses
  DUnitX.TestFramework;

type
  // Copy, cut and paste on a loaded document, and the scanner a paste splits
  // its fragment text with.
  [TestFixture]
  TClipboardTests = class
  public
    [Test]
    procedure OneSelectedComponentIsWrittenAsItsOwnBlock;
    [Test]
    procedure SeveralSelectedComponentsAreWrittenAsConsecutiveBlocks;
    [Test]
    procedure AContainerCarriesTheChildrenItHolds;
    [Test]
    procedure AChildOfASelectedContainerIsNotWrittenTwice;
    // The arrangement selects nil, which the designer maps to the root.
    [Test]
    procedure TheRootIsNotSomethingToCopy;
    [Test]
    procedure NamesTheDocumentDoesNotHoldSurviveThePaste;
    [Test]
    procedure ACollidingNameIsCountedUpFromItsStem;
    [Test]
    procedure AReferenceBetweenPastedComponentsFollowsTheRename;
    [Test]
    procedure AReferenceToSomethingNotCopiedStaysWhereItPointed;
    [Test]
    procedure APatternNamedHandlerFollowsTheComponentRename;
    [Test]
    procedure AHandNamedHandlerIsLeftAlone;
    // The first of the two pastes renames nothing and sends no handler
    // request; only the second one does.
    [Test]
    procedure ARenamedHandlerIsRequestedFromTheEditor;
    // A renamed pattern handler requires a new method in the unit beside
    // the document, and an uncoupled document has no editor to add it.
    [Test]
    procedure AnUncoupledDocumentRefusesAPasteThatRenamesAHandler;
    [Test]
    procedure AnUnknownClassRefusesThePasteAndCreatesNothing;
    [Test]
    procedure APastedControlOnTopOfAnotherStepsAside;
    [Test]
    procedure APastedComponentIsWrittenToTheFile;
    [Test]
    procedure UndoAfterAPasteRestoresTheDocument;
    [Test]
    procedure CutLeavesOneStepThatPutsTheComponentBack;
    [Test]
    procedure AFragmentSplitsIntoItsTopLevelBlocks;
    [Test]
    procedure TheSplitFollowsCollectionsStringsAndBinaryData;
    [Test]
    procedure TextTheScannerCannotFollowIsRefused;
  end;

implementation

uses
  Winapi.Windows,
  System.Classes,
  System.SysUtils,
  System.StrUtils,
  System.TypInfo,
  System.IOUtils,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Core.Coupling,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Streaming.TextSpans,
  Vallenta.FormEditor.Streaming.Clipboard,
  Vallenta.FormEditor.Surface.FormDesigner,
  Vallenta.FormEditor.Surface.Undo,
  Vallenta.FormEditor.Tests.Environment;

const
  Fixture = 'basic_form.dfm';
  NestedFixture = 'nested_panels.dfm';
  // Upper bound on CheckSynchronize rounds; a queued call may queue another,
  // and the bound stops a runaway loop.
  PumpRounds = 32;
  // Position of Button1 in basic_form.dfm and the designer's default grid
  // step, by which a paste covering it is moved.
  ButtonLeft = 24;
  ButtonTop = 24;
  GridStep = 8;

  // A label whose FocusControl names the edit beside it in the fragment.
  // Neither name occurs in basic_form.dfm, so a first paste renames nothing.
  PairFragment =
    'object Label9: TLabel'#13#10 +
    '  Left = 200'#13#10 +
    '  Top = 8'#13#10 +
    '  Width = 20'#13#10 +
    '  Height = 15'#13#10 +
    '  Caption = ''Nine'''#13#10 +
    '  FocusControl = Edit9'#13#10 +
    'end'#13#10 +
    'object Edit9: TEdit'#13#10 +
    '  Left = 200'#13#10 +
    '  Top = 32'#13#10 +
    '  Width = 100'#13#10 +
    '  Height = 23'#13#10 +
    '  TabOrder = 0'#13#10 +
    '  Text = ''Nine'''#13#10 +
    'end'#13#10;

  // A label whose FocusControl names Edit1 of basic_form.dfm rather than a
  // component of the fragment.
  OutwardFragment =
    'object Label8: TLabel'#13#10 +
    '  Left = 200'#13#10 +
    '  Top = 64'#13#10 +
    '  Width = 20'#13#10 +
    '  Height = 15'#13#10 +
    '  Caption = ''Eight'''#13#10 +
    '  FocusControl = Edit1'#13#10 +
    'end'#13#10;

  // A button whose handler carries the default name built from the component
  // and the event; only a handler in that form follows a component rename.
  PatternHandlerFragment =
    'object Button9: TButton'#13#10 +
    '  Left = 200'#13#10 +
    '  Top = 96'#13#10 +
    '  Width = 75'#13#10 +
    '  Height = 25'#13#10 +
    '  Caption = ''Nine'''#13#10 +
    '  TabOrder = 0'#13#10 +
    '  OnClick = Button9Click'#13#10 +
    'end'#13#10;

  // A button with a handler name that is not the default one, which a rename
  // of the component leaves as it is.
  HandNamedHandlerFragment =
    'object Button8: TButton'#13#10 +
    '  Left = 200'#13#10 +
    '  Top = 128'#13#10 +
    '  Width = 75'#13#10 +
    '  Height = 25'#13#10 +
    '  Caption = ''Eight'''#13#10 +
    '  TabOrder = 0'#13#10 +
    '  OnClick = DoTheThing'#13#10 +
    'end'#13#10;

  UnknownClassFragment =
    'object Odd1: TNoSuchControlExists'#13#10 +
    '  Left = 8'#13#10 +
    '  Top = 8'#13#10 +
    'end'#13#10;

  // A button with the bounding rectangle of Button1 in basic_form.dfm; the
  // paste offset triggers on an equal rectangle, not on the position alone.
  CoveringFragment =
    'object Button7: TButton'#13#10 +
    '  Left = 24'#13#10 +
    '  Top = 24'#13#10 +
    '  Width = 120'#13#10 +
    '  Height = 25'#13#10 +
    '  Caption = ''Seven'''#13#10 +
    '  TabOrder = 0'#13#10 +
    'end'#13#10;

type
  // Editor stand-in that records the handler requests a paste sends.
  // Available returns True; RenameComponent returns the empty result
  // ICodeCoupling defines as the request sent. The remaining members are
  // empty.
  TCouplingSpy = class(TInterfacedObject, ICodeCoupling)
  private
    FEnsured: TArray<TCreatedHandler>;
  public
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
    // EnsureHandler requests received, in arrival order.
    property Ensured: TArray<TCreatedHandler> read FEnsured;
  end;

  // One fixture form loaded into a designer, with an undo stack and a
  // coupling spy in place of the editor. Create with ACoupled False leaves
  // the designer without a coupling, the state of a document no editor is
  // attached to.
  TClipboardSession = class
  private
    FLog: TDesignLog;
    FFileName: string;
    FWritten: string;
    FCoupled: Boolean;
    // Second reference to FSpy, and the one that keeps it alive: a restore
    // frees the designer, which drops the reference it was given.
    FSpyKeep: ICodeCoupling;
    FSpy: TCouplingSpy;
    FDocument: TDesignDocument;
    FDesigner: TFormDesigner;
    FUndo: TUndoStack;
    procedure Build(ALoader: TFormLoader);
    procedure Release;
    function CaptureDocument(Sender: TObject): TDocumentSnapshot;
    procedure RestoreDocument(Sender: TObject; ASnapshot: TDocumentSnapshot);
    function CouplingAvailable: Boolean;
  public
    constructor Create(const AFileName: string; ACoupled: Boolean = True);
    destructor Destroy; override;
    // Runs the queued synchronized calls that the VCL message loop would
    // otherwise run.
    procedure Beat;
    // Selects the named components; the last one becomes the primary.
    procedure Select(const ANames: array of string);
    // Pastes AText into the document, without going through the system
    // clipboard.
    procedure Paste(const AText: string);
    function Copied: string;
    function Component(const AName: string): TComponent;
    // Handler name wired to AComponent's AEvent, as the event map spells it;
    // empty when the component, the event or the wiring is missing.
    function HandlerOf(const AComponent, AEvent: string): string;
    // Saves the document to the session's temp file and returns the text.
    function WrittenText: string;
    procedure StepBack;
    property Designer: TFormDesigner read FDesigner;
    property Undo: TUndoStack read FUndo;
    property Spy: TCouplingSpy read FSpy;
  end;

procedure TurnThePump;
var
  Round: Integer;
begin
  Round := 0;
  while CheckSynchronize and (Round < PumpRounds) do
    Inc(Round);
end;

function Occurrences(const AWhat, AText: string): Integer;
var
  At: Integer;
begin
  Result := 0;
  At := Pos(AWhat, AText);
  while At > 0 do
  begin
    Inc(Result);
    At := PosEx(AWhat, AText, At + Length(AWhat));
  end;
end;

{ TCouplingSpy }

function TCouplingSpy.Available: Boolean;
begin
  Result := True;
end;

procedure TCouplingSpy.ListMethods(ARequest: Integer;
  const ASignature: TEventSignature; const AWhen: TMethodListCallback);
begin
end;

procedure TCouplingSpy.EnsureHandler(const AComponent, AEvent, AMethod: string;
  const ASignature: TEventSignature);
var
  Entry: TCreatedHandler;
begin
  Entry.Component := AComponent;
  Entry.Event := AEvent;
  Entry.Method := AMethod;
  Entry.Signature := ASignature;
  FEnsured := FEnsured + [Entry];
end;

procedure TCouplingSpy.RemoveHandler(const AMethod: string);
begin
end;

procedure TCouplingSpy.GotoHandler(const AMethod: string);
begin
end;

function TCouplingSpy.RenameComponent(AToken: Integer; AKind: TRenameKind;
  const AOldName, ANewName: string;
  const AMethods: TArray<TMethodRename>): string;
begin
  Result := '';
end;

procedure TCouplingSpy.NoteRenamed(const AOldName, ANewName: string);
begin
end;

{ TClipboardSession }

constructor TClipboardSession.Create(const AFileName: string;
  ACoupled: Boolean);
var
  Loader: TFormLoader;
begin
  inherited Create;
  FFileName := AFileName;
  FCoupled := ACoupled;
  FWritten := TPath.Combine(TPath.GetTempPath, 'vsfe_clip_' +
    TPath.GetFileName(AFileName));
  FLog := TDesignLog.Create;
  FSpy := TCouplingSpy.Create;
  FSpyKeep := FSpy;
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

destructor TClipboardSession.Destroy;
begin
  Release;
  TurnThePump;
  FUndo.Free;
  FLog.Free;
  DeleteFile(FWritten);
  inherited Destroy;
end;

procedure TClipboardSession.Build(ALoader: TFormLoader);
begin
  FDocument := CreateDesignDocument(ALoader.RootKind);
  FDesigner := TFormDesigner.Create(FDocument.HostForm, FDocument.Root, FLog);
  FDesigner.UndoStack := FUndo;
  FDesigner.OnCouplingQuery := CouplingAvailable;
  if FCoupled then
    FDesigner.CodeCoupling := FSpyKeep;
  ALoader.StreamInto(FDocument.Root);
  FDesigner.AttachLoaded(FFileName, ALoader.ExtractEventMap,
    ALoader.ExtractPreserved, ALoader.ExtractFrames, ALoader.ExtractAncestor,
    ALoader.LoadedState);
  FDesigner.ShowPlaceholders;
  FDesigner.BeginEditing;
end;

procedure TClipboardSession.Release;
begin
  // The designer is freed first: it holds the placeholder controls parented
  // into the document, which would otherwise be freed twice.
  FreeAndNil(FDesigner);
  FreeDesignDocument(FDocument);
end;

function TClipboardSession.CouplingAvailable: Boolean;
begin
  Result := FCoupled;
end;

function TClipboardSession.CaptureDocument(Sender: TObject): TDocumentSnapshot;
begin
  Result := FDesigner.CaptureSnapshot;
end;

procedure TClipboardSession.RestoreDocument(Sender: TObject;
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

procedure TClipboardSession.Beat;
begin
  TurnThePump;
end;

procedure TClipboardSession.Select(const ANames: array of string);
var
  Chosen: TArray<TComponent>;
  Name: string;
begin
  Chosen := nil;
  for Name in ANames do
    Chosen := Chosen + [FDesigner.ComponentNamed(Name)];
  FDesigner.SelectMany(Chosen);
end;

procedure TClipboardSession.Paste(const AText: string);
begin
  FDesigner.PasteFragment(AText);
end;

function TClipboardSession.Copied: string;
begin
  Result := FDesigner.SelectionAsFragment;
end;

function TClipboardSession.Component(const AName: string): TComponent;
begin
  Result := FDocument.Root.FindComponent(AName);
end;

function TClipboardSession.HandlerOf(const AComponent, AEvent: string): string;
var
  Target: TComponent;
  Info: PPropInfo;
begin
  Result := '';
  Target := Component(AComponent);
  if Target = nil then
    Exit;
  Info := GetPropInfo(Target, AEvent, [tkMethod]);
  if Info = nil then
    Exit;
  Result := FDesigner.EventMap.NameFor(GetMethodProp(Target, Info));
end;

function TClipboardSession.WrittenText: string;
begin
  FDesigner.WriteTo(FWritten);
  Result := TFile.ReadAllText(FWritten);
end;

procedure TClipboardSession.StepBack;
begin
  FUndo.Undo;
  Beat;
end;

{ TClipboardTests }

procedure TClipboardTests.OneSelectedComponentIsWrittenAsItsOwnBlock;
var
  Session: TClipboardSession;
  Text: string;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Button1']);
    Text := Session.Copied;
    Assert.IsTrue(StartsText('object Button1: TButton', Text),
      'the block header is missing: ' + Text);
    Assert.IsTrue(ContainsText(Text, 'Caption = ''Click me'''),
      'the properties are missing: ' + Text);
    Assert.AreEqual(1, Occurrences('object ', Text),
      'more than one block was written');
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.SeveralSelectedComponentsAreWrittenAsConsecutiveBlocks;
var
  Session: TClipboardSession;
  Text: string;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Button1', 'Memo1']);
    Text := Session.Copied;
    Assert.IsTrue(ContainsText(Text, 'object Button1: TButton'),
      'Button1 is missing: ' + Text);
    Assert.IsTrue(ContainsText(Text, 'object Memo1: TMemo'),
      'Memo1 is missing: ' + Text);
    Assert.IsTrue(Pos('object Button1', Text) < Pos('object Memo1', Text),
      'the blocks are not in document order');
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.AContainerCarriesTheChildrenItHolds;
var
  Session: TClipboardSession;
  Text: string;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(NestedFixture));
  try
    Session.Select(['TopPanel']);
    Text := Session.Copied;
    Assert.IsTrue(ContainsText(Text, 'object TitleLabel: TLabel'),
      'the child is missing: ' + Text);
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.AChildOfASelectedContainerIsNotWrittenTwice;
var
  Session: TClipboardSession;
  Text: string;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(NestedFixture));
  try
    Session.Select(['TitleLabel', 'TopPanel']);
    Text := Session.Copied;
    Assert.AreEqual(1, Occurrences('object TitleLabel', Text),
      'the child was written beside its container');
    Assert.AreEqual(1, Occurrences('object TopPanel', Text),
      'the container was written more than once');
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.TheRootIsNotSomethingToCopy;
var
  Session: TClipboardSession;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(Fixture));
  try
    Session.Designer.SelectComponent(nil);
    Assert.IsFalse(Session.Designer.CanCopySelection,
      'the root was offered as something to copy');
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.NamesTheDocumentDoesNotHoldSurviveThePaste;
var
  Session: TClipboardSession;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(Fixture));
  try
    Session.Paste(PairFragment);
    Assert.IsNotNull(Session.Component('Label9'), 'Label9 was renamed');
    Assert.IsNotNull(Session.Component('Edit9'), 'Edit9 was renamed');
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.ACollidingNameIsCountedUpFromItsStem;
var
  Session: TClipboardSession;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(Fixture));
  try
    Session.Paste(PairFragment);
    Session.Paste(PairFragment);
    Assert.IsNotNull(Session.Component('Label1'),
      'the second Label9 was not counted up from its stem');
    Assert.IsNotNull(Session.Component('Edit2'),
      'the second Edit9 was not counted up from its stem');
    Assert.IsNull(Session.Component('Label91'),
      'the trailing digit was counted as part of the stem');
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.AReferenceBetweenPastedComponentsFollowsTheRename;
var
  Session: TClipboardSession;
  Label1: TLabel;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(Fixture));
  try
    Session.Paste(PairFragment);
    Session.Paste(PairFragment);
    Label1 := Session.Component('Label1') as TLabel;
    Assert.IsNotNull(Label1.FocusControl, 'the reference was dropped');
    Assert.AreEqual('Edit2', Label1.FocusControl.Name,
      'the reference did not follow the renamed component');
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.AReferenceToSomethingNotCopiedStaysWhereItPointed;
var
  Session: TClipboardSession;
  Pasted: TLabel;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(Fixture));
  try
    Session.Paste(OutwardFragment);
    Session.Paste(OutwardFragment);
    Pasted := Session.Component('Label1') as TLabel;
    Assert.IsNotNull(Pasted, 'the second Label8 was not renamed');
    Assert.IsNotNull(Pasted.FocusControl, 'the reference was dropped');
    Assert.AreEqual('Edit1', Pasted.FocusControl.Name,
      'a reference to a component that was not copied was rewritten');
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.APatternNamedHandlerFollowsTheComponentRename;
var
  Session: TClipboardSession;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(Fixture));
  try
    Session.Paste(PatternHandlerFragment);
    Assert.AreEqual('Button9Click', Session.HandlerOf('Button9', 'OnClick'),
      'the handler changed although the component kept its name');
    Session.Paste(PatternHandlerFragment);
    Assert.IsNotNull(Session.Component('Button2'),
      'the second Button9 was not renamed');
    Assert.AreEqual('Button2Click', Session.HandlerOf('Button2', 'OnClick'),
      'the handler did not follow the new component name');
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.AHandNamedHandlerIsLeftAlone;
var
  Session: TClipboardSession;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(Fixture));
  try
    Session.Paste(HandNamedHandlerFragment);
    Session.Paste(HandNamedHandlerFragment);
    Assert.IsNotNull(Session.Component('Button2'),
      'the second Button8 was not renamed');
    Assert.AreEqual('DoTheThing', Session.HandlerOf('Button2', 'OnClick'),
      'a handler that is not named after its component was renamed');
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.ARenamedHandlerIsRequestedFromTheEditor;
var
  Session: TClipboardSession;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(Fixture));
  try
    Session.Paste(PatternHandlerFragment);
    Assert.AreEqual(0, Length(Session.Spy.Ensured),
      'a handler was requested although nothing was renamed');
    Session.Paste(PatternHandlerFragment);
    Assert.AreEqual(1, Length(Session.Spy.Ensured),
      'the renamed handler was not requested from the editor');
    Assert.AreEqual('Button2Click', Session.Spy.Ensured[0].Method,
      'the request names the wrong method');
    Assert.AreEqual('OnClick', Session.Spy.Ensured[0].Event,
      'the request names the wrong event');
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.AnUncoupledDocumentRefusesAPasteThatRenamesAHandler;
var
  Session: TClipboardSession;
  Before: Integer;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(Fixture), False);
  try
    Session.Paste(PatternHandlerFragment);
    Assert.IsNotNull(Session.Component('Button9'),
      'a paste that renames nothing was refused');
    Before := Session.Designer.Root.ComponentCount;
    Session.Paste(PatternHandlerFragment);
    Assert.AreEqual(Before, Session.Designer.Root.ComponentCount,
      'the refused paste left components behind');
    Assert.IsNull(Session.Component('Button2'),
      'the refused paste created the component anyway');
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.AnUnknownClassRefusesThePasteAndCreatesNothing;
var
  Session: TClipboardSession;
  Before: Integer;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(Fixture));
  try
    Before := Session.Designer.Root.ComponentCount;
    Session.Paste(UnknownClassFragment);
    Assert.AreEqual(Before, Session.Designer.Root.ComponentCount,
      'the refused paste left components behind');
    Assert.IsNull(Session.Component('Odd1'),
      'a component of an unknown class was created');
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.APastedControlOnTopOfAnotherStepsAside;
var
  Session: TClipboardSession;
  Pasted: TControl;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(Fixture));
  try
    Session.Paste(CoveringFragment);
    Pasted := Session.Component('Button7') as TControl;
    Assert.IsNotNull(Pasted, 'nothing was pasted');
    Assert.AreEqual(ButtonLeft + GridStep, Pasted.Left,
      'the pasted control kept the position it covers');
    Assert.AreEqual(ButtonTop + GridStep, Pasted.Top,
      'the pasted control kept the position it covers');
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.APastedComponentIsWrittenToTheFile;
var
  Session: TClipboardSession;
  Written: string;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Button1']);
    Session.Paste(Session.Copied);
    Written := Session.WrittenText;
    Assert.IsTrue(ContainsText(Written, 'object Button1: TButton'),
      'the original is missing from the written file');
    Assert.IsTrue(ContainsText(Written, 'object Button2: TButton'),
      'the copy is missing from the written file: ' + Written);
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.UndoAfterAPasteRestoresTheDocument;
var
  Session: TClipboardSession;
  Before: Integer;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(Fixture));
  try
    Before := Session.Designer.Root.ComponentCount;
    Session.Paste(PairFragment);
    Assert.AreEqual(Before + 2, Session.Designer.Root.ComponentCount,
      'the paste created something other than the two components');
    Session.StepBack;
    Assert.AreEqual(Before, Session.Designer.Root.ComponentCount,
      'the paste was not taken back');
    Assert.IsNull(Session.Component('Label9'),
      'a pasted component survived the undo');
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.CutLeavesOneStepThatPutsTheComponentBack;
var
  Session: TClipboardSession;
begin
  BeginDesignerSession;
  Session := TClipboardSession.Create(FixtureFile(Fixture));
  try
    Session.Select(['Button1']);
    Session.Designer.CutSelection;
    Assert.IsNull(Session.Component('Button1'), 'the cut left the component');
    Session.StepBack;
    Assert.IsNotNull(Session.Component('Button1'),
      'one step did not put the cut component back');
  finally
    Session.Free;
  end;
end;

procedure TClipboardTests.AFragmentSplitsIntoItsTopLevelBlocks;
var
  Fragment: TDfmFragment;
begin
  Fragment := TDfmFragment.Create(PairFragment);
  try
    Assert.AreEqual(2, Fragment.Count, 'the fragment did not split in two');
    Assert.AreEqual('Label9', Fragment[0].Name);
    Assert.AreEqual('Edit9', Fragment[1].Name);
  finally
    Fragment.Free;
  end;
end;

procedure TClipboardTests.TheSplitFollowsCollectionsStringsAndBinaryData;
const
  Awkward =
    'object Grid1: TAwkward'#13#10 +
    '  Columns = <'#13#10 +
    '    item'#13#10 +
    '      Caption = ''one'''#13#10 +
    '    end'#13#10 +
    '    item'#13#10 +
    '      Caption = ''end'''#13#10 +
    '    end>'#13#10 +
    '  Lines.Strings = ('#13#10 +
    '    ''object Fake: TFake'''#13#10 +
    '    ''end'')'#13#10 +
    '  Data = {0102030405}'#13#10 +
    'end'#13#10 +
    'object Plain1: TPlain'#13#10 +
    '  Tag = 1'#13#10 +
    'end'#13#10;
var
  Fragment: TDfmFragment;
begin
  Fragment := TDfmFragment.Create(Awkward);
  try
    Assert.AreEqual(2, Fragment.Count,
      'a value holding block keywords was counted as a block');
    Assert.AreEqual('Grid1', Fragment[0].Name);
    Assert.AreEqual('Plain1', Fragment[1].Name);
  finally
    Fragment.Free;
  end;
end;

procedure TClipboardTests.TextTheScannerCannotFollowIsRefused;
begin
  Assert.WillRaise(
    procedure
    var
      Fragment: TDfmFragment;
    begin
      Fragment := TDfmFragment.Create('object Broken1: TThing'#13#10 +
        '  Caption = ''never closed'''#13#10);
      Fragment.Free;
    end,
    EDfmScanError, 'an unclosed block was accepted');
end;

end.
