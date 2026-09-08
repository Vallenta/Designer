// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Shell.AlignDialogs;

// Modal dialogs for the group commands: align, same size, tab order and
// creation order. Each dialog is built in code rather than from a form
// resource, runs with ShowModal, and reports the selected values only;
// designed components are read but never modified here. Main thread only.

interface

uses
  System.Classes,
  Vallenta.FormEditor.Surface.FormDesigner;

// Prompts for a horizontal and a vertical align action, both defaulting to no
// change. False when cancelled, with AHorizontal ahNone and AVertical avNone.
function ExecuteAlignDialog(out AHorizontal: TAlignHorizontal;
  out AVertical: TAlignVertical): Boolean;
// Prompts for the dimensions to take from the primary selection. A dimension
// left unchecked stays smNone, as do both when cancelled.
function ExecuteSizeDialog(out AWidth, AHeight: TSizeMatch): Boolean;
// Prompts for an order over AItems, listed as "Name: ClassName" and moved with
// Up and Down buttons. ACaption is the window caption, ADescription the label
// above the list; AOrder returns the same instances in the chosen order and is
// nil when cancelled.
function ExecuteOrderDialog(const ACaption, ADescription: string;
  const AItems: TArray<TComponent>; out AOrder: TArray<TComponent>): Boolean;

implementation

uses
  System.SysUtils,
  System.UITypes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ExtCtrls;

const
  // Choice captions, one per alignment value.
  HorizontalCaptions: array [TAlignHorizontal] of string = ('No change',
    'Left sides', 'Centers', 'Right sides', 'Space equally', 'Center in window');
  VerticalCaptions: array [TAlignVertical] of string = ('No change', 'Tops',
    'Middles', 'Bottoms', 'Space equally', 'Center in window');

  // Dialog layout, in pixels.
  DialogMargin = 12;
  ButtonWidth = 80;
  ButtonHeight = 25;

type
  // The form and the two buttons BuildDialog hands back to its caller.
  TDialogParts = record
    Form: TForm;
    OK: TButton;
    Cancel: TButton;
  end;

  // Form class for the order dialog: the Up and Down buttons need methods
  // to assign to OnClick.
  TOrderDialogForm = class(TForm)
  private
    FList: TListBox;
    procedure MoveSelected(ABy: Integer);
    procedure UpClick(Sender: TObject);
    procedure DownClick(Sender: TObject);
  end;

procedure TOrderDialogForm.MoveSelected(ABy: Integer);
var
  Index: Integer;
begin
  Index := FList.ItemIndex;
  if (Index < 0) or (Index + ABy < 0) or (Index + ABy >= FList.Count) then
    Exit;
  FList.Items.Move(Index, Index + ABy);
  FList.ItemIndex := Index + ABy;
end;

procedure TOrderDialogForm.UpClick(Sender: TObject);
begin
  MoveSelected(-1);
end;

procedure TOrderDialogForm.DownClick(Sender: TObject);
begin
  MoveSelected(1);
end;

function BuildDialog(const ACaption: string; AWidth, AContentHeight: Integer): TDialogParts;
begin
  Result.Form := TForm.CreateNew(nil);
  Result.Form.Caption := ACaption;
  Result.Form.BorderStyle := bsDialog;
  Result.Form.Position := poScreenCenter;
  Result.Form.ClientWidth := AWidth;
  Result.Form.ClientHeight := AContentHeight + DialogMargin + ButtonHeight +
    DialogMargin;

  Result.OK := TButton.Create(Result.Form);
  Result.OK.Parent := Result.Form;
  Result.OK.Caption := 'OK';
  Result.OK.Default := True;
  Result.OK.ModalResult := mrOk;
  Result.OK.SetBounds(AWidth - 2 * ButtonWidth - DialogMargin - 8,
    AContentHeight + DialogMargin, ButtonWidth, ButtonHeight);

  Result.Cancel := TButton.Create(Result.Form);
  Result.Cancel.Parent := Result.Form;
  Result.Cancel.Caption := 'Cancel';
  Result.Cancel.Cancel := True;
  Result.Cancel.ModalResult := mrCancel;
  Result.Cancel.SetBounds(AWidth - ButtonWidth - DialogMargin,
    AContentHeight + DialogMargin, ButtonWidth, ButtonHeight);
end;

function ExecuteAlignDialog(out AHorizontal: TAlignHorizontal;
  out AVertical: TAlignVertical): Boolean;
var
  Parts: TDialogParts;
  Horizontal, Vertical: TRadioGroup;
  Caption: string;
begin
  AHorizontal := ahNone;
  AVertical := avNone;
  Parts := BuildDialog('Align', 340, 170);
  try
    Horizontal := TRadioGroup.Create(Parts.Form);
    Horizontal.Parent := Parts.Form;
    Horizontal.Caption := 'Horizontal';
    Horizontal.SetBounds(DialogMargin, DialogMargin, 150, 158);
    for Caption in HorizontalCaptions do
      Horizontal.Items.Add(Caption);
    Horizontal.ItemIndex := 0;

    Vertical := TRadioGroup.Create(Parts.Form);
    Vertical.Parent := Parts.Form;
    Vertical.Caption := 'Vertical';
    Vertical.SetBounds(178, DialogMargin, 150, 158);
    for Caption in VerticalCaptions do
      Vertical.Items.Add(Caption);
    Vertical.ItemIndex := 0;

    Result := Parts.Form.ShowModal = mrOk;
    if Result then
    begin
      AHorizontal := TAlignHorizontal(Horizontal.ItemIndex);
      AVertical := TAlignVertical(Vertical.ItemIndex);
    end;
  finally
    Parts.Form.Free;
  end;
end;

function ExecuteSizeDialog(out AWidth, AHeight: TSizeMatch): Boolean;
var
  Parts: TDialogParts;
  MatchWidth, MatchHeight: TCheckBox;
  Note: TLabel;
begin
  AWidth := smNone;
  AHeight := smNone;
  Parts := BuildDialog('Same Size', 300, 100);
  try
    Note := TLabel.Create(Parts.Form);
    Note.Parent := Parts.Form;
    Note.Caption := 'Take the size from the component selected last.';
    Note.SetBounds(DialogMargin, DialogMargin, 270, 15);

    MatchWidth := TCheckBox.Create(Parts.Form);
    MatchWidth.Parent := Parts.Form;
    MatchWidth.Caption := 'Same width';
    MatchWidth.SetBounds(DialogMargin, 44, 150, 20);

    MatchHeight := TCheckBox.Create(Parts.Form);
    MatchHeight.Parent := Parts.Form;
    MatchHeight.Caption := 'Same height';
    MatchHeight.SetBounds(DialogMargin, 70, 150, 20);

    Result := Parts.Form.ShowModal = mrOk;
    if Result then
    begin
      if MatchWidth.Checked then
        AWidth := smFromPrimary;
      if MatchHeight.Checked then
        AHeight := smFromPrimary;
    end;
  finally
    Parts.Form.Free;
  end;
end;

function ExecuteOrderDialog(const ACaption, ADescription: string;
  const AItems: TArray<TComponent>; out AOrder: TArray<TComponent>): Boolean;
var
  Dialog: TOrderDialogForm;
  Up, Down, OK, Cancel: TButton;
  Note: TLabel;
  Item: TComponent;
  I, ButtonRow: Integer;
begin
  AOrder := nil;
  ButtonRow := 250 + DialogMargin;
  Dialog := TOrderDialogForm.CreateNew(nil);
  try
    Dialog.Caption := ACaption;
    Dialog.BorderStyle := bsDialog;
    Dialog.Position := poScreenCenter;
    Dialog.ClientWidth := 340;
    Dialog.ClientHeight := ButtonRow + ButtonHeight + DialogMargin;

    Note := TLabel.Create(Dialog);
    Note.Parent := Dialog;
    Note.Caption := ADescription;
    Note.SetBounds(DialogMargin, DialogMargin, 310, 15);

    Dialog.FList := TListBox.Create(Dialog);
    Dialog.FList.Parent := Dialog;
    Dialog.FList.SetBounds(DialogMargin, 34, 220, 216);
    for Item in AItems do
      Dialog.FList.Items.AddObject(Format('%s: %s', [Item.Name, Item.ClassName]),
        Item);
    if Dialog.FList.Count > 0 then
      Dialog.FList.ItemIndex := 0;

    Up := TButton.Create(Dialog);
    Up.Parent := Dialog;
    Up.Caption := 'Up';
    Up.SetBounds(244, 34, ButtonWidth, ButtonHeight);
    Up.OnClick := Dialog.UpClick;

    Down := TButton.Create(Dialog);
    Down.Parent := Dialog;
    Down.Caption := 'Down';
    Down.SetBounds(244, 34 + ButtonHeight + 6, ButtonWidth, ButtonHeight);
    Down.OnClick := Dialog.DownClick;

    OK := TButton.Create(Dialog);
    OK.Parent := Dialog;
    OK.Caption := 'OK';
    OK.Default := True;
    OK.ModalResult := mrOk;
    OK.SetBounds(340 - 2 * ButtonWidth - DialogMargin - 8, ButtonRow,
      ButtonWidth, ButtonHeight);

    Cancel := TButton.Create(Dialog);
    Cancel.Parent := Dialog;
    Cancel.Caption := 'Cancel';
    Cancel.Cancel := True;
    Cancel.ModalResult := mrCancel;
    Cancel.SetBounds(340 - ButtonWidth - DialogMargin, ButtonRow, ButtonWidth,
      ButtonHeight);

    Result := Dialog.ShowModal = mrOk;
    if Result then
    begin
      SetLength(AOrder, Dialog.FList.Count);
      for I := 0 to Dialog.FList.Count - 1 do
        AOrder[I] := TComponent(Dialog.FList.Items.Objects[I]);
    end;
  finally
    Dialog.Free;
  end;
end;

end.
