// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.Tiles;

// Covers IsNonVisual, TileAt and PaintDesignBackground of
// Vallenta.FormEditor.Surface.Tiles: which components of a root are drawn as
// tiles, which tile a point hits, and where the grid dots land. A TControl is
// not tiled, nor is a component whose HasParent is True, which a parent
// component writes; every other component owned by the root is.

interface

uses
  DUnitX.TestFramework;

type
  // Tile eligibility of root-owned components, tile hit testing, and the grid
  // of the design background.
  [TestFixture]
  TTileTests = class
  public
    [Test]
    procedure APlainNonVisualComponentStandsAsATile;
    [Test]
    procedure AControlStandsAsNoTile;
    [Test]
    procedure ASubComponentAParentPresentsStandsAsNoTile;
    [Test]
    procedure TileHitTestingPassesOverAParentedSubComponent;
    [Test]
    procedure AComponentAParentWritesStandsAsNoTileBeforeItHasOne;
    [Test]
    procedure TheGridPutsADotEveryPitchFromTheAreaCorner;
    [Test]
    procedure TheGridKeepsToTheLogicalAreaUnderAShiftedWindowOrigin;
    [Test]
    procedure TheGridKeepsToTheLogicalAreaUnderAShiftedViewportOrigin;
    [Test]
    procedure AGridSizeBelowOneFillsWithoutDots;
    [Test]
    procedure TheBackgroundLeavesTheCanvasBrushAndBrushOriginAsTheyWere;
  end;

implementation

uses
  Winapi.Windows,
  System.Classes,
  System.SysUtils,
  System.Types,
  System.UITypes,
  Vcl.Controls,
  Vcl.Graphics,
  Vallenta.FormEditor.Surface.Tiles;

const
  // Grid geometry and colors of the background cases; Sentinel marks the
  // pixels outside the painted area.
  GridPitch = 8;
  SurfaceColor = clBtnFace;
  Sentinel = clLime;
  CanvasWidth = 64;
  CanvasHeight = 48;

type
  // Test double for a grid view or level: a component that returns a parent
  // from GetParentComponent, as TcxGridDBTableView and TcxGridLevel do under
  // a TcxGrid.
  TSubComponent = class(TComponent)
  private
    FParentComponent: TComponent;
  public
    function GetParentComponent: TComponent; override;
    function HasParent: Boolean; override;
    procedure SetParentComponent(AParent: TComponent); override;
  end;

  // Test double for a placeholder menu item held by the menu designer: it
  // reports a parent through HasParent before any parent is assigned.
  TParentWrittenComponent = class(TComponent)
  public
    function HasParent: Boolean; override;
  end;

function TSubComponent.GetParentComponent: TComponent;
begin
  Result := FParentComponent;
end;

function TSubComponent.HasParent: Boolean;
begin
  Result := FParentComponent <> nil;
end;

procedure TSubComponent.SetParentComponent(AParent: TComponent);
begin
  FParentComponent := AParent;
end;

function TParentWrittenComponent.HasParent: Boolean;
begin
  Result := True;
end;

// A CanvasWidth x CanvasHeight 24-bit bitmap filled with Sentinel.
function SentinelBitmap: Vcl.Graphics.TBitmap;
begin
  Result := Vcl.Graphics.TBitmap.Create;
  try
    Result.PixelFormat := pf24bit;
    Result.SetSize(CanvasWidth, CanvasHeight);
    Result.Canvas.Brush.Color := Sentinel;
    Result.Canvas.FillRect(Rect(0, 0, CanvasWidth, CanvasHeight));
  except
    Result.Free;
    raise;
  end;
end;

function Remainder(AValue, ADivisor: Integer): Integer;
begin
  Result := ((AValue mod ADivisor) + ADivisor) mod ADivisor;
end;

// Asserts every pixel of ABitmap, read with the identity mapping: Sentinel
// outside AArea, and inside it a black dot on each AGridSize step from ADot
// and SurfaceColor elsewhere. An AGridSize below 1 expects no dots.
procedure AssertGrid(ABitmap: Vcl.Graphics.TBitmap; const AArea: TRect;
  const ADot: TPoint; AGridSize: Integer; const ACase: string);
var
  X, Y: Integer;
  Expected, Actual: TColor;
begin
  for Y := 0 to ABitmap.Height - 1 do
    for X := 0 to ABitmap.Width - 1 do
    begin
      if not AArea.Contains(Point(X, Y)) then
        Expected := ColorToRGB(Sentinel)
      else if (AGridSize > 0) and (Remainder(X - ADot.X, AGridSize) = 0) and
        (Remainder(Y - ADot.Y, AGridSize) = 0) then
        Expected := ColorToRGB(clBlack)
      else
        Expected := ColorToRGB(SurfaceColor);
      Actual := ABitmap.Canvas.Pixels[X, Y];
      if Actual <> Expected then
        Assert.Fail(Format('%s: pixel %d,%d is %.6x where %.6x was expected',
          [ACase, X, Y, Actual, Expected]));
    end;
end;

{ TTileTests }

procedure TTileTests.APlainNonVisualComponentStandsAsATile;
var
  Root: TComponent;
begin
  Root := TComponent.Create(nil);
  try
    Assert.IsTrue(IsNonVisual(TComponent.Create(Root)),
      'a root-owned component nothing presents was denied its tile');
  finally
    Root.Free;
  end;
end;

procedure TTileTests.AControlStandsAsNoTile;
var
  Root: TComponent;
begin
  Root := TComponent.Create(nil);
  try
    Assert.IsFalse(IsNonVisual(TControl.Create(Root)),
      'a control got a tile beside its own window');
  finally
    Root.Free;
  end;
end;

procedure TTileTests.ASubComponentAParentPresentsStandsAsNoTile;
var
  Root, Grid: TComponent;
  View, Level, SubLevel: TSubComponent;
begin
  Root := TComponent.Create(nil);
  try
    Grid := TControl.Create(Root);
    View := TSubComponent.Create(Root);
    View.SetParentComponent(Grid);
    Level := TSubComponent.Create(Root);
    Level.SetParentComponent(Grid);
    SubLevel := TSubComponent.Create(Root);
    SubLevel.SetParentComponent(Level);
    Assert.IsFalse(IsNonVisual(View),
      'a view its grid presents got a tile of its own');
    Assert.IsFalse(IsNonVisual(Level),
      'a level its grid presents got a tile of its own');
    Assert.IsFalse(IsNonVisual(SubLevel),
      'a level nested below another level got a tile of its own');
  finally
    Root.Free;
  end;
end;

procedure TTileTests.TileHitTestingPassesOverAParentedSubComponent;
var
  Root, Timer, Grid: TComponent;
  View: TSubComponent;
begin
  Root := TComponent.Create(nil);
  try
    Timer := TComponent.Create(Root);
    Grid := TControl.Create(Root);
    View := TSubComponent.Create(Root);
    View.SetParentComponent(Grid);
    // Timer and View keep DesignInfo at 0, so both tile rectangles contain
    // (5, 5), and TileAt reaches View first, searching by descending index.
    Assert.AreSame(Timer, TileAt(Root, Point(5, 5)),
      'the hit went past the tile to a sub-component that has none');
    Assert.IsNull(TileAt(Root, Point(500, 500)),
      'empty surface hit something');
  finally
    Root.Free;
  end;
end;

procedure TTileTests.AComponentAParentWritesStandsAsNoTileBeforeItHasOne;
var
  Root: TComponent;
  Placeholder: TParentWrittenComponent;
begin
  Root := TComponent.Create(nil);
  try
    Placeholder := TParentWrittenComponent.Create(Root);
    Assert.IsNull(Placeholder.GetParentComponent,
      'the double has a parent component');
    Assert.IsFalse(IsNonVisual(Placeholder),
      'a component its parent writes got a tile while no parent is assigned');
  finally
    Root.Free;
  end;
end;

procedure TTileTests.TheGridPutsADotEveryPitchFromTheAreaCorner;
var
  Bitmap: Vcl.Graphics.TBitmap;
  Area: TRect;
begin
  Bitmap := SentinelBitmap;
  try
    Area := Rect(3, 5, CanvasWidth - 5, CanvasHeight - 3);
    PaintDesignBackground(Bitmap.Canvas, Area, SurfaceColor, GridPitch);
    AssertGrid(Bitmap, Area, Area.TopLeft, GridPitch, 'an area off the origin');
  finally
    Bitmap.Free;
  end;
end;

// Reproduces WM_PRINTCLIENT from a child at 21, 14: the parent paints its
// whole client area with the window origin moved to the child's position.
// The offsets differ modulo the pitch, so an exchanged axis is caught too.
procedure TTileTests.TheGridKeepsToTheLogicalAreaUnderAShiftedWindowOrigin;
var
  Bitmap: Vcl.Graphics.TBitmap;
begin
  Bitmap := SentinelBitmap;
  try
    SetWindowOrgEx(Bitmap.Canvas.Handle, 21, 14, nil);
    PaintDesignBackground(Bitmap.Canvas, Rect(0, 0, 200, 200), SurfaceColor,
      GridPitch);
    SetWindowOrgEx(Bitmap.Canvas.Handle, 0, 0, nil);
    AssertGrid(Bitmap, Rect(0, 0, CanvasWidth, CanvasHeight), Point(-21, -14),
      GridPitch, 'a window origin at 21, 14');
  finally
    Bitmap.Free;
  end;
end;

procedure TTileTests.TheGridKeepsToTheLogicalAreaUnderAShiftedViewportOrigin;
var
  Bitmap: Vcl.Graphics.TBitmap;
begin
  Bitmap := SentinelBitmap;
  try
    SetViewportOrgEx(Bitmap.Canvas.Handle, -21, -14, nil);
    PaintDesignBackground(Bitmap.Canvas, Rect(0, 0, 200, 200), SurfaceColor,
      GridPitch);
    SetViewportOrgEx(Bitmap.Canvas.Handle, 0, 0, nil);
    AssertGrid(Bitmap, Rect(0, 0, CanvasWidth, CanvasHeight), Point(-21, -14),
      GridPitch, 'a viewport origin at -21, -14');
  finally
    Bitmap.Free;
  end;
end;

procedure TTileTests.AGridSizeBelowOneFillsWithoutDots;
var
  Bitmap: Vcl.Graphics.TBitmap;
  Area: TRect;
begin
  Bitmap := SentinelBitmap;
  try
    Area := Rect(3, 5, CanvasWidth - 5, CanvasHeight - 3);
    PaintDesignBackground(Bitmap.Canvas, Area, SurfaceColor, 0);
    AssertGrid(Bitmap, Area, Area.TopLeft, 0, 'a grid size of 0');
  finally
    Bitmap.Free;
  end;
end;

procedure TTileTests.TheBackgroundLeavesTheCanvasBrushAndBrushOriginAsTheyWere;
var
  Bitmap: Vcl.Graphics.TBitmap;
  Origin: TPoint;
begin
  Bitmap := SentinelBitmap;
  try
    Bitmap.Canvas.Brush.Color := clRed;
    Bitmap.Canvas.Brush.Style := bsDiagCross;
    SetBrushOrgEx(Bitmap.Canvas.Handle, 3, 2, nil);
    PaintDesignBackground(Bitmap.Canvas, Rect(1, 1, 40, 30), SurfaceColor,
      GridPitch);
    GetBrushOrgEx(Bitmap.Canvas.Handle, Origin);
    Assert.AreEqual(3, Origin.X, 'brush origin X changed');
    Assert.AreEqual(2, Origin.Y, 'brush origin Y changed');
    Assert.AreEqual(TColor(clRed), Bitmap.Canvas.Brush.Color,
      'canvas brush color changed');
    Assert.AreEqual<TBrushStyle>(bsDiagCross, Bitmap.Canvas.Brush.Style,
      'canvas brush style changed');
  finally
    Bitmap.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TTileTests);

end.
