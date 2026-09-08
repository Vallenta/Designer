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
// on ACanvas are saved and restored by PaintDesignBackground and PaintTiles,
// not by TilePaintBounds.

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

// True for a component drawn as a tile: not nil, not a TControl, and without
// a parent component. A component whose GetParentComponent returns a parent,
// such as a grid's views and levels, is not tiled.
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

// Fills AArea with AColor and sets a grid dot every AGridSize pixels; an
// AGridSize below 1 draws the fill only.
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

procedure PaintDesignBackground(ACanvas: TCanvas; const AArea: TRect;
  AColor: TColor; AGridSize: Integer);
var
  X, Y, DotColor: Integer;
  State: TCanvasState;
begin
  State.Save(ACanvas);
  try
    ACanvas.Brush.Color := AColor;
    ACanvas.Brush.Style := bsSolid;
    ACanvas.FillRect(AArea);
    if AGridSize < 1 then
      Exit;
    DotColor := ColorToRGB(GridDotColor);
    Y := AArea.Top;
    while Y < AArea.Bottom do
    begin
      X := AArea.Left;
      while X < AArea.Right do
      begin
        SetPixelV(ACanvas.Handle, X, Y, DotColor);
        Inc(X, AGridSize);
      end;
      Inc(Y, AGridSize);
    end;
  finally
    State.Restore(ACanvas);
  end;
end;

function IsNonVisual(AComponent: TComponent): Boolean;
begin
  Result := (AComponent <> nil) and not (AComponent is TControl) and
    (AComponent.GetParentComponent = nil);
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
