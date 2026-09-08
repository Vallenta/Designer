// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.Coupling;

// Covers the event coupling helpers of Vallenta.FormEditor.Core.Coupling -
// event signatures read from RTTI, default handler names and the rename pairs
// a component rename produces - and the handler name interning of
// Vallenta.FormEditor.Streaming.EventNames. Two cases call an emitted marker
// thunk and compare the stack pointer around the call.

interface

uses
  DUnitX.TestFramework;

type
  // Event signatures, identifier validation, default handler names, marker
  // thunks, the rename pairs a component rename produces and the renaming of
  // an interned handler name.
  [TestFixture]
  TCouplingTests = class
  public
    [Test]
    procedure AnEventSignatureIsReadOffTheEventType;
    [Test]
    procedure AnEventWithOneParameterReadsAsOne;
    [Test]
    procedure ByReferenceParametersKeepTheirModifier;
    [Test]
    procedure SomethingThatIsNotAnEventHasNoSignature;
    [Test]
    procedure TheSignatureGoesOverTheWireAsAListOfParameters;
    [Test]
    procedure ADefaultNameIsTheComponentAndTheEventWithoutOn;
    [Test]
    procedure OnlyALeadingOnIsTakenOffAnEventName;
    [Test]
    procedure AnEventThatDoesNotStartWithOnKeepsAllOfIt;
    [Test]
    procedure OnlySomethingAUnitCouldDeclareIsAnIdentifier;
    [Test]
    procedure AChosenNameIsInternedExactlyAsItWasSpelled;
    [Test]
    procedure TwoSpellingsOfOneNameAreTwoHandlers;
    [Test]
    procedure AMarkerForAnEventWithStackParametersLeavesTheStackBalanced;
    [Test]
    procedure AMarkerForAnEventThatReturnsAValueAnswersWithZero;
    [Test]
    procedure AHandlerNamedAfterTheComponentRidesWithTheRename;
    [Test]
    procedure AHandlerSomebodyNamedIsLeftAlone;
    [Test]
    procedure TwoEventsNamedAfterTheComponentBothRide;
    [Test]
    procedure TheOldNameIsMatchedWithoutRegardToCase;
    [Test]
    procedure TheSpellingThatGoesOutIsTheOneTheMapHolds;
    [Test]
    procedure AnEventNothingIsWiredToRidesWithNothing;
    [Test]
    procedure ThePairsGoOverTheWireAsAListOfTwoNames;
    [Test]
    procedure RenamingAHandlerReachesEveryComponentWiredToIt;
    [Test]
    procedure RenamingAHandlerTheMapNeverHeldChangesNothing;
  end;

implementation

uses
  System.Classes,
  System.SysUtils,
  System.TypInfo,
  Vcl.Controls,
  Vallenta.FormEditor.Core.Coupling,
  Vallenta.FormEditor.Streaming.EventNames;

function Describe(const ASignature: TEventSignature): string;
var
  Param: TEventParam;
begin
  Result := '';
  for Param in ASignature.Params do
  begin
    if Result <> '' then
      Result := Result + '; ';
    Result := Result + Trim(Param.Modifier + ' ' + Param.Name) + ': ' +
      Param.TypeName + ' [' + Param.UnitName + ']';
  end;
  if Result = '' then
    Result := '(none)';
end;

// TMouseEvent has parameter types declared in System.UITypes and
// System.Classes, so the declaring unit of each parameter is exercised.
procedure TCouplingTests.AnEventSignatureIsReadOffTheEventType;
begin
  Assert.AreEqual(
    'Sender: TObject [System]; Button: TMouseButton [System.UITypes]; ' +
    'Shift: TShiftState [System.Classes]; X: Integer [System]; Y: Integer [System]',
    Describe(SignatureOf(TypeInfo(TMouseEvent))),
    'the parameters of an event are not what the runtime reports for it');
end;

procedure TCouplingTests.AnEventWithOneParameterReadsAsOne;
begin
  Assert.AreEqual('Sender: TObject [System]',
    Describe(SignatureOf(TypeInfo(TNotifyEvent))),
    'the plainest event of all did not read as one parameter');
end;

procedure TCouplingTests.ByReferenceParametersKeepTheirModifier;
begin
  Assert.AreEqual(
    'Sender: TObject [System]; var Key: Word [System]; ' +
    'Shift: TShiftState [System.Classes]',
    Describe(SignatureOf(TypeInfo(TKeyEvent))),
    'a var parameter did not come back as one');
end;

procedure TCouplingTests.SomethingThatIsNotAnEventHasNoSignature;
begin
  Assert.AreEqual('(none)', Describe(SignatureOf(TypeInfo(TShiftState))),
    'a type that is not an event was read as though it had parameters');
  Assert.AreEqual('(none)', Describe(SignatureOf(nil)),
    'nothing at all was read as though it had parameters');
end;

procedure TCouplingTests.TheSignatureGoesOverTheWireAsAListOfParameters;
begin
  Assert.AreEqual(
    '{"params":[{"name":"Sender","type":"TObject","unit":"System","modifier":""}]}',
    SignatureJson(SignatureOf(TypeInfo(TNotifyEvent))),
    'the signature is not written the way the protocol says it is');
end;

procedure TCouplingTests.ADefaultNameIsTheComponentAndTheEventWithoutOn;
begin
  Assert.AreEqual('Button1Click', DefaultHandlerName('Button1', 'OnClick'),
    'the default handler name is not the one the IDE would produce');
  Assert.AreEqual('Button1MouseDown', DefaultHandlerName('Button1', 'OnMouseDown'),
    'a longer event name did not lose exactly its On');
end;

// OnOnce must become Once; stripping 'On' repeatedly would leave 'ce'.
procedure TCouplingTests.OnlyALeadingOnIsTakenOffAnEventName;
begin
  Assert.AreEqual('Timer1Once', DefaultHandlerName('Timer1', 'OnOnce'),
    'more than the leading On was taken off');
end;

procedure TCouplingTests.AnEventThatDoesNotStartWithOnKeepsAllOfIt;
begin
  Assert.AreEqual('Grid1BeforeEdit', DefaultHandlerName('Grid1', 'BeforeEdit'),
    'an event that never had an On lost something anyway');
end;

procedure TCouplingTests.OnlySomethingAUnitCouldDeclareIsAnIdentifier;
begin
  Assert.IsTrue(IsIdentifier('Button1Click'), 'an ordinary name was refused');
  Assert.IsTrue(IsIdentifier('_private2'), 'a leading underscore was refused');
  Assert.IsFalse(IsIdentifier(''), 'nothing at all was accepted as a name');
  Assert.IsFalse(IsIdentifier('2Click'), 'a name starting with a digit was accepted');
  Assert.IsFalse(IsIdentifier('Do It'), 'a name with a space in it was accepted');
  Assert.IsFalse(IsIdentifier('Form1.Click'), 'a qualified name was accepted');
end;

// The interned name reads back with the spelling that went in, and the same
// name and event type yield the same marker.
procedure TCouplingTests.AChosenNameIsInternedExactlyAsItWasSpelled;
var
  Map: TEventNameMap;
  Marker: TMethod;
begin
  Map := TEventNameMap.Create;
  try
    Marker := Map.MarkerFor('HandleSave', TypeInfo(TNotifyEvent));
    Assert.AreEqual('HandleSave', Map.NameFor(Marker),
      'the name that came back is not the name that went in');
    Assert.AreEqual(1, Map.Count, 'interning one name produced something else');
    Assert.AreEqual(NativeInt(Marker.Data),
      NativeInt(Map.MarkerFor('HandleSave', TypeInfo(TNotifyEvent)).Data),
      'the same name interned twice produced two markers');
  finally
    Map.Free;
  end;
end;

// Interning is case-sensitive: a save writes back the spelling the form file
// held, so two spellings must not collapse onto one marker.
procedure TCouplingTests.TwoSpellingsOfOneNameAreTwoHandlers;
var
  Map: TEventNameMap;
begin
  Map := TEventNameMap.Create;
  try
    Map.MarkerFor('HandleSave', TypeInfo(TNotifyEvent));
    Map.MarkerFor('Handlesave', TypeInfo(TNotifyEvent));
    Assert.AreEqual(2, Map.Count,
      'two spellings of one name were interned as one, which renames a handler');
  finally
    Map.Free;
  end;
end;

{ marker thunk calls }

// Event types with more parameters than the Win32 register convention passes
// in registers: Self, Sender and the third value use EAX, EDX and ECX, the
// remaining parameters are pushed by the caller and popped by the thunk.
type
  PSampleNode = ^TSampleNode;
  TSampleNode = record
    Height: Integer;
  end;
  TSampleInitStates = set of (sisDisabled, sisSelected);
  TSampleInitNodeEvent = procedure(Sender: TObject; ParentNode, Node: PSampleNode;
    var InitialStates: TSampleInitStates) of object;
  TSampleMeasureEvent = function(Sender: TObject; Node: PSampleNode;
    Column, Width: Integer): Integer of object;

function StackPointer: NativeInt;
asm
{$IFDEF CPUX86}
  mov eax, esp
{$ELSE}
  mov rax, rsp
{$ENDIF}
end;

// A design-mode component may call its own events while a form loads.
procedure TCouplingTests.AMarkerForAnEventWithStackParametersLeavesTheStackBalanced;
var
  Map: TEventNameMap;
  Handler: TSampleInitNodeEvent;
  Node: TSampleNode;
  States: TSampleInitStates;
  Before, After: NativeInt;
begin
  Map := TEventNameMap.Create;
  try
    Handler := TSampleInitNodeEvent(Map.MarkerFor('TreeInitNode',
      TypeInfo(TSampleInitNodeEvent)));
    States := [sisSelected];
    Before := StackPointer;
    Handler(nil, nil, @Node, States);
    After := StackPointer;
    Assert.AreEqual(Before, After,
      'the marker left the stack unbalanced, so its caller returns into rubbish');
    Assert.AreEqual('TreeInitNode', Map.NameFor(TMethod(Handler)),
      'the marker no longer names the handler it stands for');
  finally
    Map.Free;
  end;
end;

// The thunk clears EAX before returning, so a function-typed event reads 0
// rather than whatever the register held at the call.
procedure TCouplingTests.AMarkerForAnEventThatReturnsAValueAnswersWithZero;
var
  Map: TEventNameMap;
  Handler: TSampleMeasureEvent;
  Node: TSampleNode;
  Answer: Integer;
  Before, After: NativeInt;
begin
  Map := TEventNameMap.Create;
  try
    Handler := TSampleMeasureEvent(Map.MarkerFor('TreeMeasure',
      TypeInfo(TSampleMeasureEvent)));
    Before := StackPointer;
    Answer := Handler(nil, @Node, 1, 2);
    After := StackPointer;
    Assert.AreEqual(Before, After,
      'the marker left the stack unbalanced, so its caller returns into rubbish');
    Assert.AreEqual(0, Answer, 'the marker answered something other than zero');
  finally
    Map.Free;
  end;
end;

{ pattern handler renames }

// Component with two published TNotifyEvent properties, the surface
// PatternHandlerRenames reads through RTTI.
type
  TWiredButton = class(TComponent)
  private
    FOnClick: TNotifyEvent;
    FOnDblClick: TNotifyEvent;
  published
    property OnClick: TNotifyEvent read FOnClick write FOnClick;
    property OnDblClick: TNotifyEvent read FOnDblClick write FOnDblClick;
  end;

function Pairs(const AMethods: TArray<TMethodRename>): string;
var
  Pair: TMethodRename;
begin
  Result := '';
  for Pair in AMethods do
  begin
    if Result <> '' then
      Result := Result + '; ';
    Result := Result + Pair.OldName + '->' + Pair.NewName;
  end;
  if Result = '' then
    Result := '(none)';
end;

// An empty name leaves that event unassigned. The caller frees the returned
// component, which is created with no owner.
function WiredTo(AMap: TEventNameMap; const AClick, ADblClick: string): TWiredButton;
begin
  Result := TWiredButton.Create(nil);
  Result.Name := 'Button1';
  if AClick <> '' then
    Result.OnClick := TNotifyEvent(AMap.MarkerFor(AClick, TypeInfo(TNotifyEvent)));
  if ADblClick <> '' then
    Result.OnDblClick := TNotifyEvent(AMap.MarkerFor(ADblClick, TypeInfo(TNotifyEvent)));
end;

procedure TCouplingTests.AHandlerNamedAfterTheComponentRidesWithTheRename;
var
  Map: TEventNameMap;
  Button: TWiredButton;
begin
  Map := TEventNameMap.Create;
  try
    Button := WiredTo(Map, 'Button1Click', '');
    try
      Assert.AreEqual('Button1Click->Button2Click',
        Pairs(PatternHandlerRenames(Button, Map.NameFor, 'Button1', 'Button2')),
        'the handler the IDE would have named did not ride with the rename');
    finally
      Button.Free;
    end;
  finally
    Map.Free;
  end;
end;

procedure TCouplingTests.AHandlerSomebodyNamedIsLeftAlone;
var
  Map: TEventNameMap;
  Button: TWiredButton;
begin
  Map := TEventNameMap.Create;
  try
    Button := WiredTo(Map, 'HandleSave', '');
    try
      Assert.AreEqual('(none)',
        Pairs(PatternHandlerRenames(Button, Map.NameFor, 'Button1', 'Button2')),
        'a hand-named handler was renamed along with the component');
    finally
      Button.Free;
    end;
  finally
    Map.Free;
  end;
end;

procedure TCouplingTests.TwoEventsNamedAfterTheComponentBothRide;
var
  Map: TEventNameMap;
  Button: TWiredButton;
begin
  Map := TEventNameMap.Create;
  try
    Button := WiredTo(Map, 'Button1Click', 'Button1DblClick');
    try
      Assert.AreEqual('Button1Click->Button2Click; Button1DblClick->Button2DblClick',
        Pairs(PatternHandlerRenames(Button, Map.NameFor, 'Button1', 'Button2')),
        'only one of two handlers named after the component rode with it');
    finally
      Button.Free;
    end;
  finally
    Map.Free;
  end;
end;

// Pascal method names are case-insensitive, so a hand-edited form file that
// spells the handler differently still matches the default name pattern.
procedure TCouplingTests.TheOldNameIsMatchedWithoutRegardToCase;
var
  Map: TEventNameMap;
  Button: TWiredButton;
begin
  Map := TEventNameMap.Create;
  try
    Button := WiredTo(Map, 'button1click', '');
    try
      Assert.AreEqual('button1click->Button2Click',
        Pairs(PatternHandlerRenames(Button, Map.NameFor, 'Button1', 'Button2')),
        'a handler spelled differently was not recognised as the default name');
    finally
      Button.Free;
    end;
  finally
    Map.Free;
  end;
end;

// OldName is read off the event map rather than rebuilt from the pattern.
// The False argument selects DUnitX's case-sensitive AreEqual overload; the
// default ignores case, under which a rebuilt 'Button1Click' also passes.
procedure TCouplingTests.TheSpellingThatGoesOutIsTheOneTheMapHolds;
var
  Map: TEventNameMap;
  Button: TWiredButton;
  Renames: TArray<TMethodRename>;
begin
  Map := TEventNameMap.Create;
  try
    Button := WiredTo(Map, 'BUTTON1CLICK', '');
    try
      Renames := PatternHandlerRenames(Button, Map.NameFor, 'Button1', 'Button2');
      Assert.AreEqual(1, Length(Renames), 'the handler did not ride at all');
      Assert.AreEqual('BUTTON1CLICK', Renames[0].OldName, False,
        'the old name was rebuilt from the pattern instead of read off the map');
    finally
      Button.Free;
    end;
  finally
    Map.Free;
  end;
end;

procedure TCouplingTests.AnEventNothingIsWiredToRidesWithNothing;
var
  Map: TEventNameMap;
  Button: TWiredButton;
begin
  Map := TEventNameMap.Create;
  try
    Button := WiredTo(Map, '', '');
    try
      Assert.AreEqual('(none)',
        Pairs(PatternHandlerRenames(Button, Map.NameFor, 'Button1', 'Button2')),
        'an event wired to nothing produced a rename anyway');
    finally
      Button.Free;
    end;
  finally
    Map.Free;
  end;
end;

procedure TCouplingTests.ThePairsGoOverTheWireAsAListOfTwoNames;
var
  Pair: TMethodRename;
begin
  Pair.OldName := 'Button1Click';
  Pair.NewName := 'Button2Click';
  Assert.AreEqual('[{"old":"Button1Click","new":"Button2Click"}]',
    MethodRenamesJson([Pair]),
    'the pairs are not written the way the protocol says they are');
  Assert.AreEqual('[]', MethodRenamesJson([]),
    'a rename that takes no handler with it did not say so as an empty list');
end;

// Every component wired to a name shares one marker, so a rename moves the
// single interned entry instead of interning a second name.
procedure TCouplingTests.RenamingAHandlerReachesEveryComponentWiredToIt;
var
  Map: TEventNameMap;
  First, Second: TWiredButton;
begin
  Map := TEventNameMap.Create;
  try
    First := WiredTo(Map, 'Button1Click', '');
    Second := WiredTo(Map, 'Button1Click', '');
    try
      Assert.IsTrue(Map.Rename('Button1Click', 'Button2Click'),
        'the map did not hold the name it was asked to rename');
      Assert.AreEqual('Button2Click', Map.NameFor(TMethod(First.OnClick)),
        'the component that asked for the rename kept the old name');
      Assert.AreEqual('Button2Click', Map.NameFor(TMethod(Second.OnClick)),
        'a second component wired to the same handler kept the old name');
      Assert.AreEqual(1, Map.Count,
        'renaming interned a second name instead of moving the one');
    finally
      Second.Free;
      First.Free;
    end;
  finally
    Map.Free;
  end;
end;

procedure TCouplingTests.RenamingAHandlerTheMapNeverHeldChangesNothing;
var
  Map: TEventNameMap;
begin
  Map := TEventNameMap.Create;
  try
    Map.MarkerFor('Button1Click', TypeInfo(TNotifyEvent));
    Assert.IsFalse(Map.Rename('HandleSave', 'StoreAll'),
      'a name the map never held was reported as renamed');
    Assert.AreEqual(1, Map.Count, 'the map grew from a rename that found nothing');
    Assert.IsTrue(Map.Holds('Button1Click'),
      'the name that was there did not survive a rename of another');
  finally
    Map.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TCouplingTests);

end.
