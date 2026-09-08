// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Surface.IconCanvas;

// Design surface for a data module document: paints an icon tile for every
// non-visual component of the root and forwards mouse and keyboard input to
// the attached TFormDesigner. A data module has no window, so input never
// reaches the designer through IsDesignMsg. Main thread only.

interface

uses
  Winapi.Messages,
  System.Classes,
  System.Types,
  System.UITypes,
  Vcl.Controls,
  Vallenta.FormEditor.Surface.FormDesigner;

type
  // Icon tile canvas for one data module document; focusable, so arrow keys
  // and the editing shortcuts reach the designer.
  TIconSurface = class(TCustomControl)
  private
    FDesigner: TFormDesigner;
    FDragPending: Boolean;
    FDragging: Boolean;
    FAnchor: TPoint;
    FOrigin: TPoint;
    FDragged: TComponent;
    function DraggedTo(X, Y: Integer): TPoint;
    procedure AbandonDrag;
    procedure UpdateCursor;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    // Without DLGC_WANTARROWS the parent form's dialog-key handling moves
    // focus on an arrow key instead of KeyDown nudging the selection.
    procedure WMGetDlgCode(var Message: TWMGetDlgCode); message WM_GETDLGCODE;
  public
    constructor Create(AOwner: TComponent); override;
    // Attaches the designer whose document is painted here and registers this
    // control as its SurfaceControl; nil detaches. Any drag is abandoned.
    procedure Attach(ADesigner: TFormDesigner);
    // Positions the canvas at SurfaceMargin in its parent and sizes it to the
    // data module's DesignSize, at least 64 px per axis. DesignSize is read
    // only and never written back.
    procedure SizeFor(ADataModule: TDataModule);
  end;

implementation

uses
  Winapi.Windows,
  System.Math,
  Vcl.Graphics,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Surface.Tiles,
  Vallenta.FormEditor.Surface.Undo;

const
  // Design surface metrics in pixels, and its background colour.
  MinimumCanvasExtent = 64;
  SurfaceColor = clWindow;
  DragThreshold = 3;

constructor TIconSurface.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  // A VCL style paints the client area while seClient is in StyleElements,
  // overriding Color.
  StyleElements := [];
  Color := SurfaceColor;
  TabStop := True;
  Width := MinimumCanvasExtent;
  Height := MinimumCanvasExtent;
end;

procedure TIconSurface.Attach(ADesigner: TFormDesigner);
begin
  AbandonDrag;
  FDesigner := ADesigner;
  if FDesigner <> nil then
    FDesigner.SurfaceControl := Self;
  Invalidate;
end;

procedure TIconSurface.SizeFor(ADataModule: TDataModule);
begin
  SetBounds(SurfaceMargin, SurfaceMargin,
    Max(ADataModule.DesignSize.X, MinimumCanvasExtent),
    Max(ADataModule.DesignSize.Y, MinimumCanvasExtent));
end;

procedure TIconSurface.WMGetDlgCode(var Message: TWMGetDlgCode);
begin
  inherited;
  Message.Result := Message.Result or DLGC_WANTARROWS or DLGC_WANTCHARS;
end;

procedure TIconSurface.Paint;
var
  GridSize: Integer;
begin
  GridSize := 0;
  if FDesigner <> nil then
    GridSize := FDesigner.GridSize;
  PaintDesignBackground(Canvas, ClientRect, Color, GridSize);
  if FDesigner <> nil then
    PaintTiles(Canvas, FDesigner.Root, FDesigner.SelectedInstances,
      FDesigner.IconProvider);
end;

procedure TIconSurface.AbandonDrag;
begin
  FDragPending := False;
  FDragging := False;
  FDragged := nil;
  if FDesigner <> nil then
    FDesigner.ExternalGesture := False;
end;

procedure TIconSurface.UpdateCursor;
var
  Wanted: TCursor;
begin
  if (FDesigner <> nil) and (FDesigner.ArmedItem <> nil) then
    Wanted := crCross
  else
    Wanted := crDefault;
  if Cursor <> Wanted then
    Cursor := Wanted;
end;

function TIconSurface.DraggedTo(X, Y: Integer): TPoint;
begin
  Result := Point(FDesigner.Snap(FOrigin.X + X - FAnchor.X),
    FDesigner.Snap(FOrigin.Y + Y - FAnchor.Y));
end;

procedure TIconSurface.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  Target: TComponent;
begin
  inherited MouseDown(Button, Shift, X, Y);
  if FDesigner = nil then
    Exit;
  if CanFocus and not Focused then
    SetFocus;
  if Button = mbRight then
  begin
    if FDesigner.ArmedItem <> nil then
      Exit;
    Target := TileAt(FDesigner.Root, Point(X, Y));
    if not FDesigner.IsSelected(Target) then
      FDesigner.SelectComponent(Target);
    Exit;
  end;
  if Button <> mbLeft then
    Exit;
  if FDesigner.ArmedItem <> nil then
  begin
    FDesigner.PlaceArmedAt(X, Y);
    UpdateCursor;
    Exit;
  end;
  if ssDouble in Shift then
  begin
    FDesigner.RunDefaultComponentEditor;
    Exit;
  end;
  Target := TileAt(FDesigner.Root, Point(X, Y));
  if ssShift in Shift then
  begin
    FDesigner.ToggleSelection(Target);
    Exit;
  end;
  FDesigner.SelectComponent(Target);
  if Target = nil then
    Exit;
  FDragged := Target;
  FDragPending := True;
  // ExternalGesture keeps GestureInFlight true for a drag the designer does
  // not run itself, blocking undo, redo and snapshot capture until MouseUp.
  FDesigner.ExternalGesture := True;
  FAnchor := Point(X, Y);
  FOrigin := TilePosition(Target);
end;

procedure TIconSurface.MouseMove(Shift: TShiftState; X, Y: Integer);
var
  Position: TPoint;
begin
  inherited MouseMove(Shift, X, Y);
  UpdateCursor;
  if not FDragPending then
    Exit;
  if not FDragging then
  begin
    if (Abs(X - FAnchor.X) < DragThreshold) and
       (Abs(Y - FAnchor.Y) < DragThreshold) then
      Exit;
    FDragging := True;
  end;
  // SetTilePosition rather than the designer's MoveTile: a drag in progress
  // must not mark the document modified.
  Position := DraggedTo(X, Y);
  SetTilePosition(FDragged, Position.X, Position.Y);
  Invalidate;
end;

procedure TIconSurface.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  Position, Origin: TPoint;
  Dropped: TComponent;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if Button = mbRight then
  begin
    AbandonDrag;
    if FDesigner = nil then
      Exit;
    if FDesigner.ArmedItem <> nil then
    begin
      FDesigner.DisarmCreation;
      UpdateCursor;
    end
    else
      FDesigner.RequestContextMenu;
    Exit;
  end;
  if (Button <> mbLeft) or not FDragging then
  begin
    AbandonDrag;
    Exit;
  end;
  Position := DraggedTo(X, Y);
  Origin := FOrigin;
  Dropped := FDragged;
  AbandonDrag;
  if Position = Origin then
    Exit;
  // PushUndo snapshots the document as it stands, so the tile is restored to
  // its pre-drag position before the entry is recorded.
  SetTilePosition(Dropped, Origin.X, Origin.Y);
  FDesigner.PushUndo(uoMove);
  FDesigner.MoveTile(Dropped, Position.X, Position.Y);
end;

procedure TIconSurface.KeyDown(var Key: Word; Shift: TShiftState);
begin
  inherited KeyDown(Key, Shift);
  if FDesigner = nil then
    Exit;
  case Key of
    vkLeft, vkRight, vkUp, vkDown:
      FDesigner.NudgeSelection(Key, Shift);
    vkDelete:
      FDesigner.DeleteSelection;
    vkEscape:
      if FDragging then
      begin
        SetTilePosition(FDragged, FOrigin.X, FOrigin.Y);
        AbandonDrag;
        Invalidate;
      end
      else if FDesigner.ArmedItem <> nil then
      begin
        FDesigner.DisarmCreation;
        UpdateCursor;
      end
      else
        FDesigner.SelectComponent(nil);
    Ord('S'):
      if ssCtrl in Shift then
        FDesigner.RequestSave;
    Ord('Z'):
      if ssCtrl in Shift then
        FDesigner.RequestUndo;
    Ord('Y'):
      if ssCtrl in Shift then
        FDesigner.RequestRedo;
  else
    Exit;
  end;
  Key := 0;
end;

end.
