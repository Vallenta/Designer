// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Packages.ManagerDialog;

// The Tools, Packages dialog: lists every configured and installed package
// with its load state, and on OK writes the configured list and the
// switched-off list to the package settings below HKEY_CURRENT_USER. The
// IDE's list of installed packages is read, never written. Shown modally on
// the VCL main thread; the form is built in code, without a .dfm.
//
// Changes take effect at the next start; no package is loaded or unloaded
// mid-session.

interface

// Shows the manager modally. True when the settings were written; False on
// Cancel and when the registry write fails, which is logged with its reason.
function ExecutePackageManager: Boolean;

implementation

uses
  System.Classes,
  System.SysUtils,
  System.Math,
  System.UITypes,
  Vcl.Controls,
  Vcl.Dialogs,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ComCtrls,
  Vallenta.FormEditor.Core.Settings,
  Vallenta.FormEditor.Shell.Layout,
  Vallenta.FormEditor.Packages.Discovery,
  Vallenta.FormEditor.Packages.Host;

const
  // Dialog and control geometry, in pixels.
  DialogMargin = 12;
  ButtonWidth = 80;
  ButtonHeight = 25;
  ListButtonWidth = 130;
  DialogWidth = 940;
  DialogHeight = 620;
  // Fits three wrapped lines of the note at DialogWidth.
  NoteHeight = 52;
  // Lower bound applied to the window size and to a loaded layout.
  MinDialogWidth = 520;
  MinDialogHeight = 340;
  // Index of the origin column; a row's configured state is held only in
  // this column's text.
  OriginColumn = 3;
  // Index of the path column, which is also the last column; a row's package
  // is identified by this column's text.
  PathColumn = 6;
  // Key below the settings root holding this dialog's size and column widths.
  DialogSettingsKey = 'PackagesDialog';

type
  // Caption and default width, in pixels, of one list column.
  TColumnSpec = record
    Caption: string;
    Width: Integer;
  end;

  // The manager dialog form; the list is filled from OnShow.
  TPackageDialogForm = class(TForm)
  private
    FList: TListView;
    FRemove: TButton;
    procedure DialogShown(Sender: TObject);
    procedure DialogClosed(Sender: TObject; var AAction: TCloseAction);
    procedure AddClick(Sender: TObject);
    procedure RemoveClick(Sender: TObject);
    procedure ListSelected(Sender: TObject; AItem: TListItem;
      ASelected: Boolean);
    function RowIndexOf(const APath: string): Integer;
    procedure ShowButtonsFor(AItem: TListItem);
  end;

const
  // The list columns in display order; OriginColumn and PathColumn index
  // into this array.
  Columns: array [0 .. PathColumn] of TColumnSpec = (
    (Caption: 'Package'; Width: 170),
    (Caption: 'Status'; Width: 120),
    (Caption: 'On palette'; Width: 70),
    (Caption: 'From'; Width: 70),
    (Caption: 'Description'; Width: 210),
    (Caption: 'Note'; Width: 220),
    (Caption: 'Path'; Width: 380));

// The sort must be stable over the configured entries: their order in the
// list is written back as the package load order.
function InReadingOrder(
  const AStatuses: TArray<TPackageStatus>): TArray<TPackageStatus>;
var
  Moved: TPackageStatus;
  I, J: Integer;

  function StandsBefore(const A, B: TPackageStatus): Boolean;
  begin
    if A.Origin <> B.Origin then
      Exit(A.Origin = poExplicit);
    if A.Origin = poExplicit then
      Exit(False);
    Result := CompareText(ExtractFileName(A.Path), ExtractFileName(B.Path)) < 0;
  end;

begin
  Result := Copy(AStatuses);
  for I := 1 to High(Result) do
    for J := I downto 1 do
    begin
      if not StandsBefore(Result[J], Result[J - 1]) then
        Break;
      Moved := Result[J];
      Result[J] := Result[J - 1];
      Result[J - 1] := Moved;
    end;
end;

procedure FillRow(AItem: TListItem; const AStatus: TPackageStatus);
var
  Palette: string;
begin
  if AStatus.PaletteCount > 0 then
    Palette := IntToStr(AStatus.PaletteCount)
  else
    Palette := '';
  AItem.Caption := ExtractFileName(AStatus.Path);
  AItem.Checked := AStatus.State <> psSwitchedOff;
  AItem.SubItems.Clear;
  AItem.SubItems.Add(PackageStateCaptions[AStatus.State]);
  AItem.SubItems.Add(Palette);
  AItem.SubItems.Add(OriginCaptions[AStatus.Origin]);
  AItem.SubItems.Add(AStatus.Description);
  AItem.SubItems.Add(AStatus.Detail);
  AItem.SubItems.Add(AStatus.Path);
end;

procedure FillList(AList: TListView);
var
  Status: TPackageStatus;
begin
  AList.Items.BeginUpdate;
  try
    AList.Items.Clear;
    for Status in InReadingOrder(SurveyPackages) do
      FillRow(AList.Items.Add, Status);
  finally
    AList.Items.EndUpdate;
  end;
end;

function IsConfigured(AItem: TListItem): Boolean;
begin
  Result := (AItem <> nil) and
    SameText(AItem.SubItems[OriginColumn - 1], OriginCaptions[poExplicit]);
end;

function PathOf(AItem: TListItem): string;
begin
  Result := AItem.SubItems[PathColumn - 1];
end;

function SwitchedOffPaths(AList: TListView): TArray<string>;
var
  I: Integer;
begin
  Result := [];
  for I := 0 to AList.Items.Count - 1 do
    if not AList.Items[I].Checked then
      Result := Result + [PathOf(AList.Items[I])];
end;

function ConfiguredPaths(AList: TListView): TArray<string>;
var
  I: Integer;
begin
  Result := [];
  for I := 0 to AList.Items.Count - 1 do
    if IsConfigured(AList.Items[I]) then
      Result := Result + [PathOf(AList.Items[I])];
end;

function InstalledEntry(const APath: string;
  out AEntry: TDiscoveredPackage): Boolean;
var
  Installed: TDiscoveredPackage;
begin
  for Installed in InstalledPackages do
    if SameText(Installed.Path, APath) then
    begin
      AEntry := Installed;
      Exit(True);
    end;
  Result := False;
end;

function DefaultLayout: TDialogLayout;
var
  I: Integer;
begin
  Result.Width := DialogWidth;
  Result.Height := DialogHeight;
  SetLength(Result.ColumnWidths, Length(Columns));
  for I := 0 to High(Columns) do
    Result.ColumnWidths[I] := Columns[I].Width;
end;

function CurrentLayout(AList: TListView; AForm: TForm): TDialogLayout;
var
  I: Integer;
begin
  Result.Width := AForm.ClientWidth;
  Result.Height := AForm.ClientHeight;
  SetLength(Result.ColumnWidths, AList.Columns.Count);
  for I := 0 to AList.Columns.Count - 1 do
    Result.ColumnWidths[I] := AList.Columns[I].Width;
end;

function TPackageDialogForm.RowIndexOf(const APath: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FList.Items.Count - 1 do
    if SameText(PathOf(FList.Items[I]), APath) then
      Exit(I);
  Result := -1;
end;

procedure TPackageDialogForm.ShowButtonsFor(AItem: TListItem);
begin
  FRemove.Enabled := IsConfigured(AItem);
end;

procedure TPackageDialogForm.ListSelected(Sender: TObject; AItem: TListItem;
  ASelected: Boolean);
begin
  ShowButtonsFor(FList.Selected);
end;

procedure TPackageDialogForm.AddClick(Sender: TObject);
var
  Chooser: TOpenDialog;
  Index: Integer;
  Item: TListItem;
begin
  Chooser := TOpenDialog.Create(Self);
  try
    Chooser.Title := 'Add a design package';
    Chooser.Filter := 'Design packages (*.bpl)|*.bpl|All files (*.*)|*.*';
    Chooser.Options := Chooser.Options + [ofFileMustExist, ofPathMustExist];
    Chooser.InitialDir := IdeBinDirectory;
    if not Chooser.Execute then
      Exit;
    Index := RowIndexOf(Chooser.FileName);
    if Index >= 0 then
    begin
      Item := FList.Items[Index];
      Item.SubItems[OriginColumn - 1] := OriginCaptions[poExplicit];
    end
    else
    begin
      Item := FList.Items.Add;
      FillRow(Item, InspectCandidate(Chooser.FileName, poExplicit));
    end;
    Item.Selected := True;
    Item.MakeVisible(False);
  finally
    Chooser.Free;
  end;
  ShowButtonsFor(FList.Selected);
end;

procedure TPackageDialogForm.RemoveClick(Sender: TObject);
var
  Item: TListItem;
  Entry: TDiscoveredPackage;
  Status: TPackageStatus;
  Path: string;
begin
  Item := FList.Selected;
  if not IsConfigured(Item) then
    Exit;
  Path := PathOf(Item);
  if InstalledEntry(Path, Entry) then
  begin
    Status := InspectCandidate(Path, poRegistry);
    Status.Description := Entry.Description;
    FillRow(Item, Status);
  end
  else
    Item.Delete;
  ShowButtonsFor(FList.Selected);
end;

procedure TPackageDialogForm.DialogShown(Sender: TObject);
begin
  FillList(FList);
  ShowButtonsFor(FList.Selected);
end;

procedure TPackageDialogForm.DialogClosed(Sender: TObject;
  var AAction: TCloseAction);
var
  Store: TDialogLayoutStore;
begin
  if WindowState <> wsNormal then
    Exit;
  Store := TDialogLayoutStore.Create(SettingsKey(DialogSettingsKey));
  try
    Store.Save(CurrentLayout(FList, Self), CurrentPPI);
  finally
    Store.Free;
  end;
end;

function ExecutePackageManager: Boolean;
var
  Dialog: TPackageDialogForm;
  Store: TDialogLayoutStore;
  Layout: TDialogLayout;
  List: TListView;
  Note: TLabel;
  Add, OK, Cancel: TButton;
  Added: TListColumn;
  ListHeight, ListButtonRow, NoteRow, ControlRow, I: Integer;
begin
  Dialog := TPackageDialogForm.CreateNew(nil);
  try
    Store := TDialogLayoutStore.Create(SettingsKey(DialogSettingsKey));
    try
      Layout := Store.Load(DefaultLayout, Dialog.CurrentPPI);
    finally
      Store.Free;
    end;
    Layout.Width := Max(Layout.Width, MinDialogWidth);
    Layout.Height := Max(Layout.Height, MinDialogHeight);
    ListButtonRow := Layout.Height - DialogMargin - ButtonHeight -
      DialogMargin - NoteHeight - DialogMargin - ButtonHeight;
    NoteRow := ListButtonRow + ButtonHeight + DialogMargin;
    ControlRow := Layout.Height - DialogMargin - ButtonHeight;
    ListHeight := ListButtonRow - 2 * DialogMargin;

    Dialog.Caption := 'Packages';
    Dialog.BorderStyle := bsSizeable;
    Dialog.Position := poScreenCenter;
    Dialog.ClientWidth := Layout.Width;
    Dialog.ClientHeight := Layout.Height;
    Dialog.Constraints.MinWidth := MinDialogWidth;
    Dialog.Constraints.MinHeight := MinDialogHeight;

    List := TListView.Create(Dialog);
    List.Parent := Dialog;
    List.SetBounds(DialogMargin, DialogMargin,
      Layout.Width - 2 * DialogMargin, ListHeight);
    List.Anchors := [akLeft, akTop, akRight, akBottom];
    List.ViewStyle := vsReport;
    List.ReadOnly := True;
    List.RowSelect := True;
    List.Checkboxes := True;
    List.HideSelection := False;
    for I := 0 to High(Columns) do
    begin
      Added := List.Columns.Add;
      Added.Caption := Columns[I].Caption;
      Added.Width := Layout.ColumnWidths[I];
    end;
    Dialog.FList := List;
    Dialog.OnShow := Dialog.DialogShown;
    Dialog.OnClose := Dialog.DialogClosed;

    Add := TButton.Create(Dialog);
    Add.Parent := Dialog;
    Add.Caption := '&Add package...';
    Add.SetBounds(DialogMargin, ListButtonRow, ListButtonWidth, ButtonHeight);
    Add.Anchors := [akLeft, akBottom];
    Add.OnClick := Dialog.AddClick;

    Dialog.FRemove := TButton.Create(Dialog);
    Dialog.FRemove.Parent := Dialog;
    Dialog.FRemove.Caption := '&Remove package';
    Dialog.FRemove.SetBounds(2 * DialogMargin + ListButtonWidth, ListButtonRow,
      ListButtonWidth, ButtonHeight);
    Dialog.FRemove.Anchors := [akLeft, akBottom];
    Dialog.FRemove.Enabled := False;
    Dialog.FRemove.OnClick := Dialog.RemoveClick;
    List.OnSelectItem := Dialog.ListSelected;

    Note := TLabel.Create(Dialog);
    Note.Parent := Dialog;
    Note.AutoSize := False;
    Note.WordWrap := True;
    Note.Caption := 'Every design package the Delphi IDE has installed is ' +
      'loaded, together with the ones listed as configured. These settings ' +
      'belong to VallentaDesigner alone - the IDE keeps the packages it has ' +
      'installed exactly as they are. Changes take effect the next time the ' +
      'designer starts; nothing is loaded or unloaded now.';
    Note.SetBounds(DialogMargin, NoteRow, Layout.Width - 2 * DialogMargin,
      NoteHeight);
    Note.Anchors := [akLeft, akRight, akBottom];

    OK := TButton.Create(Dialog);
    OK.Parent := Dialog;
    OK.Caption := 'OK';
    OK.Default := True;
    OK.ModalResult := mrOk;
    OK.SetBounds(Layout.Width - 2 * ButtonWidth - DialogMargin - 8, ControlRow,
      ButtonWidth, ButtonHeight);
    OK.Anchors := [akRight, akBottom];

    Cancel := TButton.Create(Dialog);
    Cancel.Parent := Dialog;
    Cancel.Caption := 'Cancel';
    Cancel.Cancel := True;
    Cancel.ModalResult := mrCancel;
    Cancel.SetBounds(Layout.Width - ButtonWidth - DialogMargin, ControlRow,
      ButtonWidth, ButtonHeight);
    Cancel.Anchors := [akRight, akBottom];

    Result := Dialog.ShowModal = mrOk;
    if Result then
      Result := WritePackageSettings(SwitchedOffPaths(List),
        ConfiguredPaths(List));
  finally
    Dialog.Free;
  end;
end;

end.
