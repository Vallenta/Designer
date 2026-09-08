// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Streaming.Preserved;

// Verbatim text a load could not turn into components: blocks of unknown
// classes and unreadable property lines, each with the position in the
// original text it is spliced back into. TPreservedModel holds the pieces of
// one document, the names they reserve, and one placeholder control per
// preserved block. Placeholders are VCL controls; main thread only.
//
// A placeholder is created without an Owner, so no streaming walk writes it,
// and the model frees it. ReleasePlaceholdersIn must run before a container
// holding one is destroyed, or the container frees a control the model still
// lists.

interface

uses
  System.Classes,
  System.SysUtils,
  System.Types,
  System.Generics.Collections,
  Vcl.Controls,
  Vcl.Graphics,
  Vallenta.FormEditor.Streaming.TextSpans;

type
  // Whether a piece is a whole component block or a single property line.
  TPreservedKind = (pkBlock, pkProperty);

  // One run of preserved text and the position in the original text it is
  // spliced back into.
  TPreservedPiece = class
  public
    // pkBlock fills ComponentName, DeclaredClass and the bounds; pkProperty
    // fills PropertyName.
    Kind: TPreservedKind;
    // Name of the block the text is spliced back into.
    OwnerName: string;
    // Position in the original text, among the owner's child blocks or its
    // property lines; SpliceDfmText maps it onto the written text.
    Index: Integer;
    // The original text, with its indentation and trailing line break.
    Text: string;
    // Name of the preserved component; empty for a property line and for an
    // unnamed block.
    ComponentName: string;
    // Class name the preserved block declares; empty for a property line.
    DeclaredClass: string;
    // Property name of a pkProperty piece; empty for a block.
    PropertyName: string;
    // Position from the block's Left and Top; width and height are set only
    // when HasSize.
    Bounds: TRect;
    // True when the block carried both Width and Height.
    HasSize: Boolean;
    // TabOrder read from the block; valid only when HasTabOrder.
    TabOrder: Integer;
    // True when the block carried a TabOrder, i.e. was a windowed control.
    HasTabOrder: Boolean;
    // Field-by-field copy; the caller frees the result.
    function Clone: TPreservedPiece;
    // "Owner.Property" for a property line, "Name: TClass" for a block, or
    // the class name alone for an unnamed block.
    function Describe: string;
  end;

  // Non-windowed stand-in painted where a preserved block sat. Created
  // without an Owner, so no streaming walk writes it, and in design mode, so
  // mouse messages reach the designer through IsDesignMsg. A block that
  // carried a TabOrder gets TWindowedPlaceholder instead.
  TDesignPlaceholder = class(TGraphicControl)
  private
    FPiece: TPreservedPiece;
  protected
    procedure Paint; override;
  public
    // Creates the stand-in for APiece; APiece is not freed with the control.
    constructor CreateFor(APiece: TPreservedPiece);
    // Preserved block the control stands for; not freed with the control.
    property Piece: TPreservedPiece read FPiece;
  end;

  // Windowed stand-in for a preserved block that carried a TabOrder: holding
  // a slot in its parent's tab list keeps the controls after it at the
  // TabOrder values the file holds. Otherwise like TDesignPlaceholder.
  TWindowedPlaceholder = class(TCustomControl)
  private
    FPiece: TPreservedPiece;
  protected
    procedure Paint; override;
  public
    // Creates the stand-in for APiece; APiece is not freed with the control.
    constructor CreateFor(APiece: TPreservedPiece);
    // Preserved block the control stands for; not freed with the control.
    property Piece: TPreservedPiece read FPiece;
  end;

  // The preserved pieces of one document, the names they reserve, and the
  // placeholder controls built for them; pieces and placeholders are freed
  // with the model.
  TPreservedModel = class
  private
    FPieces: TObjectList<TPreservedPiece>;
    FPlaceholders: TObjectList<TControl>;
    FReserved: TStringList;
    function GetCount: Integer;
    function GetPiece(AIndex: Integer): TPreservedPiece;
  public
    constructor Create;
    destructor Destroy; override;
    // Appends APiece; the model frees it.
    procedure Add(APiece: TPreservedPiece);
    // Records AName as held by preserved content; an empty name is ignored
    // and a repeat of a recorded name has no effect.
    procedure ReserveName(const AName: string);
    // True for a recorded name, matched case-insensitively. A new component
    // given such a name collides with the preserved text at the next load.
    function IsReservedName(const AName: string): Boolean;
    // Copy of the pieces and the reserved names, without the placeholders;
    // the caller frees the result.
    function Clone: TPreservedModel;
    // One insertion per piece, in the order the pieces were added, as
    // SpliceDfmText takes them.
    function Insertions: TArray<TDfmInsertion>;

    // Rebuilds one placeholder per preserved block, parented to the owner
    // block's component when ARoot resolves it to a TWinControl and to
    // ASurface for every other owner, including a non-windowed one. A block
    // is skipped only when ASurface is nil; earlier placeholders are freed.
    procedure BuildPlaceholders(ARoot: TComponent; ASurface: TWinControl);
    // Placeholder whose piece names the preserved component AName, matched
    // case-insensitively; nil for none. A placeholder carries no Name itself.
    function PlaceholderNamed(const AName: string): TControl;
    // Removes APiece and frees it, along with its placeholder if it has one.
    procedure DropPiece(APiece: TPreservedPiece);
    // Removes and frees every piece whose OwnerName is one of AOwnerNames,
    // matched case-insensitively, with the placeholders of those pieces.
    procedure DropOwnedBy(const AOwnerNames: TArray<string>);
    // Removes the pieces whose placeholders sit at or inside AControl and
    // frees both. Must run before AControl is destroyed, because a parent
    // frees its child controls and the model would keep freed placeholders.
    procedure ReleasePlaceholdersIn(AControl: TWinControl);
    // Number of preserved pieces.
    property Count: Integer read GetCount;
    // Piece at AIndex, in the order the pieces were added.
    property Pieces[AIndex: Integer]: TPreservedPiece read GetPiece; default;
  end;

// The piece a placeholder control stands for; nil for any other component.
function PlaceholderPiece(AComponent: TComponent): TPreservedPiece;

// True when AComponent is one of the two placeholder classes.
function IsPlaceholder(AComponent: TComponent): Boolean;

const
  // Edge length in pixels of a placeholder whose block held no size.
  PlaceholderTileSize = 48;

implementation

type
  TComponentAccess = class(TComponent);

const
  PlaceholderFill = TColor($00E8E8FF);
  PlaceholderEdge = TColor($00505090);
  PlaceholderText = TColor($00303060);

function PlaceholderPiece(AComponent: TComponent): TPreservedPiece;
begin
  if AComponent is TDesignPlaceholder then
    Result := TDesignPlaceholder(AComponent).Piece
  else if AComponent is TWindowedPlaceholder then
    Result := TWindowedPlaceholder(AComponent).Piece
  else
    Result := nil;
end;

function IsPlaceholder(AComponent: TComponent): Boolean;
begin
  Result := PlaceholderPiece(AComponent) <> nil;
end;

procedure PaintPlaceholder(ACanvas: TCanvas; const ABounds: TRect;
  const ACaption: string);
var
  Extent: TSize;
begin
  ACanvas.Brush.Color := PlaceholderFill;
  ACanvas.Brush.Style := bsSolid;
  ACanvas.FillRect(ABounds);
  ACanvas.Brush.Style := bsDiagCross;
  ACanvas.Brush.Color := PlaceholderEdge;
  ACanvas.FillRect(ABounds);
  ACanvas.Brush.Style := bsClear;
  ACanvas.Pen.Color := PlaceholderEdge;
  ACanvas.Pen.Style := psSolid;
  ACanvas.Rectangle(ABounds);

  ACanvas.Font.Color := PlaceholderText;
  Extent := ACanvas.TextExtent(ACaption);
  // TextOut fills the text background from the brush; a solid fill keeps the
  // hatch from showing through the caption.
  ACanvas.Brush.Color := PlaceholderFill;
  ACanvas.Brush.Style := bsSolid;
  ACanvas.TextOut(ABounds.Left + (ABounds.Width - Extent.cx) div 2,
    ABounds.Top + (ABounds.Height - Extent.cy) div 2, ACaption);
end;

{ TPreservedPiece }

function TPreservedPiece.Clone: TPreservedPiece;
begin
  Result := TPreservedPiece.Create;
  Result.Kind := Kind;
  Result.OwnerName := OwnerName;
  Result.Index := Index;
  Result.Text := Text;
  Result.ComponentName := ComponentName;
  Result.DeclaredClass := DeclaredClass;
  Result.PropertyName := PropertyName;
  Result.Bounds := Bounds;
  Result.HasSize := HasSize;
  Result.TabOrder := TabOrder;
  Result.HasTabOrder := HasTabOrder;
end;

function TPreservedPiece.Describe: string;
begin
  if Kind = pkProperty then
    Result := Format('%s.%s', [OwnerName, PropertyName])
  else if ComponentName = '' then
    Result := DeclaredClass
  else
    Result := Format('%s: %s', [ComponentName, DeclaredClass]);
end;

{ TDesignPlaceholder }

constructor TDesignPlaceholder.CreateFor(APiece: TPreservedPiece);
begin
  inherited Create(nil);
  FPiece := APiece;
  TComponentAccess(Self).SetDesigning(True);
  Width := PlaceholderTileSize;
  Height := PlaceholderTileSize;
end;

procedure TDesignPlaceholder.Paint;
begin
  PaintPlaceholder(Canvas, ClientRect, FPiece.Describe);
end;

constructor TWindowedPlaceholder.CreateFor(APiece: TPreservedPiece);
begin
  inherited Create(nil);
  FPiece := APiece;
  TComponentAccess(Self).SetDesigning(True);
  ControlStyle := ControlStyle + [csOpaque];
  StyleElements := [];
  Width := PlaceholderTileSize;
  Height := PlaceholderTileSize;
end;

procedure TWindowedPlaceholder.Paint;
begin
  PaintPlaceholder(Canvas, ClientRect, FPiece.Describe);
end;

{ TPreservedModel }

constructor TPreservedModel.Create;
begin
  inherited Create;
  FPieces := TObjectList<TPreservedPiece>.Create(True);
  FPlaceholders := TObjectList<TControl>.Create(True);
  FReserved := TStringList.Create;
  FReserved.CaseSensitive := False;
  FReserved.Duplicates := dupIgnore;
  FReserved.Sorted := True;
end;

destructor TPreservedModel.Destroy;
begin
  FPlaceholders.Free;
  FReserved.Free;
  FPieces.Free;
  inherited Destroy;
end;

function TPreservedModel.GetCount: Integer;
begin
  Result := FPieces.Count;
end;

function TPreservedModel.GetPiece(AIndex: Integer): TPreservedPiece;
begin
  Result := FPieces[AIndex];
end;

procedure TPreservedModel.Add(APiece: TPreservedPiece);
begin
  FPieces.Add(APiece);
end;

procedure TPreservedModel.ReserveName(const AName: string);
begin
  if AName <> '' then
    FReserved.Add(AName);
end;

function TPreservedModel.IsReservedName(const AName: string): Boolean;
var
  Index: Integer;
begin
  Result := FReserved.Find(AName, Index);
end;

function TPreservedModel.Clone: TPreservedModel;
var
  Piece: TPreservedPiece;
  I: Integer;
begin
  Result := TPreservedModel.Create;
  for Piece in FPieces do
    Result.FPieces.Add(Piece.Clone);
  for I := 0 to FReserved.Count - 1 do
    Result.FReserved.Add(FReserved[I]);
end;

function TPreservedModel.Insertions: TArray<TDfmInsertion>;
var
  I: Integer;
  Piece: TPreservedPiece;
begin
  SetLength(Result, FPieces.Count);
  for I := 0 to FPieces.Count - 1 do
  begin
    Piece := FPieces[I];
    if Piece.Kind = pkBlock then
      Result[I].Kind := dikBlock
    else
      Result[I].Kind := dikProperty;
    Result[I].Owner := Piece.OwnerName;
    Result[I].Index := Piece.Index;
    Result[I].Text := Piece.Text;
  end;
end;

procedure TPreservedModel.BuildPlaceholders(ARoot: TComponent;
  ASurface: TWinControl);
var
  Piece: TPreservedPiece;
  Placeholder: TControl;
  Container: TComponent;
  Parent: TWinControl;
begin
  FPlaceholders.Clear;
  for Piece in FPieces do
  begin
    if Piece.Kind <> pkBlock then
      Continue;
    Parent := ASurface;
    if not SameText(Piece.OwnerName, ARoot.Name) then
    begin
      Container := ARoot.FindComponent(Piece.OwnerName);
      if Container is TWinControl then
        Parent := TWinControl(Container);
    end;
    if Parent = nil then
      Continue;
    if Piece.HasTabOrder then
      Placeholder := TWindowedPlaceholder.CreateFor(Piece)
    else
      Placeholder := TDesignPlaceholder.CreateFor(Piece);
    FPlaceholders.Add(Placeholder);
    Placeholder.Parent := Parent;
    if Piece.HasSize then
      Placeholder.BoundsRect := Piece.Bounds
    else
      Placeholder.SetBounds(Piece.Bounds.Left, Piece.Bounds.Top,
        PlaceholderTileSize, PlaceholderTileSize);
    // Parenting appends the control at the end of the tab list, so TabOrder
    // must be assigned afterwards to move it to the slot the file names.
    if Placeholder is TWindowedPlaceholder then
      TWindowedPlaceholder(Placeholder).TabOrder := Piece.TabOrder;
  end;
end;

function TPreservedModel.PlaceholderNamed(const AName: string): TControl;
var
  Placeholder: TControl;
  Piece: TPreservedPiece;
begin
  if AName <> '' then
    for Placeholder in FPlaceholders do
    begin
      Piece := PlaceholderPiece(Placeholder);
      if (Piece <> nil) and SameText(Piece.ComponentName, AName) then
        Exit(Placeholder);
    end;
  Result := nil;
end;

procedure TPreservedModel.DropPiece(APiece: TPreservedPiece);
var
  I: Integer;
begin
  for I := FPlaceholders.Count - 1 downto 0 do
    if PlaceholderPiece(FPlaceholders[I]) = APiece then
      FPlaceholders.Delete(I);
  FPieces.Remove(APiece);
end;

function NamesContain(const ANames: TArray<string>; const AName: string): Boolean;
var
  Candidate: string;
begin
  for Candidate in ANames do
    if SameText(Candidate, AName) then
      Exit(True);
  Result := False;
end;

procedure TPreservedModel.DropOwnedBy(const AOwnerNames: TArray<string>);
var
  I: Integer;
begin
  for I := FPieces.Count - 1 downto 0 do
    if NamesContain(AOwnerNames, FPieces[I].OwnerName) then
      DropPiece(FPieces[I]);
end;

procedure TPreservedModel.ReleasePlaceholdersIn(AControl: TWinControl);
var
  I: Integer;

  function SitsInside(AParent: TWinControl): Boolean;
  begin
    Result := False;
    while AParent <> nil do
    begin
      if AParent = AControl then
        Exit(True);
      AParent := AParent.Parent;
    end;
  end;

begin
  for I := FPlaceholders.Count - 1 downto 0 do
    if SitsInside(FPlaceholders[I].Parent) then
      DropPiece(PlaceholderPiece(FPlaceholders[I]));
end;

end.
