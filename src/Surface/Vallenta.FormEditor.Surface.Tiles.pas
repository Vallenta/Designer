// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Surface.Tiles;

// Icon tiles for the non-visual components of a form, frame or data module: a
// glyph at the position held in DesignInfo, the component name below it, and
// a dotted adorner on selected tiles. The same routines paint the tile layer
// of a form or frame and the icon surface of a data module. Main thread only.
//
// The caption font is set to fqNonAntialiased because TTileLayer derives its
// window region from the non-key pixels of this drawing. Brush, pen and font
// on ACanvas are saved and restored by PaintTiles, not by TilePaintBounds;
// PaintDesignBackground draws with brushes of its own and changes none of them.

interface

uses
  System.Classes,
  System.Types,
  Vcl.Graphics,
  Vallenta.FormEditor.Palette.Model;

const
  // Tile geometry, in pixels.
  TileGlyphSize = 24;
  TileAdornerMargin = 2;
  TileCaptionGap = 2;

// True for a component drawn as a tile: not nil, not a TControl, and written
// by the root itself. A component whose HasParent is True, such as a grid's
// views and levels or a menu item, is written by a parent component and is not
// tiled, even while no parent is assigned yet.
function IsNonVisual(AComponent: TComponent): Boolean;

// Tile position in surface coordinates, read from the component's DesignInfo:
// the low word holds X, the high word Y.
function TilePosition(AComponent: TComponent): TPoint;
// Writes the tile position into DesignInfo, clamped to 0..High(Word) per axis.
procedure SetTilePosition(AComponent: TComponent; X, Y: Integer);

// The TileGlyphSize square at the tile position, without the adorner margin
// and without the caption.
function TileGlyphBounds(AComponent: TComponent): TRect;

// Hit-test rectangle used by TileAt, and the outline the adorner is drawn on:
// the glyph grown by TileAdornerMargin. The caption is not part of it.
function TileBounds(AComponent: TComponent): TRect;

// Rectangle PaintTiles covers for one tile: the hit-test rectangle united
// with the caption below it, measured on ACanvas. Leaves the tile caption
// font selected in ACanvas.
function TilePaintBounds(ACanvas: TCanvas; AComponent: TComponent): TRect;

// The topmost tile containing APoint, or nil for a miss or a nil ARoot.
// Components are searched from the highest index down, the reverse of the
// order PaintTiles draws them in.
function TileAt(ARoot: TComponent; const APoint: TPoint): TComponent;

// Fills AArea with AColor and a grid dot every AGridSize pixels from
// AArea.TopLeft, in one GDI fill; an AGridSize below 1 draws the fill only.
// Leaves the pens, brushes, fonts and brush origin of ACanvas as they were.
procedure PaintDesignBackground(ACanvas: TCanvas; const AArea: TRect;
  AColor: TColor; AGridSize: Integer);

// Draws a tile for every non-visual component of ARoot, with the adorner on
// those in ASelection. A nil ARoot or AProvider draws nothing.
procedure PaintTiles(ACanvas: TCanvas; ARoot: TComponent;
  const ASelection: array of TComponent; const AProvider: IPaletteIconProvider);

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Math,
  System.UITypes,
  Vcl.Controls;

const
  TileCaptionColor = clWindowText;
  TileAdornerColor = clBlack;
  TileCaptionFontName = 'Segoe UI';
  TileCaptionFontHeight = -11;
  GridDotColor: TColor = clBlack;

type
  TCanvasState = record
    BrushColor, PenColor, FontColor: TColor;
    BrushStyle: TBrushStyle;
    PenStyle: TPenStyle;
    FontName: TFontName;
    FontHeight: Integer;
    FontStyle: TFontStyles;
    FontQuality: TFontQuality;
    procedure Save(ACanvas: TCanvas);
    procedure Restore(ACanvas: TCanvas);
  end;

procedure TCanvasState.Save(ACanvas: TCanvas);
begin
  BrushColor := ACanvas.Brush.Color;
  BrushStyle := ACanvas.Brush.Style;
  PenColor := ACanvas.Pen.Color;
  PenStyle := ACanvas.Pen.Style;
  FontColor := ACanvas.Font.Color;
  FontName := ACanvas.Font.Name;
  FontHeight := ACanvas.Font.Height;
  FontStyle := ACanvas.Font.Style;
  FontQuality := ACanvas.Font.Quality;
end;

procedure TCanvasState.Restore(ACanvas: TCanvas);
begin
  ACanvas.Brush.Color := BrushColor;
  ACanvas.Brush.Style := BrushStyle;
  ACanvas.Pen.Color := PenColor;
  ACanvas.Pen.Style := PenStyle;
  ACanvas.Font.Color := FontColor;
  ACanvas.Font.Name := FontName;
  ACanvas.Font.Height := FontHeight;
  ACanvas.Font.Style := FontStyle;
  ACanvas.Font.Quality := FontQuality;
end;

// The AGridSize square the grid's pattern brush repeats: AColor with the dot
// on its top-left pixel.
function CreateGridTile(AColor: TColor; AGridSize: Integer): Vcl.Graphics.TBitmap;
begin
  Result := Vcl.Graphics.TBitmap.Create;
  try
    Result.PixelFormat := pf24bit;
    Result.SetSize(AGridSize, AGridSize);
    Result.Canvas.Brush.Color := AColor;
    Result.Canvas.FillRect(Rect(0, 0, AGridSize, AGridSize));
    Result.Canvas.Pixels[0, 0] := GridDotColor;
  except
    Result.Free;
    raise;
  end;
end;

procedure PaintDesignBackground(ACanvas: TCanvas; const AArea: TRect;
  AColor: TColor; AGridSize: Integer);

  function Remainder(AValue: Integer): Integer;
  begin
    Result := ((AValue mod AGridSize) + AGridSize) mod AGridSize;
  end;

var
  DC: HDC;
  Tile: Vcl.Graphics.TBitmap;
  Brush: HBRUSH;
  Origin, Previous: TPoint;
begin
  DC := ACanvas.Handle;
  if AGridSize < 1 then
  begin
    Brush := CreateSolidBrush(ColorToRGB(AColor));
    try
      Winapi.Windows.FillRect(DC, AArea, Brush);
    finally
      DeleteObject(Brush);
    end;
    Exit;
  end;
  Tile := CreateGridTile(AColor, AGridSize);
  try
    Brush := CreatePatternBrush(Tile.Handle);
    try
      // The brush origin is in device units, and a WM_PRINTCLIENT caller shifts
      // the logical origin: the dots stay on AArea.TopLeft only through LPtoDP.
      Origin := AArea.TopLeft;
      LPtoDP(DC, Origin, 1);
      if not SetBrushOrgEx(DC, Remainder(Origin.X), Remainder(Origin.Y),
        @Previous) then
        Exit;
      try
        Winapi.Windows.FillRect(DC, AArea, Brush);
      finally
        SetBrushOrgEx(DC, Previous.X, Previous.Y, nil);
      end;
    finally
      DeleteObject(Brush);
    end;
  finally
    Tile.Free;
  end;
end;

function IsNonVisual(AComponent: TComponent): Boolean;
begin
  Result := (AComponent <> nil) and not (AComponent is TControl) and
    not AComponent.HasParent;
end;

function TilePosition(AComponent: TComponent): TPoint;
var
  Info: Integer;
begin
  Info := AComponent.DesignInfo;
  Result := Point(LongRec(Info).Lo, LongRec(Info).Hi);
end;

procedure SetTilePosition(AComponent: TComponent; X, Y: Integer);
var
  Info: Integer;
begin
  Info := 0;
  LongRec(Info).Lo := EnsureRange(X, 0, High(Word));
  LongRec(Info).Hi := EnsureRange(Y, 0, High(Word));
  AComponent.DesignInfo := Info;
end;

function TileGlyphBounds(AComponent: TComponent): TRect;
begin
  Result := TRect.Create(TilePosition(AComponent), TileGlyphSize, TileGlyphSize);
end;

function TileBounds(AComponent: TComponent): TRect;
begin
  Result := TileGlyphBounds(AComponent);
  Result.Inflate(TileAdornerMargin, TileAdornerMargin);
end;

procedure ApplyCaptionFont(ACanvas: TCanvas);
begin
  ACanvas.Font.Name := TileCaptionFontName;
  ACanvas.Font.Height := TileCaptionFontHeight;
  ACanvas.Font.Style := [];
  ACanvas.Font.Quality := fqNonAntialiased;
end;

function TilePaintBounds(ACanvas: TCanvas; AComponent: TComponent): TRect;
var
  Glyph, Caption: TRect;
  Width: Integer;
begin
  Glyph := TileGlyphBounds(AComponent);
  ApplyCaptionFont(ACanvas);
  Width := ACanvas.TextWidth(AComponent.Name);
  Caption := TRect.Create(
    Point(Glyph.Left + (TileGlyphSize - Width) div 2,
      Glyph.Bottom + TileCaptionGap),
    Width, ACanvas.TextHeight(AComponent.Name));
  Result := TRect.Union(TileBounds(AComponent), Caption);
end;

function TileAt(ARoot: TComponent; const APoint: TPoint): TComponent;
var
  I: Integer;
  Candidate: TComponent;
begin
  Result := nil;
  if ARoot = nil then
    Exit;
  for I := ARoot.ComponentCount - 1 downto 0 do
  begin
    Candidate := ARoot.Components[I];
    if IsNonVisual(Candidate) and TileBounds(Candidate).Contains(APoint) then
      Exit(Candidate);
  end;
end;

procedure PaintTile(ACanvas: TCanvas; AComponent: TComponent; ASelected: Boolean;
  const AProvider: IPaletteIconProvider);
var
  Glyph, Adorner: TRect;
  Caption: string;
begin
  Glyph := TileGlyphBounds(AComponent);
  AProvider.DrawClassGlyph(TComponentClass(AComponent.ClassType), ACanvas, Glyph);

  Caption := AComponent.Name;
  ApplyCaptionFont(ACanvas);
  ACanvas.Font.Color := TileCaptionColor;
  ACanvas.Brush.Style := bsClear;
  ACanvas.TextOut(Glyph.Left + (Glyph.Width - ACanvas.TextWidth(Caption)) div 2,
    Glyph.Bottom + TileCaptionGap, Caption);

  if ASelected then
  begin
    Adorner := TileBounds(AComponent);
    ACanvas.Pen.Color := TileAdornerColor;
    ACanvas.Pen.Style := psDot;
    ACanvas.Brush.Style := bsClear;
    ACanvas.Rectangle(Adorner);
  end;
end;

function IsOneOf(AComponent: TComponent; const ASelection: array of TComponent): Boolean;
var
  Selected: TComponent;
begin
  for Selected in ASelection do
    if Selected = AComponent then
      Exit(True);
  Result := False;
end;

procedure PaintTiles(ACanvas: TCanvas; ARoot: TComponent;
  const ASelection: array of TComponent; const AProvider: IPaletteIconProvider);
var
  I: Integer;
  Component: TComponent;
  State: TCanvasState;
begin
  if (ARoot = nil) or (AProvider = nil) then
    Exit;
  State.Save(ACanvas);
  try
    for I := 0 to ARoot.ComponentCount - 1 do
    begin
      Component := ARoot.Components[I];
      if IsNonVisual(Component) then
        PaintTile(ACanvas, Component, IsOneOf(Component, ASelection), AProvider);
    end;
  finally
    State.Restore(ACanvas);
  end;
end;

end.
