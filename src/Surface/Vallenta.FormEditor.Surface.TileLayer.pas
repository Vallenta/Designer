// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Surface.TileLayer;

// Windowed layer holding the icon tiles of one form or frame document. Tiles
// have no z-order against the designed controls, so the layer is a child
// window of the document's host raised above them and a control repainting
// itself cannot erase a tile. Owner is nil, so streaming the host does not
// write the layer itself. Main thread only.
//
// As a child window of the host the layer holds a place in the host's tab
// list; the host must sink it to the end of that list before streaming, or
// sibling TabOrder values shift. The layer takes no mouse input, so
// resolving a click over a tile from the cursor position is left to the
// caller.

interface

uses
  Winapi.Messages,
  System.Classes,
  System.Types,
  Vcl.Controls,
  Vcl.Graphics,
  Vallenta.FormEditor.Palette.Model;

type
  // The tile surface of one form or frame document: a child window shaped
  // like the tiles rendered into its offscreen image.
  TTileLayer = class(TCustomControl)
  private
    FRoot: TComponent;
    FProvider: IPaletteIconProvider;
    FSelection: TArray<TComponent>;
    FImage: TBitmap;
    FArea: TRect;
    function PaintedArea: TRect;
    procedure RenderImage;
    procedure ApplyInkRegion;
  protected
    // Draws the offscreen image the window region was cut from.
    procedure Paint; override;
    // Answers HTTRANSPARENT, so a mouse message over a tile reaches the
    // designed control underneath and the designer resolves the tile itself.
    procedure WMNCHitTest(var Message: TWMNCHitTest); message WM_NCHITTEST;
  public
    // Creates the layer for ARoot with Owner nil; AProvider supplies the
    // glyph of each component. Hidden until Sync runs while ARoot holds at
    // least one non-visual component.
    constructor CreateLayer(ARoot: TComponent;
      const AProvider: IPaletteIconProvider);
    destructor Destroy; override;
    // Redraws the tiles of ARoot, adorning the ones in ASelection, cuts the
    // window region from the drawn pixels and reparents the layer to AHost
    // above the designed controls. Tile positions are read in ASurface's
    // client space and offset into AHost's; a root with no tiles hides it.
    procedure Sync(AHost, ASurface: TWinControl;
      const ASelection: array of TComponent);
  end;

implementation

uses
  Winapi.Windows,
  System.UITypes,
  Vallenta.FormEditor.Surface.Tiles;

const
  // Background of the offscreen image; every pixel not in this color becomes
  // window region.
  InkKeyColor = TColor($00FE00FF);

constructor TTileLayer.CreateLayer(ARoot: TComponent;
  const AProvider: IPaletteIconProvider);
begin
  inherited Create(nil);
  FRoot := ARoot;
  FProvider := AProvider;
  FImage := Vcl.Graphics.TBitmap.Create;
  FImage.PixelFormat := pf32bit;
  ControlStyle := ControlStyle + [csOpaque];
  StyleElements := [];
  Visible := False;
end;

destructor TTileLayer.Destroy;
begin
  FImage.Free;
  inherited Destroy;
end;

function TTileLayer.PaintedArea: TRect;
var
  I: Integer;
  Component: TComponent;
begin
  Result := TRect.Empty;
  for I := 0 to FRoot.ComponentCount - 1 do
  begin
    Component := FRoot.Components[I];
    if not IsNonVisual(Component) then
      Continue;
    if Result.IsEmpty then
      Result := TilePaintBounds(FImage.Canvas, Component)
    else
      Result := TRect.Union(Result,
        TilePaintBounds(FImage.Canvas, Component));
  end;
end;

procedure TTileLayer.RenderImage;
begin
  FImage.SetSize(FArea.Width, FArea.Height);
  FImage.Canvas.Brush.Color := InkKeyColor;
  FImage.Canvas.Brush.Style := bsSolid;
  FImage.Canvas.FillRect(TRect.Create(0, 0, FArea.Width, FArea.Height));
  SetWindowOrgEx(FImage.Canvas.Handle, FArea.Left, FArea.Top, nil);
  try
    PaintTiles(FImage.Canvas, FRoot, FSelection, FProvider);
  finally
    SetWindowOrgEx(FImage.Canvas.Handle, 0, 0, nil);
  end;
end;

procedure TTileLayer.ApplyInkRegion;
var
  Runs: TArray<TRect>;
  Used, X, Y, Start: Integer;
  Row: PByte;
  Key: Cardinal;
  Data: TArray<Byte>;
  Header: PRgnDataHeader;

  function IsKey(AX: Integer): Boolean;
  begin
    Result := (PCardinal(Row + AX * SizeOf(Cardinal))^ and $00FFFFFF) = Key;
  end;

begin
  // ColorToRGB returns $00BBGGRR while a pf32bit scan line reads back as
  // $00RRGGBB; red and blue are swapped before any pixel is compared.
  Key := Cardinal(ColorToRGB(InkKeyColor));
  Key := (Key and $0000FF00) or ((Key and $FF) shl 16) or ((Key shr 16) and $FF);
  Used := 0;
  SetLength(Runs, 256);
  for Y := 0 to FImage.Height - 1 do
  begin
    Row := FImage.ScanLine[Y];
    X := 0;
    while X < FImage.Width do
    begin
      while (X < FImage.Width) and IsKey(X) do
        Inc(X);
      Start := X;
      while (X < FImage.Width) and not IsKey(X) do
        Inc(X);
      if X > Start then
      begin
        if Used = Length(Runs) then
          SetLength(Runs, Used * 2);
        Runs[Used] := TRect.Create(Start, Y, X, Y + 1);
        Inc(Used);
      end;
    end;
  end;
  SetLength(Data, SizeOf(TRgnDataHeader) + Used * SizeOf(TRect));
  Header := PRgnDataHeader(@Data[0]);
  Header.dwSize := SizeOf(TRgnDataHeader);
  Header.iType := RDH_RECTANGLES;
  Header.nCount := Used;
  Header.nRgnSize := Used * SizeOf(TRect);
  Header.rcBound := TRect.Create(0, 0, FImage.Width, FImage.Height);
  if Used > 0 then
    Move(Runs[0], Data[SizeOf(TRgnDataHeader)], Used * SizeOf(TRect));
  // SetWindowRgn transfers the region to the system; deleting it here would
  // free it twice.
  SetWindowRgn(Handle,
    ExtCreateRegion(nil, Length(Data), PRgnData(@Data[0])^), True);
end;

procedure TTileLayer.Sync(AHost, ASurface: TWinControl;
  const ASelection: array of TComponent);
var
  I: Integer;
  Origin: TPoint;
begin
  SetLength(FSelection, Length(ASelection));
  for I := 0 to High(ASelection) do
    FSelection[I] := ASelection[I];
  if (FRoot = nil) or (AHost = nil) or (ASurface = nil) then
    Exit;
  FArea := PaintedArea;
  if FArea.IsEmpty then
  begin
    Visible := False;
    Exit;
  end;
  if ASurface = AHost then
    Origin := Point(0, 0)
  else
    Origin := AHost.ScreenToClient(ASurface.ClientToScreen(Point(0, 0)));
  RenderImage;
  Parent := AHost;
  SetBounds(FArea.Left + Origin.X, FArea.Top + Origin.Y, FArea.Width,
    FArea.Height);
  ApplyInkRegion;
  Visible := True;
  BringToFront;
  Invalidate;
end;

procedure TTileLayer.Paint;
begin
  Canvas.Draw(0, 0, FImage);
end;

procedure TTileLayer.WMNCHitTest(var Message: TWMNCHitTest);
begin
  Message.Result := HTTRANSPARENT;
end;

end.
