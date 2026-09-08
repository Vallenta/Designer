// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Shell.RecoveryDialog;

// Modal dialog over the documents an earlier session left unsaved: one row
// per entry, with the buttons Recover, Discard and Close. Built in code with
// no form resource and shown through ShowModal, so main thread only. Reports
// the button pressed and the entries selected; performs no recovery itself.

interface

uses
  Vallenta.FormEditor.Core.Recovery;

type
  // Outcome of the dialog: rcNothing when neither Recover nor Discard was
  // pressed.
  TRecoveryChoice = (rcNothing, rcRecover, rcDiscard);

// Runs the dialog modally with every row selected to begin with, and returns
// the button pressed together with the entries still selected. AChosen is
// empty when the result is rcNothing.
function ExecuteRecoveryDialog(const AEntries: TArray<TRecoveryEntry>;
  out AChosen: TArray<TRecoveryEntry>): TRecoveryChoice;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.UITypes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ComCtrls;

const
  // Dialog layout, in pixels.
  DialogMargin = 12;
  ButtonWidth = 90;
  ButtonHeight = 25;
  DialogWidth = 660;
  ListHeight = 240;
  NoteHeight = 48;

type
  TRecoveryDialogForm = class(TForm)
  private
    FList: TListView;
    FChoice: TRecoveryChoice;
    FRecover: TButton;
    FDiscard: TButton;
    procedure Answer(AChoice: TRecoveryChoice);
    procedure RecoverClick(Sender: TObject);
    procedure DiscardClick(Sender: TObject);
    procedure SelectionChanged(Sender: TObject; AItem: TListItem;
      AChange: TItemChange);
  end;

procedure TRecoveryDialogForm.Answer(AChoice: TRecoveryChoice);
begin
  FChoice := AChoice;
  ModalResult := mrOk;
end;

procedure TRecoveryDialogForm.RecoverClick(Sender: TObject);
begin
  Answer(rcRecover);
end;

procedure TRecoveryDialogForm.DiscardClick(Sender: TObject);
begin
  Answer(rcDiscard);
end;

procedure TRecoveryDialogForm.SelectionChanged(Sender: TObject;
  AItem: TListItem; AChange: TItemChange);
begin
  FRecover.Enabled := FList.SelCount > 0;
  FDiscard.Enabled := FRecover.Enabled;
end;

function CapturedText(const AEntry: TRecoveryEntry): string;
begin
  if AEntry.CapturedAt = 0 then
    Exit('(not recorded)');
  Result := DateTimeToStr(AEntry.CapturedAt);
end;

function ExecuteRecoveryDialog(const AEntries: TArray<TRecoveryEntry>;
  out AChosen: TArray<TRecoveryEntry>): TRecoveryChoice;
var
  Dialog: TRecoveryDialogForm;
  Note: TLabel;
  Dismiss: TButton;
  Row: TListItem;
  ButtonRow, ListTop, I: Integer;

  procedure Column(const ACaption: string; AWidth: Integer);
  var
    Added: TListColumn;
  begin
    Added := Dialog.FList.Columns.Add;
    Added.Caption := ACaption;
    Added.Width := AWidth;
  end;

  function Button(const ACaption: string; ALeft: Integer): TButton;
  begin
    Result := TButton.Create(Dialog);
    Result.Parent := Dialog;
    Result.Caption := ACaption;
    Result.SetBounds(ALeft, ButtonRow, ButtonWidth, ButtonHeight);
  end;

begin
  AChosen := nil;
  ListTop := DialogMargin + NoteHeight + DialogMargin;
  ButtonRow := ListTop + ListHeight + DialogMargin;
  Dialog := TRecoveryDialogForm.CreateNew(nil);
  try
    Dialog.Caption := 'Vallenta Designer - unsaved work from an earlier session';
    Dialog.BorderStyle := bsDialog;
    Dialog.Position := poScreenCenter;
    Dialog.ClientWidth := DialogWidth;
    Dialog.ClientHeight := ButtonRow + ButtonHeight + DialogMargin;

    Note := TLabel.Create(Dialog);
    Note.Parent := Dialog;
    // AutoSize must stay off: a later caption or font change, including DPI
    // scaling, re-runs AdjustBounds, which keeps the width and replaces the
    // height with the height of the full text.
    Note.AutoSize := False;
    Note.WordWrap := True;
    Note.Caption := 'These forms had unsaved changes when the designer last ' +
      'ended. Recover opens the selected ones with those changes and writes ' +
      'nothing until you save them yourself; Discard throws their copies ' +
      'away. Whatever is left over is offered again next time.';
    Note.SetBounds(DialogMargin, DialogMargin,
      DialogWidth - 2 * DialogMargin, NoteHeight);

    Dialog.FList := TListView.Create(Dialog);
    Dialog.FList.Parent := Dialog;
    Dialog.FList.ViewStyle := vsReport;
    Dialog.FList.RowSelect := True;
    Dialog.FList.MultiSelect := True;
    Dialog.FList.ReadOnly := True;
    Dialog.FList.HideSelection := False;
    Dialog.FList.SetBounds(DialogMargin, ListTop,
      DialogWidth - 2 * DialogMargin, ListHeight);
    Column('Form', 170);
    Column('Unsaved since', 140);
    Column('Where it belongs', 310);

    for I := 0 to High(AEntries) do
    begin
      Row := Dialog.FList.Items.Add;
      Row.Caption := ExtractFileName(AEntries[I].SourceFile);
      Row.SubItems.Add(CapturedText(AEntries[I]));
      Row.SubItems.Add(ExtractFilePath(AEntries[I].SourceFile));
      Row.Data := Pointer(NativeInt(I));
    end;
    Dialog.FList.SelectAll;

    Dialog.FRecover := Button('Recover', DialogMargin);
    Dialog.FRecover.OnClick := Dialog.RecoverClick;
    Dialog.FRecover.Default := True;
    Dialog.FDiscard := Button('Discard', DialogMargin + ButtonWidth + 8);
    Dialog.FDiscard.OnClick := Dialog.DiscardClick;
    Dismiss := Button('Close', DialogWidth - ButtonWidth - DialogMargin);
    Dismiss.Cancel := True;
    Dismiss.ModalResult := mrCancel;
    // The list fires OnChange while rows are added and selected, and
    // SelectionChanged dereferences both buttons, which must exist by then.
    Dialog.FList.OnChange := Dialog.SelectionChanged;
    Dialog.SelectionChanged(Dialog.FList, nil, ctState);

    Dialog.ShowModal;
    Result := Dialog.FChoice;
    if Result = rcNothing then
      Exit;
    for I := 0 to Dialog.FList.Items.Count - 1 do
      if Dialog.FList.Items[I].Selected then
        AChosen := AChosen + [AEntries[NativeInt(Dialog.FList.Items[I].Data)]];
  finally
    Dialog.Free;
  end;
end;

end.
