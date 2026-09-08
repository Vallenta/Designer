// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Palette.Buttons;

// Category button control for the palette, drawing a favourite star on each
// component row and page header. No favourite state is stored here:
// OnItemKind and OnGroupFavourite are queried while painting, OnItemKind also
// on a star press, and a star press raises OnToggleItem or OnToggleGroup.
// Main thread only, as for every VCL control.

interface

uses
  Winapi.Messages,
  System.Classes,
  System.Types,
  System.UITypes,
  Vcl.Controls,
  Vcl.Graphics,
  Vcl.CategoryButtons;

type
  // Favourite state of a component row or page header; fkByGroup applies to
  // rows only.
  TFavouriteKind = (
    fkNone,     // not a favourite
    fkOwn,      // the component class or the page itself is marked
    fkByGroup); // only its page is marked; its star raises no toggle

  // Queried for each component row while it is drawn and when its star is
  // clicked. AKind arrives as fkNone.
  TPaletteItemKindEvent = procedure(Sender: TObject;
    const AButton: TButtonItem; var AKind: TFavouriteKind) of object;

  // Queried for each visible page header while the control paints.
  // AFavourite arrives as False.
  TPaletteGroupKindEvent = procedure(Sender: TObject;
    const ACategory: TButtonCategory; var AFavourite: Boolean) of object;

  // Category buttons with a favourite star at the right edge of each
  // component row and page header. A star is drawn only for a favourite or
  // for the row or header under the mouse.
  TPaletteButtons = class(TCategoryButtons)
  private
    FHotItem: TButtonItem;
    FHotGroup: TButtonCategory;
    FConsumedPress: Boolean;
    FOnItemKind: TPaletteItemKindEvent;
    FOnGroupFavourite: TPaletteGroupKindEvent;
    FOnToggleItem: TCatButtonEvent;
    FOnToggleGroup: TCatButtonCategoryEvent;
    function StarRect(const ABounds: TRect): TRect;
    function ItemKind(const AButton: TButtonItem): TFavouriteKind;
    function GroupIsFavourite(const ACategory: TButtonCategory): Boolean;
    function ItemStarAt(X, Y: Integer): TButtonItem;
    function GroupStarAt(X, Y: Integer): TButtonCategory;
    procedure DrawItemStar(ACanvas: TCanvas; const ABounds: TRect;
      AButton: TButtonItem);
    procedure DrawGroupStar(ACanvas: TCanvas; const ABounds: TRect;
      ACategory: TButtonCategory);
    procedure DrawStar(ACanvas: TCanvas; const ABounds: TRect;
      AKind: TFavouriteKind; AHot: Boolean);
    procedure TrackHot(X, Y: Integer);
    procedure RepaintStar(AItem: TButtonItem; ACategory: TButtonCategory);
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
  protected
    // Draws the inherited button, then the favourite star of that row.
    procedure DrawButton(const Button: TButtonItem; Canvas: TCanvas;
      Rect: TRect; State: TButtonDrawState); override;
    // Draws the header stars after the inherited paint; TCategoryButtons has
    // no per-header draw hook.
    procedure Paint; override;
    // A left press on a star is consumed here and does not reach the
    // inherited handler, so the row is neither selected nor armed.
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    // Discards the release that follows a press consumed by a star; the
    // inherited handler collapses a page on a release inside its header when
    // no press was recorded.
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    // Tracks the row or header under the mouse, where a star is drawn even
    // when it is not a favourite.
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
  public
    constructor Create(AOwner: TComponent); override;
    // Clears the remembered hot row and header. Must run before Categories is
    // cleared; both fields point at objects that Clear frees.
    procedure ForgetHot;
    // Supplies the favourite kind of a component row; when unassigned no row
    // is a favourite.
    property OnItemKind: TPaletteItemKindEvent read FOnItemKind
      write FOnItemKind;
    // Supplies whether a page is marked; when unassigned no page is.
    property OnGroupFavourite: TPaletteGroupKindEvent read FOnGroupFavourite
      write FOnGroupFavourite;
    // Raised when a component row's star is clicked, except on an fkByGroup
    // row.
    property OnToggleItem: TCatButtonEvent read FOnToggleItem
      write FOnToggleItem;
    // Raised when a page header's star is clicked.
    property OnToggleGroup: TCatButtonCategoryEvent read FOnToggleGroup
      write FOnToggleGroup;
  end;

implementation

uses
  Winapi.Windows,
  System.Math;

const
  // Star geometry and colours; StarExtent and StarMargin are pixels.
  StarExtent = 13;
  StarMargin = 4;
  StarPointCount = 5;
  // Radius of the inner vertices as a fraction of the outer radius.
  StarWaist = 0.42;
  // BGR order, as in every TColor literal.
  StarFill = TColor($0000B9FF);
  StarEdge = TColor($000078B4);
  StarDimmedFill = TColor($00A0C8D7);
  StarDimmedEdge = TColor($008296A0);
  StarOutlineEdge = TColor($00828282);

constructor TPaletteButtons.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  // Header stars paint after the inherited paint and the hot star changes on
  // every mouse move; without double buffering the control flickers.
  DoubleBuffered := True;
end;

procedure TPaletteButtons.ForgetHot;
begin
  FHotItem := nil;
  FHotGroup := nil;
end;

function TPaletteButtons.StarRect(const ABounds: TRect): TRect;
begin
  Result := TRect.Create(
    TPoint.Create(ABounds.Right - StarMargin - StarExtent,
    ABounds.Top + (ABounds.Height - StarExtent) div 2), StarExtent, StarExtent);
end;

function TPaletteButtons.ItemKind(const AButton: TButtonItem): TFavouriteKind;
begin
  Result := fkNone;
  if Assigned(FOnItemKind) then
    FOnItemKind(Self, AButton, Result);
end;

function TPaletteButtons.GroupIsFavourite(
  const ACategory: TButtonCategory): Boolean;
begin
  Result := False;
  if Assigned(FOnGroupFavourite) then
    FOnGroupFavourite(Self, ACategory, Result);
end;

// Brush and pen are restored because the inherited painter draws the
// following buttons on the same canvas.
procedure TPaletteButtons.DrawStar(ACanvas: TCanvas; const ABounds: TRect;
  AKind: TFavouriteKind; AHot: Boolean);
var
  Points: array [0 .. 2 * StarPointCount - 1] of TPoint;
  SavedBrushColor, SavedPenColor: TColor;
  SavedBrushStyle: TBrushStyle;
  SavedPenStyle: TPenStyle;
  CentreX, CentreY, I: Integer;
  Outer, Radius, Angle: Double;
begin
  if (AKind = fkNone) and not AHot then
    Exit;

  CentreX := (ABounds.Left + ABounds.Right) div 2;
  CentreY := (ABounds.Top + ABounds.Bottom) div 2;
  Outer := Min(ABounds.Width, ABounds.Height) / 2;
  for I := 0 to High(Points) do
  begin
    if Odd(I) then
      Radius := Outer * StarWaist
    else
      Radius := Outer;
    Angle := -Pi / 2 + I * Pi / StarPointCount;
    Points[I] := Point(Round(CentreX + Radius * Cos(Angle)),
      Round(CentreY + Radius * Sin(Angle)));
  end;

  SavedBrushColor := ACanvas.Brush.Color;
  SavedBrushStyle := ACanvas.Brush.Style;
  SavedPenColor := ACanvas.Pen.Color;
  SavedPenStyle := ACanvas.Pen.Style;
  try
    ACanvas.Pen.Style := psSolid;
    case AKind of
      fkOwn:
        begin
          ACanvas.Brush.Style := bsSolid;
          ACanvas.Brush.Color := StarFill;
          ACanvas.Pen.Color := StarEdge;
        end;
      fkByGroup:
        begin
          ACanvas.Brush.Style := bsSolid;
          ACanvas.Brush.Color := StarDimmedFill;
          ACanvas.Pen.Color := StarDimmedEdge;
        end;
    else
      ACanvas.Brush.Style := bsClear;
      ACanvas.Pen.Color := StarOutlineEdge;
    end;
    ACanvas.Polygon(Points);
  finally
    ACanvas.Brush.Color := SavedBrushColor;
    ACanvas.Brush.Style := SavedBrushStyle;
    ACanvas.Pen.Color := SavedPenColor;
    ACanvas.Pen.Style := SavedPenStyle;
  end;
end;

procedure TPaletteButtons.DrawItemStar(ACanvas: TCanvas; const ABounds: TRect;
  AButton: TButtonItem);
begin
  DrawStar(ACanvas, StarRect(ABounds), ItemKind(AButton), AButton = FHotItem);
end;

procedure TPaletteButtons.DrawGroupStar(ACanvas: TCanvas; const ABounds: TRect;
  ACategory: TButtonCategory);
const
  HeaderKind: array [Boolean] of TFavouriteKind = (fkNone, fkOwn);
begin
  DrawStar(ACanvas, StarRect(ABounds), HeaderKind[GroupIsFavourite(ACategory)],
    ACategory = FHotGroup);
end;

procedure TPaletteButtons.DrawButton(const Button: TButtonItem;
  Canvas: TCanvas; Rect: TRect; State: TButtonDrawState);
begin
  inherited DrawButton(Button, Canvas, Rect, State);
  DrawItemStar(Canvas, Rect, Button);
end;

procedure TPaletteButtons.Paint;
var
  Header: TRect;
  I: Integer;
begin
  inherited Paint;
  for I := 0 to Categories.Count - 1 do
  begin
    Header := Categories[I].GetButtonRect(True);
    if (Header.Bottom > 0) and (Header.Top < ClientHeight) then
      DrawGroupStar(Canvas, Header, Categories[I]);
  end;
end;

function TPaletteButtons.ItemStarAt(X, Y: Integer): TButtonItem;
var
  Item: TButtonItem;
begin
  Result := nil;
  Item := GetButtonAt(X, Y);
  if (Item <> nil) and StarRect(Item.Bounds).Contains(Point(X, Y)) then
    Result := Item;
end;

function TPaletteButtons.GroupStarAt(X, Y: Integer): TButtonCategory;
var
  Category: TButtonCategory;
begin
  Result := nil;
  Category := GetCategoryAt(X, Y);
  if (Category <> nil) and
    StarRect(Category.GetButtonRect(True)).Contains(Point(X, Y)) then
    Result := Category;
end;

// FConsumedPress is set before the toggle event runs, so an exception in the
// handler still suppresses the matching release.
procedure TPaletteButtons.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  Item: TButtonItem;
  Category: TButtonCategory;
begin
  FConsumedPress := False;
  if Button = mbLeft then
  begin
    Item := ItemStarAt(X, Y);
    if Item <> nil then
    begin
      FConsumedPress := True;
      if (ItemKind(Item) <> fkByGroup) and Assigned(FOnToggleItem) then
        FOnToggleItem(Self, Item);
      Invalidate;
      Exit;
    end;
    Category := GroupStarAt(X, Y);
    if Category <> nil then
    begin
      FConsumedPress := True;
      if Assigned(FOnToggleGroup) then
        FOnToggleGroup(Self, Category);
      Invalidate;
      Exit;
    end;
  end;
  inherited MouseDown(Button, Shift, X, Y);
end;

procedure TPaletteButtons.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  if FConsumedPress then
  begin
    FConsumedPress := False;
    Exit;
  end;
  inherited MouseUp(Button, Shift, X, Y);
end;

procedure TPaletteButtons.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  TrackHot(X, Y);
end;

procedure TPaletteButtons.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  TrackHot(-1, -1);
end;

procedure TPaletteButtons.TrackHot(X, Y: Integer);
var
  Item: TButtonItem;
  Category: TButtonCategory;
begin
  Item := GetButtonAt(X, Y);
  Category := nil;
  if Item = nil then
  begin
    Category := GetCategoryAt(X, Y);
    // GetCategoryAt also returns a category for points below its header row,
    // where no star is drawn.
    if (Category <> nil) and
      not Category.GetButtonRect(True).Contains(Point(X, Y)) then
      Category := nil;
  end;
  if (Item = FHotItem) and (Category = FHotGroup) then
    Exit;
  RepaintStar(FHotItem, FHotGroup);
  FHotItem := Item;
  FHotGroup := Category;
  RepaintStar(FHotItem, FHotGroup);
end;

procedure TPaletteButtons.RepaintStar(AItem: TButtonItem;
  ACategory: TButtonCategory);
var
  R: TRect;
begin
  if not HandleAllocated then
    Exit;
  if AItem <> nil then
    R := AItem.Bounds
  else if ACategory <> nil then
    R := ACategory.GetButtonRect(True)
  else
    Exit;
  Winapi.Windows.InvalidateRect(Handle, @R, True);
end;

end.
