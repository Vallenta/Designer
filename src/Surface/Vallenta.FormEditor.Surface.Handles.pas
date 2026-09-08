// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Surface.Handles;

// Designer chrome: the eight grab handles around the selection and the
// four-strip rectangle used for drag feedback, the marquee and secondary
// selections. All are real child windows with a nil Owner and never enter
// the streamed component tree; overlay painting is erased when a control
// repaints itself, and the desktop compositor discards direct screen output.
//
// The windows are parented to the window Chrome names, normally the
// document's host window and not the designed container the target is a child
// of: a parent that arranges its children treats an inserted window as one of
// them (a TToolBar as a toolbar item). Bounds are passed in the target
// parent's client coordinates and mapped into the host's. Main thread only.

interface

uses
  System.Classes,
  System.Types,
  Vcl.Controls;

type
  // Position of a grab handle on the selection rectangle.
  THandleKind = (hkTopLeft, hkTop, hkTopRight, hkLeft, hkRight, hkBottomLeft,
    hkBottom, hkBottomRight);

  // Stage reported by THandleDragEvent for a grab handle.
  THandleDragStage = (hdsBegin, hdsMove, hdsEnd);

  // Handler for a grab handle. hdsBegin and hdsEnd are raised for the left
  // button; hdsMove is raised on every mouse move over the handle, so the
  // handler must check that a gesture is in progress.
  THandleDragEvent = procedure(Kind: THandleKind; Stage: THandleDragStage) of object;

  // One grab handle window. csCaptureMouse captures the mouse from mouse-down
  // to mouse-up, so the moves of a drag started here reach this window and are
  // reported through the handler passed to CreateGrabHandle.
  THandleWindow = class(TCustomControl)
  private
    FKind: THandleKind;
    FOnDrag: THandleDragEvent;
  protected
    procedure Paint; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState; X, Y: Integer); override;
  public
    // Creates a handle of HandleSize pixels, hidden, with the resize cursor
    // for Kind; AOnDrag receives the drag stages, hdsMove also on plain hover.
    constructor CreateGrabHandle(Kind: THandleKind; AOnDrag: THandleDragEvent);
    // Position of this handle on the selection rectangle.
    property Kind: THandleKind read FKind;
  end;

  // One edge of the rectangle a TDragFrame draws.
  TFrameStrip = class(TCustomControl)
  protected
    procedure Paint; override;
  public
    // Creates the strip hidden and unparented, with a nil Owner.
    constructor CreateStrip;
  end;

  // Rectangle outline drawn as four edge windows. Used as feedback during a
  // move, resize, marquee or component-creation gesture, which changes no
  // bounds before the drop, and as the outline of each other control in a
  // multi-selection.
  TDragFrame = class
  private
    FStrips: array [0 .. 3] of TFrameStrip;
    FChrome: TWinControl;
    FParent: TWinControl;
    FBounds: TRect;
  public
    constructor Create;
    destructor Destroy; override;
    // Shows the outline at Bounds, given in AParent's client coordinates.
    // A repeat call with the same parent and rectangle does nothing; edge
    // thickness shrinks for a rectangle smaller than FrameThickness.
    procedure ShowRect(AParent: TWinControl; const Bounds: TRect);
    // Hides and unparents the strips and clears the cached rectangle, so the
    // same rectangle shows again on the next ShowRect.
    procedure Hide;
    // Moves the strips to the end of their parent's tab list, so streaming
    // does not count them in sibling TabOrder values.
    procedure SinkInTabOrder;
    // Parent window for the strips, normally the document's host window.
    // Nil parents them to the AParent passed to ShowRect.
    property Chrome: TWinControl read FChrome write FChrome;
  end;

  // The eight grab handles shown around one control. The handles are hidden
  // and unparented when the target is not a TControl or has no parent.
  THandleSet = class
  private
    FHandles: array [THandleKind] of THandleWindow;
    FChrome: TWinControl;
    FTarget: TControl;
    procedure PositionHandle(Kind: THandleKind);
  public
    // Creates the eight handles, hidden; AOnDrag receives every drag stage.
    constructor Create(AOnDrag: THandleDragEvent);
    destructor Destroy; override;
    // Shows the handles around AComponent, or hides and unparents them when
    // AComponent is not a TControl or has no parent.
    procedure ShowFor(AComponent: TComponent);
    // Repositions the handles on the current target bounds and raises them;
    // does nothing while no parented target is set.
    procedure Update;
    // Hides the handles and unparents them; Target keeps its last value.
    procedure Detach;
    // Moves the handles to the end of their parent's tab list, so streaming
    // does not count them in sibling TabOrder values.
    procedure SinkInTabOrder;
    // Parent window for the handles, normally the document's host window; nil
    // parents them to the target's own parent. ShowFor applies the parenting,
    // Update maps positions through the current value.
    property Chrome: TWinControl read FChrome write FChrome;
    // Control the handles are positioned around. Set by ShowFor, nil when it
    // received a non-control, and left unchanged by Detach.
    property Target: TControl read FTarget;
  end;

// Moves AWindow to the end of its parent's tab list, so streaming does not
// count it in sibling TabOrder values. A window with no parent is ignored;
// the VCL clamps the assigned TabOrder to the last position.
procedure SinkBehindSiblings(AWindow: TWinControl);

// Chrome dimensions, in pixels.
const
  HandleSize = 5;
  FrameThickness = 2;

implementation

uses
  System.UITypes,
  Vcl.Graphics;

const
  HandleCursors: array [THandleKind] of TCursor = (crSizeNWSE, crSizeNS,
    crSizeNESW, crSizeWE, crSizeWE, crSizeNESW, crSizeNS, crSizeNWSE);

procedure SinkBehindSiblings(AWindow: TWinControl);
begin
  if AWindow.Parent <> nil then
    AWindow.TabOrder := High(TTabOrder);
end;

{ THandleWindow }

constructor THandleWindow.CreateGrabHandle(Kind: THandleKind;
  AOnDrag: THandleDragEvent);
begin
  inherited Create(nil);
  FKind := Kind;
  FOnDrag := AOnDrag;
  ControlStyle := ControlStyle + [csOpaque];
  Cursor := HandleCursors[Kind];
  Width := HandleSize;
  Height := HandleSize;
  Visible := False;
end;

procedure THandleWindow.Paint;
begin
  Canvas.Brush.Color := clBlack;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(ClientRect);
end;

procedure THandleWindow.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button = mbLeft) and Assigned(FOnDrag) then
    FOnDrag(FKind, hdsBegin);
end;

procedure THandleWindow.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  if Assigned(FOnDrag) then
    FOnDrag(FKind, hdsMove);
end;

procedure THandleWindow.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseUp(Button, Shift, X, Y);
  if (Button = mbLeft) and Assigned(FOnDrag) then
    FOnDrag(FKind, hdsEnd);
end;

{ TFrameStrip }

constructor TFrameStrip.CreateStrip;
begin
  inherited Create(nil);
  ControlStyle := ControlStyle + [csOpaque];
  Visible := False;
end;

procedure TFrameStrip.Paint;
begin
  Canvas.Brush.Color := clBlack;
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(ClientRect);
end;

{ TDragFrame }

constructor TDragFrame.Create;
var
  I: Integer;
begin
  inherited Create;
  for I := Low(FStrips) to High(FStrips) do
    FStrips[I] := TFrameStrip.CreateStrip;
end;

destructor TDragFrame.Destroy;
var
  I: Integer;
begin
  for I := Low(FStrips) to High(FStrips) do
    FStrips[I].Free;
  inherited Destroy;
end;

procedure TDragFrame.ShowRect(AParent: TWinControl; const Bounds: TRect);
var
  I, Thick: Integer;
  Home: TWinControl;
  Origin: TPoint;
  Area: TRect;
  Edges: array [0 .. 3] of TRect;
  Appearing: Boolean;
begin
  // A drag reports the same snapped rectangle repeatedly; re-moving and
  // re-raising four windows for those repeats makes the outline flicker.
  if (AParent = FParent) and (Bounds = FBounds) then
    Exit;
  Appearing := AParent <> FParent;
  FParent := AParent;
  FBounds := Bounds;
  Home := FChrome;
  if Home = nil then
    Home := AParent;
  if Home = AParent then
    Origin := Point(0, 0)
  else
    Origin := Home.ScreenToClient(AParent.ClientToScreen(Point(0, 0)));
  Area := Bounds;
  Area.Offset(Origin.X, Origin.Y);
  Thick := FrameThickness;
  if Area.Width < Thick then
    Thick := Area.Width;
  if Area.Height < Thick then
    Thick := Area.Height;
  Edges[0] := TRect.Create(Area.Left, Area.Top, Area.Right, Area.Top + Thick);
  Edges[1] := TRect.Create(Area.Left, Area.Bottom - Thick, Area.Right, Area.Bottom);
  Edges[2] := TRect.Create(Area.Left, Area.Top, Area.Left + Thick, Area.Bottom);
  Edges[3] := TRect.Create(Area.Right - Thick, Area.Top, Area.Right, Area.Bottom);
  for I := Low(FStrips) to High(FStrips) do
  begin
    FStrips[I].SetBounds(Edges[I].Left, Edges[I].Top, Edges[I].Width, Edges[I].Height);
    if Appearing then
    begin
      FStrips[I].Parent := Home;
      FStrips[I].Visible := True;
      FStrips[I].BringToFront;
    end;
  end;
end;

procedure TDragFrame.Hide;
var
  I: Integer;
begin
  // The cached rectangle must be cleared here, or ShowRect's repeat check
  // skips a next drag that starts on the same rectangle.
  FParent := nil;
  FBounds := TRect.Empty;
  for I := Low(FStrips) to High(FStrips) do
  begin
    FStrips[I].Visible := False;
    FStrips[I].Parent := nil;
  end;
end;

procedure TDragFrame.SinkInTabOrder;
var
  I: Integer;
begin
  for I := Low(FStrips) to High(FStrips) do
    SinkBehindSiblings(FStrips[I]);
end;

{ THandleSet }

constructor THandleSet.Create(AOnDrag: THandleDragEvent);
var
  Kind: THandleKind;
begin
  inherited Create;
  for Kind := Low(THandleKind) to High(THandleKind) do
    FHandles[Kind] := THandleWindow.CreateGrabHandle(Kind, AOnDrag);
end;

destructor THandleSet.Destroy;
var
  Kind: THandleKind;
begin
  for Kind := Low(THandleKind) to High(THandleKind) do
    FHandles[Kind].Free;
  inherited Destroy;
end;

procedure THandleSet.PositionHandle(Kind: THandleKind);
var
  Bounds: TRect;
  Center: TPoint;
begin
  Bounds := FTarget.BoundsRect;
  case Kind of
    hkTopLeft:     Center := Point(Bounds.Left, Bounds.Top);
    hkTop:         Center := Point((Bounds.Left + Bounds.Right) div 2, Bounds.Top);
    hkTopRight:    Center := Point(Bounds.Right, Bounds.Top);
    hkLeft:        Center := Point(Bounds.Left, (Bounds.Top + Bounds.Bottom) div 2);
    hkRight:       Center := Point(Bounds.Right, (Bounds.Top + Bounds.Bottom) div 2);
    hkBottomLeft:  Center := Point(Bounds.Left, Bounds.Bottom);
    hkBottom:      Center := Point((Bounds.Left + Bounds.Right) div 2, Bounds.Bottom);
    hkBottomRight: Center := Point(Bounds.Right, Bounds.Bottom);
  end;
  if (FChrome <> nil) and (FChrome <> FTarget.Parent) then
    Center := FChrome.ScreenToClient(FTarget.Parent.ClientToScreen(Center));
  FHandles[Kind].SetBounds(Center.X - HandleSize div 2, Center.Y - HandleSize div 2,
    HandleSize, HandleSize);
end;

procedure THandleSet.ShowFor(AComponent: TComponent);
var
  Kind: THandleKind;
  Home: TWinControl;
begin
  if AComponent is TControl then
    FTarget := TControl(AComponent)
  else
    FTarget := nil;
  if (FTarget = nil) or (FTarget.Parent = nil) then
  begin
    Detach;
    Exit;
  end;
  Home := FChrome;
  if Home = nil then
    Home := FTarget.Parent;
  for Kind := Low(THandleKind) to High(THandleKind) do
  begin
    FHandles[Kind].Parent := Home;
    PositionHandle(Kind);
    FHandles[Kind].Visible := True;
    FHandles[Kind].BringToFront;
  end;
end;

procedure THandleSet.Update;
var
  Kind: THandleKind;
begin
  if (FTarget = nil) or (FTarget.Parent = nil) then
    Exit;
  for Kind := Low(THandleKind) to High(THandleKind) do
  begin
    PositionHandle(Kind);
    FHandles[Kind].BringToFront;
  end;
end;

procedure THandleSet.Detach;
var
  Kind: THandleKind;
begin
  for Kind := Low(THandleKind) to High(THandleKind) do
  begin
    FHandles[Kind].Visible := False;
    FHandles[Kind].Parent := nil;
  end;
end;

procedure THandleSet.SinkInTabOrder;
var
  Kind: THandleKind;
begin
  for Kind := Low(THandleKind) to High(THandleKind) do
    SinkBehindSiblings(FHandles[Kind]);
end;

end.
