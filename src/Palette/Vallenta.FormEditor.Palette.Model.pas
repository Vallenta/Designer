// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Palette.Model;

// Palette content model: groups of items, one item per component class the
// designer can place. TPaletteModel builds the content from
// Vallenta.FormEditor.Core.ComponentRegistry: classes contributed by loaded
// packages, plus the built-in table while BuiltInClassesActive. Glyphs are
// drawn through a replaceable IPaletteIconProvider; nothing is synchronized.
//
// A palette item holds a class reference into a package module, so
// DropDynamicEntries must run before those packages are unloaded.

interface

uses
  System.SysUtils,
  System.Classes,
  System.Types,
  System.Masks,
  System.Generics.Collections,
  Vcl.Controls,
  Vcl.Graphics,
  Vallenta.FormEditor.Core.ComponentRegistry;

type
  // Raised by TPaletteItem.ControlClass for an item whose class does not
  // descend from TControl.
  EPaletteError = class(Exception);

  // One component class offered on the palette. IsNonVisual selects the
  // placement path the surface takes: a control into a parent at bounds, any
  // other component as an icon tile.
  TPaletteItem = class
  private
    FDisplayName: string;
    FComponentClass: TComponentClass;
    FIsDynamic: Boolean;
    function GetIsNonVisual: Boolean;
    function GetControlClass: TControlClass;
  public
    constructor Create(AComponentClass: TComponentClass; AIsDynamic: Boolean);
    // Class name without a leading 'T': the palette caption, and the base of
    // the component name the designer generates.
    property DisplayName: string read FDisplayName;
    // The component class this item offers for placement.
    property ComponentClass: TComponentClass read FComponentClass;
    // ComponentClass as TControlClass; raises EPaletteError for a non-visual
    // item.
    property ControlClass: TControlClass read GetControlClass;
    // True when the class does not descend from TControl.
    property IsNonVisual: Boolean read GetIsNonVisual;
    // True when the class was contributed by a loaded package.
    // DropDynamicEntries removes such an item from a built-in group, whose
    // caption a package page can share.
    property IsDynamic: Boolean read FIsDynamic;
  end;

  // Source of the component glyphs drawn on palette buttons and icon tiles.
  // An implementation may leave brush, pen and font of the canvas changed; a
  // caller that needs them saves and restores them itself.
  IPaletteIconProvider = interface
    ['{6C3A1F84-9E2D-4B77-8B3E-5D41C0A7E912}']
    // Glyph edge length in pixels; glyphs are square.
    function GlyphSize: Integer;
    // Draws the glyph of AItem into ABounds.
    procedure DrawGlyph(AItem: TPaletteItem; ACanvas: TCanvas; const ABounds: TRect);
    // Draws the glyph of a component class into ABounds, for a caller holding
    // a live component rather than a palette item.
    procedure DrawClassGlyph(AComponentClass: TComponentClass; ACanvas: TCanvas;
      const ABounds: TRect);
  end;

  // One palette category. The item objects are freed with the group.
  TPaletteGroup = class
  private
    FCaption: string;
    FIsBuiltIn: Boolean;
    FItems: TObjectList<TPaletteItem>;
  public
    constructor Create(const ACaption: string; AIsBuiltIn: Boolean);
    destructor Destroy; override;
    // Creates an item for AComponentClass, appends it to Items and returns
    // it; the item is freed with the group.
    function Add(AComponentClass: TComponentClass;
      AIsDynamic: Boolean): TPaletteItem;
    // Category caption shown in the palette UI; for a package group, the
    // palette page name the package registered the class under.
    property Caption: string read FCaption;
    // True for a group created from the built-in class table.
    // DropDynamicEntries keeps such a group and removes its dynamic items.
    property IsBuiltIn: Boolean read FIsBuiltIn;
    // Items in the order they were added; TPaletteModel.BuildFromRegistry
    // leaves them sorted by display name, case-insensitively.
    property Items: TObjectList<TPaletteItem> read FItems;
  end;

  // The complete palette content. The group objects are freed with the model.
  TPaletteModel = class
  private
    FGroups: TObjectList<TPaletteGroup>;
    FIconProvider: IPaletteIconProvider;
    function FindGroup(const ACaption: string): TPaletteGroup;
    procedure AddBuiltInGroups;
    procedure AddDynamicEntries;
    procedure SortContent;
  public
    constructor Create;
    destructor Destroy; override;
    // Rebuilds the content from the component registry: the built-in table
    // only while BuiltInClassesActive, then the package classes, merged into
    // a group of the same caption where one exists. Frees every group and
    // item held before the call; the result is sorted by name.
    procedure BuildFromRegistry;
    // Removes every package-contributed item and group. Must run before the
    // packages are unloaded, because an item holds a class reference into the
    // package module.
    procedure DropDynamicEntries;
    // All groups; sorted by caption, case-insensitively, after
    // BuildFromRegistry.
    property Groups: TObjectList<TPaletteGroup> read FGroups;
    // Glyph source; a TGenericGlyphProvider until it is replaced.
    property IconProvider: IPaletteIconProvider read FIconProvider
      write FIconProvider;
  end;

  // Display-name filter for the palette search box. SetTerm compiles one mask
  // that Matches reuses for every item.
  TPaletteFilter = class
  private
    FTerm: string;
    FMask: TMask;
  public
    destructor Destroy; override;
    // Sets the term, trimmed of surrounding whitespace. A term holding
    // neither '*' nor '?' is matched as a substring, anything else as a mask;
    // matching is case-insensitive either way.
    procedure SetTerm(const ATerm: string);
    // True when the display name of AItem passes the term. An empty term
    // passes everything; a term that is not a valid mask passes nothing.
    function Matches(AItem: TPaletteItem): Boolean;
    // The term last set, trimmed; an empty term filters nothing.
    property Term: string read FTerm;
  end;

  // Fallback provider drawing a rounded chip with the first two letters of
  // the display name, the class name without its leading 'T', used where no
  // package bitmap exists for the class.
  TGenericGlyphProvider = class(TInterfacedObject, IPaletteIconProvider)
  public
    // Glyph edge length: a constant 16 pixels, not scaled for the monitor DPI.
    function GlyphSize: Integer;
    // Draws the chip for the component class of AItem.
    procedure DrawGlyph(AItem: TPaletteItem; ACanvas: TCanvas; const ABounds: TRect);
    // Draws the chip for AComponentClass, in a second color pair for a class
    // that does not descend from TControl.
    procedure DrawClassGlyph(AComponentClass: TComponentClass; ACanvas: TCanvas;
      const ABounds: TRect);
  end;

// Class name without a leading 'T'. AClassName is returned unchanged when it
// is one character long or does not start with 'T'.
function StripTypePrefix(const AClassName: string): string;

implementation

uses
  System.Generics.Defaults;

const
  // Geometry and colors of the drawn chip.
  GlyphExtent = 16;
  GlyphFill = TColor($00B08050);
  GlyphEdge = TColor($00703C10);
  GlyphNonVisualFill = TColor($00707070);
  GlyphNonVisualEdge = TColor($00404040);
  GlyphText = clWhite;
  GlyphFontHeight = -9;
  GlyphCornerRadius = 5;

function StripTypePrefix(const AClassName: string): string;
begin
  Result := AClassName;
  if (Length(Result) > 1) and (Result[1] = 'T') then
    Delete(Result, 1, 1);
end;

{ TPaletteItem }

constructor TPaletteItem.Create(AComponentClass: TComponentClass;
  AIsDynamic: Boolean);
begin
  inherited Create;
  FComponentClass := AComponentClass;
  FIsDynamic := AIsDynamic;
  FDisplayName := StripTypePrefix(AComponentClass.ClassName);
end;

function TPaletteItem.GetIsNonVisual: Boolean;
begin
  Result := not FComponentClass.InheritsFrom(TControl);
end;

function TPaletteItem.GetControlClass: TControlClass;
begin
  if GetIsNonVisual then
    raise EPaletteError.CreateFmt(
      '%s has no bounds on the design surface: it is placed as an icon.',
      [FComponentClass.ClassName]);
  Result := TControlClass(FComponentClass);
end;

{ TPaletteGroup }

constructor TPaletteGroup.Create(const ACaption: string; AIsBuiltIn: Boolean);
begin
  inherited Create;
  FCaption := ACaption;
  FIsBuiltIn := AIsBuiltIn;
  FItems := TObjectList<TPaletteItem>.Create(True);
end;

destructor TPaletteGroup.Destroy;
begin
  FItems.Free;
  inherited Destroy;
end;

function TPaletteGroup.Add(AComponentClass: TComponentClass;
  AIsDynamic: Boolean): TPaletteItem;
begin
  Result := TPaletteItem.Create(AComponentClass, AIsDynamic);
  FItems.Add(Result);
end;

{ TPaletteModel }

constructor TPaletteModel.Create;
begin
  inherited Create;
  FGroups := TObjectList<TPaletteGroup>.Create(True);
  FIconProvider := TGenericGlyphProvider.Create;
end;

destructor TPaletteModel.Destroy;
begin
  FIconProvider := nil;
  FGroups.Free;
  inherited Destroy;
end;

procedure TPaletteModel.AddBuiltInGroups;
var
  Kind: TPaletteGroupKind;
  Group: TPaletteGroup;
  I: Integer;
begin
  for Kind := Low(TPaletteGroupKind) to High(TPaletteGroupKind) do
  begin
    Group := nil;
    for I := Low(DesignerClasses) to High(DesignerClasses) do
      if DesignerClasses[I].Group = Kind then
      begin
        if Group = nil then
        begin
          Group := TPaletteGroup.Create(PaletteGroupCaptions[Kind], True);
          FGroups.Add(Group);
        end;
        Group.Add(DesignerClasses[I].ComponentClass, False);
      end;
  end;
end;

procedure TPaletteModel.BuildFromRegistry;
begin
  FGroups.Clear;
  if BuiltInClassesActive then
    AddBuiltInGroups;
  AddDynamicEntries;
  SortContent;
end;

procedure TPaletteModel.SortContent;
var
  I: Integer;
begin
  FGroups.Sort(TComparer<TPaletteGroup>.Construct(
    function(const A, B: TPaletteGroup): Integer
    begin
      Result := AnsiCompareText(A.Caption, B.Caption);
    end));
  for I := 0 to FGroups.Count - 1 do
    FGroups[I].Items.Sort(TComparer<TPaletteItem>.Construct(
      function(const A, B: TPaletteItem): Integer
      begin
        Result := AnsiCompareText(A.DisplayName, B.DisplayName);
      end));
end;

function TPaletteModel.FindGroup(const ACaption: string): TPaletteGroup;
var
  I: Integer;
begin
  for I := 0 to FGroups.Count - 1 do
    if SameText(FGroups[I].Caption, ACaption) then
      Exit(FGroups[I]);
  Result := nil;
end;

procedure TPaletteModel.AddDynamicEntries;
var
  Entries: TArray<TDynamicClassEntry>;
  Group: TPaletteGroup;
  I: Integer;
begin
  Entries := DynamicClasses;
  for I := 0 to High(Entries) do
  begin
    Group := FindGroup(Entries[I].Page);
    if Group = nil then
    begin
      Group := TPaletteGroup.Create(Entries[I].Page, False);
      FGroups.Add(Group);
    end;
    Group.Add(Entries[I].ComponentClass, True);
  end;
end;

procedure TPaletteModel.DropDynamicEntries;
var
  I, J: Integer;
begin
  for I := FGroups.Count - 1 downto 0 do
    if not FGroups[I].IsBuiltIn then
      FGroups.Delete(I)
    else
      for J := FGroups[I].Items.Count - 1 downto 0 do
        if FGroups[I].Items[J].IsDynamic then
          FGroups[I].Items.Delete(J);
end;

{ TPaletteFilter }

destructor TPaletteFilter.Destroy;
begin
  FMask.Free;
  inherited Destroy;
end;

procedure TPaletteFilter.SetTerm(const ATerm: string);
var
  Pattern: string;
begin
  FTerm := Trim(ATerm);
  FreeAndNil(FMask);
  if FTerm = '' then
    Exit;
  Pattern := FTerm;
  if (Pos('*', Pattern) = 0) and (Pos('?', Pattern) = 0) then
    Pattern := '*' + Pattern + '*';
  try
    FMask := TMask.Create(Pattern);
  except
    on EMaskException do
      FMask := nil;
  end;
end;

function TPaletteFilter.Matches(AItem: TPaletteItem): Boolean;
begin
  if FTerm = '' then
    Exit(True);
  Result := (FMask <> nil) and FMask.Matches(AItem.DisplayName);
end;

{ TGenericGlyphProvider }

function TGenericGlyphProvider.GlyphSize: Integer;
begin
  Result := GlyphExtent;
end;

procedure TGenericGlyphProvider.DrawGlyph(AItem: TPaletteItem; ACanvas: TCanvas;
  const ABounds: TRect);
begin
  DrawClassGlyph(AItem.ComponentClass, ACanvas, ABounds);
end;

procedure TGenericGlyphProvider.DrawClassGlyph(AComponentClass: TComponentClass;
  ACanvas: TCanvas; const ABounds: TRect);
var
  Initials: string;
  TextWidth, TextHeight: Integer;
begin
  ACanvas.Brush.Style := bsSolid;
  if AComponentClass.InheritsFrom(TControl) then
  begin
    ACanvas.Brush.Color := GlyphFill;
    ACanvas.Pen.Color := GlyphEdge;
  end
  else
  begin
    ACanvas.Brush.Color := GlyphNonVisualFill;
    ACanvas.Pen.Color := GlyphNonVisualEdge;
  end;
  ACanvas.Pen.Style := psSolid;
  ACanvas.RoundRect(ABounds.Left, ABounds.Top, ABounds.Right, ABounds.Bottom,
    GlyphCornerRadius, GlyphCornerRadius);

  Initials := Copy(StripTypePrefix(AComponentClass.ClassName), 1, 2);
  ACanvas.Font.Name := 'Segoe UI';
  ACanvas.Font.Height := GlyphFontHeight;
  ACanvas.Font.Style := [fsBold];
  ACanvas.Font.Color := GlyphText;
  ACanvas.Brush.Style := bsClear;
  TextWidth := ACanvas.TextWidth(Initials);
  TextHeight := ACanvas.TextHeight(Initials);
  ACanvas.TextOut(ABounds.Left + (ABounds.Width - TextWidth) div 2,
    ABounds.Top + (ABounds.Height - TextHeight) div 2, Initials);
end;

end.
