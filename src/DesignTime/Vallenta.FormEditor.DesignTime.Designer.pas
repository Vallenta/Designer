// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.DesignTime.Designer;

// IDesigner implementation for hosted design-time property and component
// editors, exception-guarded wrappers around the IProperty and
// IComponentEditor calls the inspector makes, and registration of the
// standard property editors that only the IDE would otherwise register.
// Holds no synchronization: everything runs on the VCL main thread.

interface

uses
  System.Classes,
  System.SysUtils,
  System.Types,
  System.TypInfo,
  System.IniFiles,
  Vcl.Controls,
  DesignIntf,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Core.Coupling,
  Vallenta.FormEditor.Streaming.EventNames;

type
  // Sends a rename of an event handler to the editor holding the unit.
  // Returns a refusal message, or '' when the request went out; the rename
  // itself is applied later, when the editor answers.
  TMethodRenameRequest = function(const AOldName, ANewName: string): string
    of object;

  // Gathers the items a design-time callback delivers one at a time into an
  // array.
  TCollector<T> = class
  private
    FItems: TArray<T>;
  public
    // Callback target; appends AItem to Items.
    procedure Take(const AItem: T);
    // Items taken so far, in call order.
    property Items: TArray<T> read FItems;
  end;

  // Modification count of a designer, which is how a caller tells whether an
  // editor dialog changed anything.
  IHostDesignerState = interface
    ['{4F2C8E71-0B93-4A62-9C1D-6E5A83B7D204}']
    // Number of Modified calls received; only ever increases.
    function ModificationCount: Integer;
  end;

  // The IDesigner passed to hosted editors, implementing every IDesigner
  // version the design-time packages query. Answers from the root component,
  // the event map, the selection, the code coupling and the injected naming
  // callback. Unimplemented methods log once per method and return a fixed
  // default; the remaining methods return a constant silently.
  TVallentaDesigner = class(TInterfacedObject, IHostDesignerState, IDesigner60,
    IDesigner70, IDesigner80, IDesigner100, IDesigner170, IDesigner200,
{$IF CompilerVersion >= 36.0} 
    IDesigner290,
{$IFEND}
    IDesigner)
  private
    FRoot: TComponent;
    FLog: TDesignLog;
    FEventMap: TEventNameMap;
    FSelection: TArray<TPersistent>;
    FUniqueName: TFunc<string, string>;
    FModifiedCount: Integer;
    FOnModified: TNotifyEvent;
    FOnSelectionRequest: TNotifyEvent;
    FRequestedSelection: TArray<TPersistent>;
    FStubbed: TStringList;
    FCoupling: ICodeCoupling;
    FOnRenameMethod: TMethodRenameRequest;
    procedure NoteOnce(const AKey, AText: string);
    procedure NoteStub(const AMethod: string);
    procedure NoteUncoupled(const AMethod, AWanted: string);
    function Coupled: Boolean;
    function EventBehind(ATypeData: PTypeData; const AEventInfo: IEventInfo;
      out AComponent: TComponent; out AEvent: string;
      out ASignature: TEventSignature; out AEventType: PTypeInfo): Boolean;
    function MakeHandler(const AName: string; ATypeData: PTypeData;
      const AEventInfo: IEventInfo): TMethod;
  public
    // AUniqueName supplies a component name not yet used in the document and
    // must not be nil; EArgumentNilException otherwise. ARoot, ALog and
    // AEventMap may each be nil, and the methods reading them then answer
    // with their defaults.
    constructor Create(ARoot: TComponent; ALog: TDesignLog;
      AEventMap: TEventNameMap; const AUniqueName: TFunc<string, string>);
    destructor Destroy; override;
    // Sets the selection reported by GetSelections. Entries are TPersistent:
    // a collection editor selects collection items, not components.
    procedure SetSelection(const AInstances: TArray<TPersistent>);
    // Selection last requested through SetSelections or
    // SelectComponent(TPersistent), read by the OnSelectionRequest handler.
    // Empty when the editor cleared it.
    property RequestedSelection: TArray<TPersistent> read FRequestedSelection;
    // Fired from Modified, after the modification count is raised.
    property OnModified: TNotifyEvent read FOnModified write FOnModified;
    // Fired when a hosted editor sets the selection; the handler reads
    // RequestedSelection.
    property OnSelectionRequest: TNotifyEvent read FOnSelectionRequest
      write FOnSelectionRequest;
    // Link to the editor holding the document's unit. While nil or not
    // Available, CreateMethod, ShowMethod and RenameMethod refuse and log
    // once per method.
    property Coupling: ICodeCoupling read FCoupling write FCoupling;
    // Target of RenameMethod; while unassigned, RenameMethod refuses and logs
    // instead of sending the request.
    property OnRenameMethod: TMethodRenameRequest read FOnRenameMethod
      write FOnRenameMethod;

    { IHostDesignerState }
    function ModificationCount: Integer;

    { IDesigner60 }
    procedure Activate;
    procedure Modified;
    function CreateMethod(const Name: string; TypeData: PTypeData): TMethod; overload;
    function GetMethodName(const Method: TMethod): string;
    procedure GetMethods(TypeData: PTypeData; Proc: TGetStrProc); overload;
    function GetPathAndBaseExeName: string;
    function GetPrivateDirectory: string;
    function GetBaseRegKey: string;
    function GetIDEOptions: TCustomIniFile;
    procedure GetSelections(const List: IDesignerSelections);
    function MethodExists(const Name: string): Boolean;
    procedure RenameMethod(const CurName, NewName: string);
    procedure SelectComponent(Instance: TPersistent); overload;
    procedure SetSelections(const List: IDesignerSelections);
    procedure ShowMethod(const Name: string);
    procedure GetComponentNames(TypeData: PTypeData; Proc: TGetStrProc);
    function GetComponent(const Name: string): TComponent;
    function GetComponentName(Component: TComponent): string;
    function GetObject(const Name: string): TPersistent;
    function GetObjectName(Instance: TPersistent): string;
    procedure GetObjectNames(TypeData: PTypeData; Proc: TGetStrProc);
    function MethodFromAncestor(const Method: TMethod): Boolean;
    function CreateComponent(ComponentClass: TComponentClass; Parent: TComponent;
      Left, Top, Width, Height: Integer): TComponent;
    function CreateCurrentComponent(Parent: TComponent; const Rect: TRect): TComponent;
    function IsComponentLinkable(Component: TComponent): Boolean;
    function IsComponentHidden(Component: TComponent): Boolean;
    procedure MakeComponentLinkable(Component: TComponent);
    procedure Revert(Instance: TPersistent; PropInfo: PPropInfo);
    function GetIsDormant: Boolean;
    procedure GetProjectModules(Proc: TGetModuleProc);
    function GetAncestorDesigner: IDesigner;
    function IsSourceReadOnly: Boolean;
    function GetScrollRanges(const ScrollPosition: TPoint): TPoint;
    procedure Edit(const Component: TComponent);
    procedure ChainCall(const MethodName, InstanceName, InstanceMethod: string;
      TypeData: PTypeData); overload;
    procedure ChainCall(const MethodName, InstanceName, InstanceMethod: string;
      const AEventInfo: IEventInfo); overload;
    procedure CopySelection;
    procedure CutSelection;
    function CanPaste: Boolean;
    procedure PasteSelection;
    procedure DeleteSelection(ADoAll: Boolean = False);
    procedure ClearSelection;
    procedure NoSelection;
    procedure ModuleFileNames(var ImplFileName, IntfFileName, FormFileName: string);
    function GetRootClassName: string;
    // Component name not yet used in the document. A leading 'T' is stripped
    // from BaseName before the naming callback passed to Create is called.
    function UniqueName(const BaseName: string): string;
    function GetRoot: TComponent;
    function GetShiftState: TShiftState;
    procedure ModalEdit(EditKey: Char; const ReturnWindow: IActivatable);
    procedure SelectItemName(const PropertyName: string);
    procedure Resurrect;
    { IDesigner70 }
    function GetActiveClassGroup: TPersistentClass;
    function FindRootAncestor(const AClassName: string): TComponent;
    { IDesigner80 }
    function CreateMethod(const Name: string; const AEventInfo: IEventInfo): TMethod; overload;
    procedure GetMethods(const AEventInfo: IEventInfo; Proc: TGetStrProc); overload;
    procedure SelectComponent(const ADesignObject: IDesignObject); overload;
    { IDesigner100 }
    function GetDesignerExtension: string;
    { IDesigner170 }
    // Value of the APPDATA environment variable; Local is ignored.
    function GetAppDataDirectory(Local: Boolean = False): string;
    { IDesigner200 }
    function GetCurrentParent: TComponent;
    { IDesigner290 }
    function CreateCurrentComponentScaled(Parent: TComponent; const Rect: TRect;
      ScaleRect: Boolean): TComponent;
    { IDesigner }
    function CreateChild(ComponentClass: TComponentClass; Parent: TComponent): TComponent;
  end;

// True when the inspector builds rows from the editors of the loaded
// design-time packages instead of from type information alone. Read once per
// process from the HostedEditors value under the package settings key.
function HostedEditors: Boolean;

// Registers the property editors for the standard VCL types (color, cursor,
// font, ...) that the IDE would otherwise register. Registers once per
// process; call it before loading design-time packages, so a package's editor
// for the same type takes precedence.
procedure InstallStandardEditors;

// Properties the design-time editors offer for ASelection. The non-nil
// entries are passed to GetComponentProperties and intersected there. False
// for an empty selection, a nil ADesigner, and a call that raised; the
// inspector then falls back to type information.
function EditorProperties(const ASelection: TArray<TPersistent>;
  const ADesigner: IDesigner; AKinds: TTypeKinds;
  out AProperties: TArray<IProperty>): Boolean;

// Display text of the property. False when the editor raised or reports no
// value available; a raising editor is confined to that property row.
function EditorValue(const AProp: IProperty; out AValue: string): Boolean;
// Attribute flags of the property, paValueList and paDialog among them.
// False when the editor raised.
function EditorAttributes(const AProp: IProperty;
  out AAttributes: TPropertyAttributes): Boolean;
// Values the editor offers as a pick list, empty when it offers none. False
// when the editor raised.
function EditorChoices(const AProp: IProperty; out AChoices: TArray<string>): Boolean;
// Sub-properties of an expandable property. False when the editor raised.
function EditorChildren(const AProp: IProperty;
  out AChildren: TArray<IProperty>): Boolean;
// Type info behind a property row; nil when the editor reports no property
// type. False when the editor raised.
function EditorPropType(const AProp: IProperty; out ATypeInfo: PTypeInfo): Boolean;

// Writes AValue through the editor. False when the write raised, and
// AMessage then holds the exception message.
function EditorSetValue(const AProp: IProperty; const AValue: string;
  out AMessage: string): Boolean;
// Runs the editor's own dialog. False when it raised, and AMessage then holds
// the exception message.
function EditorEdit(const AProp: IProperty; out AMessage: string): Boolean;

// Component editor for AComponent, TDefaultEditor when no editor class is
// registered for the type; nil for a nil AComponent or ADesigner and when the
// lookup raised. The result is implemented in a design-time package and
// must be released before the packages unload, so it is fetched per use
// rather than cached.
function ComponentEditorFor(AComponent: TComponent;
  const ADesigner: IDesigner): IComponentEditor;
// Captions of the editor's context-menu verbs; nil for a nil AEditor and when
// the editor raised.
function ComponentEditorVerbs(const AEditor: IComponentEditor): TArray<string>;
// Runs verb AVerb; a negative AVerb runs Edit, the editor's default action.
// False when the editor raised, and AMessage then holds class name and text.
function RunComponentEditor(const AEditor: IComponentEditor; AVerb: Integer;
  out AMessage: string): Boolean;

// Number of Modified calls ADesigner has received; 0 when it is nil or does
// not implement IHostDesignerState.
function ModificationCountOf(const ADesigner: IDesigner): Integer;

implementation

uses
  Winapi.Windows,
  System.StrUtils,
  Vcl.Graphics,
  DesignEditors,
  VCLEditors,
  PicEdit,
  StrEdit,
  Vallenta.FormEditor.Packages.Host;

var
  StandardEditorsInstalled: Boolean = False;

function HostedEditors: Boolean;
begin
  Result := Vallenta.FormEditor.Packages.Host.HostedEditors;
end;

procedure InstallStandardEditors;
begin
  if StandardEditorsInstalled or not Assigned(RegisterPropertyEditorProc) then
    Exit;
  StandardEditorsInstalled := True;
  RegisterPropertyEditor(TypeInfo(TComponent), nil, '', TComponentProperty);
  RegisterPropertyEditor(TypeInfo(TColor), nil, '', TColorProperty);
  RegisterPropertyEditor(TypeInfo(TCursor), nil, '', TCursorProperty);
  RegisterPropertyEditor(TypeInfo(TFont), nil, '', TFontProperty);
  RegisterPropertyEditor(TypeInfo(TBrushStyle), nil, '', TBrushStyleProperty);
  RegisterPropertyEditor(TypeInfo(TPenStyle), nil, '', TPenStyleProperty);
  RegisterPropertyEditor(TypeInfo(TModalResult), nil, '', TModalResultProperty);
  RegisterPropertyEditor(TypeInfo(TShortCut), nil, '', TShortCutProperty);
  RegisterPropertyEditor(TypeInfo(TPicture), nil, '', TPictureProperty);
  RegisterPropertyEditor(TypeInfo(TGraphic), nil, '', TGraphicProperty);
  RegisterPropertyEditor(TypeInfo(TStrings), nil, '', TStringListProperty);
end;

function EditorValue(const AProp: IProperty; out AValue: string): Boolean;
begin
  AValue := '';
  Result := False;
  try
    if not AProp.ValueAvailable then
      Exit;
    AValue := AProp.GetValue;
    Result := True;
  except
    on Exception do
      Result := False;
  end;
end;

function EditorAttributes(const AProp: IProperty;
  out AAttributes: TPropertyAttributes): Boolean;
begin
  AAttributes := [];
  try
    AAttributes := AProp.GetAttributes;
    Result := True;
  except
    on Exception do
      Result := False;
  end;
end;

procedure TCollector<T>.Take(const AItem: T);
begin
  FItems := FItems + [AItem];
end;

function EditorChoices(const AProp: IProperty;
  out AChoices: TArray<string>): Boolean;
var
  Collector: TCollector<string>;
begin
  AChoices := nil;
  Collector := TCollector<string>.Create;
  try
    try
      AProp.GetValues(Collector.Take);
      AChoices := Collector.Items;
      Result := True;
    except
      on Exception do
        Result := False;
    end;
  finally
    Collector.Free;
  end;
end;

function EditorProperties(const ASelection: TArray<TPersistent>;
  const ADesigner: IDesigner; AKinds: TTypeKinds;
  out AProperties: TArray<IProperty>): Boolean;
var
  Selections: IDesignerSelections;
  Instance: TPersistent;
  Collector: TCollector<IProperty>;
begin
  AProperties := nil;
  Result := False;
  if (Length(ASelection) = 0) or (ADesigner = nil) then
    Exit;
  Collector := TCollector<IProperty>.Create;
  try
    try
      Selections := CreateSelectionList;
      for Instance in ASelection do
        if Instance <> nil then
          Selections.Add(Instance);
      GetComponentProperties(Selections, AKinds, ADesigner, Collector.Take);
      AProperties := Collector.Items;
      Result := True;
    except
      on Exception do
        Result := False;
    end;
  finally
    Collector.Free;
  end;
end;

function EditorChildren(const AProp: IProperty;
  out AChildren: TArray<IProperty>): Boolean;
var
  Collector: TCollector<IProperty>;
begin
  AChildren := nil;
  Collector := TCollector<IProperty>.Create;
  try
    try
      AProp.GetProperties(Collector.Take);
      AChildren := Collector.Items;
      Result := True;
    except
      on Exception do
        Result := False;
    end;
  finally
    Collector.Free;
  end;
end;

function EditorPropType(const AProp: IProperty; out ATypeInfo: PTypeInfo): Boolean;
begin
  ATypeInfo := nil;
  try
    ATypeInfo := AProp.GetPropType;
    Result := True;
  except
    on Exception do
      Result := False;
  end;
end;

function EditorSetValue(const AProp: IProperty; const AValue: string;
  out AMessage: string): Boolean;
begin
  AMessage := '';
  try
    AProp.SetValue(AValue);
    Result := True;
  except
    on E: Exception do
    begin
      AMessage := E.Message;
      Result := False;
    end;
  end;
end;

function EditorEdit(const AProp: IProperty; out AMessage: string): Boolean;
begin
  AMessage := '';
  try
    AProp.Edit;
    Result := True;
  except
    on E: Exception do
    begin
      AMessage := E.Message;
      Result := False;
    end;
  end;
end;

function ComponentEditorFor(AComponent: TComponent;
  const ADesigner: IDesigner): IComponentEditor;
begin
  Result := nil;
  if (AComponent = nil) or (ADesigner = nil) then
    Exit;
  try
    Result := GetComponentEditor(AComponent, ADesigner);
  except
    on Exception do
      Result := nil;
  end;
end;

function ComponentEditorVerbs(const AEditor: IComponentEditor): TArray<string>;
var
  I: Integer;
begin
  Result := nil;
  if AEditor = nil then
    Exit;
  try
    for I := 0 to AEditor.GetVerbCount - 1 do
      Result := Result + [AEditor.GetVerb(I)];
  except
    on Exception do
      Result := nil;
  end;
end;

function RunComponentEditor(const AEditor: IComponentEditor; AVerb: Integer;
  out AMessage: string): Boolean;
begin
  AMessage := '';
  Result := False;
  if AEditor = nil then
    Exit;
  try
    if AVerb < 0 then
      AEditor.Edit
    else
      AEditor.ExecuteVerb(AVerb);
    Result := True;
  except
    on E: Exception do
      AMessage := E.ClassName + ': ' + E.Message;
  end;
end;

function ModificationCountOf(const ADesigner: IDesigner): Integer;
var
  State: IHostDesignerState;
begin
  if (ADesigner <> nil) and Supports(ADesigner, IHostDesignerState, State) then
    Result := State.ModificationCount
  else
    Result := 0;
end;

{ TVallentaDesigner }

constructor TVallentaDesigner.Create(ARoot: TComponent; ALog: TDesignLog;
  AEventMap: TEventNameMap; const AUniqueName: TFunc<string, string>);
begin
  if not Assigned(AUniqueName) then
    raise EArgumentNilException.Create(
      'A hosted designer without the document''s naming rule would name a ' +
      'component something the document has already spoken for.');
  inherited Create;
  FRoot := ARoot;
  FLog := ALog;
  FEventMap := AEventMap;
  FUniqueName := AUniqueName;
  FStubbed := TStringList.Create;
  FStubbed.Sorted := True;
  FStubbed.Duplicates := dupIgnore;
end;

destructor TVallentaDesigner.Destroy;
begin
  FStubbed.Free;
  inherited Destroy;
end;

procedure TVallentaDesigner.NoteOnce(const AKey, AText: string);
var
  Index: Integer;
begin
  if FStubbed.Find(AKey, Index) then
    Exit;
  FStubbed.Add(AKey);
  if FLog <> nil then
    FLog.Add(lsInfo, AText);
end;

procedure TVallentaDesigner.NoteStub(const AMethod: string);
begin
  NoteOnce(AMethod, Format('a hosted editor asked the designer for %s, which ' +
    'this designer does not answer yet', [AMethod]));
end;

procedure TVallentaDesigner.NoteUncoupled(const AMethod, AWanted: string);
begin
  NoteOnce(AMethod, Format('a hosted editor asked to %s, and no editor is ' +
    'attached to this document to write its unit - the form file is all this ' +
    'designer writes', [AWanted]));
end;

procedure TVallentaDesigner.SetSelection(const AInstances: TArray<TPersistent>);
begin
  FSelection := AInstances;
end;

procedure TVallentaDesigner.Modified;
begin
  Inc(FModifiedCount);
  if Assigned(FOnModified) then
    FOnModified(Self);
  // Without NotifyItemsModified the design-time layer's own windows do not
  // repaint; a collection editor would show a new item without its caption.
  NotifyItemsModified(Self);
end;

function TVallentaDesigner.ModificationCount: Integer;
begin
  Result := FModifiedCount;
end;

procedure TVallentaDesigner.GetSelections(const List: IDesignerSelections);
var
  Instance: TPersistent;
begin
  if List = nil then
    Exit;
  for Instance in FSelection do
    if Instance <> nil then
      List.Add(Instance);
end;

procedure TVallentaDesigner.SetSelections(const List: IDesignerSelections);
var
  I: Integer;
begin
  FRequestedSelection := nil;
  if List <> nil then
    for I := 0 to List.Count - 1 do
      if List[I] <> nil then
        FRequestedSelection := FRequestedSelection + [List[I]];
  if Assigned(FOnSelectionRequest) then
    FOnSelectionRequest(Self);
end;

procedure TVallentaDesigner.SelectComponent(Instance: TPersistent);
begin
  FRequestedSelection := nil;
  if Instance <> nil then
    FRequestedSelection := [Instance];
  if Assigned(FOnSelectionRequest) then
    FOnSelectionRequest(Self);
end;

function TVallentaDesigner.GetRoot: TComponent;
begin
  Result := FRoot;
end;

function TVallentaDesigner.GetRootClassName: string;
begin
  if FRoot <> nil then
    Result := FRoot.ClassName
  else
    Result := '';
end;

function TVallentaDesigner.GetComponent(const Name: string): TComponent;
begin
  if FRoot <> nil then
    Result := FRoot.FindComponent(Name)
  else
    Result := nil;
end;

function TVallentaDesigner.GetComponentName(Component: TComponent): string;
begin
  if Component <> nil then
    Result := Component.Name
  else
    Result := '';
end;

function TVallentaDesigner.GetObject(const Name: string): TPersistent;
begin
  Result := GetComponent(Name);
end;

function TVallentaDesigner.GetObjectName(Instance: TPersistent): string;
begin
  if Instance is TComponent then
    Result := TComponent(Instance).Name
  else
    Result := '';
end;

procedure TVallentaDesigner.GetComponentNames(TypeData: PTypeData;
  Proc: TGetStrProc);
var
  I: Integer;
  Accepted: TClass;
begin
  if (FRoot = nil) or not Assigned(Proc) then
    Exit;
  Accepted := nil;
  if TypeData <> nil then
    Accepted := TypeData^.ClassType;
  for I := 0 to FRoot.ComponentCount - 1 do
    if (Accepted = nil) or FRoot.Components[I].InheritsFrom(Accepted) then
      Proc(FRoot.Components[I].Name);
end;

procedure TVallentaDesigner.GetObjectNames(TypeData: PTypeData; Proc: TGetStrProc);
begin
  GetComponentNames(TypeData, Proc);
end;

function TVallentaDesigner.UniqueName(const BaseName: string): string;
var
  Stem: string;
begin
  Stem := BaseName;
  if StartsText('T', Stem) and (Length(Stem) > 1) then
    Stem := Copy(Stem, 2, MaxInt);
  Result := FUniqueName(Stem);
end;

function TVallentaDesigner.CreateComponent(ComponentClass: TComponentClass;
  Parent: TComponent; Left, Top, Width, Height: Integer): TComponent;
begin
  Result := ComponentClass.Create(FRoot);
  Result.Name := UniqueName(ComponentClass.ClassName);
  if (Result is TControl) and (Parent is TWinControl) then
  begin
    TControl(Result).Parent := TWinControl(Parent);
    if (Width > 0) and (Height > 0) then
      TControl(Result).SetBounds(Left, Top, Width, Height);
  end;
end;

function TVallentaDesigner.CreateChild(ComponentClass: TComponentClass;
  Parent: TComponent): TComponent;
begin
  Result := CreateComponent(ComponentClass, Parent, 0, 0, 0, 0);
end;

function TVallentaDesigner.GetMethodName(const Method: TMethod): string;
begin
  if (FEventMap <> nil) and (Method.Code <> nil) then
    Result := FEventMap.NameFor(Method)
  else
    Result := '';
end;

procedure TVallentaDesigner.GetMethods(TypeData: PTypeData; Proc: TGetStrProc);
var
  I: Integer;
begin
  if (FEventMap = nil) or not Assigned(Proc) then
    Exit;
  for I := 0 to FEventMap.Count - 1 do
    Proc(FEventMap.Names[I]);
end;

procedure TVallentaDesigner.GetMethods(const AEventInfo: IEventInfo;
  Proc: TGetStrProc);
begin
  GetMethods(PTypeData(nil), Proc);
end;

function TVallentaDesigner.MethodExists(const Name: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if FEventMap = nil then
    Exit;
  for I := 0 to FEventMap.Count - 1 do
    if SameText(FEventMap.Names[I], Name) then
      Exit(True);
end;

function TVallentaDesigner.MethodFromAncestor(const Method: TMethod): Boolean;
begin
  Result := False;
end;

function TVallentaDesigner.Coupled: Boolean;
begin
  Result := (FCoupling <> nil) and FCoupling.Available;
end;

function SameShape(const ASignature: TEventSignature;
  const AEventInfo: IEventInfo): Boolean;
var
  I: Integer;
begin
  if Length(ASignature.Params) <> AEventInfo.GetParamCount then
    Exit(False);
  for I := 0 to High(ASignature.Params) do
    if not SameText(ASignature.Params[I].TypeName, AEventInfo.GetParamType(I)) or
       (ASignature.Params[I].Modifier <> ModifierOf(AEventInfo.GetParamFlags(I))) then
      Exit(False);
  Result := True;
end;

function TVallentaDesigner.EventBehind(ATypeData: PTypeData;
  const AEventInfo: IEventInfo; out AComponent: TComponent; out AEvent: string;
  out ASignature: TEventSignature; out AEventType: PTypeInfo): Boolean;
var
  Instance: TPersistent;
  List: PPropList;
  Count, I: Integer;
  PropType: PTypeInfo;
  Matched: Boolean;
begin
  AComponent := nil;
  AEvent := '';
  ASignature := Default(TEventSignature);
  AEventType := nil;
  if (ATypeData = nil) and (AEventInfo = nil) then
    Exit(False);
  for Instance in FSelection do
  begin
    if not (Instance is TComponent) then
      Continue;
    Count := GetPropList(Instance.ClassInfo, [tkMethod], nil);
    if Count = 0 then
      Continue;
    GetMem(List, Count * SizeOf(PPropInfo));
    try
      GetPropList(Instance.ClassInfo, [tkMethod], List);
      for I := 0 to Count - 1 do
      begin
        PropType := List^[I]^.PropType^;
        if ATypeData <> nil then
          Matched := GetTypeData(PropType) = ATypeData
        else
          Matched := SameShape(SignatureOf(PropType), AEventInfo);
        if not Matched then
          Continue;
        AComponent := TComponent(Instance);
        AEvent := string(List^[I]^.Name);
        AEventType := PropType;
        ASignature := SignatureOf(PropType);
        Exit(True);
      end;
    finally
      FreeMem(List);
    end;
  end;
  Result := False;
end;

function TVallentaDesigner.MakeHandler(const AName: string;
  ATypeData: PTypeData; const AEventInfo: IEventInfo): TMethod;
var
  Component: TComponent;
  Event: string;
  Signature: TEventSignature;
  EventType: PTypeInfo;
begin
  Result.Code := nil;
  Result.Data := nil;
  if not Coupled or (FEventMap = nil) then
  begin
    NoteUncoupled('CreateMethod', 'have an event handler made');
    Exit;
  end;
  if not EventBehind(ATypeData, AEventInfo, Component, Event, Signature,
       EventType) then
  begin
    if FLog <> nil then
      FLog.AddFmt(lsWarn, '%s was not created: the event does not belong to ' +
        'the selected component', [AName]);
    Exit;
  end;
  Result := FEventMap.MarkerFor(AName, EventType);
  FCoupling.EnsureHandler(Component.Name, Event, AName, Signature);
end;

function TVallentaDesigner.CreateMethod(const Name: string;
  TypeData: PTypeData): TMethod;
begin
  Result := MakeHandler(Name, TypeData, nil);
end;

function TVallentaDesigner.CreateMethod(const Name: string;
  const AEventInfo: IEventInfo): TMethod;
begin
  Result := MakeHandler(Name, nil, AEventInfo);
end;

procedure TVallentaDesigner.ShowMethod(const Name: string);
begin
  if not Coupled then
  begin
    NoteUncoupled('ShowMethod', 'open an event handler');
    Exit;
  end;
  FCoupling.GotoHandler(Name);
end;

procedure TVallentaDesigner.RenameMethod(const CurName, NewName: string);
var
  Refusal: string;
begin
  if not Coupled or not Assigned(FOnRenameMethod) then
  begin
    NoteUncoupled('RenameMethod', 'have an event handler renamed');
    Exit;
  end;
  Refusal := FOnRenameMethod(CurName, NewName);
  if (Refusal <> '') and (FLog <> nil) then
    FLog.AddFmt(lsWarn, '%s was not renamed to %s: %s',
      [CurName, NewName, Refusal]);
end;

function TVallentaDesigner.GetActiveClassGroup: TPersistentClass;
begin
  Result := TControl;
end;

function TVallentaDesigner.GetPathAndBaseExeName: string;
begin
  Result := ParamStr(0);
end;

function TVallentaDesigner.GetPrivateDirectory: string;
begin
  Result := ExtractFilePath(ParamStr(0));
end;

function TVallentaDesigner.GetAppDataDirectory(Local: Boolean): string;
begin
  Result := GetEnvironmentVariable('APPDATA');
end;

function TVallentaDesigner.GetDesignerExtension: string;
begin
  Result := 'dfm';
end;

function TVallentaDesigner.GetCurrentParent: TComponent;
begin
  Result := FRoot;
end;

function TVallentaDesigner.GetShiftState: TShiftState;
begin
  Result := [];
end;

procedure TVallentaDesigner.Activate;
begin
end;

function TVallentaDesigner.GetBaseRegKey: string;
begin
  NoteStub('GetBaseRegKey');
  Result := '';
end;

function TVallentaDesigner.GetIDEOptions: TCustomIniFile;
begin
  NoteStub('GetIDEOptions');
  Result := nil;
end;

function TVallentaDesigner.CreateCurrentComponent(Parent: TComponent;
  const Rect: TRect): TComponent;
begin
  NoteStub('CreateCurrentComponent');
  Result := nil;
end;

function TVallentaDesigner.CreateCurrentComponentScaled(Parent: TComponent;
  const Rect: TRect; ScaleRect: Boolean): TComponent;
begin
  NoteStub('CreateCurrentComponentScaled');
  Result := nil;
end;

function TVallentaDesigner.IsComponentLinkable(Component: TComponent): Boolean;
begin
  Result := False;
end;

function TVallentaDesigner.IsComponentHidden(Component: TComponent): Boolean;
begin
  Result := False;
end;

procedure TVallentaDesigner.MakeComponentLinkable(Component: TComponent);
begin
  NoteStub('MakeComponentLinkable');
end;

procedure TVallentaDesigner.Revert(Instance: TPersistent; PropInfo: PPropInfo);
begin
  NoteStub('Revert');
end;

function TVallentaDesigner.GetIsDormant: Boolean;
begin
  Result := False;
end;

procedure TVallentaDesigner.GetProjectModules(Proc: TGetModuleProc);
begin
  NoteStub('GetProjectModules');
end;

function TVallentaDesigner.GetAncestorDesigner: IDesigner;
begin
  Result := nil;
end;

function TVallentaDesigner.IsSourceReadOnly: Boolean;
begin
  Result := False;
end;

function TVallentaDesigner.GetScrollRanges(const ScrollPosition: TPoint): TPoint;
begin
  Result := Point(0, 0);
end;

procedure TVallentaDesigner.Edit(const Component: TComponent);
begin
  NoteStub('Edit');
end;

procedure TVallentaDesigner.ChainCall(const MethodName, InstanceName,
  InstanceMethod: string; TypeData: PTypeData);
begin
  NoteStub('ChainCall');
end;

procedure TVallentaDesigner.ChainCall(const MethodName, InstanceName,
  InstanceMethod: string; const AEventInfo: IEventInfo);
begin
  NoteStub('ChainCall');
end;

procedure TVallentaDesigner.CopySelection;
begin
  NoteStub('CopySelection');
end;

procedure TVallentaDesigner.CutSelection;
begin
  NoteStub('CutSelection');
end;

function TVallentaDesigner.CanPaste: Boolean;
begin
  Result := False;
end;

procedure TVallentaDesigner.PasteSelection;
begin
  NoteStub('PasteSelection');
end;

procedure TVallentaDesigner.DeleteSelection(ADoAll: Boolean);
begin
  NoteStub('DeleteSelection');
end;

procedure TVallentaDesigner.ClearSelection;
begin
  NoteStub('ClearSelection');
end;

procedure TVallentaDesigner.NoSelection;
begin
  NoteStub('NoSelection');
end;

procedure TVallentaDesigner.ModuleFileNames(var ImplFileName, IntfFileName,
  FormFileName: string);
begin
  NoteStub('ModuleFileNames');
end;

procedure TVallentaDesigner.ModalEdit(EditKey: Char;
  const ReturnWindow: IActivatable);
begin
  NoteStub('ModalEdit');
end;

procedure TVallentaDesigner.SelectItemName(const PropertyName: string);
begin
  NoteStub('SelectItemName');
end;

procedure TVallentaDesigner.Resurrect;
begin
  NoteStub('Resurrect');
end;

function TVallentaDesigner.FindRootAncestor(const AClassName: string): TComponent;
begin
  NoteStub('FindRootAncestor');
  Result := nil;
end;

procedure TVallentaDesigner.SelectComponent(const ADesignObject: IDesignObject);
begin
  NoteStub('SelectComponent(IDesignObject)');
end;

end.
