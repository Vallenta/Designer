// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Inspector.Frame;

// Object inspector pane over one TFormDesigner: a component tree above,
// property and event grids in tabs below. A selection made in the tree is
// written to the designer, and a selection made on the design surface is
// written back to the tree. VCL frame, main thread only.
//
// Attach assigns the designer's OnSelectionChanged, OnStructureChanged and
// OnGeometryChanged, so one designer can be attached to one inspector only.

interface

uses
  System.Classes,
  System.Types,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.ComCtrls,
  Vallenta.FormEditor.Surface.FormDesigner,
  Vallenta.FormEditor.Streaming.Preserved,
  Vallenta.FormEditor.Inspector.PropertyModel,
  Vallenta.FormEditor.Inspector.Grid;

type
  // Inspector frame: component tree, property grid and event grid. All three
  // stay empty until Attach binds a designer, and are cleared by Attach(nil).
  TInspectorFrame = class(TFrame)
    // Controls and event handlers bound by the .dfm.
    HeaderPanel: TPanel;
    ComponentTree: TTreeView;
    TreeSplitter: TSplitter;
    Tabs: TPageControl;
    PropertiesTab: TTabSheet;
    EventsTab: TTabSheet;
    procedure ComponentTreeChange(Sender: TObject; Node: TTreeNode);
    procedure ComponentTreeContextPopup(Sender: TObject; MousePos: TPoint;
      var Handled: Boolean);
  private
    FDesigner: TFormDesigner;
    FUpdating: Boolean;
    FPropertyModel: TPropertyModel;
    FEventModel: TPropertyModel;
    FPropertyGrid: TPropertyGrid;
    FEventGrid: TPropertyGrid;
    procedure DesignerSelectionChanged(Sender: TObject);
    procedure DesignerStructureChanged(Sender: TObject);
    procedure DesignerGeometryChanged(Sender: TObject);
    procedure AddControlNode(ParentNode: TTreeNode; Control: TControl);
    procedure AddCollectionNodes(ParentNode: TTreeNode; AComponent: TComponent);
    procedure AddNonVisualNodes(ParentNode: TTreeNode);
    procedure AddSubComponentNodes(ParentNode: TTreeNode; AComponent: TComponent);
    procedure ShowPreservedNotice(APiece: TPreservedPiece);
    function BelongsInTree(AControl: TControl): Boolean;
    function SelectedPersistents: TArray<TPersistent>;
    procedure RebuildTree;
    procedure SyncTreeToSelection;
    procedure RebuildGrids;
    function CodeCoupled: Boolean;
    function FindNodeFor(AInstance: TPersistent): TTreeNode;
    procedure GridBeforeChange(Sender: TObject);
    procedure GridValueChanged(Sender: TObject);
    procedure GridInvalidValue(Sender: TObject);
    procedure GridEditorInvoked(Sender: TObject);
    procedure GridEditCancelled(Sender: TObject);
    procedure GridEditPending(Sender: TObject);
    function GetTreeHeight: Integer;
    procedure SetTreeHeight(AValue: Integer);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    // Binds the inspector to ADesigner and rebuilds the tree and both grids,
    // clearing the handlers on any previous designer. nil leaves all three
    // empty.
    procedure Attach(ADesigner: TFormDesigner);
    // Rebuilds both grids for the same document and selection: after the
    // guard is lifted, code coupling connects or disconnects, or a rename
    // settles, each of which changes which rows are editable.
    procedure RefreshRows;
    // Height of the component tree in pixels; the tab control below fills the
    // remaining space. Read and written with the stored window layout.
    property TreeHeight: Integer read GetTreeHeight write SetTreeHeight;
  end;

implementation

{$R *.dfm}

uses
  System.SysUtils,
  System.TypInfo,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Surface.Tiles,
  Vallenta.FormEditor.Surface.Undo;

constructor TInspectorFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  ComponentTree.DoubleBuffered := True;
  FPropertyModel := TPropertyModel.Create;
  FEventModel := TPropertyModel.Create;

  FPropertyGrid := TPropertyGrid.Create(Self);
  FPropertyGrid.Parent := PropertiesTab;
  FPropertyGrid.Align := alClient;
  FPropertyGrid.OnBeforeChange := GridBeforeChange;
  FPropertyGrid.OnValueChanged := GridValueChanged;
  FPropertyGrid.OnInvalidValue := GridInvalidValue;
  FPropertyGrid.OnEditorInvoked := GridEditorInvoked;
  FPropertyGrid.OnEditCancelled := GridEditCancelled;
  FPropertyGrid.OnEditPending := GridEditPending;

  FEventGrid := TPropertyGrid.Create(Self);
  FEventGrid.Parent := EventsTab;
  FEventGrid.Align := alClient;
  FEventGrid.OnBeforeChange := GridBeforeChange;
  FEventGrid.OnValueChanged := GridValueChanged;
  FEventGrid.OnInvalidValue := GridInvalidValue;
  FEventGrid.OnEditorInvoked := GridEditorInvoked;
  FEventGrid.OnEditCancelled := GridEditCancelled;
  FEventGrid.OnEditPending := GridEditPending;
end;

destructor TInspectorFrame.Destroy;
begin
  FPropertyModel.Free;
  FEventModel.Free;
  inherited Destroy;
end;

function TInspectorFrame.GetTreeHeight: Integer;
begin
  Result := ComponentTree.Height;
end;

procedure TInspectorFrame.SetTreeHeight(AValue: Integer);
begin
  ComponentTree.Height := AValue;
end;

procedure TInspectorFrame.Attach(ADesigner: TFormDesigner);
begin
  if FDesigner <> nil then
  begin
    FDesigner.OnSelectionChanged := nil;
    FDesigner.OnStructureChanged := nil;
    FDesigner.OnGeometryChanged := nil;
  end;
  FDesigner := ADesigner;
  if FDesigner <> nil then
  begin
    FDesigner.OnSelectionChanged := DesignerSelectionChanged;
    FDesigner.OnStructureChanged := DesignerStructureChanged;
    FDesigner.OnGeometryChanged := DesignerGeometryChanged;
  end;
  RebuildTree;
  RebuildGrids;
end;

procedure TInspectorFrame.ShowPreservedNotice(APiece: TPreservedPiece);
var
  Line: string;
begin
  FPropertyModel.BeginNotice;
  FPropertyModel.AddNotice('Class', APiece.DeclaredClass);
  FPropertyModel.AddNotice('Name', APiece.ComponentName);
  FPropertyModel.AddNotice('State', 'not loaded - kept exactly as found');
  for Line in APiece.Text.Split([sLineBreak]) do
    if Trim(Line) <> '' then
      FPropertyModel.AddNotice('', Line);
  FEventModel.Clear;
end;

function TInspectorFrame.SelectedPersistents: TArray<TPersistent>;
begin
  Result := FDesigner.SelectedPersistents;
end;

procedure TInspectorFrame.RebuildGrids;
var
  Instances: TArray<TPersistent>;
  Piece: TPreservedPiece;
begin
  // The rebuild frees every row; each grid holds a pointer to the row it is
  // editing.
  FPropertyGrid.CancelEdit;
  FEventGrid.CancelEdit;
  FPropertyGrid.ReadOnly := (FDesigner <> nil) and FDesigner.Guarded;
  FEventGrid.ReadOnly := FPropertyGrid.ReadOnly;
  Piece := nil;
  if FDesigner <> nil then
    Piece := PlaceholderPiece(FDesigner.Selected);
  if FDesigner = nil then
  begin
    FPropertyModel.Clear;
    FEventModel.Clear;
    // A stale ICodeCoupling keeps the closed document's coupling object alive
    // through its reference count; a stale Rename points at a freed designer.
    FPropertyModel.CodeCoupling := nil;
    FEventModel.CodeCoupling := nil;
    FPropertyModel.Rename := nil;
    FEventModel.Rename := nil;
  end
  else if Piece <> nil then
    ShowPreservedNotice(Piece)
  else
  begin
    Instances := SelectedPersistents;
    FPropertyModel.Log := FDesigner.Log;
    FEventModel.Log := FDesigner.Log;
    FPropertyModel.CodeCoupling := FDesigner.CodeCoupling;
    FEventModel.CodeCoupling := FDesigner.CodeCoupling;
    FPropertyModel.CouplingQuery := CodeCoupled;
    FEventModel.CouplingQuery := CodeCoupled;
    FPropertyModel.Rename := FDesigner;
    FEventModel.Rename := FDesigner;
    FPropertyModel.BuildMany(Instances, FDesigner.Root, FDesigner.EventMap,
      False, FDesigner.HostDesigner);
    FEventModel.BuildMany(Instances, FDesigner.Root, FDesigner.EventMap,
      True, FDesigner.HostDesigner);
  end;
  FPropertyGrid.ShowModel(FPropertyModel);
  FEventGrid.ShowModel(FEventModel);
end;

procedure TInspectorFrame.RefreshRows;
begin
  RebuildGrids;
end;

function TInspectorFrame.CodeCoupled: Boolean;
begin
  Result := (FDesigner <> nil) and FDesigner.CodeCouplingAvailable;
end;

procedure TInspectorFrame.GridBeforeChange(Sender: TObject);
begin
  if FDesigner = nil then
    Exit;
  FDesigner.BeginGridEdit;
  FDesigner.PushUndo(uoProperty);
end;

procedure TInspectorFrame.GridValueChanged(Sender: TObject);
begin
  if FDesigner = nil then
    Exit;
  FDesigner.EndGridEdit;
  FDesigner.NotifyEdited;
end;

procedure TInspectorFrame.GridInvalidValue(Sender: TObject);
var
  Grid: TPropertyGrid;
begin
  if FDesigner = nil then
    Exit;
  FDesigner.EndGridEdit;
  FDesigner.DropUndo;
  if (FDesigner.Log = nil) or not (Sender is TPropertyGrid) then
    Exit;
  // Both grids report through this handler; the refusal must be read from
  // Sender, since the other grid still holds its own last refusal.
  Grid := TPropertyGrid(Sender);
  if Grid.InvalidMessage <> '' then
    FDesigner.Log.AddFmt(lsWarn, '%s was refused: %s',
      [Grid.InvalidName, Grid.InvalidMessage])
  else
    FDesigner.Log.AddFmt(lsWarn, 'value rejected for %s - the property kept its ' +
      'previous value', [Grid.InvalidName]);
end;

procedure TInspectorFrame.GridEditorInvoked(Sender: TObject);
begin
  if FDesigner = nil then
    Exit;
  FDesigner.EndGridEdit;
  FDesigner.NotifyEditorChanged;
end;

procedure TInspectorFrame.GridEditPending(Sender: TObject);
begin
  if FDesigner = nil then
    Exit;
  FDesigner.EndGridEdit;
end;

procedure TInspectorFrame.GridEditCancelled(Sender: TObject);
begin
  if FDesigner = nil then
    Exit;
  FDesigner.EndGridEdit;
  FDesigner.DropUndo;
  if (Sender is TPropertyGrid) and
    (TPropertyGrid(Sender).SilentEditName <> '') and (FDesigner.Log <> nil) then
    FDesigner.Log.AddFmt(lsInfo, '%s: the property editor returned without ' +
      'opening a window or reporting a change - its dialog may not be ' +
      'available in this host', [TPropertyGrid(Sender).SilentEditName]);
end;

procedure TInspectorFrame.DesignerGeometryChanged(Sender: TObject);
begin
  FPropertyGrid.RefreshValues;
end;

function TInspectorFrame.BelongsInTree(AControl: TControl): Boolean;
var
  Owner: TComponent;
begin
  if IsPlaceholder(AControl) then
    Exit(True);
  Owner := AControl.Owner;
  while (Owner <> nil) and (Owner <> FDesigner.Root) and
    (csInline in Owner.ComponentState) do
    Owner := Owner.Owner;
  Result := Owner = FDesigner.Root;
end;

function DescribeNode(AControl: TControl): string;
var
  Piece: TPreservedPiece;
begin
  Piece := PlaceholderPiece(AControl);
  if Piece <> nil then
    Result := Format('%s  (kept as found)', [Piece.Describe])
  else
    Result := Format('%s: %s', [AControl.Name, AControl.ClassName]);
end;

procedure TInspectorFrame.AddControlNode(ParentNode: TTreeNode; Control: TControl);
var
  Node: TTreeNode;
  Container: TWinControl;
  I: Integer;
begin
  Node := ComponentTree.Items.AddChildObject(ParentNode, DescribeNode(Control),
    Control);
  if not IsPlaceholder(Control) then
  begin
    AddCollectionNodes(Node, Control);
    AddSubComponentNodes(Node, Control);
  end;
  if not (Control is TWinControl) then
    Exit;
  Container := TWinControl(Control);
  for I := 0 to Container.ControlCount - 1 do
    if BelongsInTree(Container.Controls[I]) then
      AddControlNode(Node, Container.Controls[I]);
end;

procedure TInspectorFrame.AddCollectionNodes(ParentNode: TTreeNode;
  AComponent: TComponent);
var
  Count, I, J: Integer;
  List: PPropList;
  Obj: TObject;
  Collection: TCollection;
  CollectionNode: TTreeNode;
begin
  Count := GetPropList(AComponent.ClassInfo, [tkClass], nil);
  if Count = 0 then
    Exit;
  GetMem(List, Count * SizeOf(PPropInfo));
  try
    GetPropList(AComponent.ClassInfo, [tkClass], List);
    for I := 0 to Count - 1 do
    begin
      Obj := GetObjectProp(AComponent, List[I]);
      if not (Obj is TCollection) then
        Continue;
      Collection := TCollection(Obj);
      CollectionNode := ComponentTree.Items.AddChildObject(ParentNode,
        string(List[I]^.Name), Collection);
      for J := 0 to Collection.Count - 1 do
        ComponentTree.Items.AddChildObject(CollectionNode,
          Format('%d - %s', [J, Collection.Items[J].DisplayName]),
          Collection.Items[J]);
    end;
  finally
    FreeMem(List);
  end;
end;

procedure TInspectorFrame.AddNonVisualNodes(ParentNode: TTreeNode);
var
  I: Integer;
  Component: TComponent;
  Node: TTreeNode;
begin
  for I := 0 to FDesigner.Root.ComponentCount - 1 do
  begin
    Component := FDesigner.Root.Components[I];
    if not IsNonVisual(Component) then
      Continue;
    Node := ComponentTree.Items.AddChildObject(ParentNode,
      Format('%s: %s', [Component.Name, Component.ClassName]), Component);
    AddCollectionNodes(Node, Component);
    AddSubComponentNodes(Node, Component);
  end;
end;

procedure TInspectorFrame.AddSubComponentNodes(ParentNode: TTreeNode;
  AComponent: TComponent);
var
  I: Integer;
  Child: TComponent;
  Node: TTreeNode;
begin
  for I := 0 to FDesigner.Root.ComponentCount - 1 do
  begin
    Child := FDesigner.Root.Components[I];
    if (Child is TControl) or (Child.GetParentComponent <> AComponent) then
      Continue;
    Node := ComponentTree.Items.AddChildObject(ParentNode,
      Format('%s: %s', [Child.Name, Child.ClassName]), Child);
    AddCollectionNodes(Node, Child);
    AddSubComponentNodes(Node, Child);
  end;
end;

procedure TInspectorFrame.RebuildTree;
var
  RootNode: TTreeNode;
  I: Integer;
  Root: TComponent;
  Container: TWinControl;
begin
  FUpdating := True;
  try
    ComponentTree.Items.BeginUpdate;
    try
      ComponentTree.Items.Clear;
      if FDesigner = nil then
        Exit;
      Root := FDesigner.Root;
      RootNode := ComponentTree.Items.AddObject(nil,
        Format('%s: %s', [Root.Name, FDesigner.RootClassName]), Root);
      AddCollectionNodes(RootNode, Root);
      if Root is TWinControl then
      begin
        Container := TWinControl(Root);
        for I := 0 to Container.ControlCount - 1 do
          if BelongsInTree(Container.Controls[I]) then
            AddControlNode(RootNode, Container.Controls[I]);
      end;
      AddNonVisualNodes(RootNode);
      RootNode.Expand(True);
    finally
      ComponentTree.Items.EndUpdate;
    end;
  finally
    FUpdating := False;
  end;
  SyncTreeToSelection;
end;

function TInspectorFrame.FindNodeFor(AInstance: TPersistent): TTreeNode;
var
  I: Integer;
begin
  for I := 0 to ComponentTree.Items.Count - 1 do
    if ComponentTree.Items[I].Data = Pointer(AInstance) then
      Exit(ComponentTree.Items[I]);
  Result := nil;
end;

procedure TInspectorFrame.SyncTreeToSelection;
var
  Node: TTreeNode;
  Instances: TArray<TPersistent>;
begin
  if FDesigner = nil then
    Exit;
  Node := nil;
  Instances := FDesigner.SelectedPersistents;
  if (Length(Instances) > 0) and not (Instances[0] is TComponent) then
    Node := FindNodeFor(Instances[0]);
  if Node = nil then
    Node := FindNodeFor(FDesigner.Selected);
  if (Node = nil) or (Node = ComponentTree.Selected) then
    Exit;
  FUpdating := True;
  try
    Node.Selected := True;
  finally
    FUpdating := False;
  end;
end;

procedure TInspectorFrame.ComponentTreeChange(Sender: TObject; Node: TTreeNode);
begin
  if FUpdating or (FDesigner = nil) or (Node = nil) then
    Exit;
  // SelectPersistent raises OnSelectionChanged before it returns; FUpdating
  // stops that handler from writing the selection back into the tree.
  FUpdating := True;
  try
    FDesigner.SelectPersistent(TPersistent(Node.Data));
  finally
    FUpdating := False;
  end;
end;

procedure TInspectorFrame.ComponentTreeContextPopup(Sender: TObject;
  MousePos: TPoint; var Handled: Boolean);
var
  Node: TTreeNode;
  Target: TComponent;
begin
  if FDesigner = nil then
    Exit;
  // The keyboard context-menu key reports a negative MousePos rather than a
  // client point.
  if (MousePos.X < 0) and (MousePos.Y < 0) then
    Node := ComponentTree.Selected
  else
    Node := ComponentTree.GetNodeAt(MousePos.X, MousePos.Y);
  if (Node = nil) or not (TPersistent(Node.Data) is TComponent) then
    Exit;
  Target := TComponent(Node.Data);
  if (FDesigner.SelectionCount = 1) or not FDesigner.IsSelected(Target) then
    FDesigner.SelectComponent(Target);
  Handled := True;
  FDesigner.RequestContextMenu;
end;

procedure TInspectorFrame.DesignerSelectionChanged(Sender: TObject);
begin
  if not FUpdating then
    SyncTreeToSelection;
  RebuildGrids;
end;

procedure TInspectorFrame.DesignerStructureChanged(Sender: TObject);
begin
  RebuildTree;
  RebuildGrids;
end;

end.
