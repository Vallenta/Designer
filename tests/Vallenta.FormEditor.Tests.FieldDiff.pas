// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.FieldDiff;

// Covers TFieldLedger: the diff of a document's components against the
// acknowledged field set, the acknowledgement that adds an entry or drops it,
// and the baseline that keeps components the document already held out of
// AddsSinceBaseline. FieldOf, which builds an entry from a component, is
// covered as well.

interface

uses
  DUnitX.TestFramework,
  Vallenta.FormEditor.Core.FieldLedger;

type
  // Diff, acknowledgement, baseline and rename behaviour of TFieldLedger, and
  // the entry FieldOf builds from a component.
  [TestFixture]
  TFieldDiffTests = class
  public
    [Test]
    procedure ABaselineSeedsTheSetAndReportsNothing;
    [Test]
    procedure AComponentThatAppearedIsOneAdd;
    [Test]
    procedure AComponentThatWentIsOneRemove;
    [Test]
    procedure AComponentCreatedAndDeletedBetweenSettlePointsIsNothing;
    [Test]
    procedure ARestoreThatTookTwoAwayIsTwoRemoves;
    [Test]
    procedure OnlyAnAcknowledgementMovesTheLedger;
    [Test]
    procedure ARefusedAddIsReportedAgainAtTheNextSettlePoint;
    [Test]
    procedure AResumeSendsWhatWasAddedAndNotWhatWasThereFirst;
    [Test]
    procedure ADocumentThatHasBaselinedSaysSoEvenWithNothingInIt;
    [Test]
    procedure AFieldTakenAwayAndPutBackIsAskedForAgain;
    [Test]
    procedure ANameIsMatchedWhateverItIsSpelledLike;
    [Test]
    procedure ARenamedComponentKeepsItsFieldUnderTheNewName;
    [Test]
    procedure AComponentNamesItsOwnClassAndTheUnitItComesFrom;
  end;

implementation

uses
  System.Classes,
  System.SysUtils,
  Vcl.Controls;

function Field(const AName, AType, AUnit: string): TFieldEntry;
begin
  Result.Name := AName;
  Result.TypeName := AType;
  Result.UnitName := AUnit;
end;

function Button(const AName: string): TFieldEntry;
begin
  Result := Field(AName, 'TButton', 'Vcl.StdCtrls');
end;

procedure SettleWithEverythingAnswered(ALedger: TFieldLedger;
  const AFields: TArray<TFieldEntry>);
var
  Change: TFieldChange;
begin
  for Change in ALedger.Diff(AFields) do
    ALedger.Acknowledge(Change);
end;

function Describe(const AChanges: TArray<TFieldChange>): string;
const
  Kinds: array [TFieldChangeKind] of string = ('add', 'remove');
var
  Change: TFieldChange;
begin
  Result := '';
  for Change in AChanges do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + Kinds[Change.Kind] + ' ' + Change.Entry.Name;
  end;
  if Result = '' then
    Result := '(nothing)';
end;

function Names(const AFields: TArray<TFieldEntry>): string;
var
  Entry: TFieldEntry;
begin
  Result := '';
  for Entry in AFields do
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + Entry.Name;
  end;
  if Result = '' then
    Result := '(nothing)';
end;

procedure TFieldDiffTests.ABaselineSeedsTheSetAndReportsNothing;
var
  Ledger: TFieldLedger;
begin
  Ledger := TFieldLedger.Create;
  try
    Ledger.Baseline([Button('Ok'), Button('Cancel')]);
    Assert.AreEqual(2, Ledger.Count, 'the baseline did not seed the set');
    Assert.AreEqual('(nothing)', Describe(Ledger.Diff([Button('Ok'), Button('Cancel')])),
      'a form that was already like this was reported as though it had changed');
    Assert.AreEqual('(nothing)', Names(Ledger.AddsSinceBaseline),
      'components that predate the coupling were counted as its own additions');
  finally
    Ledger.Free;
  end;
end;

procedure TFieldDiffTests.AComponentThatAppearedIsOneAdd;
var
  Ledger: TFieldLedger;
begin
  Ledger := TFieldLedger.Create;
  try
    Ledger.Baseline([Button('Ok')]);
    Assert.AreEqual('add Button1',
      Describe(Ledger.Diff([Button('Ok'), Button('Button1')])),
      'creating one component did not produce exactly one add');
  finally
    Ledger.Free;
  end;
end;

procedure TFieldDiffTests.AComponentThatWentIsOneRemove;
var
  Ledger: TFieldLedger;
begin
  Ledger := TFieldLedger.Create;
  try
    Ledger.Baseline([Button('Ok'), Button('Cancel')]);
    Assert.AreEqual('remove Cancel', Describe(Ledger.Diff([Button('Ok')])),
      'deleting one component did not produce exactly one remove');
  finally
    Ledger.Free;
  end;
end;

// The create and the delete are not arranged at all: the ledger receives the
// component set only at a settle point, never the changes in between.
procedure TFieldDiffTests.AComponentCreatedAndDeletedBetweenSettlePointsIsNothing;
var
  Ledger: TFieldLedger;
begin
  Ledger := TFieldLedger.Create;
  try
    Ledger.Baseline([Button('Ok')]);
    Assert.AreEqual('(nothing)', Describe(Ledger.Diff([Button('Ok')])),
      'a component that came and went was reported as something');
  finally
    Ledger.Free;
  end;
end;

// The restore is arranged as one diff of the whole component set, which is how
// an undo reaches the ledger.
procedure TFieldDiffTests.ARestoreThatTookTwoAwayIsTwoRemoves;
var
  Ledger: TFieldLedger;
begin
  Ledger := TFieldLedger.Create;
  try
    Ledger.Baseline([Button('Ok')]);
    SettleWithEverythingAnswered(Ledger,
      [Button('Ok'), Button('Button1'), Button('Button2')]);
    Assert.AreEqual('remove Button1, remove Button2',
      Describe(Ledger.Diff([Button('Ok')])),
      'a restore that took two components away was not two removes');
  finally
    Ledger.Free;
  end;
end;

procedure TFieldDiffTests.OnlyAnAcknowledgementMovesTheLedger;
var
  Ledger: TFieldLedger;
  Changes: TArray<TFieldChange>;
begin
  Ledger := TFieldLedger.Create;
  try
    Ledger.Baseline([]);
    Changes := Ledger.Diff([Button('Button1')]);
    Assert.AreEqual(0, Ledger.Count,
      'the ledger moved on the strength of a report nobody had answered yet');
    Ledger.Acknowledge(Changes[0]);
    Assert.AreEqual(1, Ledger.Count, 'an acknowledged add did not reach the ledger');
  finally
    Ledger.Free;
  end;
end;

// A refusal is arranged by discarding the diff result without acknowledging
// it; Acknowledge is the only call that records a change.
procedure TFieldDiffTests.ARefusedAddIsReportedAgainAtTheNextSettlePoint;
var
  Ledger: TFieldLedger;
begin
  Ledger := TFieldLedger.Create;
  try
    Ledger.Baseline([]);
    Ledger.Diff([Button('Button1')]);
    Assert.AreEqual('add Button1', Describe(Ledger.Diff([Button('Button1')])),
      'an add nobody confirmed was quietly forgotten');
  finally
    Ledger.Free;
  end;
end;

// A resume is not a ledger operation: what a session re-sends on attach is
// AddsSinceBaseline, and that is what the assertions read.
procedure TFieldDiffTests.AResumeSendsWhatWasAddedAndNotWhatWasThereFirst;
var
  Ledger: TFieldLedger;
begin
  Ledger := TFieldLedger.Create;
  try
    Ledger.Baseline([Button('Ok')]);
    SettleWithEverythingAnswered(Ledger, [Button('Ok'), Button('Button1')]);
    Assert.AreEqual('Button1', Names(Ledger.AddsSinceBaseline),
      'a resume would have re-sent the wrong set');
    Assert.IsTrue(Ledger.HasBaseline,
      'the ledger forgot that it had already been seeded');
  finally
    Ledger.Free;
  end;
end;

// Count cannot stand in for HasBaseline: a document with no components and a
// document that was never baselined both leave the ledger at zero entries.
procedure TFieldDiffTests.ADocumentThatHasBaselinedSaysSoEvenWithNothingInIt;
var
  Ledger: TFieldLedger;
begin
  Ledger := TFieldLedger.Create;
  try
    Assert.IsFalse(Ledger.HasBaseline, 'a fresh ledger claimed to have been seeded');
    Ledger.Baseline([]);
    Assert.IsTrue(Ledger.HasBaseline,
      'seeding an empty document did not count as seeding it');
  finally
    Ledger.Free;
  end;
end;

// An acknowledged remove drops the baseline mark as well, so the field counts
// as an add since baseline once the component is put back.
procedure TFieldDiffTests.AFieldTakenAwayAndPutBackIsAskedForAgain;
var
  Ledger: TFieldLedger;
begin
  Ledger := TFieldLedger.Create;
  try
    Ledger.Baseline([Button('Ok')]);
    SettleWithEverythingAnswered(Ledger, []);
    Assert.AreEqual('add Ok', Describe(Ledger.Diff([Button('Ok')])),
      'a field that had been removed was assumed to be there still');
    SettleWithEverythingAnswered(Ledger, [Button('Ok')]);
    Assert.AreEqual('Ok', Names(Ledger.AddsSinceBaseline),
      'a field this designer asked for was counted as one it found');
  finally
    Ledger.Free;
  end;
end;

// Names match case-insensitively: another casing of the same component name
// must not be reported as a remove plus an add.
procedure TFieldDiffTests.ANameIsMatchedWhateverItIsSpelledLike;
var
  Ledger: TFieldLedger;
begin
  Ledger := TFieldLedger.Create;
  try
    Ledger.Baseline([Button('Button1')]);
    Assert.AreEqual('(nothing)', Describe(Ledger.Diff([Button('BUTTON1')])),
      'the same component under another spelling was taken for two');
  finally
    Ledger.Free;
  end;
end;

procedure TFieldDiffTests.ARenamedComponentKeepsItsFieldUnderTheNewName;
var
  Ledger: TFieldLedger;
begin
  Ledger := TFieldLedger.Create;
  try
    Ledger.Baseline([]);
    SettleWithEverythingAnswered(Ledger, [Button('Button1')]);
    Ledger.RenameKey('Button1', 'Button2');
    Assert.AreEqual('(nothing)', Describe(Ledger.Diff([Button('Button2')])),
      'a rename the ledger was told about was reported as a delete and an add');
    Assert.AreEqual('Button2', Names(Ledger.AddsSinceBaseline),
      'the renamed field is not what a resume would re-ensure');
  finally
    Ledger.Free;
  end;
end;

procedure TFieldDiffTests.AComponentNamesItsOwnClassAndTheUnitItComesFrom;
var
  Component: TComponent;
  Entry: TFieldEntry;
begin
  Component := TComponent.Create(nil);
  try
    Component.Name := 'Thing1';
    Entry := FieldOf(Component);
    Assert.AreEqual('Thing1', Entry.Name, 'the field is not named after the component');
    Assert.AreEqual('TComponent', Entry.TypeName, 'the field did not take the component''s class');
    Assert.AreEqual('System.Classes', Entry.UnitName,
      'the unit a class comes from is not what it answers with');
  finally
    Component.Free;
  end;
  Assert.AreEqual('Vcl.Controls', TControl.UnitName,
    'a dotted unit name did not survive being read off the class');
end;

initialization
  TDUnitX.RegisterTestFixture(TFieldDiffTests);

end.
