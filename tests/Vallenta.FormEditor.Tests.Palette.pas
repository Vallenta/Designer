// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.Palette;

// Covers the palette content model, the search filter and the favourites
// store: the order groups and items are returned in, what a search term
// matches, and what a reopened favourites store reads back.
//
// The ordering fixture starts the designer session, so the packages a run
// loaded determine the content; its cases assert that every neighbouring
// pair is in order rather than compare against a fixed list of names. The
// favourites fixture writes to HKEY_CURRENT_USER, under a Tests subkey of
// the settings root rather than the key the product reads.

interface

uses
  DUnitX.TestFramework,
  Vallenta.FormEditor.Palette.Model,
  Vallenta.FormEditor.Palette.Favourites;

type
  // TPaletteModel: groups sorted by caption and items by display name, both
  // case-insensitively. While BuiltInClassesActive is False the model holds
  // package groups only, and DropDynamicEntries empties it.
  [TestFixture]
  TPaletteOrderTests = class
  private
    FModel: TPaletteModel;
    function FirstGroupOutOfOrder: string;
    function FirstItemOutOfOrder: string;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;
    [Test]
    procedure GroupsComeOutSortedByCaption;
    [Test]
    procedure ItemsComeOutSortedWithinTheirGroup;
    [Test]
    procedure DroppingThePackageEntriesLeavesBothOrdersStanding;
  end;

  // TPaletteFilter: what a search term matches on an item display name,
  // including masks and a pattern TMask rejects.
  [TestFixture]
  TPaletteFilterTests = class
  private
    FFilter: TPaletteFilter;
    FItem: TPaletteItem;
    function Passes(const ATerm: string): Boolean;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;
    [Test]
    procedure AnEmptyTermPassesEverything;
    [Test]
    procedure ABareTermMatchesAnywhereInTheName;
    [Test]
    procedure ABareTermIgnoresCase;
    [Test]
    procedure ATermThatIsNowhereInTheNameMatchesNothing;
    [Test]
    procedure AStarAnchorsWhatSurroundsIt;
    [Test]
    procedure AQuestionMarkStandsForOneCharacter;
    [Test]
    procedure SurroundingWhitespaceIsNotPartOfTheTerm;
    [Test]
    procedure APatternThatWillNotCompilePassesNothing;
    [Test]
    procedure OneFilterReusedAgreesWithAFreshOnePerItem;
  end;

  // TPaletteFavourites: page and component marks, what a marked page covers,
  // and what a reopened store reads back from the registry.
  [TestFixture]
  TPaletteFavouritesTests = class
  private
    FFavourites: TPaletteFavourites;
    FItem: TPaletteItem;
    procedure Reopen;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;
    [Test]
    procedure AComponentIsMarkedAndUnmarked;
    [Test]
    procedure APageIsMarkedAndUnmarked;
    [Test]
    procedure AMarkedPageCarriesTheComponentsOnIt;
    [Test]
    procedure UnmarkingThePageLeavesAComponentMarkedInItsOwnRight;
    [Test]
    procedure WhatWasMarkedIsThereAgainAtTheNextStart;
    [Test]
    procedure APageNameSurvivesTheCharactersAKeyNameCouldNotHold;
    [Test]
    procedure AClassNoPackageRegistersStaysInTheStore;
    [Test]
    procedure UnmarkingOneEntryLeavesTheOthersAlone;
    [Test]
    procedure AStoreThatMarkedNothingLeavesNoKeyBehind;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Win.Registry,
  Vcl.StdCtrls,
  Vallenta.FormEditor.Core.Settings,
  Vallenta.FormEditor.Tests.Environment;

{ TPaletteOrderTests }

procedure TPaletteOrderTests.Setup;
begin
  BeginDesignerSession;
  FModel := TPaletteModel.Create;
  FModel.BuildFromRegistry;
end;

procedure TPaletteOrderTests.TearDown;
begin
  FreeAndNil(FModel);
end;

function TPaletteOrderTests.FirstGroupOutOfOrder: string;
var
  I: Integer;
begin
  for I := 1 to FModel.Groups.Count - 1 do
    if AnsiCompareText(FModel.Groups[I - 1].Caption,
      FModel.Groups[I].Caption) > 0 then
      Exit(Format('%s comes before %s',
        [FModel.Groups[I - 1].Caption, FModel.Groups[I].Caption]));
  Result := '';
end;

function TPaletteOrderTests.FirstItemOutOfOrder: string;
var
  Group: TPaletteGroup;
  I, J: Integer;
begin
  for I := 0 to FModel.Groups.Count - 1 do
  begin
    Group := FModel.Groups[I];
    for J := 1 to Group.Items.Count - 1 do
      if AnsiCompareText(Group.Items[J - 1].DisplayName,
        Group.Items[J].DisplayName) > 0 then
        Exit(Format('on %s, %s comes before %s', [Group.Caption,
          Group.Items[J - 1].DisplayName, Group.Items[J].DisplayName]));
  end;
  Result := '';
end;

procedure TPaletteOrderTests.GroupsComeOutSortedByCaption;
begin
  Assert.IsTrue(FModel.Groups.Count > 0,
    'the palette model built no groups at all - the run has no packages');
  Assert.AreEqual('', FirstGroupOutOfOrder);
end;

procedure TPaletteOrderTests.ItemsComeOutSortedWithinTheirGroup;
begin
  Assert.AreEqual('', FirstItemOutOfOrder);
end;

// DropDynamicEntries only deletes and never sorts again. While
// BuiltInClassesActive is False it deletes every group, so both checks run
// over an empty list and the case pins nothing.
procedure TPaletteOrderTests.DroppingThePackageEntriesLeavesBothOrdersStanding;
begin
  FModel.DropDynamicEntries;
  Assert.AreEqual('', FirstGroupOutOfOrder);
  Assert.AreEqual('', FirstItemOutOfOrder);
end;

{ TPaletteFilterTests }

// TButton is linked into the test executable, so the item exists whatever
// packages a run loaded. The Passes helper matches a term against its
// display name, 'Button'.
procedure TPaletteFilterTests.Setup;
begin
  FFilter := TPaletteFilter.Create;
  FItem := TPaletteItem.Create(TButton, False);
end;

procedure TPaletteFilterTests.TearDown;
begin
  FreeAndNil(FItem);
  FreeAndNil(FFilter);
end;

function TPaletteFilterTests.Passes(const ATerm: string): Boolean;
begin
  FFilter.SetTerm(ATerm);
  Result := FFilter.Matches(FItem);
end;

procedure TPaletteFilterTests.AnEmptyTermPassesEverything;
begin
  Assert.IsTrue(Passes(''));
  Assert.IsTrue(Passes('   '));
end;

procedure TPaletteFilterTests.ABareTermMatchesAnywhereInTheName;
begin
  Assert.IsTrue(Passes('But'), 'at the start');
  Assert.IsTrue(Passes('utto'), 'in the middle');
  Assert.IsTrue(Passes('ton'), 'at the end');
  Assert.IsTrue(Passes('Button'), 'the whole name');
end;

procedure TPaletteFilterTests.ABareTermIgnoresCase;
begin
  Assert.IsTrue(Passes('button'));
  Assert.IsTrue(Passes('BUTTON'));
  Assert.IsTrue(Passes('bUtToN'));
end;

procedure TPaletteFilterTests.ATermThatIsNowhereInTheNameMatchesNothing;
begin
  Assert.IsFalse(Passes('Memo'));
  Assert.IsFalse(Passes('TButton'));
end;

procedure TPaletteFilterTests.AStarAnchorsWhatSurroundsIt;
begin
  Assert.IsTrue(Passes('But*'), 'anchored at the start');
  Assert.IsTrue(Passes('*ton'), 'anchored at the end');
  Assert.IsFalse(Passes('utton*'), 'a star does not loosen the other end');
  Assert.IsFalse(Passes('*Butto'), 'nor this one');
end;

procedure TPaletteFilterTests.AQuestionMarkStandsForOneCharacter;
begin
  Assert.IsTrue(Passes('?utton'));
  Assert.IsFalse(Passes('?tton'), 'one character, not any number of them');
end;

procedure TPaletteFilterTests.SurroundingWhitespaceIsNotPartOfTheTerm;
begin
  Assert.IsTrue(Passes('  Button  '));
  Assert.AreEqual('Button', FFilter.Term);
end;

// The term is set while it is still being typed, so a partly typed mask such
// as '[But' reaches TMask.Create, which rejects it.
procedure TPaletteFilterTests.APatternThatWillNotCompilePassesNothing;
begin
  Assert.IsFalse(Passes('[But'));
  Assert.AreEqual('[But', FFilter.Term, 'the term still reads as it was typed');
  Assert.IsTrue(Passes('But'), 'and the next keystroke recovers');
end;

// The palette sets one term and then tests every item against that filter,
// repeatedly across rebuilds, so Matches must not carry state from one item
// to the next; a filter created per item is the reference.
procedure TPaletteFilterTests.OneFilterReusedAgreesWithAFreshOnePerItem;
const
  Terms: array [0 .. 5] of string = ('but', 'Memo', '*o', 'b?tton', '', 'x');
  Classes: array [0 .. 4] of TComponentClass = (TButton, TEdit, TMemo,
    TCheckBox, TLabel);
var
  Items: array [0 .. 4] of TPaletteItem;
  Fresh: TPaletteFilter;
  T, I, Pass: Integer;
  Reused, PerItem: Boolean;
begin
  for I := Low(Classes) to High(Classes) do
    Items[I] := TPaletteItem.Create(Classes[I], False);
  try
    for T := Low(Terms) to High(Terms) do
    begin
      FFilter.SetTerm(Terms[T]);
      for Pass := 1 to 3 do
        for I := Low(Items) to High(Items) do
        begin
          Reused := FFilter.Matches(Items[I]);
          Fresh := TPaletteFilter.Create;
          try
            Fresh.SetTerm(Terms[T]);
            PerItem := Fresh.Matches(Items[I]);
          finally
            Fresh.Free;
          end;
          Assert.AreEqual(PerItem, Reused, Format('term "%s", %s, pass %d',
            [Terms[T], Items[I].DisplayName, Pass]));
        end;
    end;
  finally
    for I := Low(Items) to High(Items) do
      Items[I].Free;
  end;
end;

{ TPaletteFavouritesTests }

const
  // Subkey below the settings root used by this fixture only; the product
  // reads SettingsKey('Palette'). Fixed rather than generated, so a run that
  // fails mid-case leaves one key, which the next Setup deletes.
  TestKey = 'Tests\PaletteFavourites';
  UnregisteredClass = 'TNoPackageRegistersThis';
  // Contains '=', a character a registry value name accepts and an ini key
  // name does not.
  AwkwardPage = 'Vallenta = Studio Controls';

function TestKeyPath: string;
begin
  Result := SettingsKey(TestKey);
end;

// Deletes this fixture's subtree only; the parent Tests key also holds the
// keys of other fixtures. DeleteKey removes the two subkeys with it.
procedure DropTestKeys;
var
  Registry: TRegistry;
begin
  Registry := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    Registry.RootKey := HKEY_CURRENT_USER;
    Registry.DeleteKey(TestKeyPath);
  finally
    Registry.Free;
  end;
end;

function TestKeyExists: Boolean;
var
  Registry: TRegistry;
begin
  Registry := TRegistry.Create(KEY_READ);
  try
    Registry.RootKey := HKEY_CURRENT_USER;
    Result := Registry.KeyExists(TestKeyPath);
  finally
    Registry.Free;
  end;
end;

procedure TPaletteFavouritesTests.Setup;
begin
  DropTestKeys;
  FFavourites := TPaletteFavourites.Create(TestKeyPath);
  FItem := TPaletteItem.Create(TButton, False);
end;

procedure TPaletteFavouritesTests.TearDown;
begin
  FreeAndNil(FItem);
  FreeAndNil(FFavourites);
  DropTestKeys;
end;

// TPaletteFavourites reads both registry subkeys at construction only, so a
// second store over the same key reads what a restart would.
procedure TPaletteFavouritesTests.Reopen;
begin
  FreeAndNil(FFavourites);
  FFavourites := TPaletteFavourites.Create(TestKeyPath);
end;

procedure TPaletteFavouritesTests.AComponentIsMarkedAndUnmarked;
begin
  Assert.IsFalse(FFavourites.HasItem('TButton'), 'nothing is marked to start');
  Assert.IsTrue(FFavourites.ToggleItem('TButton'), 'the toggle reports it on');
  Assert.IsTrue(FFavourites.HasItem('TButton'));
  Assert.IsFalse(FFavourites.ToggleItem('TButton'), 'and reports it off again');
  Assert.IsFalse(FFavourites.HasItem('TButton'));
  Assert.AreEqual('', FFavourites.LastError);
end;

procedure TPaletteFavouritesTests.APageIsMarkedAndUnmarked;
begin
  Assert.IsFalse(FFavourites.HasGroup('Standard'));
  Assert.IsTrue(FFavourites.ToggleGroup('Standard'));
  Assert.IsTrue(FFavourites.HasGroup('Standard'));
  Assert.IsFalse(FFavourites.ToggleGroup('Standard'));
  Assert.IsFalse(FFavourites.HasGroup('Standard'));
  Assert.AreEqual('', FFavourites.LastError);
end;

// Holds is True from the page mark alone; marking a page does not mark the
// components on it in their own right.
procedure TPaletteFavouritesTests.AMarkedPageCarriesTheComponentsOnIt;
begin
  Assert.IsFalse(FFavourites.Holds(FItem, 'Standard'));
  FFavourites.ToggleGroup('Standard');
  Assert.IsTrue(FFavourites.Holds(FItem, 'Standard'));
  Assert.IsFalse(FFavourites.HasItem('TButton'),
    'the page carries it; the component itself is not marked');
  Assert.IsFalse(FFavourites.Holds(FItem, 'Additional'),
    'and only on the page that is marked');
end;

procedure TPaletteFavouritesTests.
  UnmarkingThePageLeavesAComponentMarkedInItsOwnRight;
begin
  FFavourites.ToggleItem('TButton');
  FFavourites.ToggleGroup('Standard');
  Assert.IsTrue(FFavourites.Holds(FItem, 'Standard'));
  FFavourites.ToggleGroup('Standard');
  Assert.IsFalse(FFavourites.HasGroup('Standard'));
  Assert.IsTrue(FFavourites.Holds(FItem, 'Standard'),
    'its own mark outlives the page it sat on');
end;

procedure TPaletteFavouritesTests.WhatWasMarkedIsThereAgainAtTheNextStart;
begin
  FFavourites.ToggleGroup('Standard');
  FFavourites.ToggleGroup('Win32');
  FFavourites.ToggleItem('TButton');
  FFavourites.ToggleItem('TMemo');
  FFavourites.ToggleGroup('Win32');
  Reopen;
  Assert.IsTrue(FFavourites.HasGroup('Standard'));
  Assert.IsFalse(FFavourites.HasGroup('Win32'), 'unmarked before the restart');
  Assert.IsTrue(FFavourites.HasItem('TButton'));
  Assert.IsTrue(FFavourites.HasItem('TMemo'));
end;

procedure TPaletteFavouritesTests.
  APageNameSurvivesTheCharactersAKeyNameCouldNotHold;
begin
  FFavourites.ToggleGroup(AwkwardPage);
  Reopen;
  Assert.IsTrue(FFavourites.HasGroup(AwkwardPage));
end;

// The store never resolves a name against the component registry.
procedure TPaletteFavouritesTests.AClassNoPackageRegistersStaysInTheStore;
begin
  FFavourites.ToggleItem(UnregisteredClass);
  Reopen;
  Assert.IsTrue(FFavourites.HasItem(UnregisteredClass));
end;

procedure TPaletteFavouritesTests.UnmarkingOneEntryLeavesTheOthersAlone;
begin
  FFavourites.ToggleItem('TButton');
  FFavourites.ToggleItem('TMemo');
  FFavourites.ToggleGroup('Standard');
  FFavourites.ToggleItem('TButton');
  Reopen;
  Assert.IsFalse(FFavourites.HasItem('TButton'));
  Assert.IsTrue(FFavourites.HasItem('TMemo'), 'its neighbour is untouched');
  Assert.IsTrue(FFavourites.HasGroup('Standard'),
    'and so is the other subkey');
end;

procedure TPaletteFavouritesTests.AStoreThatMarkedNothingLeavesNoKeyBehind;
begin
  Assert.IsFalse(TestKeyExists, 'reading must not create the tree');
  Assert.IsFalse(FFavourites.HasItem('TButton'));
  Assert.IsFalse(FFavourites.HasGroup('Standard'));
  Reopen;
  Assert.IsFalse(TestKeyExists, 'and neither must reopening it');
  FFavourites.ToggleItem('TButton');
  Assert.IsTrue(TestKeyExists, 'the first mark is what creates it');
end;

initialization
  TDUnitX.RegisterTestFixture(TPaletteOrderTests);
  TDUnitX.RegisterTestFixture(TPaletteFilterTests);
  TDUnitX.RegisterTestFixture(TPaletteFavouritesTests);

end.
