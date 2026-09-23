// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Shell.AlignPalette;

// Strip above the design surface: a drawn button that opens a menu of the ten
// align actions, each with a glyph drawn from geometry into an image list, and
// at the right end the list of installed VCL styles. The button is drawn
// rather than a TButton, which would take the keyboard focus off the design
// surface and leave the arrow keys moving between controls.
//
// The style list takes the focus while it is open and changes the selection
// only there; OnStyleListClosed asks the owner to take the focus back. The
// strip holds no designer reference. Main thread only.

interface

uses
  Winapi.Messages,
  System.Classes,
  System.Types,
  Vcl.Controls,
  Vcl.Graphics,
  Vcl.Menus,
  Vcl.StdCtrls,
  Vallenta.FormEditor.Surface.FormDesigner,
  Vallenta.FormEditor.Shell.Styles;

const
  // Align actions the menu offers. The table in the implementation is
  // declared over this, so the two cannot drift apart.
  AlignActionCount = 10;

  // Posted by the strip to itself once the style list has closed.
  WM_STYLELISTCLOSED = WM_APP + 1;

type
  // Raised when a menu entry is chosen. Exactly one of the two arguments
  // names an action, the other is ahNone or avNone.
  TAlignActionEvent = procedure(Sender: TObject; AHorizontal: TAlignHorizontal;
    AVertical: TAlignVertical) of object;

  // Asked once per action by RefreshCommands; AEnabled arrives False. The
  // actions differ in what they need, so each is asked for itself.
  TAlignQueryEvent = procedure(Sender: TObject; AHorizontal: TAlignHorizontal;
    AVertical: TAlignVertical; var AEnabled: Boolean) of object;

  // Raised when the style list closes on a style other than the active one.
  TStyleChosenEvent = procedure(Sender: TObject;
    const AStyle: TDesignerStyle) of object;

  // Alignment bar above a design surface. Height is its own: the strip sizes
  // itself for the DPI it is parented at.
  TAlignPalette = class(TCustomControl)
  private
    FHot: Boolean;
    FPressed: Boolean;
    FEnabled: array [0 .. AlignActionCount - 1] of Boolean;
    FItems: array [0 .. AlignActionCount - 1] of TMenuItem;
    FMenu: TPopupMenu;
    FImages: TImageList;
    FStyleCombo: TComboBox;
    FOnAlign: TAlignActionEvent;
    FOnQueryAlign: TAlignQueryEvent;
    FOnStyleChosen: TStyleChosenEvent;
    FOnStyleListClosed: TNotifyEvent;
    function ButtonBounds: TRect;
    function AnyEnabled: Boolean;
    function StyleColor(AColor: TColor): TColor;
    procedure BuildImages;
    procedure BuildMenu;
    procedure ItemClick(Sender: TObject);
    procedure DropMenu;
    procedure TrackHot(X, Y: Integer);
    procedure PlaceStyleCombo;
    procedure StyleListCloseUp(Sender: TObject);
    procedure CMMouseLeave(var Message: TMessage); message CM_MOUSELEAVE;
    procedure CMStyleChanged(var Message: TMessage); message CM_STYLECHANGED;
    procedure WMStyleListClosed(var Message: TMessage);
      message WM_STYLELISTCLOSED;
  protected
    procedure Paint; override;
    procedure Resize; override;
    procedure MouseDown(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    procedure MouseMove(Shift: TShiftState; X, Y: Integer); override;
    procedure MouseUp(Button: TMouseButton; Shift: TShiftState;
      X, Y: Integer); override;
    // Both re-derive the strip's height and redraw the glyphs at the new
    // scale: a control created in code is not scaled by the form that takes
    // it, and a monitor change rescales it.
    procedure SetParent(AParent: TWinControl); override;
    procedure ChangeScale(M, D: Integer; isDpiChange: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
    // Asks OnQueryAlign for every action and enables the entries from the
    // answers. The button is offered while any one of them is. The owner
    // calls this where it refreshes its command states.
    procedure RefreshCommands;
    property OnAlign: TAlignActionEvent read FOnAlign write FOnAlign;
    property OnQueryAlign: TAlignQueryEvent read FOnQueryAlign
      write FOnQueryAlign;
    // Raised when the style list closes on a style other than the one the
    // windows are drawn in. The list shows the active style again afterwards,
    // so a style the handler could not apply is not left selected.
    property OnStyleChosen: TStyleChosenEvent read FOnStyleChosen
      write FOnStyleChosen;
    // Raised each time the style list closes, after OnStyleChosen. The list
    // holds the keyboard focus at that point.
    property OnStyleListClosed: TNotifyEvent read FOnStyleListClosed
      write FOnStyleListClosed;
  end;

implementation

uses
  Winapi.Windows,
  System.Math,
  System.SysUtils,
  System.UITypes,
  Vcl.Forms,
  Vcl.Themes;

type
  // One entry of the menu: the action it runs and the text it carries.
  TAlignEntry = record
    Horizontal: TAlignHorizontal;
    Vertical: TAlignVertical;
    Caption: string;
  end;

  // Combo box of the installed styles, filled when its window is first
  // created. While its list is closed it ignores the wheel and the keys that
  // move the selection, so the selection changes only in the open list.
  TStyleCombo = class(TComboBox)
  private
    FStyles: TArray<TDesignerStyle>;
  protected
    procedure CreateWnd; override;
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
      MousePos: TPoint): Boolean; override;
    procedure KeyDown(var Key: Word; Shift: TShiftState); override;
    procedure KeyPress(var Key: Char); override;
  public
    // Selects the entry of the style the windows are drawn in; none when that
    // style is not installed. Does nothing before the window exists.
    procedure ShowActiveStyle;
    // The selected entry; False when none is selected.
    function Selected(out AStyle: TDesignerStyle): Boolean;
  end;

const
  // The ten actions, horizontal first. The menu separates the two groups
  // after EntriesPerGroup entries.
  Entries: array [0 .. AlignActionCount - 1] of TAlignEntry = (
    (Horizontal: ahLeft; Vertical: avNone;
      Caption: 'Align left sides'),
    (Horizontal: ahCenters; Vertical: avNone;
      Caption: 'Align centers horizontally'),
    (Horizontal: ahRight; Vertical: avNone;
      Caption: 'Align right sides'),
    (Horizontal: ahSpaceEqually; Vertical: avNone;
      Caption: 'Space equally horizontally'),
    (Horizontal: ahCenterInWindow; Vertical: avNone;
      Caption: 'Center horizontally in the container'),
    (Horizontal: ahNone; Vertical: avTop;
      Caption: 'Align tops'),
    (Horizontal: ahNone; Vertical: avMiddles;
      Caption: 'Align centers vertically'),
    (Horizontal: ahNone; Vertical: avBottom;
      Caption: 'Align bottoms'),
    (Horizontal: ahNone; Vertical: avSpaceEqually;
      Caption: 'Space equally vertically'),
    (Horizontal: ahNone; Vertical: avCenterInWindow;
      Caption: 'Center vertically in the container'));

  EntriesPerGroup = 5;

  ButtonCaption = 'Align';
  StyleCaption = 'Style';

  // Strip, button and style list metrics in pixels at 96 DPI, scaled to the
  // DPI the strip is shown at. The height below is what SetParent derives
  // from them.
  StripMargin = 4;
  ButtonHeight = 24;
  TextPadding = 10;
  ArrowWidth = 7;
  ArrowHeight = 4;
  ArrowGap = 8;
  StripHeight = 2 * StripMargin + ButtonHeight + 1;
  StyleComboWidth = 180;
  StyleComboRows = 16;

  // Side of the square a glyph is drawn in, and the grid its parts are
  // measured on: every coordinate below is a unit of that grid.
  GlyphSize = 16;
  GlyphUnits = 16;

  // System colors of the strip, mapped through the active style when drawn.
  BackColor = clBtnFace;
  BorderColor = clBtnShadow;
  HotColor = clBtnHighlight;
  PressedColor = clBtnShadow;
  FrameColor = clHighlight;
  TextColor = clBtnText;
  GuideColor = clHighlight;
  DisabledColor = clGrayText;

  // Filled behind a glyph and made transparent as it enters the image list;
  // no part of a glyph is drawn in it.
  MaskColor = clFuchsia;

// Draws the glyph of the action at AIndex into ABox. Its parts are measured
// on a GlyphUnits grid over the square, so one description serves every DPI.
procedure DrawAlignGlyph(ACanvas: TCanvas; const ABox: TRect; AIndex: Integer;
  ABars, AGuides: TColor);

  function UnitX(AUnit: Integer): Integer;
  begin
    Result := ABox.Left + MulDiv(AUnit, ABox.Width, GlyphUnits);
  end;

  function UnitY(AUnit: Integer): Integer;
  begin
    Result := ABox.Top + MulDiv(AUnit, ABox.Height, GlyphUnits);
  end;

  // A filled rectangle over the unit grid, never thinner than one pixel: the
  // grid divides a small glyph into steps below one.
  procedure Bar(ALeft, ATop, ARight, ABottom: Integer; AColor: TColor);
  var
    Area: TRect;
  begin
    Area := TRect.Create(UnitX(ALeft), UnitY(ATop), UnitX(ARight),
      UnitY(ABottom));
    if Area.Width < 1 then
      Area.Right := Area.Left + 1;
    if Area.Height < 1 then
      Area.Bottom := Area.Top + 1;
    ACanvas.Brush.Color := AColor;
    ACanvas.FillRect(Area);
  end;

  // The reference edge the action lines everything up on.
  procedure Guide(AAt: Integer; AVertical: Boolean);
  begin
    if AVertical then
      Bar(AAt, 0, AAt + 1, GlyphUnits, AGuides)
    else
      Bar(0, AAt, GlyphUnits, AAt + 1, AGuides);
  end;

  // The container outline the two center-in-container actions measure in.
  procedure Container;
  begin
    Bar(1, 1, 15, 2, AGuides);
    Bar(1, 14, 15, 15, AGuides);
    Bar(1, 1, 2, 15, AGuides);
    Bar(14, 1, 15, 15, AGuides);
  end;

begin
  case AIndex of
    0: // left sides: a common left edge under two rows of different length
      begin
        Guide(2, True);
        Bar(2, 3, 14, 6, ABars);
        Bar(2, 10, 10, 13, ABars);
      end;
    1: // centers horizontally
      begin
        Guide(8, True);
        Bar(1, 3, 15, 6, ABars);
        Bar(4, 10, 12, 13, ABars);
      end;
    2: // right sides
      begin
        Guide(14, True);
        Bar(2, 3, 14, 6, ABars);
        Bar(6, 10, 14, 13, ABars);
      end;
    3: // space equally horizontally: three columns, two equal gaps
      begin
        Bar(1, 2, 4, 14, ABars);
        Bar(7, 2, 10, 14, ABars);
        Bar(13, 2, 16, 14, ABars);
      end;
    4: // center horizontally in the container
      begin
        Container;
        Bar(5, 6, 11, 10, ABars);
      end;
    5: // tops
      begin
        Guide(2, False);
        Bar(3, 2, 6, 14, ABars);
        Bar(10, 2, 13, 8, ABars);
      end;
    6: // centers vertically
      begin
        Guide(8, False);
        Bar(3, 1, 6, 15, ABars);
        Bar(10, 4, 13, 12, ABars);
      end;
    7: // bottoms
      begin
        Guide(14, False);
        Bar(3, 2, 6, 14, ABars);
        Bar(10, 8, 13, 14, ABars);
      end;
    8: // space equally vertically
      begin
        Bar(2, 1, 14, 4, ABars);
        Bar(2, 7, 14, 10, ABars);
        Bar(2, 13, 14, 16, ABars);
      end;
    9: // center vertically in the container
      begin
        Container;
        Bar(6, 5, 10, 11, ABars);
      end;
  end;
end;

{ TStyleCombo }

procedure TStyleCombo.CreateWnd;
var
  Style: TDesignerStyle;
begin
  inherited CreateWnd;
  // A recreated window gets its entries back from the inherited CreateWnd.
  if Items.Count > 0 then
    Exit;
  FStyles := InstalledStyles;
  for Style in FStyles do
    Items.Add(Style.Name);
  ShowActiveStyle;
end;

function TStyleCombo.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  Result := not DroppedDown or
    inherited DoMouseWheel(Shift, WheelDelta, MousePos);
end;

procedure TStyleCombo.KeyDown(var Key: Word; Shift: TShiftState);
begin
  if not DroppedDown and not (ssAlt in Shift) and
     (Key in [VK_UP, VK_DOWN, VK_LEFT, VK_RIGHT, VK_PRIOR, VK_NEXT, VK_HOME,
       VK_END]) then
    Key := 0;
  inherited KeyDown(Key, Shift);
end;

procedure TStyleCombo.KeyPress(var Key: Char);
begin
  if not DroppedDown then
    Key := #0;
  inherited KeyPress(Key);
end;

procedure TStyleCombo.ShowActiveStyle;
var
  Active: string;
  I: Integer;
begin
  if not HandleAllocated then
    Exit;
  Active := ActiveStyleName;
  for I := 0 to High(FStyles) do
    if SameText(FStyles[I].Name, Active) then
    begin
      ItemIndex := I;
      Exit;
    end;
  ItemIndex := -1;
end;

function TStyleCombo.Selected(out AStyle: TDesignerStyle): Boolean;
begin
  Result := (ItemIndex >= 0) and (ItemIndex <= High(FStyles));
  if Result then
    AStyle := FStyles[ItemIndex];
end;

{ TAlignPalette }

constructor TAlignPalette.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ControlStyle := ControlStyle + [csOpaque];
  DoubleBuffered := True;
  ShowHint := True;
  Hint := 'Align the selection';
  FImages := TImageList.Create(Self);
  FMenu := TPopupMenu.Create(Self);
  FMenu.Images := FImages;
  FStyleCombo := TStyleCombo.Create(Self);
  FStyleCombo.Parent := Self;
  FStyleCombo.Style := csDropDownList;
  FStyleCombo.TabStop := False;
  FStyleCombo.DropDownCount := StyleComboRows;
  FStyleCombo.Hint := 'Style of the designer windows';
  FStyleCombo.OnCloseUp := StyleListCloseUp;
  BuildMenu;
  BuildImages;
  Height := StripHeight;
end;

procedure TAlignPalette.SetParent(AParent: TWinControl);
begin
  inherited SetParent(AParent);
  if AParent = nil then
    Exit;
  Height := ScaleValue(StripHeight);
  BuildImages;
  PlaceStyleCombo;
end;

procedure TAlignPalette.ChangeScale(M, D: Integer; isDpiChange: Boolean);
begin
  inherited ChangeScale(M, D, isDpiChange);
  Height := ScaleValue(StripHeight);
  BuildImages;
  PlaceStyleCombo;
end;

procedure TAlignPalette.Resize;
begin
  inherited Resize;
  PlaceStyleCombo;
end;

procedure TAlignPalette.PlaceStyleCombo;
var
  ComboWidth: Integer;
begin
  ComboWidth := ScaleValue(StyleComboWidth);
  FStyleCombo.SetBounds(ClientWidth - ScaleValue(StripMargin) - ComboWidth,
    (ClientHeight - 1 - FStyleCombo.Height) div 2, ComboWidth,
    FStyleCombo.Height);
end;

function TAlignPalette.StyleColor(AColor: TColor): TColor;
begin
  Result := StyleServices(Self).GetSystemColor(AColor);
end;

procedure TAlignPalette.BuildMenu;
var
  I: Integer;
  Item: TMenuItem;
begin
  FMenu.Items.Clear;
  for I := Low(Entries) to High(Entries) do
  begin
    if (I > 0) and (I mod EntriesPerGroup = 0) then
    begin
      Item := TMenuItem.Create(Self);
      Item.Caption := '-';
      FMenu.Items.Add(Item);
    end;
    Item := TMenuItem.Create(Self);
    Item.Caption := Entries[I].Caption;
    Item.ImageIndex := I;
    Item.Tag := I;
    // Starts disabled to match FEnabled: RefreshCommands writes an entry only
    // where the answer changed, so the two have to begin in step.
    Item.Enabled := False;
    Item.OnClick := ItemClick;
    FMenu.Items.Add(Item);
    FItems[I] := Item;
  end;
end;

// The image list is rebuilt rather than rescaled: a glyph drawn at the size it
// is shown at has no resampling in it. The bars take the menu text color of
// the active style, so the glyphs read on the menu that shows them.
procedure TAlignPalette.BuildImages;
var
  Side, I: Integer;
  // Qualified: Winapi.Windows declares a TBitmap of its own, and this unit
  // has it in scope.
  Glyph: Vcl.Graphics.TBitmap;
  Box: TRect;
  Bars, Guides: TColor;
begin
  Side := ScaleValue(GlyphSize);
  Bars := StyleServices(Self).GetStyleFontColor(sfPopupMenuItemTextNormal);
  Guides := StyleColor(GuideColor);
  FImages.Clear;
  FImages.Width := Side;
  FImages.Height := Side;
  Box := TRect.Create(0, 0, Side, Side);
  Glyph := Vcl.Graphics.TBitmap.Create;
  try
    Glyph.PixelFormat := pf24bit;
    Glyph.SetSize(Side, Side);
    for I := Low(Entries) to High(Entries) do
    begin
      Glyph.Canvas.Brush.Color := MaskColor;
      Glyph.Canvas.FillRect(Box);
      DrawAlignGlyph(Glyph.Canvas, Box, I, Bars, Guides);
      FImages.AddMasked(Glyph, MaskColor);
    end;
  finally
    Glyph.Free;
  end;
end;

function TAlignPalette.ButtonBounds: TRect;
var
  Margin: Integer;
begin
  Margin := ScaleValue(StripMargin);
  Canvas.Font := Font;
  Result := TRect.Create(Margin, Margin, 0, 0);
  Result.Width := Canvas.TextWidth(ButtonCaption) +
    ScaleValue(2 * TextPadding + ArrowGap + ArrowWidth);
  Result.Height := ScaleValue(ButtonHeight);
end;

function TAlignPalette.AnyEnabled: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := Low(FEnabled) to High(FEnabled) do
    if FEnabled[I] then
      Exit(True);
end;

procedure TAlignPalette.RefreshCommands;
var
  I: Integer;
  Allowed, Changed: Boolean;
begin
  Changed := False;
  for I := Low(Entries) to High(Entries) do
  begin
    Allowed := False;
    if Assigned(FOnQueryAlign) then
      FOnQueryAlign(Self, Entries[I].Horizontal, Entries[I].Vertical, Allowed);
    if Allowed = FEnabled[I] then
      Continue;
    FEnabled[I] := Allowed;
    FItems[I].Enabled := Allowed;
    Changed := True;
  end;
  if not Changed then
    Exit;
  if not AnyEnabled then
  begin
    FHot := False;
    FPressed := False;
  end;
  Invalidate;
end;

procedure TAlignPalette.Paint;
var
  Button, Arrow: TRect;
  Live: Boolean;
  Text: string;
begin
  Canvas.Brush.Color := StyleColor(BackColor);
  Canvas.Brush.Style := bsSolid;
  Canvas.FillRect(ClientRect);
  Canvas.Pen.Color := StyleColor(BorderColor);
  Canvas.Pen.Style := psSolid;
  Canvas.MoveTo(0, Height - 1);
  Canvas.LineTo(Width, Height - 1);

  Live := AnyEnabled;
  Button := ButtonBounds;
  if Live and FPressed then
    Canvas.Brush.Color := StyleColor(PressedColor)
  else if Live and FHot then
    Canvas.Brush.Color := StyleColor(HotColor)
  else
    Canvas.Brush.Color := StyleColor(BackColor);
  Canvas.FillRect(Button);
  if Live and (FHot or FPressed) then
    Canvas.Brush.Color := StyleColor(FrameColor)
  else
    Canvas.Brush.Color := StyleColor(BorderColor);
  Canvas.FrameRect(Button);

  Canvas.Font := Font;
  Canvas.Brush.Style := bsClear;
  if Live then
    Canvas.Font.Color := StyleColor(TextColor)
  else
    Canvas.Font.Color := StyleColor(DisabledColor);
  Text := ButtonCaption;
  Canvas.TextOut(Button.Left + ScaleValue(TextPadding),
    Button.Top + (Button.Height - Canvas.TextHeight(Text)) div 2, Text);

  // The triangle marking the button as one that opens a menu.
  Arrow := TRect.Create(Button.Right - ScaleValue(TextPadding + ArrowWidth),
    Button.CenterPoint.Y - ScaleValue(ArrowHeight) div 2, 0, 0);
  Arrow.Width := ScaleValue(ArrowWidth);
  Arrow.Height := ScaleValue(ArrowHeight);
  Canvas.Brush.Style := bsSolid;
  Canvas.Brush.Color := Canvas.Font.Color;
  Canvas.Pen.Color := Canvas.Brush.Color;
  Canvas.Polygon([Arrow.TopLeft, Point(Arrow.Right, Arrow.Top),
    Point(Arrow.CenterPoint.X, Arrow.Bottom)]);

  Canvas.Brush.Style := bsClear;
  Canvas.Font.Color := StyleColor(TextColor);
  Text := StyleCaption;
  Canvas.TextOut(FStyleCombo.Left - ScaleValue(TextPadding) -
    Canvas.TextWidth(Text),
    (Height - 1 - Canvas.TextHeight(Text)) div 2, Text);
end;

procedure TAlignPalette.TrackHot(X, Y: Integer);
var
  Over: Boolean;
begin
  Over := ButtonBounds.Contains(Point(X, Y));
  if Over = FHot then
    Exit;
  FHot := Over;
  Invalidate;
end;

procedure TAlignPalette.MouseDown(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
begin
  inherited MouseDown(Button, Shift, X, Y);
  if (Button <> mbLeft) or not AnyEnabled then
    Exit;
  if not ButtonBounds.Contains(Point(X, Y)) then
    Exit;
  FPressed := True;
  Invalidate;
end;

procedure TAlignPalette.MouseMove(Shift: TShiftState; X, Y: Integer);
begin
  inherited MouseMove(Shift, X, Y);
  TrackHot(X, Y);
end;

procedure TAlignPalette.MouseUp(Button: TMouseButton; Shift: TShiftState;
  X, Y: Integer);
var
  Dropping: Boolean;
begin
  inherited MouseUp(Button, Shift, X, Y);
  if Button <> mbLeft then
    Exit;
  Dropping := FPressed and ButtonBounds.Contains(Point(X, Y));
  FPressed := False;
  Invalidate;
  // A press that left the button before the release opens nothing, which is
  // how a press is taken back.
  if Dropping then
    DropMenu;
end;

procedure TAlignPalette.DropMenu;
var
  Button: TRect;
  At: TPoint;
begin
  Button := ButtonBounds;
  At := ClientToScreen(Point(Button.Left, Button.Bottom));
  FMenu.Popup(At.X, At.Y);
end;

procedure TAlignPalette.ItemClick(Sender: TObject);
var
  Index: Integer;
begin
  Index := TMenuItem(Sender).Tag;
  if Assigned(FOnAlign) then
    FOnAlign(Self, Entries[Index].Horizontal, Entries[Index].Vertical);
end;

// Posted rather than handled here: the list can report its new selection
// after it reports closing.
procedure TAlignPalette.StyleListCloseUp(Sender: TObject);
begin
  if HandleAllocated then
    PostMessage(Handle, WM_STYLELISTCLOSED, 0, 0);
end;

procedure TAlignPalette.WMStyleListClosed(var Message: TMessage);
var
  Style: TDesignerStyle;
begin
  if TStyleCombo(FStyleCombo).Selected(Style) and
     not SameText(Style.Name, ActiveStyleName) and Assigned(FOnStyleChosen) then
    FOnStyleChosen(Self, Style);
  TStyleCombo(FStyleCombo).ShowActiveStyle;
  if Assigned(FOnStyleListClosed) then
    FOnStyleListClosed(Self);
end;

procedure TAlignPalette.CMMouseLeave(var Message: TMessage);
begin
  inherited;
  if not FHot then
    Exit;
  FHot := False;
  Invalidate;
end;

procedure TAlignPalette.CMStyleChanged(var Message: TMessage);
begin
  inherited;
  BuildImages;
  TStyleCombo(FStyleCombo).ShowActiveStyle;
  PlaceStyleCombo;
  Invalidate;
end;

end.
