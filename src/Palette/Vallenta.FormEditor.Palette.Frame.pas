// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Palette.Frame;

// Component palette pane over one TPaletteModel: a tab of every component
// the attached designer can place and a tab of the favourites, each showing
// one collapsible category per palette page and narrowed by the header's
// search box. A click arms the designer for placement, a double click places
// the component centered on the design surface. Main thread only.
//
// Construction reads the component registry and picks the icon provider from
// the package icons harvested so far, so the packages must be loaded first;
// DropDynamicItems must run before they are unloaded again.

interface

uses
  System.Classes,
  System.Types,
  System.UITypes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.ComCtrls,
  Vcl.Buttons,
  Vcl.Graphics,
  Vcl.CategoryButtons,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Surface.FormDesigner,
  Vallenta.FormEditor.Palette.Model,
  Vallenta.FormEditor.Palette.Favourites,
  Vallenta.FormEditor.Palette.Buttons;

type
  // Palette frame over one designer at a time. The buttons and the header
  // stay disabled while no designer is attached.
  TPaletteFrame = class(TFrame)
    // Controls bound by the .dfm.
    TitlePanel: TPanel;
    HeaderPanel: TPanel;
  private
  type
    // One tab: its buttons, and whether they need a rebuild after a change
    // to the model, the search term or the favourites. Rebuilt when it shows.
    TPaletteView = record
      Buttons: TPaletteButtons;
      Stale: Boolean;
    end;
  var
    FModel: TPaletteModel;
    FFilter: TPaletteFilter;
    FFavourites: TPaletteFavourites;
    FLog: TDesignLog;
    FPages: TPageControl;
    FViews: array [0 .. 1] of TPaletteView;
    FSearch: TEdit;
    FSearchTimer: TTimer;
    FCollapseAll: TSpeedButton;
    FExpandAll: TSpeedButton;
    FExpandedBeforeSearch: TStringList;
    FDesigner: TFormDesigner;
    FArmedItem: TPaletteItem;
    FPlacedByDoubleClick: Boolean;
    procedure BuildHeader;
    procedure KeepSearchHintVisible;
    procedure BuildViews;
    function NewView(const ACaption: string): TPaletteButtons;
    function FrontButtons: TPaletteButtons;
    procedure BuildView(AIndex: Integer);
    procedure RefreshFront(ARestoreExpanded: Boolean);
    procedure MarkStale;
    procedure FavouritesChanged;
    procedure PageChanged(Sender: TObject);
    function HoldPainting(AButtons: TPaletteButtons): Boolean;
    procedure ResumePainting(AButtons: TPaletteButtons; AHeld: Boolean);
    procedure SetAllCollapsed(ACollapsed: Boolean);
    procedure CaptureExpanded;
    procedure RestoreExpanded;
    procedure ApplySearch;
    procedure SearchChanged(Sender: TObject);
    procedure SearchTick(Sender: TObject);
    procedure CollapseAllClick(Sender: TObject);
    procedure ExpandAllClick(Sender: TObject);
    procedure ItemFavouriteKind(Sender: TObject; const AButton: TButtonItem;
      var AKind: TFavouriteKind);
    procedure GroupIsFavourite(Sender: TObject;
      const ACategory: TButtonCategory; var AFavourite: Boolean);
    procedure ToggleItemFavourite(Sender: TObject; const AButton: TButtonItem);
    procedure ToggleGroupFavourite(Sender: TObject;
      const ACategory: TButtonCategory);
    procedure ReportFailedWrite;
    function NonVisualOnly: Boolean;
    function Offers(AItem: TPaletteItem): Boolean;
    function Shows(AIndex: Integer; AItem: TPaletteItem;
      const AGroupCaption: string): Boolean;
    function ItemOf(AButton: TButtonItem): TPaletteItem;
    function ButtonFor(AButtons: TCategoryButtons;
      AItem: TPaletteItem): TButtonItem;
    procedure ShowArmedIn(AButtons: TPaletteButtons);
    procedure ShowArmedState;
    procedure ArmItem(AItem: TPaletteItem);
    procedure ClearArmedState;
    procedure ButtonClicked(Sender: TObject; const Button: TButtonItem);
    procedure ButtonsMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure ButtonsKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure ButtonsEditing(Sender: TObject; Item: TBaseItem;
      var AllowEdit: Boolean);
    procedure DrawButtonIcon(Sender: TObject; const Button: TButtonItem;
      Canvas: TCanvas; Rect: TRect; State: TButtonDrawState;
      var TextOffset: Integer);
    procedure DesignerCreationFinished(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Binds the palette to ADesigner; nil detaches it and disables the
    // buttons. A data module root narrows them to non-visual components.
    procedure Attach(ADesigner: TFormDesigner);
    // Removes the palette items contributed by loaded packages. Must run
    // before the packages are unloaded: an item holds a class reference into
    // the package module.
    procedure DropDynamicItems;
    // Optional log target; nil discards the warning raised when a favourite
    // cannot be written to the registry.
    property Log: TDesignLog read FLog write FLog;
  end;

implementation

{$R *.dfm}

uses
  Winapi.Windows,
  Winapi.Messages,
  Winapi.CommCtrl,
  System.SysUtils,
  Vallenta.FormEditor.Core.Settings,
  Vallenta.FormEditor.Packages.Icons,
  Vallenta.FormEditor.Streaming.RootClassifier;

const
  // View indexes, texts, the settings subkey, and layout metrics in px.
  AllView = 0;
  FavouritesView = 1;
  ViewCaptions: array [AllView .. FavouritesView] of string =
    ('Components', 'Favourites');
  PaletteSettingsKey = 'Palette';
  SearchHintText = 'Search';
  PaletteButtonHeight = 22;
  GlyphIndent = 6;
  GlyphTextGap = 2;
  HeaderMargin = 2;
  HeaderControlHeight = 22;
  HeaderButtonWidth = 22;
  // Search box debounce, in ms.
  SearchDelay = 200;

constructor TPaletteFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FModel := TPaletteModel.Create;
  // IconProviderOver returns the fallback unchanged while no package icons
  // have been harvested, so the packages must already be loaded here.
  FModel.IconProvider := IconProviderOver(FModel.IconProvider);
  FModel.BuildFromRegistry;
  FFilter := TPaletteFilter.Create;
  FFavourites := TPaletteFavourites.Create(SettingsKey(PaletteSettingsKey));
  FExpandedBeforeSearch := TStringList.Create;
  BuildHeader;
  BuildViews;
  MarkStale;
  RefreshFront(False);
end;

destructor TPaletteFrame.Destroy;
var
  I: Integer;
begin
  // A tick after the buttons are freed rebuilds into a freed collection.
  // FSearchTimer is nil when construction failed before BuildHeader.
  if FSearchTimer <> nil then
    FSearchTimer.Enabled := False;
  // The buttons reference the model's items; free them before the model.
  for I := Low(FViews) to High(FViews) do
    FreeAndNil(FViews[I].Buttons);
  FExpandedBeforeSearch.Free;
  FFavourites.Free;
  FFilter.Free;
  FModel.Free;
  inherited Destroy;
end;

procedure TPaletteFrame.BuildHeader;
begin
  FExpandAll := TSpeedButton.Create(Self);
  FExpandAll.Parent := HeaderPanel;
  FExpandAll.Flat := True;
  FExpandAll.Caption := '+';
  FExpandAll.Hint := 'Expand all groups';
  FExpandAll.ShowHint := True;
  FExpandAll.SetBounds(HeaderPanel.Width - HeaderMargin - HeaderButtonWidth,
    HeaderMargin, HeaderButtonWidth, HeaderControlHeight);
  FExpandAll.Anchors := [akTop, akRight];
  FExpandAll.OnClick := ExpandAllClick;

  FCollapseAll := TSpeedButton.Create(Self);
  FCollapseAll.Parent := HeaderPanel;
  FCollapseAll.Flat := True;
  FCollapseAll.Caption := '-';
  FCollapseAll.Hint := 'Collapse all groups';
  FCollapseAll.ShowHint := True;
  FCollapseAll.SetBounds(FExpandAll.Left - HeaderButtonWidth, HeaderMargin,
    HeaderButtonWidth, HeaderControlHeight);
  FCollapseAll.Anchors := [akTop, akRight];
  FCollapseAll.OnClick := CollapseAllClick;

  FSearch := TEdit.Create(Self);
  FSearch.Parent := HeaderPanel;
  FSearch.TextHint := SearchHintText;
  FSearch.Hint := 'Filter the components by name; * and ? match';
  FSearch.ShowHint := True;
  FSearch.SetBounds(HeaderMargin, HeaderMargin,
    FCollapseAll.Left - 2 * HeaderMargin, HeaderControlHeight);
  FSearch.Anchors := [akLeft, akTop, akRight];
  FSearch.OnChange := SearchChanged;

  FSearchTimer := TTimer.Create(Self);
  FSearchTimer.Enabled := False;
  FSearchTimer.Interval := SearchDelay;
  FSearchTimer.OnTimer := SearchTick;

  HeaderPanel.Enabled := False;
end;

// EM_SETCUEBANNER with wParam 1 keeps the hint visible while the edit has
// focus; TEdit.TextHint sends wParam 0, which hides it on focus.
procedure TPaletteFrame.KeepSearchHintVisible;
begin
  if FSearch.HandleAllocated then
    SendMessage(FSearch.Handle, EM_SETCUEBANNER, 1,
      LPARAM(PChar(SearchHintText)));
end;

procedure TPaletteFrame.BuildViews;
var
  I: Integer;
begin
  FPages := TPageControl.Create(Self);
  FPages.Parent := Self;
  FPages.Align := alClient;
  for I := AllView to FavouritesView do
    FViews[I].Buttons := NewView(ViewCaptions[I]);
  FPages.ActivePageIndex := AllView;
  FPages.OnChange := PageChanged;
end;

function TPaletteFrame.NewView(const ACaption: string): TPaletteButtons;
var
  Tab: TTabSheet;
begin
  Tab := TTabSheet.Create(Self);
  Tab.PageControl := FPages;
  Tab.Caption := ACaption;

  Result := TPaletteButtons.Create(Self);
  Result.Parent := Tab;
  Result.Align := alClient;
  Result.BorderStyle := bsNone;
  Result.ButtonFlow := cbfVertical;
  Result.ButtonOptions := [boGradientFill, boShowCaptions, boFullSize,
    boUsePlusMinus];
  Result.ButtonHeight := PaletteButtonHeight;
  Result.Enabled := False;
  Result.OnButtonClicked := ButtonClicked;
  Result.OnMouseDown := ButtonsMouseDown;
  Result.OnKeyDown := ButtonsKeyDown;
  Result.OnDrawIcon := DrawButtonIcon;
  // boFullSize with boShowCaptions enables inline caption editing, which
  // ButtonsEditing refuses.
  Result.OnEditing := ButtonsEditing;
  Result.OnItemKind := ItemFavouriteKind;
  Result.OnGroupFavourite := GroupIsFavourite;
  Result.OnToggleItem := ToggleItemFavourite;
  Result.OnToggleGroup := ToggleGroupFavourite;
end;

function TPaletteFrame.FrontButtons: TPaletteButtons;
begin
  Result := FViews[FPages.ActivePageIndex].Buttons;
end;

// TCategoryButtons repaints synchronously (RDW_UPDATENOW) on every collection
// or collapse change; WM_SETREDRAW holds a batch of them to one paint.
function TPaletteFrame.HoldPainting(AButtons: TPaletteButtons): Boolean;
begin
  Result := AButtons.HandleAllocated;
  if Result then
    SendMessage(AButtons.Handle, WM_SETREDRAW, 0, 0);
end;

procedure TPaletteFrame.ResumePainting(AButtons: TPaletteButtons;
  AHeld: Boolean);
begin
  if not AHeld then
    Exit;
  SendMessage(AButtons.Handle, WM_SETREDRAW, 1, 0);
  AButtons.Invalidate;
end;

// A paint during the rebuild reaches DrawButtonIcon for a button whose Data
// is not assigned yet, so painting stays held for the whole loop.
procedure TPaletteFrame.BuildView(AIndex: Integer);
var
  Buttons: TPaletteButtons;
  I, J: Integer;
  Group: TPaletteGroup;
  Category: TButtonCategory;
  Button: TButtonItem;
  Item: TPaletteItem;
  Drawing: Boolean;
begin
  Buttons := FViews[AIndex].Buttons;
  Drawing := HoldPainting(Buttons);
  try
    Buttons.ForgetHot;
    Buttons.Categories.Clear;
    for I := 0 to FModel.Groups.Count - 1 do
    begin
      Group := FModel.Groups[I];
      Category := nil;
      for J := 0 to Group.Items.Count - 1 do
      begin
        Item := Group.Items[J];
        if not Shows(AIndex, Item, Group.Caption) then
          Continue;
        if Category = nil then
        begin
          Category := Buttons.Categories.Add;
          Category.Caption := Group.Caption;
          Category.Collapsed := True;
        end;
        Button := Category.Items.Add;
        Button.Data := Item;
        Button.Caption := Item.DisplayName;
        Button.Hint := Item.ComponentClass.ClassName;
      end;
    end;
    ShowArmedIn(Buttons);
  finally
    ResumePainting(Buttons, Drawing);
  end;
  FViews[AIndex].Stale := False;
end;

procedure TPaletteFrame.RefreshFront(ARestoreExpanded: Boolean);
begin
  BuildView(FPages.ActivePageIndex);
  if FFilter.Term <> '' then
    SetAllCollapsed(False)
  else if ARestoreExpanded then
    RestoreExpanded;
end;

procedure TPaletteFrame.MarkStale;
var
  I: Integer;
begin
  for I := Low(FViews) to High(FViews) do
    FViews[I].Stale := True;
end;

procedure TPaletteFrame.FavouritesChanged;
begin
  FViews[FavouritesView].Stale := True;
  if FPages.ActivePageIndex = FavouritesView then
    RefreshFront(False);
end;

procedure TPaletteFrame.PageChanged(Sender: TObject);
begin
  if FViews[FPages.ActivePageIndex].Stale then
    RefreshFront(False);
end;

procedure TPaletteFrame.SetAllCollapsed(ACollapsed: Boolean);
var
  Buttons: TPaletteButtons;
  Held: Boolean;
  I: Integer;
begin
  Buttons := FrontButtons;
  Held := HoldPainting(Buttons);
  try
    for I := 0 to Buttons.Categories.Count - 1 do
      Buttons.Categories[I].Collapsed := ACollapsed;
  finally
    ResumePainting(Buttons, Held);
  end;
end;

procedure TPaletteFrame.CaptureExpanded;
var
  Buttons: TPaletteButtons;
  I: Integer;
begin
  Buttons := FrontButtons;
  FExpandedBeforeSearch.Clear;
  for I := 0 to Buttons.Categories.Count - 1 do
    if not Buttons.Categories[I].Collapsed then
      FExpandedBeforeSearch.Add(Buttons.Categories[I].Caption);
end;

procedure TPaletteFrame.RestoreExpanded;
var
  Buttons: TPaletteButtons;
  Held: Boolean;
  I: Integer;
begin
  Buttons := FrontButtons;
  Held := HoldPainting(Buttons);
  try
    for I := 0 to Buttons.Categories.Count - 1 do
      Buttons.Categories[I].Collapsed := FExpandedBeforeSearch.IndexOf(
        Buttons.Categories[I].Caption) < 0;
  finally
    ResumePainting(Buttons, Held);
  end;
end;

procedure TPaletteFrame.ApplySearch;
var
  Term: string;
  Clearing: Boolean;
begin
  FSearchTimer.Enabled := False;
  Term := Trim(FSearch.Text);
  if Term = FFilter.Term then
    Exit;
  if (Term <> '') and (FFilter.Term = '') then
    CaptureExpanded;
  Clearing := (Term = '') and (FFilter.Term <> '');
  FFilter.SetTerm(Term);
  MarkStale;
  RefreshFront(Clearing);
end;

procedure TPaletteFrame.SearchChanged(Sender: TObject);
begin
  FSearchTimer.Enabled := False;
  FSearchTimer.Enabled := True;
end;

procedure TPaletteFrame.SearchTick(Sender: TObject);
begin
  ApplySearch;
end;

procedure TPaletteFrame.CollapseAllClick(Sender: TObject);
begin
  SetAllCollapsed(True);
end;

procedure TPaletteFrame.ExpandAllClick(Sender: TObject);
begin
  SetAllCollapsed(False);
end;

procedure TPaletteFrame.ItemFavouriteKind(Sender: TObject;
  const AButton: TButtonItem; var AKind: TFavouriteKind);
begin
  if FFavourites.HasItem(ItemOf(AButton).ComponentClass.ClassName) then
    AKind := fkOwn
  else if FFavourites.HasGroup(AButton.Category.Caption) then
    AKind := fkByGroup
  else
    AKind := fkNone;
end;

procedure TPaletteFrame.GroupIsFavourite(Sender: TObject;
  const ACategory: TButtonCategory; var AFavourite: Boolean);
begin
  AFavourite := FFavourites.HasGroup(ACategory.Caption);
end;

procedure TPaletteFrame.ToggleItemFavourite(Sender: TObject;
  const AButton: TButtonItem);
begin
  FFavourites.ToggleItem(ItemOf(AButton).ComponentClass.ClassName);
  ReportFailedWrite;
  FavouritesChanged;
end;

procedure TPaletteFrame.ToggleGroupFavourite(Sender: TObject;
  const ACategory: TButtonCategory);
begin
  FFavourites.ToggleGroup(ACategory.Caption);
  ReportFailedWrite;
  FavouritesChanged;
end;

procedure TPaletteFrame.ReportFailedWrite;
begin
  if (FLog <> nil) and (FFavourites.LastError <> '') then
    FLog.AddFmt(lsWarn, 'the palette favourite could not be stored: %s',
      [FFavourites.LastError]);
end;

function TPaletteFrame.NonVisualOnly: Boolean;
begin
  Result := (FDesigner <> nil) and (FDesigner.RootKind = drDataModule);
end;

function TPaletteFrame.Offers(AItem: TPaletteItem): Boolean;
begin
  Result := (AItem.IsNonVisual or not NonVisualOnly) and FFilter.Matches(AItem);
end;

function TPaletteFrame.Shows(AIndex: Integer; AItem: TPaletteItem;
  const AGroupCaption: string): Boolean;
begin
  Result := Offers(AItem) and
    ((AIndex = AllView) or FFavourites.Holds(AItem, AGroupCaption));
end;

function TPaletteFrame.ItemOf(AButton: TButtonItem): TPaletteItem;
begin
  Result := TPaletteItem(AButton.Data);
end;

function TPaletteFrame.ButtonFor(AButtons: TCategoryButtons;
  AItem: TPaletteItem): TButtonItem;
var
  Category: TButtonCategory;
  I, J: Integer;
begin
  if AItem <> nil then
    for I := 0 to AButtons.Categories.Count - 1 do
    begin
      Category := AButtons.Categories[I];
      for J := 0 to Category.Items.Count - 1 do
        if ItemOf(Category.Items[J]) = AItem then
          Exit(Category.Items[J]);
    end;
  Result := nil;
end;

procedure TPaletteFrame.ShowArmedIn(AButtons: TPaletteButtons);
begin
  AButtons.SelectedItem := ButtonFor(AButtons, FArmedItem);
end;

procedure TPaletteFrame.ShowArmedState;
var
  I: Integer;
begin
  for I := Low(FViews) to High(FViews) do
    ShowArmedIn(FViews[I].Buttons);
end;

procedure TPaletteFrame.ArmItem(AItem: TPaletteItem);
begin
  FArmedItem := AItem;
  ShowArmedState;
  FDesigner.ArmCreation(AItem);
end;

procedure TPaletteFrame.ClearArmedState;
begin
  FArmedItem := nil;
  ShowArmedState;
end;

procedure TPaletteFrame.DesignerCreationFinished(Sender: TObject);
begin
  ClearArmedState;
end;

procedure TPaletteFrame.Attach(ADesigner: TFormDesigner);
var
  WasNarrowed: Boolean;
  I: Integer;
begin
  if FDesigner <> nil then
    FDesigner.OnCreationFinished := nil;
  WasNarrowed := NonVisualOnly;
  FDesigner := ADesigner;
  if FDesigner <> nil then
    FDesigner.OnCreationFinished := DesignerCreationFinished;
  FPlacedByDoubleClick := False;
  // Cleared before the rebuild below: ShowArmedIn would otherwise select the
  // button of an item armed for the previous designer.
  ClearArmedState;
  if NonVisualOnly <> WasNarrowed then
  begin
    FSearchTimer.Enabled := False;
    FFilter.SetTerm(FSearch.Text);
    MarkStale;
    RefreshFront(False);
  end;
  for I := Low(FViews) to High(FViews) do
    FViews[I].Buttons.Enabled := FDesigner <> nil;
  HeaderPanel.Enabled := FDesigner <> nil;
  // Not at construction: EM_SETCUEBANNER needs an allocated handle, which
  // the edit gains only once the pane is shown.
  KeepSearchHintVisible;
end;

procedure TPaletteFrame.DropDynamicItems;
var
  I: Integer;
begin
  // FModel.DropDynamicEntries frees items that FArmedItem and the button
  // Data point at, so both are cleared before it runs.
  ClearArmedState;
  for I := Low(FViews) to High(FViews) do
  begin
    FViews[I].Buttons.ForgetHot;
    FViews[I].Buttons.Categories.Clear;
  end;
  FModel.DropDynamicEntries;
  MarkStale;
  RefreshFront(False);
end;

procedure TPaletteFrame.ButtonClicked(Sender: TObject; const Button: TButtonItem);
begin
  if FDesigner = nil then
    Exit;
  // A double click arrives as click, double click, click; the placement has
  // already happened when the trailing click is reported.
  if FPlacedByDoubleClick then
  begin
    FPlacedByDoubleClick := False;
    ShowArmedState;
    Exit;
  end;
  if ItemOf(Button) = FArmedItem then
    FDesigner.DisarmCreation
  else
    ArmItem(ItemOf(Button));
end;

procedure TPaletteFrame.ButtonsMouseDown(Sender: TObject; Button: TMouseButton;
  Shift: TShiftState; X, Y: Integer);
var
  Item: TButtonItem;
begin
  if (FDesigner = nil) or (Button <> mbLeft) then
    Exit;
  if not (ssDouble in Shift) then
  begin
    // A flag left set would swallow the next unrelated click.
    FPlacedByDoubleClick := False;
    Exit;
  end;
  Item := TPaletteButtons(Sender).GetButtonAt(X, Y);
  if Item = nil then
    Exit;
  // Handled here rather than in ButtonClicked: OnButtonClicked reports one
  // click per press and carries no double-click state.
  FPlacedByDoubleClick := True;
  FDesigner.CreateCentered(ItemOf(Item));
end;

procedure TPaletteFrame.ButtonsKeyDown(Sender: TObject; var Key: Word;
  Shift: TShiftState);
begin
  // Focus stays on the palette after arming; the designer's own Esc handling
  // runs only while the design surface has focus.
  if (Key = vkEscape) and (FArmedItem <> nil) then
  begin
    FDesigner.DisarmCreation;
    Key := 0;
  end;
end;

procedure TPaletteFrame.ButtonsEditing(Sender: TObject; Item: TBaseItem;
  var AllowEdit: Boolean);
begin
  AllowEdit := False;
end;

procedure TPaletteFrame.DrawButtonIcon(Sender: TObject; const Button: TButtonItem;
  Canvas: TCanvas; Rect: TRect; State: TButtonDrawState;
  var TextOffset: Integer);
var
  Extent: Integer;
  Bounds: TRect;
  SavedBrushColor, SavedPenColor, SavedFontColor: TColor;
  SavedBrushStyle: TBrushStyle;
  SavedFontHeight: Integer;
  SavedFontName: TFontName;
  SavedFontStyle: TFontStyles;
begin
  Extent := FModel.IconProvider.GlyphSize;
  TextOffset := Extent + GlyphTextGap;
  Bounds := TRect.Create(Point(Rect.Left + GlyphIndent,
    Rect.Top + (Rect.Height - Extent) div 2), Extent, Extent);
  if bdsDown in State then
    Bounds.Offset(1, 1);

  // The control draws the caption after this hook with the canvas state it
  // finds, so every property the provider may change is restored.
  SavedBrushColor := Canvas.Brush.Color;
  SavedBrushStyle := Canvas.Brush.Style;
  SavedPenColor := Canvas.Pen.Color;
  SavedFontColor := Canvas.Font.Color;
  SavedFontHeight := Canvas.Font.Height;
  SavedFontName := Canvas.Font.Name;
  SavedFontStyle := Canvas.Font.Style;
  try
    FModel.IconProvider.DrawGlyph(ItemOf(Button), Canvas, Bounds);
  finally
    Canvas.Brush.Color := SavedBrushColor;
    Canvas.Brush.Style := SavedBrushStyle;
    Canvas.Pen.Color := SavedPenColor;
    Canvas.Font.Color := SavedFontColor;
    Canvas.Font.Height := SavedFontHeight;
    Canvas.Font.Name := SavedFontName;
    Canvas.Font.Style := SavedFontStyle;
  end;
end;

end.
