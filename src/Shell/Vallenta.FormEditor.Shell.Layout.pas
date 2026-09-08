// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Shell.Layout;

// Reads and writes designer window layout and resizable dialog geometry as
// registry values below HKEY_CURRENT_USER, under the key path each store is
// constructed with. Sizes are pixels; a save records the DPI they were
// measured at, and a load rescales them to the DPI it is passed. Loading
// creates no key and no method raises; a failure sets LastError.

interface

type
  // Pane and window sizes of one designer window, in pixels at the DPI passed
  // to Load or Save.
  TDesignerLayout = record
    // Width of the palette pane, left of the design surface.
    PaletteWidth: Integer;
    // Width of the inspector pane, right of the design surface.
    InspectorWidth: Integer;
    // Height of the component tree above the inspector's own splitter.
    InspectorTreeHeight: Integer;
    // Height of the messages pane below the design surface.
    MessagesHeight: Integer;
    // Window size while not maximized.
    WindowWidth: Integer;
    WindowHeight: Integer;
    // True when the window was left maximized.
    WindowMaximized: Boolean;
  end;

  // Reads and writes one designer window layout below HKEY_CURRENT_USER.
  // Loading creates no key; the first Save creates it.
  TLayoutStore = class
  private
    FKey: string;
    FLastError: string;
  public
    // AKey is the key path below HKEY_CURRENT_USER holding the values, given
    // without a root key.
    constructor Create(const AKey: string);
    // The stored layout, rescaled from the saved DPI to APPI. A missing or
    // out-of-range value leaves that field at its ADefaults value. A read
    // error stops the load; every field not yet read keeps its default.
    function Load(const ADefaults: TDesignerLayout;
      APPI: Integer): TDesignerLayout;
    // Writes every field of ALayout, creating the key if needed. APPI is the
    // DPI the sizes were measured at and is stored beside them.
    procedure Save(const ALayout: TDesignerLayout; APPI: Integer);
    // Message from the last Load or Save, empty when it succeeded. Neither
    // method raises, so this is the only signal of a failure.
    property LastError: string read FLastError;
  end;

  // Size of a resizable list dialog and the widths of its columns, in pixels
  // at the DPI passed to Load or Save.
  TDialogLayout = record
    // Client size of the dialog.
    Width: Integer;
    Height: Integer;
    // One width per column, left to right.
    ColumnWidths: TArray<Integer>;
  end;

  // Reads and writes one dialog's size and column widths below
  // HKEY_CURRENT_USER. Loading creates no key; the first Save creates it.
  TDialogLayoutStore = class
  private
    FKey: string;
    FLastError: string;
  public
    // AKey is the key path below HKEY_CURRENT_USER holding the values, given
    // without a root key.
    constructor Create(const AKey: string);
    // The stored layout, rescaled from the saved DPI to APPI, with as many
    // column widths as ADefaults carries. A missing or out-of-range value
    // keeps the ADefaults field; a stored column width of 0 is read back.
    function Load(const ADefaults: TDialogLayout; APPI: Integer): TDialogLayout;
    // Writes ALayout, one value per column width, creating the key if needed.
    // APPI is the DPI the sizes were measured at and is stored beside them.
    procedure Save(const ALayout: TDialogLayout; APPI: Integer);
    // Message from the last Load or Save, empty when it succeeded. Neither
    // method raises, so this is the only signal of a failure.
    property LastError: string read FLastError;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Win.Registry;

const
  // Registry value names.
  PPIValue = 'PPI';
  PaletteWidthValue = 'PaletteWidth';
  InspectorWidthValue = 'InspectorWidth';
  InspectorTreeHeightValue = 'InspectorTreeHeight';
  MessagesHeightValue = 'MessagesHeight';
  WindowWidthValue = 'WindowWidth';
  WindowHeightValue = 'WindowHeight';
  WindowMaximizedValue = 'WindowMaximized';
  WidthValue = 'Width';
  HeightValue = 'Height';
  ColumnValuePrefix = 'Column';

  // Range in pixels a stored size must lie in; outside it the value is
  // discarded and the caller's default kept.
  MinStoredSize = 16;
  MaxStoredSize = 30000;

  // Range a stored DPI must lie in; outside it the sizes are read at the DPI
  // the caller passed and stay unscaled. The lower bound also keeps the MulDiv
  // divisor above zero.
  MinStoredPPI = 48;
  MaxStoredPPI = 960;

  // Smallest stored column width read back, in pixels; zero is accepted so a
  // column dragged shut stays shut.
  MinStoredColumnWidth = 0;

{ TLayoutStore }

constructor TLayoutStore.Create(const AKey: string);
begin
  inherited Create;
  FKey := AKey;
end;

function TLayoutStore.Load(const ADefaults: TDesignerLayout;
  APPI: Integer): TDesignerLayout;
var
  Registry: TRegistry;
  StoredPPI: Integer;

  function StoredSize(const AName: string; ADefault: Integer): Integer;
  var
    Stored: Integer;
  begin
    Result := ADefault;
    if not Registry.ValueExists(AName) then
      Exit;
    Stored := Registry.ReadInteger(AName);
    if (Stored >= MinStoredSize) and (Stored <= MaxStoredSize) then
      Result := MulDiv(Stored, APPI, StoredPPI);
  end;

  function StoredFlag(const AName: string; ADefault: Boolean): Boolean;
  begin
    if Registry.ValueExists(AName) then
      Result := Registry.ReadBool(AName)
    else
      Result := ADefault;
  end;

begin
  FLastError := '';
  Result := ADefaults;
  try
    Registry := TRegistry.Create(KEY_READ);
    try
      Registry.RootKey := HKEY_CURRENT_USER;
      if not Registry.OpenKeyReadOnly(FKey) then
        Exit;
      StoredPPI := APPI;
      if Registry.ValueExists(PPIValue) then
        StoredPPI := Registry.ReadInteger(PPIValue);
      if (StoredPPI < MinStoredPPI) or (StoredPPI > MaxStoredPPI) then
        StoredPPI := APPI;
      Result.PaletteWidth := StoredSize(PaletteWidthValue,
        ADefaults.PaletteWidth);
      Result.InspectorWidth := StoredSize(InspectorWidthValue,
        ADefaults.InspectorWidth);
      Result.InspectorTreeHeight := StoredSize(InspectorTreeHeightValue,
        ADefaults.InspectorTreeHeight);
      Result.MessagesHeight := StoredSize(MessagesHeightValue,
        ADefaults.MessagesHeight);
      Result.WindowWidth := StoredSize(WindowWidthValue,
        ADefaults.WindowWidth);
      Result.WindowHeight := StoredSize(WindowHeightValue,
        ADefaults.WindowHeight);
      Result.WindowMaximized := StoredFlag(WindowMaximizedValue,
        ADefaults.WindowMaximized);
    finally
      Registry.Free;
    end;
  except
    on E: Exception do
      FLastError := E.Message;
  end;
end;

procedure TLayoutStore.Save(const ALayout: TDesignerLayout; APPI: Integer);
var
  Registry: TRegistry;
begin
  FLastError := '';
  try
    Registry := TRegistry.Create(KEY_READ or KEY_WRITE);
    try
      Registry.RootKey := HKEY_CURRENT_USER;
      if not Registry.OpenKey(FKey, True) then
        FLastError := Format('cannot open HKEY_CURRENT_USER\%s', [FKey])
      else
      begin
        Registry.WriteInteger(PPIValue, APPI);
        Registry.WriteInteger(PaletteWidthValue, ALayout.PaletteWidth);
        Registry.WriteInteger(InspectorWidthValue, ALayout.InspectorWidth);
        Registry.WriteInteger(InspectorTreeHeightValue,
          ALayout.InspectorTreeHeight);
        Registry.WriteInteger(MessagesHeightValue, ALayout.MessagesHeight);
        Registry.WriteInteger(WindowWidthValue, ALayout.WindowWidth);
        Registry.WriteInteger(WindowHeightValue, ALayout.WindowHeight);
        Registry.WriteBool(WindowMaximizedValue, ALayout.WindowMaximized);
      end;
    finally
      Registry.Free;
    end;
  except
    on E: Exception do
      FLastError := E.Message;
  end;
end;

{ TDialogLayoutStore }

constructor TDialogLayoutStore.Create(const AKey: string);
begin
  inherited Create;
  FKey := AKey;
end;

function TDialogLayoutStore.Load(const ADefaults: TDialogLayout;
  APPI: Integer): TDialogLayout;
var
  Registry: TRegistry;
  StoredPPI, I: Integer;

  function StoredSize(const AName: string; AMinimum, ADefault: Integer): Integer;
  var
    Stored: Integer;
  begin
    Result := ADefault;
    if not Registry.ValueExists(AName) then
      Exit;
    Stored := Registry.ReadInteger(AName);
    if (Stored >= AMinimum) and (Stored <= MaxStoredSize) then
      Result := MulDiv(Stored, APPI, StoredPPI);
  end;

begin
  FLastError := '';
  Result := ADefaults;
  // A dynamic array assignment shares storage; the column widths written
  // into the result must not alias the caller's ADefaults.
  Result.ColumnWidths := Copy(ADefaults.ColumnWidths);
  try
    Registry := TRegistry.Create(KEY_READ);
    try
      Registry.RootKey := HKEY_CURRENT_USER;
      if not Registry.OpenKeyReadOnly(FKey) then
        Exit;
      StoredPPI := APPI;
      if Registry.ValueExists(PPIValue) then
        StoredPPI := Registry.ReadInteger(PPIValue);
      if (StoredPPI < MinStoredPPI) or (StoredPPI > MaxStoredPPI) then
        StoredPPI := APPI;
      Result.Width := StoredSize(WidthValue, MinStoredSize, ADefaults.Width);
      Result.Height := StoredSize(HeightValue, MinStoredSize, ADefaults.Height);
      for I := 0 to High(Result.ColumnWidths) do
        Result.ColumnWidths[I] := StoredSize(ColumnValuePrefix + IntToStr(I),
          MinStoredColumnWidth, Result.ColumnWidths[I]);
    finally
      Registry.Free;
    end;
  except
    on E: Exception do
      FLastError := E.Message;
  end;
end;

procedure TDialogLayoutStore.Save(const ALayout: TDialogLayout; APPI: Integer);
var
  Registry: TRegistry;
  I: Integer;
begin
  FLastError := '';
  try
    Registry := TRegistry.Create(KEY_READ or KEY_WRITE);
    try
      Registry.RootKey := HKEY_CURRENT_USER;
      if not Registry.OpenKey(FKey, True) then
        FLastError := Format('cannot open HKEY_CURRENT_USER\%s', [FKey])
      else
      begin
        Registry.WriteInteger(PPIValue, APPI);
        Registry.WriteInteger(WidthValue, ALayout.Width);
        Registry.WriteInteger(HeightValue, ALayout.Height);
        for I := 0 to High(ALayout.ColumnWidths) do
          Registry.WriteInteger(ColumnValuePrefix + IntToStr(I),
            ALayout.ColumnWidths[I]);
      end;
    finally
      Registry.Free;
    end;
  except
    on E: Exception do
      FLastError := E.Message;
  end;
end;

end.
