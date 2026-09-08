// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.Layout;

// Covers TLayoutStore and TDialogLayoutStore: the defaults returned for an
// absent key, the round trip through a reopened store, DPI rescaling, and the
// stored values a load rejects as damage.
//
// Both fixtures write to HKEY_CURRENT_USER, under Tests subkeys of the
// settings root rather than the keys the product reads, and delete them in
// Setup and TearDown.

interface

uses
  DUnitX.TestFramework,
  Vallenta.FormEditor.Shell.Layout;

type
  // TLayoutStore: pane sizes, window size and the maximized flag across a
  // reopened store, rescaled to the reading DPI, with a damaged stored value
  // leaving the default in place.
  [TestFixture]
  TLayoutStoreTests = class
  private
    FStore: TLayoutStore;
    FDefaults: TDesignerLayout;
    procedure Reopen;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;
    [Test]
    procedure AStoreWithNothingInItAnswersWithTheDefaults;
    [Test]
    procedure WhatWasKeptIsThereAgainAtTheNextStart;
    [Test]
    procedure TheMaximizedWindowIsKeptAsOne;
    [Test]
    procedure SizesGrowWithTheDpiTheyAreReadAt;
    [Test]
    procedure SizesKeptAndReadAtTheSameDpiComeBackUnchanged;
    [Test]
    procedure ASizeNoPaneCouldHaveLeavesTheDefaultStanding;
    [Test]
    procedure ADamagedDpiIsReadAsTheReadersOwn;
    [Test]
    procedure AValueOfTheWrongKindLeavesTheDefaultsStanding;
    [Test]
    procedure AStoreThatWasOnlyReadLeavesNoKeyBehind;
  end;

  // TDialogLayoutStore: dialog size and column widths across a reopened
  // store, rescaled to the reading DPI, with as many columns as the defaults
  // record carries.
  [TestFixture]
  TDialogLayoutStoreTests = class
  private
    FStore: TDialogLayoutStore;
    FDefaults: TDialogLayout;
    procedure Reopen;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;
    [Test]
    procedure AStoreWithNothingInItAnswersWithTheDefaults;
    [Test]
    procedure WhatWasDraggedIsThereAgainAtTheNextStart;
    [Test]
    procedure SizesGrowWithTheDpiTheyAreReadAt;
    [Test]
    procedure AColumnDraggedShutComesBackShut;
    [Test]
    procedure ASizeNoDialogCouldHaveLeavesTheDefaultStanding;
    [Test]
    procedure OnlyAsManyColumnsAsTheCallerAsksForComeBack;
    [Test]
    procedure AStoreThatWasOnlyReadLeavesNoKeyBehind;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Win.Registry,
  Vallenta.FormEditor.Core.Settings;

const
  // Subkeys below the settings root used by these fixtures only; deleting one
  // must not delete a key the product reads.
  TestKey = 'Tests\WindowLayout';
  DialogTestKey = 'Tests\DialogLayout';
  KeptPPI = 96;
  DoublePPI = 192;

function TestKeyPath: string;
begin
  Result := SettingsKey(TestKey);
end;

function DialogTestKeyPath: string;
begin
  Result := SettingsKey(DialogTestKey);
end;

procedure DropKey(const AKey: string);
var
  Registry: TRegistry;
begin
  Registry := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    Registry.RootKey := HKEY_CURRENT_USER;
    Registry.DeleteKey(AKey);
  finally
    Registry.Free;
  end;
end;

function KeyIsThere(const AKey: string): Boolean;
var
  Registry: TRegistry;
begin
  Registry := TRegistry.Create(KEY_READ);
  try
    Registry.RootKey := HKEY_CURRENT_USER;
    Result := Registry.KeyExists(AKey);
  finally
    Registry.Free;
  end;
end;

procedure PutValue(const AKey, AName: string; AValue: Integer);
var
  Registry: TRegistry;
begin
  Registry := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    Registry.RootKey := HKEY_CURRENT_USER;
    Assert.IsTrue(Registry.OpenKey(AKey, True), 'the test key opens');
    Registry.WriteInteger(AName, AValue);
  finally
    Registry.Free;
  end;
end;

procedure PutText(const AKey, AName, AValue: string);
var
  Registry: TRegistry;
begin
  Registry := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    Registry.RootKey := HKEY_CURRENT_USER;
    Assert.IsTrue(Registry.OpenKey(AKey, True), 'the test key opens');
    Registry.WriteString(AName, AValue);
  finally
    Registry.Free;
  end;
end;

function DraggedLayout: TDesignerLayout;
begin
  Result.PaletteWidth := 210;
  Result.InspectorWidth := 340;
  Result.InspectorTreeHeight := 260;
  Result.MessagesHeight := 190;
  Result.WindowWidth := 1400;
  Result.WindowHeight := 900;
  Result.WindowMaximized := False;
end;

procedure TLayoutStoreTests.Setup;
begin
  DropKey(TestKeyPath);
  FStore := TLayoutStore.Create(TestKeyPath);
  FDefaults := Default(TDesignerLayout);
  FDefaults.PaletteWidth := 180;
  FDefaults.InspectorWidth := 300;
  FDefaults.InspectorTreeHeight := 180;
  FDefaults.MessagesHeight := 150;
  FDefaults.WindowWidth := 1100;
  FDefaults.WindowHeight := 700;
end;

procedure TLayoutStoreTests.TearDown;
begin
  FreeAndNil(FStore);
  DropKey(TestKeyPath);
end;

procedure TLayoutStoreTests.Reopen;
begin
  FreeAndNil(FStore);
  FStore := TLayoutStore.Create(TestKeyPath);
end;

procedure TLayoutStoreTests.AStoreWithNothingInItAnswersWithTheDefaults;
var
  Kept: TDesignerLayout;
begin
  Kept := FStore.Load(FDefaults, KeptPPI);
  Assert.AreEqual(FDefaults.PaletteWidth, Kept.PaletteWidth);
  Assert.AreEqual(FDefaults.InspectorWidth, Kept.InspectorWidth);
  Assert.AreEqual(FDefaults.InspectorTreeHeight, Kept.InspectorTreeHeight);
  Assert.AreEqual(FDefaults.MessagesHeight, Kept.MessagesHeight);
  Assert.AreEqual(FDefaults.WindowWidth, Kept.WindowWidth);
  Assert.AreEqual(FDefaults.WindowHeight, Kept.WindowHeight);
  Assert.IsFalse(Kept.WindowMaximized);
  Assert.AreEqual('', FStore.LastError);
end;

procedure TLayoutStoreTests.WhatWasKeptIsThereAgainAtTheNextStart;
var
  Dragged, Kept: TDesignerLayout;
begin
  Dragged := DraggedLayout;
  FStore.Save(Dragged, KeptPPI);
  Assert.AreEqual('', FStore.LastError);
  Reopen;
  Kept := FStore.Load(FDefaults, KeptPPI);
  Assert.AreEqual(Dragged.PaletteWidth, Kept.PaletteWidth);
  Assert.AreEqual(Dragged.InspectorWidth, Kept.InspectorWidth);
  Assert.AreEqual(Dragged.InspectorTreeHeight, Kept.InspectorTreeHeight);
  Assert.AreEqual(Dragged.MessagesHeight, Kept.MessagesHeight);
  Assert.AreEqual(Dragged.WindowWidth, Kept.WindowWidth);
  Assert.AreEqual(Dragged.WindowHeight, Kept.WindowHeight);
  Assert.AreEqual('', FStore.LastError);
end;

procedure TLayoutStoreTests.TheMaximizedWindowIsKeptAsOne;
var
  Dragged: TDesignerLayout;
begin
  Dragged := DraggedLayout;
  Dragged.WindowMaximized := True;
  FStore.Save(Dragged, KeptPPI);
  Reopen;
  Assert.IsTrue(FStore.Load(FDefaults, KeptPPI).WindowMaximized);
  Dragged.WindowMaximized := False;
  FStore.Save(Dragged, KeptPPI);
  Reopen;
  Assert.IsFalse(FStore.Load(FDefaults, KeptPPI).WindowMaximized);
end;

procedure TLayoutStoreTests.SizesGrowWithTheDpiTheyAreReadAt;
var
  Dragged, Kept: TDesignerLayout;
begin
  Dragged := DraggedLayout;
  FStore.Save(Dragged, KeptPPI);
  Reopen;
  Kept := FStore.Load(FDefaults, DoublePPI);
  Assert.AreEqual(2 * Dragged.PaletteWidth, Kept.PaletteWidth);
  Assert.AreEqual(2 * Dragged.InspectorWidth, Kept.InspectorWidth);
  Assert.AreEqual(2 * Dragged.InspectorTreeHeight, Kept.InspectorTreeHeight);
  Assert.AreEqual(2 * Dragged.MessagesHeight, Kept.MessagesHeight);
  Assert.AreEqual(2 * Dragged.WindowWidth, Kept.WindowWidth);
  Assert.AreEqual(2 * Dragged.WindowHeight, Kept.WindowHeight);
end;

procedure TLayoutStoreTests.SizesKeptAndReadAtTheSameDpiComeBackUnchanged;
var
  Dragged, Kept: TDesignerLayout;
begin
  Dragged := DraggedLayout;
  FStore.Save(Dragged, DoublePPI);
  Reopen;
  Kept := FStore.Load(FDefaults, DoublePPI);
  Assert.AreEqual(Dragged.PaletteWidth, Kept.PaletteWidth);
  Assert.AreEqual(Dragged.WindowWidth, Kept.WindowWidth);
end;

procedure TLayoutStoreTests.ASizeNoPaneCouldHaveLeavesTheDefaultStanding;
var
  Kept: TDesignerLayout;
begin
  FStore.Save(DraggedLayout, KeptPPI);
  PutValue(TestKeyPath, 'PaletteWidth', 0);
  PutValue(TestKeyPath, 'WindowHeight', 1000000);
  Reopen;
  Kept := FStore.Load(FDefaults, KeptPPI);
  Assert.AreEqual(FDefaults.PaletteWidth, Kept.PaletteWidth,
    'a pane of no width is a damaged store, not a choice');
  Assert.AreEqual(FDefaults.WindowHeight, Kept.WindowHeight,
    'and neither is a window taller than any screen');
  Assert.AreEqual(DraggedLayout.InspectorWidth, Kept.InspectorWidth,
    'the values beside them are read as they stand');
  Assert.AreEqual('', FStore.LastError);
end;

// A stored PPI outside 48..960 is replaced by the DPI passed to Load, so the
// sizes come back unscaled instead of being divided by zero.
procedure TLayoutStoreTests.ADamagedDpiIsReadAsTheReadersOwn;
var
  Dragged, Kept: TDesignerLayout;
begin
  Dragged := DraggedLayout;
  FStore.Save(Dragged, KeptPPI);
  PutValue(TestKeyPath, 'PPI', 0);
  Reopen;
  Kept := FStore.Load(FDefaults, DoublePPI);
  Assert.AreEqual(Dragged.PaletteWidth, Kept.PaletteWidth);
  Assert.AreEqual(Dragged.WindowWidth, Kept.WindowWidth);
  Assert.AreEqual('', FStore.LastError);
end;

procedure TLayoutStoreTests.AValueOfTheWrongKindLeavesTheDefaultsStanding;
var
  Kept: TDesignerLayout;
begin
  FStore.Save(DraggedLayout, KeptPPI);
  PutText(TestKeyPath, 'PaletteWidth', 'wide');
  Reopen;
  Kept := FStore.Load(FDefaults, KeptPPI);
  Assert.AreEqual(FDefaults.PaletteWidth, Kept.PaletteWidth);
  Assert.AreNotEqual('', FStore.LastError, 'and the reader is told why');
end;

procedure TLayoutStoreTests.AStoreThatWasOnlyReadLeavesNoKeyBehind;
begin
  FStore.Load(FDefaults, KeptPPI);
  Assert.IsFalse(KeyIsThere(TestKeyPath), 'reading creates nothing');
  Assert.AreEqual('', FStore.LastError);
end;

{ TDialogLayoutStoreTests }

function DraggedDialog: TDialogLayout;
begin
  Result.Width := 1200;
  Result.Height := 800;
  Result.ColumnWidths := [200, 140, 80, 90, 260, 240, 400];
end;

procedure TDialogLayoutStoreTests.Setup;
begin
  DropKey(DialogTestKeyPath);
  FStore := TDialogLayoutStore.Create(DialogTestKeyPath);
  FDefaults.Width := 940;
  FDefaults.Height := 620;
  FDefaults.ColumnWidths := [170, 120, 70, 70, 210, 220, 380];
end;

procedure TDialogLayoutStoreTests.TearDown;
begin
  FreeAndNil(FStore);
  DropKey(DialogTestKeyPath);
end;

procedure TDialogLayoutStoreTests.Reopen;
begin
  FreeAndNil(FStore);
  FStore := TDialogLayoutStore.Create(DialogTestKeyPath);
end;

procedure TDialogLayoutStoreTests.AStoreWithNothingInItAnswersWithTheDefaults;
var
  Kept: TDialogLayout;
  I: Integer;
begin
  Kept := FStore.Load(FDefaults, KeptPPI);
  Assert.AreEqual(FDefaults.Width, Kept.Width);
  Assert.AreEqual(FDefaults.Height, Kept.Height);
  Assert.AreEqual(Length(FDefaults.ColumnWidths), Length(Kept.ColumnWidths));
  for I := 0 to High(FDefaults.ColumnWidths) do
    Assert.AreEqual(FDefaults.ColumnWidths[I], Kept.ColumnWidths[I]);
  Assert.AreEqual('', FStore.LastError);
end;

procedure TDialogLayoutStoreTests.WhatWasDraggedIsThereAgainAtTheNextStart;
var
  Dragged, Kept: TDialogLayout;
  I: Integer;
begin
  Dragged := DraggedDialog;
  FStore.Save(Dragged, KeptPPI);
  Assert.AreEqual('', FStore.LastError);
  Reopen;
  Kept := FStore.Load(FDefaults, KeptPPI);
  Assert.AreEqual(Dragged.Width, Kept.Width);
  Assert.AreEqual(Dragged.Height, Kept.Height);
  for I := 0 to High(Dragged.ColumnWidths) do
    Assert.AreEqual(Dragged.ColumnWidths[I], Kept.ColumnWidths[I]);
  Assert.AreEqual('', FStore.LastError);
end;

procedure TDialogLayoutStoreTests.SizesGrowWithTheDpiTheyAreReadAt;
var
  Dragged, Kept: TDialogLayout;
  I: Integer;
begin
  Dragged := DraggedDialog;
  FStore.Save(Dragged, KeptPPI);
  Reopen;
  Kept := FStore.Load(FDefaults, DoublePPI);
  Assert.AreEqual(2 * Dragged.Width, Kept.Width);
  Assert.AreEqual(2 * Dragged.Height, Kept.Height);
  for I := 0 to High(Dragged.ColumnWidths) do
    Assert.AreEqual(2 * Dragged.ColumnWidths[I], Kept.ColumnWidths[I]);
end;

// A stored column width of 0 is read back; every other stored size is
// discarded below 16 pixels and the default kept.
procedure TDialogLayoutStoreTests.AColumnDraggedShutComesBackShut;
var
  Dragged, Kept: TDialogLayout;
begin
  Dragged := DraggedDialog;
  Dragged.ColumnWidths[5] := 0;
  FStore.Save(Dragged, KeptPPI);
  Reopen;
  Kept := FStore.Load(FDefaults, KeptPPI);
  Assert.AreEqual(0, Kept.ColumnWidths[5]);
  Assert.AreEqual(Dragged.ColumnWidths[4], Kept.ColumnWidths[4],
    'the columns beside it are read as they stand');
end;

procedure TDialogLayoutStoreTests.ASizeNoDialogCouldHaveLeavesTheDefaultStanding;
var
  Kept: TDialogLayout;
begin
  FStore.Save(DraggedDialog, KeptPPI);
  PutValue(DialogTestKeyPath, 'Width', 0);
  PutValue(DialogTestKeyPath, 'Column1', 1000000);
  Reopen;
  Kept := FStore.Load(FDefaults, KeptPPI);
  Assert.AreEqual(FDefaults.Width, Kept.Width,
    'a dialog of no width is a damaged store, not a choice');
  Assert.AreEqual(FDefaults.ColumnWidths[1], Kept.ColumnWidths[1],
    'and neither is a column wider than any screen');
  Assert.AreEqual(DraggedDialog.Height, Kept.Height,
    'the values beside them are read as they stand');
  Assert.AreEqual('', FStore.LastError);
end;

// The column count comes from the defaults record.
procedure TDialogLayoutStoreTests.OnlyAsManyColumnsAsTheCallerAsksForComeBack;
var
  Fewer, Kept: TDialogLayout;
begin
  FStore.Save(DraggedDialog, KeptPPI);
  Reopen;
  Fewer := FDefaults;
  Fewer.ColumnWidths := [170, 120, 70];
  Kept := FStore.Load(Fewer, KeptPPI);
  Assert.AreEqual(3, Length(Kept.ColumnWidths));
  Assert.AreEqual(DraggedDialog.ColumnWidths[2], Kept.ColumnWidths[2]);
end;

procedure TDialogLayoutStoreTests.AStoreThatWasOnlyReadLeavesNoKeyBehind;
begin
  FStore.Load(FDefaults, KeptPPI);
  Assert.IsFalse(KeyIsThere(DialogTestKeyPath), 'reading creates nothing');
  Assert.AreEqual('', FStore.LastError);
end;

initialization
  TDUnitX.RegisterTestFixture(TLayoutStoreTests);
  TDUnitX.RegisterTestFixture(TDialogLayoutStoreTests);

end.
