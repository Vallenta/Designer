// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Inspector.Grid;

// Two-column grid over a TPropertyModel, one grid row per visible model row.
// An overlay control edits the value cell of the selected row: an edit box, a
// drop-down for a row with a pick list, an ellipsis button for a row with a
// dialog. Enter, a row change and focus loss apply the text, Escape discards
// it. Main thread only, as for every VCL control.
//
// The model is referenced, not owned. CancelEdit must run before the model's
// rows are freed: the open editor and a pending method-list request both hold
// a row reference.

interface

uses
  Winapi.Messages,
  System.Classes,
  System.Types,
  Vcl.Controls,
  Vcl.Grids,
  Vcl.StdCtrls,
  Vcl.Graphics,
  Vallenta.FormEditor.Inspector.PropertyModel;

type
  // Draw grid over a TPropertyModel with overlay editors on the value column.
  TPropertyGrid = class(TDrawGrid)
  private
    FModel: TPropertyModel;
    FEdit: TEdit;
    FCombo: TComboBox;
    FEllipsis: TButton;
    FEditingRow: TPropertyRow;
    FReadOnly: Boolean;
    FOnBeforeChange: TNotifyEvent;
    FOnValueChanged: TNotifyEvent;
    FOnInvalidValue: TNotifyEvent;
    FOnEditorInvoked: TNotifyEvent;
    FOnEditCancelled: TNotifyEvent;
    FOnEditPending: TNotifyEvent;
    FInvalidName: string;
    FInvalidMessage: string;
    FSilentEditName: string;
    FSawWindow: Boolean;
    FPreviousModalBegin: TNotifyEvent;
    FMethodsRow: TPropertyRow;
    FMethodsAsked: Integer;
    procedure ModalSeen(Sender: TObject);
    procedure HideEditors;
    procedure ShowEditorFor(Row: TPropertyRow);
    procedure AskForMethods(Row: TPropertyRow);
    procedure MethodsArrived(ARequest: Integer; const AMethods: TArray<string>);
    procedure ActivateRow(Row: TPropertyRow);
    procedure ApplyEditor;
    procedure ApplyRowValue(Row: TPropertyRow; const Text: string);
    procedure ReportEditFailure(Row: TPropertyRow; const AMessage: string);
    procedure EllipsisClicked(Sender: TObject);
    procedure RunRowDialog(Row: TPropertyRow);
    procedure EditKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure EditorExit(Sender: TObject);
    procedure ComboSelected(Sender: TObject);
    function RowAt(Index: Integer): TPropertyRow;
    function ExpanderRect(const CellRect: TRect; Row: TPropertyRow): TRect;
  protected
    // Reflects an overlay control's notification back to it as a CN_ message.
    // TCustomGrid.WMCommand acts only on its own inplace editor, so without
    // this the drop-down stays unsized and the ellipsis click is unreported.
    procedure WMCommand(var Message: TWMCommand); message WM_COMMAND;
    procedure DrawCell(ACol, ARow: Integer; ARect: TRect;
      AState: TGridDrawState); override;
    // Reapplies the control font to the canvas before the inherited paint.
    // Without it the cells paint in a twice-scaled font once the grid has been
    // reparented into a window at another DPI.
    procedure Paint; override;
    procedure Click; override;
    procedure DblClick; override;
    procedure Resize; override;
    procedure ColWidthsChanged; override;
    function SelectCell(ACol, ARow: Integer): Boolean; override;
  public
    constructor Create(AOwner: TComponent); override;
    // Shows AModel and sets the row count from it; nil or a model without
    // visible rows leaves one empty row. Any open editor is discarded first.
    procedure ShowModel(AModel: TPropertyModel);
    // Hides the editor overlay and discards the typed text. Must run before
    // the model's rows are freed; the overlay refers to one of them.
    procedure CancelEdit;
    // Repaints the cells after values changed elsewhere; row count, expansion
    // state and selection stay as they are.
    procedure RefreshValues;
    // Model currently shown; nil until the first ShowModel. Not owned.
    property Model: TPropertyModel read FModel;
    // Name of the row of the last refused edit. Written before OnInvalidValue
    // and not cleared afterwards.
    property InvalidName: string read FInvalidName;
    // Reason the last edit was refused; empty when the row reported none.
    property InvalidMessage: string read FInvalidMessage;
    // True suppresses the overlay editors. Rows still select, expand and run
    // their double-click action.
    property ReadOnly: Boolean read FReadOnly write FReadOnly;
    // Raised before a write, a dialog run or a double-click action; the last
    // point at which the pre-edit state can be recorded for undo. Exactly one
    // of the five events below follows it.
    property OnBeforeChange: TNotifyEvent read FOnBeforeChange write FOnBeforeChange;
    // Raised after a write or a double-click action changed the document.
    property OnValueChanged: TNotifyEvent read FOnValueChanged write FOnValueChanged;
    // Raised when an edit was refused or raised an exception; InvalidName and
    // InvalidMessage describe it.
    property OnInvalidValue: TNotifyEvent read FOnInvalidValue write FOnInvalidValue;
    // Raised after a property editor's dialog changed the document. Such a
    // dialog may add or remove components, so the view must be rebuilt rather
    // than repainted.
    property OnEditorInvoked: TNotifyEvent read FOnEditorInvoked
      write FOnEditorInvoked;
    // Raised when a dialog run or a double-click action ended without a change
    // and without an error; the undo entry recorded for it covers no change.
    property OnEditCancelled: TNotifyEvent read FOnEditCancelled
      write FOnEditCancelled;
    // Raised when a rename went to the code editor and its answer is still
    // outstanding. The document is unchanged and the recorded undo entry is
    // neither committed nor dropped here.
    property OnEditPending: TNotifyEvent read FOnEditPending
      write FOnEditPending;
    // Name of the row whose last dialog run opened no window and reported no
    // change, marking a property editor whose dialog cannot open in this
    // process. Empty otherwise; cleared at the start of every dialog run.
    property SilentEditName: string read FSilentEditName;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Math,
  System.UITypes,
  Vcl.Forms,
  Vcl.Dialogs,
  Vallenta.FormEditor.Core.Coupling;

const
  // Name-column layout, in pixels.
  IndentStep = 12;
  ExpanderSize = 9;

constructor TPropertyGrid.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ColCount := 2;
  RowCount := 1;
  FixedCols := 0;
  FixedRows := 0;
  DefaultRowHeight := 19;
  Options := [goVertLine, goHorzLine, goRowSelect, goThumbTracking];
  ScrollBars := ssVertical;
  BorderStyle := bsNone;
  DefaultDrawing := False;
  // DefaultDrawing is off, so an Invalidate repaints every cell by hand; a
  // drag on the design surface invalidates the grid on each geometry change.
  DoubleBuffered := True;

  FEdit := TEdit.Create(Self);
  FEdit.Parent := Self;
  FEdit.Visible := False;
  FEdit.BorderStyle := bsNone;
  FEdit.OnKeyDown := EditKeyDown;
  FEdit.OnExit := EditorExit;

  FCombo := TComboBox.Create(Self);
  FCombo.Parent := Self;
  FCombo.Visible := False;
  FCombo.Style := csDropDownList;
  FCombo.OnKeyDown := EditKeyDown;
  FCombo.OnExit := EditorExit;
  FCombo.OnSelect := ComboSelected;

  FEllipsis := TButton.Create(Self);
  FEllipsis.Parent := Self;
  FEllipsis.Visible := False;
  FEllipsis.Caption := '...';
  FEllipsis.TabStop := False;
  FEllipsis.OnClick := EllipsisClicked;
end;

procedure TPropertyGrid.ShowModel(AModel: TPropertyModel);
begin
  HideEditors;
  FModel := AModel;
  if (FModel = nil) or (FModel.VisibleCount = 0) then
    RowCount := 1
  else
    RowCount := FModel.VisibleCount;
  Resize;
  Invalidate;
end;

procedure TPropertyGrid.Resize;
begin
  inherited Resize;
  if ColCount <> 2 then
    Exit;
  ColWidths[0] := Max(90, ClientWidth div 2);
  ColWidths[1] := Max(60, ClientWidth - ColWidths[0] - 2);
end;

procedure TPropertyGrid.CancelEdit;
begin
  HideEditors;
end;

procedure TPropertyGrid.RefreshValues;
begin
  Invalidate;
end;

function TPropertyGrid.RowAt(Index: Integer): TPropertyRow;
begin
  Result := nil;
  if (FModel = nil) or (Index < 0) or (Index >= FModel.VisibleCount) then
    Exit;
  Result := FModel[Index];
end;

function TPropertyGrid.ExpanderRect(const CellRect: TRect; Row: TPropertyRow): TRect;
begin
  Result := TRect.Create(
    CellRect.Left + 2 + Row.Level * IndentStep,
    CellRect.Top + (CellRect.Height - ExpanderSize) div 2,
    CellRect.Left + 2 + Row.Level * IndentStep + ExpanderSize,
    CellRect.Top + (CellRect.Height - ExpanderSize) div 2 + ExpanderSize);
end;

procedure TPropertyGrid.DrawCell(ACol, ARow: Integer; ARect: TRect;
  AState: TGridDrawState);
var
  Row: TPropertyRow;
  Text: string;
  TextLeft: Integer;
  Box: TRect;
begin
  Row := RowAt(ARow);
  Canvas.Brush.Color := clWindow;
  if (Row <> nil) and (gdSelected in AState) then
    Canvas.Brush.Color := clBtnFace;
  Canvas.FillRect(ARect);
  if Row = nil then
    Exit;

  Canvas.Font.Color := clWindowText;
  if ACol = 0 then
  begin
    TextLeft := ARect.Left + 4 + Row.Level * IndentStep;
    if Row.Expandable then
    begin
      Box := ExpanderRect(ARect, Row);
      Canvas.Brush.Color := clWindow;
      Canvas.Pen.Color := clGrayText;
      Canvas.Rectangle(Box);
      Canvas.MoveTo(Box.Left + 2, Box.CenterPoint.Y);
      Canvas.LineTo(Box.Right - 2, Box.CenterPoint.Y);
      if not Row.Expanded then
      begin
        Canvas.MoveTo(Box.CenterPoint.X, Box.Top + 2);
        Canvas.LineTo(Box.CenterPoint.X, Box.Bottom - 2);
      end;
      Inc(TextLeft, ExpanderSize + 2);
    end;
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(TextLeft, ARect.Top + 2, Row.Name);
    Canvas.Brush.Style := bsSolid;
  end
  else
  begin
    Text := Row.ValueText;
    if not Row.CanEdit then
      Canvas.Font.Color := clGrayText;
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(ARect.Left + 4, ARect.Top + 2, Text);
    Canvas.Brush.Style := bsSolid;
    Canvas.Font.Color := clWindowText;
  end;
end;

procedure TPropertyGrid.WMCommand(var Message: TWMCommand);
var
  Target: TWinControl;
begin
  if Message.Ctl <> 0 then
  begin
    Target := FindControl(Message.Ctl);
    if (Target = FCombo) or (Target = FEdit) or (Target = FEllipsis) then
    begin
      Message.Result := Target.Perform(Message.Msg + CN_BASE,
        TMessage(Message).WParam, TMessage(Message).LParam);
      Exit;
    end;
  end;
  inherited;
end;

procedure TPropertyGrid.Paint;
begin
  Canvas.Font := Font;
  inherited Paint;
end;

procedure TPropertyGrid.ColWidthsChanged;
begin
  inherited ColWidthsChanged;
  HideEditors;
end;

function TPropertyGrid.SelectCell(ACol, ARow: Integer): Boolean;
begin
  Result := inherited SelectCell(ACol, ARow);
  if Result and (ARow <> Row) then
    ApplyEditor;
end;

procedure TPropertyGrid.Click;
var
  Cell: TGridCoord;
  Point: TPoint;
  Current: TPropertyRow;
begin
  inherited Click;
  Point := ScreenToClient(Mouse.CursorPos);
  Cell := MouseCoord(Point.X, Point.Y);
  Current := RowAt(Cell.Y);
  if Current = nil then
    Exit;
  if Current.Expandable and (Cell.X = 0) and
     ExpanderRect(CellRect(0, Cell.Y), Current).Contains(Point) then
  begin
    HideEditors;
    FModel.ToggleExpanded(Current);
    ShowModel(FModel);
    Exit;
  end;
  if Cell.X = 1 then
    ShowEditorFor(Current);
end;

procedure TPropertyGrid.HideEditors;
begin
  FEditingRow := nil;
  FMethodsRow := nil;
  FEdit.Visible := False;
  FCombo.Visible := False;
  FEllipsis.Visible := False;
end;

procedure TPropertyGrid.ShowEditorFor(Row: TPropertyRow);
var
  Cell: TRect;
  Choices: TArray<string>;
  Choice: string;
begin
  HideEditors;
  if (Row = nil) or FReadOnly then
    Exit;
  if Row.HasDialog then
  begin
    FEditingRow := Row;
    Cell := CellRect(1, Self.Row);
    FEllipsis.SetBounds(Cell.Right - Cell.Height, Cell.Top + 1,
      Cell.Height - 2, Cell.Height - 2);
    FEllipsis.Visible := True;
  end;
  if not Row.CanEdit then
  begin
    if not FEllipsis.Visible then
      FEditingRow := nil;
    Exit;
  end;
  FEditingRow := Row;
  Cell := CellRect(1, Self.Row);
  if FEllipsis.Visible then
    Cell.Right := Cell.Right - Cell.Height;
  Choices := Row.PickList;
  if Length(Choices) > 0 then
  begin
    if Row.AllowsFreeText then
      FCombo.Style := csDropDown
    else
      FCombo.Style := csDropDownList;
    // VCL auto-complete fires OnSelect on the first matching keystroke, and
    // ComboSelected applies the value; a free-text row must not commit there.
    FCombo.AutoComplete := not Row.AllowsFreeText;
    FCombo.Items.BeginUpdate;
    try
      FCombo.Items.Clear;
      for Choice in Choices do
        FCombo.Items.Add(Choice);
    finally
      FCombo.Items.EndUpdate;
    end;
    FCombo.ItemIndex := FCombo.Items.IndexOf(Row.ValueText);
    if Row.AllowsFreeText then
      FCombo.Text := Row.ValueText;
    // Assigning a combo's Height sizes the dropped-down list, so only position
    // and width are set here.
    FCombo.Left := Cell.Left;
    FCombo.Top := Cell.Top + (Cell.Height - FCombo.Height) div 2;
    FCombo.Width := Cell.Width;
    FCombo.Visible := True;
    FCombo.SetFocus;
    AskForMethods(Row);
  end
  else
  begin
    FEdit.Text := Row.ValueText;
    FEdit.SetBounds(Cell.Left + 2, Cell.Top + 2, Cell.Width - 4, Cell.Height - 3);
    FEdit.Visible := True;
    FEdit.SetFocus;
    FEdit.SelectAll;
  end;
end;

procedure TPropertyGrid.AskForMethods(Row: TPropertyRow);
var
  Coupling: ICodeCoupling;
begin
  FMethodsRow := nil;
  if Row.Kind <> prkEvent then
    Exit;
  Coupling := Row.Coupling;
  if (Coupling = nil) or not Coupling.Available then
    Exit;
  Inc(FMethodsAsked);
  FMethodsRow := Row;
  Coupling.ListMethods(FMethodsAsked, Row.EventSignature, MethodsArrived);
end;

procedure TPropertyGrid.MethodsArrived(ARequest: Integer;
  const AMethods: TArray<string>);
var
  Name: string;
begin
  // A late answer must not reach a row that is no longer edited; HideEditors
  // clears FMethodsRow before the model holding the row is replaced.
  if (ARequest <> FMethodsAsked) or (FEditingRow = nil) or
     (FMethodsRow <> FEditingRow) or not FCombo.Visible then
    Exit;
  FEditingRow.OfferMethods(AMethods);
  for Name in AMethods do
    if FCombo.Items.IndexOf(Name) < 0 then
      FCombo.Items.Add(Name);
end;

procedure TPropertyGrid.ActivateRow(Row: TPropertyRow);
var
  Changed: Boolean;
begin
  if Row = nil then
    Exit;
  if not Row.CanActivate then
  begin
    if Row.Kind = prkEvent then
      ReportEditFailure(Row,
        'making or opening a handler needs VS Code attached to this document');
    Exit;
  end;
  HideEditors;
  if Assigned(FOnBeforeChange) then
    FOnBeforeChange(Self);

  try
    Changed := Row.Activate;
  except
    on E: Exception do
    begin
      ReportEditFailure(Row, Format('%s: %s', [E.ClassName, E.Message]));
      Exit;
    end;
  end;
  Invalidate;
  if Changed then
  begin
    if Assigned(FOnValueChanged) then
      FOnValueChanged(Self);
  end
  else if Assigned(FOnEditCancelled) then
    FOnEditCancelled(Self);
end;

procedure TPropertyGrid.DblClick;
begin
  inherited DblClick;
  ActivateRow(RowAt(Row));
end;

procedure TPropertyGrid.ReportEditFailure(Row: TPropertyRow;
  const AMessage: string);
begin
  FInvalidName := Row.Name;
  FInvalidMessage := AMessage;
  HideEditors;
  Invalidate;
  if Assigned(FOnInvalidValue) then
    FOnInvalidValue(Self);
end;

procedure TPropertyGrid.ApplyRowValue(Row: TPropertyRow; const Text: string);
var
  Applied: Boolean;
begin
  if Assigned(FOnBeforeChange) then
    FOnBeforeChange(Self);
  try
    Applied := Row.SetValueText(Text);
  except
    on E: Exception do
    begin
      ReportEditFailure(Row, Format('%s: %s', [E.ClassName, E.Message]));
      Exit;
    end;
  end;
  if not Applied then
  begin
    ReportEditFailure(Row, Row.LastError);
    Exit;
  end;
  HideEditors;
  Invalidate;
  if Row.Waiting then
  begin
    if Assigned(FOnEditPending) then
      FOnEditPending(Self);
    Exit;
  end;
  if Assigned(FOnValueChanged) then
    FOnValueChanged(Self);
end;

procedure TPropertyGrid.ModalSeen(Sender: TObject);
begin
  FSawWindow := True;
  if Assigned(FPreviousModalBegin) then
    FPreviousModalBegin(Sender);
end;

procedure TPropertyGrid.RunRowDialog(Row: TPropertyRow);
var
  Changed: Boolean;
  FormsBefore: Integer;
begin
  if (Row = nil) or not Row.HasDialog then
    Exit;

  HideEditors;
  if Assigned(FOnBeforeChange) then
    FOnBeforeChange(Self);
  FSilentEditName := '';
  FSawWindow := False;
  FormsBefore := Screen.FormCount;
  FPreviousModalBegin := Application.OnModalBegin;
  Application.OnModalBegin := ModalSeen;
  try
    try
      Changed := Row.EditValue;
    finally
      Application.OnModalBegin := FPreviousModalBegin;
      FPreviousModalBegin := nil;
    end;
  except
    on E: Exception do
    begin
      ReportEditFailure(Row, Format('%s: %s', [E.ClassName, E.Message]));
      Exit;
    end;
  end;
  Invalidate;
  if Changed then
  begin
    if Assigned(FOnEditorInvoked) then
      FOnEditorInvoked(Self);
    Exit;
  end;
  if Row.LastError = '' then
  begin
    if not FSawWindow and (Screen.FormCount = FormsBefore) then
      FSilentEditName := Row.Name;
    if Assigned(FOnEditCancelled) then
      FOnEditCancelled(Self);
    Exit;
  end;
  ReportEditFailure(Row, Row.LastError);
end;

procedure TPropertyGrid.EllipsisClicked(Sender: TObject);
begin
  RunRowDialog(FEditingRow);
  if CanFocus then
    SetFocus;
end;

procedure TPropertyGrid.ApplyEditor;
var
  Row: TPropertyRow;
  Text: string;
  Dialog: TColorDialog;
begin
  if FEditingRow = nil then
    Exit;
  Row := FEditingRow;
  if FCombo.Visible then
    Text := FCombo.Text
  else
    Text := FEdit.Text;
  if (Row.Kind = prkColor) and (Text = CustomColorItem) then
  begin
    FEditingRow := nil;
    HideEditors;
    Dialog := TColorDialog.Create(Self);
    try
      Dialog.Color := Row.AsColor;
      if not Dialog.Execute then
        Exit;
      Text := IntToStr(Dialog.Color);
    finally
      Dialog.Free;
    end;
    ApplyRowValue(Row, Text);
    Exit;
  end;
  // Cleared before the write: a focus change caused by the write re-enters
  // this routine, which would otherwise apply the value a second time.
  FEditingRow := nil;
  if Text = Row.ValueText then
  begin
    HideEditors;
    Exit;
  end;
  ApplyRowValue(Row, Text);
end;

procedure TPropertyGrid.EditKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  case Key of
    VK_RETURN:
      begin
        Key := 0;
        ApplyEditor;
        SetFocus;
      end;
    VK_ESCAPE:
      begin
        Key := 0;
        HideEditors;
        SetFocus;
      end;
  end;
end;

procedure TPropertyGrid.EditorExit(Sender: TObject);
begin
  // Applying while focus moves to the ellipsis would hide the button between
  // mouse press and release, so its click would never complete.
  if Screen.ActiveControl = FEllipsis then
    Exit;
  ApplyEditor;
end;

procedure TPropertyGrid.ComboSelected(Sender: TObject);
begin
  ApplyEditor;
  if CanFocus then
    SetFocus;
end;

end.
