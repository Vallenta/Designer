// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Inspector.PropertyModel;

// Row model behind the property grid: one row per published property of the
// selected instance, plus child rows for set elements and for sub-objects
// such as a font. Rows are read from RTTI, or from the property editors of
// the loaded design-time packages when BuildMany is given a designer and the
// HostedEditors setting is on. Main thread only, no locking.
//
// An editor-backed row degrades to the RTTI path permanently once a read of
// its attributes, value, type or pick list fails, or its dialog raises; a
// rejected write does not degrade it. A row holds its instance and PropInfo
// as bare pointers, so the model must be cleared or rebuilt before the
// components its rows reference are freed.

interface

uses
  System.Classes,
  System.TypInfo,
  System.SysUtils,
  System.Generics.Collections,
  DesignIntf,
  Vallenta.FormEditor.Streaming.EventNames,
  Vallenta.FormEditor.Core.Coupling,
  Vallenta.FormEditor.Core.Log;

type
  // Presentation kind of a grid row. A prkName row is written through
  // IComponentRename instead of the property itself, on both row paths.
  TPropertyRowKind = (prkReadOnly, prkText, prkInteger, prkFloat, prkChar,
    prkEnum, prkSet, prkSetElement, prkColor, prkComponentRef, prkSubObject,
    prkEvent, prkName);

  // One grid row over a property of one instance and, in a multi-selection,
  // its peers; a notice row instead holds fixed text and no property. The
  // virtual methods are overridden for a row backed by a property editor.
  TPropertyRow = class
  private
    FInstance: TPersistent;
    FPropInfo: PPropInfo;
    FName: string;
    FKind: TPropertyRowKind;
    FLevel: Integer;
    FElementIndex: Integer;
    FExpanded: Boolean;
    FNoticeText: string;
    FPeers: TArray<TPersistent>;
    FChildren: TObjectList<TPropertyRow>;
    FRoot: TComponent;
    FEventMap: TEventNameMap;
    FCoupling: ICodeCoupling;
    FCouplingQuery: TCodeCouplingQuery;
    FRename: IComponentRename;
    FRefusal: string;
    FOffered: TArray<string>;
    function SetNameText(const AText: string): Boolean;
    function SetOrdinalText(const Text: string): Boolean;
    function SetSetElement(const Text: string): Boolean;
    function ApplyValueText(const Text: string): Boolean;
    function CurrentValueText: string;
    function ApplyToCurrent(const Text: string): Boolean;
    function StandOn(AInstance: TPersistent): Boolean;
    function SetEventText(const AText: string): Boolean;
    procedure WireEvent(const AName: string);
    function KnowsMethod(const AName: string): Boolean;
    function CompatibleMethods: TArray<string>;
    procedure CollectWiredNames(AInstance: TPersistent; ANames: TStringList);
  public
    constructor Create(AInstance: TPersistent; APropInfo: PPropInfo;
      const AName: string; AKind: TPropertyRowKind; ALevel: Integer);
    // Read-only row showing AText, with no property behind it: Instance is
    // nil and Kind is prkReadOnly.
    constructor CreateNotice(const AName, AText: string);
    destructor Destroy; override;
    // Display text of the value; empty when the instances of a multi-selection
    // do not all hold the same value.
    function ValueText: string; virtual;
    // True when the value can be written. An event row requires an attached
    // code editor; a name row also requires a Rename target and no rename of
    // the component in flight.
    function CanEdit: Boolean; virtual;
    // True when the row has child rows.
    function Expandable: Boolean; virtual;
    // Drop-down choices; empty for a row edited as plain text.
    function PickList: TArray<string>; virtual;
    // Writes the text to the row's instance and then to its peers; a name row
    // renames its own component only. False when the value was refused, in
    // which case nothing is written.
    function SetValueText(const Text: string): Boolean; virtual;
    // Value of a color row, used to seed the color dialog; 0 for every other
    // kind.
    function AsColor: Integer; virtual;
    // True when the row is edited through its own dialog, reached from the
    // ellipsis button.
    function HasDialog: Boolean; virtual;
    // Runs the row's dialog. True when the document changed, which decides
    // whether the caller keeps the undo entry it pushed beforehand.
    function EditValue: Boolean; virtual;
    // Reason a write or a dialog was refused; empty where the value was
    // rejected without one, as for a number that did not parse.
    function LastError: string; virtual;
    // Value read straight through RTTI, bypassing the display path;
    // '(no type information)' or '(not read)' where it cannot be read.
    function RawValueText: string;
    // True when typed text is accepted besides the pick list; event rows only.
    function AllowsFreeText: Boolean;
    // True when a code editor is attached, read through CouplingQuery; False
    // when no query is assigned.
    function Coupled: Boolean;
    // True while a rename of this component awaits its answer; name rows
    // only, and False without a Rename target.
    function Waiting: Boolean;
    // Handler parameter signature of an event row; empty for any other kind.
    function EventSignature: TEventSignature;
    // True when Activate has an effect: an editable event row whose Coupling
    // is assigned.
    function CanActivate: Boolean;
    // Double-click action of an event row: opens the wired handler, or wires
    // the IDE-style default handler name, requesting it from the editor
    // unless that handler already exists. True when the document changed,
    // which opening a handler does not.
    function Activate: Boolean;
    // Records the handler names the code editor listed for this event; one of
    // them is wired without requesting a new handler.
    procedure OfferMethods(const AMethods: TArray<string>);
    // Instance whose property the row reads and writes; nil on a notice row.
    property Instance: TPersistent read FInstance;
    // Property name shown in the grid.
    property Name: string read FName;
    // Presentation kind of the row.
    property Kind: TPropertyRowKind read FKind;
    // Indentation depth; 0 for a top-level row.
    property Level: Integer read FLevel;
    // True while this row's children are expanded; they reach the visible
    // list only while every ancestor is expanded too.
    property Expanded: Boolean read FExpanded write FExpanded;
    // Child rows: set elements or sub-object properties, freed with the row.
    property Children: TObjectList<TPropertyRow> read FChildren;
    // Root component of the document; scanned for component-reference
    // candidates and for the handler names wired anywhere in it.
    property Root: TComponent read FRoot write FRoot;
    // Interns handler names for event rows; without one an event write is
    // refused.
    property EventMap: TEventNameMap read FEventMap write FEventMap;
    // Editor-side operations for event handlers; nil only while no designer
    // is attached, not while the editor is detached.
    property Coupling: ICodeCoupling read FCoupling write FCoupling;
    // Returns whether an editor is attached; unassigned counts as uncoupled.
    property CouplingQuery: TCodeCouplingQuery read FCouplingQuery
      write FCouplingQuery;
    // Target for the rename requests of name rows; nil makes a name row
    // read-only.
    property Rename: IComponentRename read FRename write FRename;
  end;

const
  // Pick-list entry on a color row; choosing it opens the color dialog.
  CustomColorItem = 'Custom...';

type
  // Builds and holds the rows for one selection and the flattened list of the
  // visible ones; every row is freed with the model.
  TPropertyModel = class
  private
    FRows: TObjectList<TPropertyRow>;
    FVisible: TList<TPropertyRow>;
    FRoot: TComponent;
    FEventMap: TEventNameMap;
    FCoupling: ICodeCoupling;
    FCouplingQuery: TCodeCouplingQuery;
    FRename: IComponentRename;
    FLog: TDesignLog;
    FLastFallback: string;
    FMultiple: Boolean;
    procedure Adopt(ARow: TPropertyRow);
    procedure NoteFallback(AInstance: TPersistent);
    procedure BuildInto(Instance: TPersistent; Level: Integer;
      Target: TObjectList<TPropertyRow>; Events: Boolean);
    procedure AddSetElements(Row: TPropertyRow);
    function BuildFromEditors(const AInstances: TArray<TPersistent>;
      const ADesigner: IDesigner; AEvents: Boolean): Boolean;
    procedure AddEditorChildren(ARow: TPropertyRow; ALevel: Integer);
    function GetVisibleCount: Integer;
    function GetVisibleRow(Index: Integer): TPropertyRow;
  public
    constructor Create;
    destructor Destroy; override;
    // Builds rows for one instance from RTTI, replacing the current rows.
    // AEvents selects the method properties instead of the data ones; a nil
    // AInstance leaves the model empty.
    procedure Build(AInstance: TPersistent; ARoot: TComponent;
      AEventMap: TEventNameMap; AEvents: Boolean);
    // Builds rows for a selection, replacing the current rows. Several
    // instances yield only the properties they all publish with the identical
    // type, without child rows and, on the RTTI path, without a Name row.
    // Without ADesigner, or with HostedEditors off, rows come from RTTI.
    procedure BuildMany(const AInstances: TArray<TPersistent>; ARoot: TComponent;
      AEventMap: TEventNameMap; AEvents: Boolean;
      const ADesigner: IDesigner = nil);
    // Clears the model before notice rows are added.
    procedure BeginNotice;
    // Adds one read-only notice row and refreshes the visible list.
    procedure AddNotice(const AName, AText: string);
    // Removes every row and empties the visible list.
    procedure Clear;
    // Rebuilds the visible list from the row tree and the expansion flags.
    procedure Flatten;
    // Expands or collapses one row and rebuilds the visible list; a row
    // without children is left unchanged.
    procedure ToggleExpanded(Row: TPropertyRow);
    // Optional log target; a build that falls back from the hosted editors to
    // RTTI logs a warning, suppressed while the class stays the same.
    property Log: TDesignLog read FLog write FLog;
    // Editor-side operations for event handlers, copied into each row a build
    // creates; a change afterwards does not reach the rows already built.
    property CodeCoupling: ICodeCoupling read FCoupling write FCoupling;
    // Returns whether an editor is attached; copied into each row a build
    // creates.
    property CouplingQuery: TCodeCouplingQuery read FCouplingQuery
      write FCouplingQuery;
    // Target for the rename requests of name rows; copied into each row a
    // build creates.
    property Rename: IComponentRename read FRename write FRename;
    // All top-level rows, visible or not; freed with the model.
    property Rows: TObjectList<TPropertyRow> read FRows;
    // Number of rows in the flattened visible list.
    property VisibleCount: Integer read GetVisibleCount;
    // Visible rows in display order.
    property VisibleRows[Index: Integer]: TPropertyRow read GetVisibleRow; default;
  end;

implementation

uses
  System.Generics.Defaults,
  Vcl.Forms,
  Vcl.Graphics,
  Vallenta.FormEditor.DesignTime.Designer,
  Vallenta.FormEditor.Streaming.Loader;

const
  NoneRef = '(none)';

type
  // Row read and written through an IProperty of the design-time packages.
  TEditorRow = class(TPropertyRow)
  private
    FProp: IProperty;
    FDesigner: IDesigner;
    FAttributes: TPropertyAttributes;
    FMultiple: Boolean;
    FDegraded: Boolean;
    FLastError: string;
    procedure Degrade;
    function Differs: Boolean;
    function IsEvent: Boolean;
  public
    constructor Create(const AProp: IProperty; const ADesigner: IDesigner;
      AInstance: TPersistent; ALevel: Integer; AMultiple: Boolean);
    function ValueText: string; override;
    function CanEdit: Boolean; override;
    function PickList: TArray<string>; override;
    function SetValueText(const Text: string): Boolean; override;
    function HasDialog: Boolean; override;
    function EditValue: Boolean; override;
    function LastError: string; override;
    property Attributes: TPropertyAttributes read FAttributes;
    property Prop: IProperty read FProp;
  end;

type
  // Collects identifiers delivered through a TGetStrProc-style callback.
  TIdentCollector = class
  private
    FNames: TList<string>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Add(const Ident: string);
    property Names: TList<string> read FNames;
  end;

constructor TIdentCollector.Create;
begin
  inherited Create;
  FNames := TList<string>.Create;
end;

destructor TIdentCollector.Destroy;
begin
  FNames.Free;
  inherited Destroy;
end;

procedure TIdentCollector.Add(const Ident: string);
begin
  FNames.Add(Ident);
end;

{ TPropertyRow }

constructor TPropertyRow.Create(AInstance: TPersistent; APropInfo: PPropInfo;
  const AName: string; AKind: TPropertyRowKind; ALevel: Integer);
begin
  inherited Create;
  FInstance := AInstance;
  FPropInfo := APropInfo;
  FName := AName;
  FKind := AKind;
  FLevel := ALevel;
  FElementIndex := -1;
  FChildren := TObjectList<TPropertyRow>.Create(True);
end;

constructor TPropertyRow.CreateNotice(const AName, AText: string);
begin
  Create(nil, nil, AName, prkReadOnly, 0);
  FNoticeText := AText;
end;

destructor TPropertyRow.Destroy;
begin
  FChildren.Free;
  inherited Destroy;
end;

function TPropertyRow.Expandable: Boolean;
begin
  Result := FChildren.Count > 0;
end;

function TPropertyRow.HasDialog: Boolean;
begin
  Result := False;
end;

function TPropertyRow.EditValue: Boolean;
begin
  Result := False;
end;

function TPropertyRow.LastError: string;
begin
  Result := FRefusal;
end;

function TPropertyRow.AllowsFreeText: Boolean;
begin
  Result := FKind = prkEvent;
end;

function TPropertyRow.Coupled: Boolean;
begin
  Result := Assigned(FCouplingQuery) and FCouplingQuery;
end;

function TPropertyRow.Waiting: Boolean;
begin
  Result := (FKind = prkName) and (FRename <> nil) and
    (FInstance is TComponent) and FRename.RenameInFlight(TComponent(FInstance));
end;

function TPropertyRow.EventSignature: TEventSignature;
begin
  Result := Default(TEventSignature);
  if (FKind = prkEvent) and (FPropInfo <> nil) then
    Result := SignatureOf(FPropInfo^.PropType^);
end;

procedure TPropertyRow.OfferMethods(const AMethods: TArray<string>);
begin
  FOffered := AMethods;
end;

function TPropertyRow.CompatibleMethods: TArray<string>;
var
  Names: TStringList;
  I: Integer;
begin
  Result := nil;
  if (FKind <> prkEvent) or (FPropInfo = nil) or (FEventMap = nil) or
     (FRoot = nil) then
    Exit;
  Names := TStringList.Create;
  try
    // The event map interns names case-sensitively, so two spellings of one
    // name are distinct handlers and must not be merged here.
    Names.CaseSensitive := True;
    Names.Sorted := True;
    Names.Duplicates := dupIgnore;
    CollectWiredNames(FRoot, Names);
    for I := 0 to FRoot.ComponentCount - 1 do
      CollectWiredNames(FRoot.Components[I], Names);
    SetLength(Result, Names.Count);
    for I := 0 to Names.Count - 1 do
      Result[I] := Names[I];
  finally
    Names.Free;
  end;
end;

procedure TPropertyRow.CollectWiredNames(AInstance: TPersistent;
  ANames: TStringList);
var
  List: PPropList;
  Count, I: Integer;
  Method: TMethod;
  Wired: string;
begin
  Count := GetPropList(AInstance.ClassInfo, [tkMethod], nil);
  if Count = 0 then
    Exit;
  GetMem(List, Count * SizeOf(PPropInfo));
  try
    GetPropList(AInstance.ClassInfo, [tkMethod], List);
    for I := 0 to Count - 1 do
    begin
      if List^[I]^.PropType^ <> FPropInfo^.PropType^ then
        Continue;
      Method := GetMethodProp(AInstance, List^[I]);
      if Method.Code = nil then
        Continue;
      Wired := FEventMap.NameFor(Method);
      if Wired <> '' then
        ANames.Add(Wired);
    end;
  finally
    FreeMem(List);
  end;
end;

function TPropertyRow.KnowsMethod(const AName: string): Boolean;
var
  Known: string;
begin
  for Known in FOffered do
    if SameText(Known, AName) then
      Exit(True);
  for Known in CompatibleMethods do
    if SameText(Known, AName) then
      Exit(True);
  Result := False;
end;

function TPropertyRow.CanActivate: Boolean;
begin
  Result := (FKind = prkEvent) and CanEdit and (FCoupling <> nil);
end;

function TPropertyRow.Activate: Boolean;
var
  Wired, Wanted: string;
  Existed: Boolean;
begin
  Result := False;
  if not CanActivate or not (FInstance is TComponent) then
    Exit;
  Wired := Trim(CurrentValueText);
  if Wired <> '' then
  begin
    FCoupling.GotoHandler(Wired);
    Exit;
  end;
  Wanted := DefaultHandlerName(TComponent(FInstance).Name, FName);
  // KnowsMethod is asked before SetEventText interns the name, which would
  // make the answer True.
  Existed := KnowsMethod(Wanted);
  Result := SetEventText(Wanted);
  // SetEventText sends no EnsureHandler for a name KnowsMethod already
  // reports, so an existing handler is opened here instead.
  if Result and Existed then
    FCoupling.GotoHandler(Wanted);
end;

function TPropertyRow.RawValueText: string;
begin
  if (FInstance = nil) or (FPropInfo = nil) then
    Exit('(no type information)');
  case FPropInfo^.PropType^.Kind of
    tkInteger, tkEnumeration, tkChar, tkSet:
      Result := IntToStr(GetOrdProp(FInstance, FPropInfo));
    tkInt64:
      Result := IntToStr(GetInt64Prop(FInstance, FPropInfo));
    tkString, tkLString, tkUString, tkWString:
      Result := GetStrProp(FInstance, FPropInfo);
  else
    Result := '(not read)';
  end;
end;

function TPropertyRow.CanEdit: Boolean;
begin
  if FKind = prkEvent then
    Exit(Coupled);
  if FKind = prkName then
    Exit(Coupled and (FRename <> nil) and (FInstance is TComponent) and
      not Waiting);
  Result := not (FKind in [prkReadOnly, prkSet, prkSubObject]);
end;

function TPropertyRow.StandOn(AInstance: TPersistent): Boolean;
begin
  FInstance := AInstance;
  FPropInfo := GetPropInfo(AInstance.ClassInfo, FName);
  Result := FPropInfo <> nil;
end;

function TPropertyRow.ValueText: string;
var
  SavedInstance: TPersistent;
  SavedInfo: PPropInfo;
  Peer: TPersistent;
begin
  Result := CurrentValueText;
  if Length(FPeers) = 0 then
    Exit;
  SavedInstance := FInstance;
  SavedInfo := FPropInfo;
  try
    for Peer in FPeers do
      if StandOn(Peer) and (CurrentValueText <> Result) then
        Exit('');
  finally
    FInstance := SavedInstance;
    FPropInfo := SavedInfo;
  end;
end;

function TPropertyRow.CurrentValueText: string;
var
  Obj: TObject;
  Method: TMethod;
begin
  Result := '';
  case FKind of
    prkText, prkName:
      Result := GetStrProp(FInstance, FPropInfo);
    prkInteger:
      if FPropInfo^.PropType^.Kind = tkInt64 then
        Result := IntToStr(GetInt64Prop(FInstance, FPropInfo))
      else
        Result := IntToStr(GetOrdProp(FInstance, FPropInfo));
    prkFloat:
      Result := FloatToStr(GetFloatProp(FInstance, FPropInfo),
        TFormatSettings.Invariant);
    prkChar:
      Result := Char(GetOrdProp(FInstance, FPropInfo));
    prkEnum:
      Result := GetEnumName(FPropInfo^.PropType^, GetOrdProp(FInstance, FPropInfo));
    prkColor:
      Result := ColorToString(TColor(GetOrdProp(FInstance, FPropInfo)));
    prkSet:
      Result := GetSetProp(FInstance, FPropInfo, True);
    prkSetElement:
      if (GetOrdProp(FInstance, FPropInfo) and (1 shl FElementIndex)) <> 0 then
        Result := 'True'
      else
        Result := 'False';
    prkComponentRef:
      begin
        Obj := GetObjectProp(FInstance, FPropInfo);
        if Obj is TComponent then
          Result := TComponent(Obj).Name
        else
          Result := NoneRef;
      end;
    prkSubObject:
      begin
        Obj := GetObjectProp(FInstance, FPropInfo);
        if Obj <> nil then
          Result := '(' + Obj.ClassName + ')'
        else
          Result := NoneRef;
      end;
    prkEvent:
      begin
        Method := GetMethodProp(FInstance, FPropInfo);
        if (FEventMap <> nil) and (Method.Code <> nil) then
          Result := FEventMap.NameFor(Method);
      end;
    prkReadOnly:
      if FPropInfo = nil then
        Result := FNoticeText
      else if FPropInfo^.PropType^.Kind = tkMethod then
      begin
        Method := GetMethodProp(FInstance, FPropInfo);
        if (FEventMap <> nil) and (Method.Code <> nil) then
          Result := FEventMap.NameFor(Method);
      end
      else if FPropInfo^.PropType^.Kind = tkClass then
      begin
        Obj := GetObjectProp(FInstance, FPropInfo);
        if Obj <> nil then
          Result := '(' + Obj.ClassName + ')';
      end
      else
        Result := GetStrProp(FInstance, FPropInfo);
  end;
end;

function TPropertyRow.PickList: TArray<string>;
var
  TypeData: PTypeData;
  I: Integer;
  Names: TList<string>;
  Collector: TIdentCollector;
  Component: TComponent;
  Accepted: TClass;
begin
  Result := nil;
  case FKind of
    prkEvent:
      begin
        Names := TList<string>.Create;
        try
          Names.Add('');
          Names.AddRange(CompatibleMethods);
          Result := Names.ToArray;
        finally
          Names.Free;
        end;
      end;
    prkEnum:
      begin
        TypeData := GetTypeData(FPropInfo^.PropType^);
        SetLength(Result, TypeData^.MaxValue - TypeData^.MinValue + 1);
        for I := TypeData^.MinValue to TypeData^.MaxValue do
          Result[I - TypeData^.MinValue] := GetEnumName(FPropInfo^.PropType^, I);
      end;
    prkSetElement:
      Result := ['False', 'True'];
    prkColor:
      begin
        Collector := TIdentCollector.Create;
        try
          Collector.Add(CustomColorItem);
          GetColorValues(Collector.Add);
          Result := Collector.Names.ToArray;
        finally
          Collector.Free;
        end;
      end;
    prkComponentRef:
      begin
        Names := TList<string>.Create;
        try
          Names.Add(NoneRef);
          Accepted := GetTypeData(FPropInfo^.PropType^)^.ClassType;
          if FRoot <> nil then
            for I := 0 to FRoot.ComponentCount - 1 do
            begin
              Component := FRoot.Components[I];
              if Component.InheritsFrom(Accepted) then
                Names.Add(Component.Name);
            end;
          Result := Names.ToArray;
        finally
          Names.Free;
        end;
      end;
  end;
end;

function TPropertyRow.AsColor: Integer;
begin
  if FKind = prkColor then
    Result := GetOrdProp(FInstance, FPropInfo)
  else
    Result := 0;
end;

function TPropertyRow.SetOrdinalText(const Text: string): Boolean;
var
  Value: Int64;
  EnumValue: Integer;
  Color: TColor;
begin
  Result := False;
  case FKind of
    prkInteger:
      begin
        if not TryStrToInt64(Trim(Text), Value) then
          Exit;
        if FPropInfo^.PropType^.Kind = tkInt64 then
          SetInt64Prop(FInstance, FPropInfo, Value)
        else
          SetOrdProp(FInstance, FPropInfo, Value);
      end;
    prkChar:
      begin
        if Text = '' then
          Exit;
        SetOrdProp(FInstance, FPropInfo, Ord(Text[Low(Text)]));
      end;
    prkEnum:
      begin
        EnumValue := GetEnumValue(FPropInfo^.PropType^, Trim(Text));
        if EnumValue < 0 then
          Exit;
        SetOrdProp(FInstance, FPropInfo, EnumValue);
      end;
    prkColor:
      begin
        if not IdentToColor(Trim(Text), Integer(Color)) and
           not TryStrToInt(Trim(Text), Integer(Color)) then
          Exit;
        SetOrdProp(FInstance, FPropInfo, Color);
      end;
  end;
  Result := True;
end;

function TPropertyRow.SetSetElement(const Text: string): Boolean;
var
  Current: Integer;
  Bit: Integer;
begin
  Result := False;
  if not SameText(Text, 'True') and not SameText(Text, 'False') then
    Exit;
  Current := GetOrdProp(FInstance, FPropInfo);
  Bit := 1 shl FElementIndex;
  if SameText(Text, 'True') then
    Current := Current or Bit
  else
    Current := Current and not Bit;
  SetOrdProp(FInstance, FPropInfo, Current);
  Result := True;
end;

function TPropertyRow.ApplyValueText(const Text: string): Boolean;
var
  FloatValue: Double;
  Target: TComponent;
begin
  Result := False;
  case FKind of
      prkText:
        begin
          SetStrProp(FInstance, FPropInfo, Text);
          Result := True;
        end;
      prkFloat:
        begin
          if not TryStrToFloat(Trim(Text), FloatValue, TFormatSettings.Invariant) then
            Exit;
          SetFloatProp(FInstance, FPropInfo, FloatValue);
          Result := True;
        end;
      prkInteger, prkChar, prkEnum, prkColor:
        Result := SetOrdinalText(Text);
      prkSetElement:
        Result := SetSetElement(Text);
      prkComponentRef:
        begin
          if SameText(Trim(Text), NoneRef) or (Trim(Text) = '') then
            SetObjectProp(FInstance, FPropInfo, nil)
          else
          begin
            if FRoot = nil then
              Exit;
            Target := FRoot.FindComponent(Trim(Text));
            if Target = nil then
              Exit;
            SetObjectProp(FInstance, FPropInfo, Target);
          end;
          Result := True;
        end;
  end;
end;

function TPropertyRow.SetNameText(const AText: string): Boolean;
begin
  FRefusal := '';
  if FRename = nil then
  begin
    FRefusal := 'this document has nowhere to send a rename';
    Exit(False);
  end;
  if not (FInstance is TComponent) then
  begin
    FRefusal := 'only a component has a name to change';
    Exit(False);
  end;
  FRefusal := FRename.BeginRename(TComponent(FInstance), Trim(AText));
  Result := FRefusal = '';
end;

function TPropertyRow.SetEventText(const AText: string): Boolean;
var
  Wanted: string;
  Known: Boolean;
  SavedInstance: TPersistent;
  SavedInfo: PPropInfo;
  Peer: TPersistent;
begin
  FRefusal := '';
  if (FEventMap = nil) or (FPropInfo = nil) then
  begin
    FRefusal := 'this document has no event map';
    Exit(False);
  end;
  Wanted := Trim(AText);
  if (Wanted <> '') and not IsIdentifier(Wanted) then
  begin
    FRefusal := Format('"%s" is not a name a unit could declare', [Wanted]);
    Exit(False);
  end;
  // KnowsMethod is asked before WireEvent interns the name, which would make
  // the answer True.
  Known := (Wanted = '') or KnowsMethod(Wanted);
  WireEvent(Wanted);
  SavedInstance := FInstance;
  SavedInfo := FPropInfo;
  try
    for Peer in FPeers do
      if StandOn(Peer) then
        WireEvent(Wanted);
  finally
    FInstance := SavedInstance;
    FPropInfo := SavedInfo;
  end;
  // EnsureHandler is sent once outside the peer loop: every peer is wired to
  // the same handler.
  if not Known and (FCoupling <> nil) and (FInstance is TComponent) then
    FCoupling.EnsureHandler(TComponent(FInstance).Name, FName, Wanted,
      EventSignature);
  Result := True;
end;

procedure TPropertyRow.WireEvent(const AName: string);
var
  Marker: TMethod;
begin
  if AName = '' then
  begin
    Marker.Code := nil;
    Marker.Data := nil;
  end
  else
    Marker := FEventMap.MarkerFor(AName, FPropInfo^.PropType^);
  SetMethodProp(FInstance, FPropInfo, Marker);
end;

function TPropertyRow.SetValueText(const Text: string): Boolean;
var
  SavedInstance: TPersistent;
  SavedInfo: PPropInfo;
  Peer: TPersistent;
begin
  if FKind = prkEvent then
    Exit(SetEventText(Text));
  if FKind = prkName then
    Exit(SetNameText(Text));
  Result := ApplyToCurrent(Text);
  if not Result or (Length(FPeers) = 0) then
    Exit;
  SavedInstance := FInstance;
  SavedInfo := FPropInfo;
  try
    for Peer in FPeers do
      if StandOn(Peer) then
        ApplyToCurrent(Text);
  finally
    FInstance := SavedInstance;
    FPropInfo := SavedInfo;
  end;
end;

function TPropertyRow.ApplyToCurrent(const Text: string): Boolean;
var
  Applied: Boolean;
begin
  Result := False;
  if not CanEdit or (FPropInfo = nil) then
    Exit;
  Applied := False;
  // Writing Left or Top of an embedded design-root form also changes its
  // Position property, which PreservingPosition restores afterwards.
  if (FInstance is TCustomForm) and (TCustomForm(FInstance).Parent <> nil) and
     ((FName = 'Left') or (FName = 'Top')) then
    PreservingPosition(TCustomForm(FInstance),
      procedure
      begin
        Applied := ApplyValueText(Text);
      end)
  else
    Applied := ApplyValueText(Text);
  Result := Applied;
end;

{ TPropertyModel }

constructor TPropertyModel.Create;
begin
  inherited Create;
  FRows := TObjectList<TPropertyRow>.Create(True);
  FVisible := TList<TPropertyRow>.Create;
end;

destructor TPropertyModel.Destroy;
begin
  FVisible.Free;
  FRows.Free;
  inherited Destroy;
end;

procedure TPropertyModel.Clear;
begin
  FRows.Clear;
  FVisible.Clear;
end;

function SharedByAll(const AInstances: TArray<TPersistent>; ARow: TPropertyRow;
  AFrom: Integer): Boolean;
var
  I: Integer;
  Info, Reference: PPropInfo;
begin
  Reference := GetPropInfo(AInstances[0].ClassInfo, ARow.Name);
  if Reference = nil then
    Exit(False);
  for I := AFrom to High(AInstances) do
  begin
    Info := GetPropInfo(AInstances[I].ClassInfo, ARow.Name);
    if (Info = nil) or (Info^.PropType^ <> Reference^.PropType^) then
      Exit(False);
  end;
  Result := True;
end;

procedure TPropertyModel.BuildMany(const AInstances: TArray<TPersistent>;
  ARoot: TComponent; AEventMap: TEventNameMap; AEvents: Boolean;
  const ADesigner: IDesigner);
var
  I: Integer;
  Row: TPropertyRow;
begin
  if Length(AInstances) = 0 then
  begin
    Clear;
    Exit;
  end;
  Clear;
  FRoot := ARoot;
  FEventMap := AEventMap;
  if HostedEditors and (ADesigner <> nil) then
  begin
    if BuildFromEditors(AInstances, ADesigner, AEvents) then
      Exit;
    NoteFallback(AInstances[0]);
  end;
  if Length(AInstances) = 1 then
  begin
    Build(AInstances[0], ARoot, AEventMap, AEvents);
    Exit;
  end;
  FMultiple := True;
  try
    BuildInto(AInstances[0], 0, FRows, AEvents);
    for I := FRows.Count - 1 downto 0 do
    begin
      Row := FRows[I];
      if SameText(Row.Name, 'Name') or not SharedByAll(AInstances, Row, 1) then
        FRows.Delete(I)
      else
        Row.FPeers := Copy(AInstances, 1, Length(AInstances) - 1);
    end;
  finally
    FMultiple := False;
  end;
  Flatten;
end;

procedure TPropertyModel.BeginNotice;
begin
  Clear;
end;

procedure TPropertyModel.AddNotice(const AName, AText: string);
begin
  FRows.Add(TPropertyRow.CreateNotice(AName, AText));
  Flatten;
end;

procedure TPropertyModel.Adopt(ARow: TPropertyRow);
begin
  ARow.Root := FRoot;
  ARow.EventMap := FEventMap;
  ARow.Coupling := FCoupling;
  ARow.CouplingQuery := FCouplingQuery;
  ARow.Rename := FRename;
end;

function TPropertyModel.GetVisibleCount: Integer;
begin
  Result := FVisible.Count;
end;

function TPropertyModel.GetVisibleRow(Index: Integer): TPropertyRow;
begin
  Result := FVisible[Index];
end;

function KindOf(PropInfo: PPropInfo; const PropName: string;
  out SubObject: Boolean): TPropertyRowKind;
var
  PropType: PTypeInfo;
  ClassType: TClass;
begin
  SubObject := False;
  PropType := PropInfo^.PropType^;
  if SameText(PropName, 'Name') then
    Exit(prkName);
  case PropType^.Kind of
    tkString, tkLString, tkUString, tkWString:
      Result := prkText;
    tkInteger:
      if SameText(string(PropType^.Name), 'TColor') then
        Result := prkColor
      else
        Result := prkInteger;
    tkInt64:
      Result := prkInteger;
    tkFloat:
      Result := prkFloat;
    tkChar, tkWChar:
      Result := prkChar;
    tkEnumeration:
      Result := prkEnum;
    tkSet:
      Result := prkSet;
    tkMethod:
      Result := prkEvent;
    tkClass:
      begin
        ClassType := GetTypeData(PropType)^.ClassType;
        if ClassType.InheritsFrom(TComponent) then
          Result := prkComponentRef
        else if ClassType.InheritsFrom(TStrings) or
                ClassType.InheritsFrom(TCollection) or
                (ClassType.ClassName = 'TPicture') then
          Result := prkReadOnly
        else if ClassType.InheritsFrom(TPersistent) then
        begin
          Result := prkSubObject;
          SubObject := True;
        end
        else
          Result := prkReadOnly;
      end;
  else
    Result := prkReadOnly;
  end;
  if (PropInfo^.SetProc = nil) and (Result <> prkSubObject) then
    Result := prkReadOnly;
end;

{ TEditorRow }

constructor TEditorRow.Create(const AProp: IProperty; const ADesigner: IDesigner;
  AInstance: TPersistent; ALevel: Integer; AMultiple: Boolean);
var
  Info: PPropInfo;
  Kind: TPropertyRowKind;
  IsSubObject: Boolean;
  PropName: string;
begin
  PropName := '';
  try
    PropName := AProp.GetName;
    Info := AProp.GetPropInfo;
  except
    on Exception do
      Info := nil;
  end;
  // Without both a PropInfo and an instance there is no RTTI path to degrade
  // to, and the RTTI calls would read through a nil instance.
  if (Info <> nil) and (AInstance <> nil) then
    Kind := KindOf(Info, PropName, IsSubObject)
  else
  begin
    Info := nil;
    Kind := prkReadOnly;
  end;
  inherited Create(AInstance, Info, PropName, Kind, ALevel);
  FProp := AProp;
  FDesigner := ADesigner;
  FMultiple := AMultiple;
  if not EditorAttributes(AProp, FAttributes) then
    Degrade;
end;

procedure TEditorRow.Degrade;
begin
  FDegraded := True;
end;

function TEditorRow.Differs: Boolean;
begin
  Result := False;
  if not FMultiple then
    Exit;
  try
    Result := not FProp.AllEqual;
  except
    on Exception do
      Result := False;
  end;
end;

function TEditorRow.ValueText: string;
begin
  if FDegraded then
    Exit(inherited ValueText);
  if Differs then
    Exit('');
  if not EditorValue(FProp, Result) then
  begin
    Degrade;
    Result := inherited ValueText;
  end;
end;

function TEditorRow.IsEvent: Boolean;
var
  Info: PTypeInfo;
begin
  // A failed type query returns True, so every caller takes its event branch
  // instead of going through an editor that raised.
  if not EditorPropType(FProp, Info) then
  begin
    Degrade;
    Exit(True);
  end;
  Result := (Info <> nil) and (Info^.Kind = tkMethod);
end;

function TEditorRow.CanEdit: Boolean;
begin
  Result := False;
  if FDegraded then
    Exit(inherited CanEdit);
  if Kind = prkName then
    Exit(inherited CanEdit);
  if IsEvent then
    Exit((Kind = prkEvent) and inherited CanEdit);
  if paDisplayReadOnly in FAttributes then
    Exit;
  if paReadOnly in FAttributes then
    Exit((paValueEditable in FAttributes) and
      ((paValueList in FAttributes) or HasDialog));
  Result := True;
end;

function TEditorRow.HasDialog: Boolean;
begin
  if FDegraded then
    Exit(inherited HasDialog);
  // An editor dialog on a name row would write the name locally instead of
  // through IComponentRename.
  if Kind = prkName then
    Exit(False);
  if IsEvent then
    Exit(inherited HasDialog);
  // paDialog means an ellipsis button. A paCustomDropDown row without a pick
  // list has no drop-down control here, so its editor is reached through the
  // ellipsis as well.
  Result := (paDialog in FAttributes) or
    ((paCustomDropDown in FAttributes) and not (paValueList in FAttributes));
end;

function TEditorRow.SetValueText(const Text: string): Boolean;
begin
  FLastError := '';
  if FDegraded or (Kind in [prkEvent, prkName]) then
    Exit(inherited SetValueText(Text));
  if not CanEdit then
    Exit(False);
  Result := EditorSetValue(FProp, Text, FLastError);
end;

function TEditorRow.EditValue: Boolean;
var
  Before: Integer;
begin
  FLastError := '';
  Result := False;
  if FDegraded or not HasDialog then
    Exit;
  // A dialog such as the font dialog changes the object in place and leaves
  // the row text unchanged, so the designer's modification count is the test.
  Before := ModificationCountOf(FDesigner);
  if not EditorEdit(FProp, FLastError) then
  begin
    Degrade;
    Exit;
  end;
  Result := ModificationCountOf(FDesigner) > Before;
end;

function TEditorRow.LastError: string;
begin
  if Kind in [prkEvent, prkName] then
    Exit(inherited LastError);
  Result := FLastError;
end;

function TEditorRow.PickList: TArray<string>;
begin
  Result := nil;
  if FDegraded or (Kind in [prkEvent, prkName]) then
    Exit(inherited PickList);
  if not (paValueList in FAttributes) then
    Exit;
  if not EditorChoices(FProp, Result) then
  begin
    Degrade;
    Result := inherited PickList;
  end;
end;

function SubObjectOf(ARow: TPropertyRow): TPersistent;
var
  Value: TObject;
begin
  Result := nil;
  if (ARow.Instance = nil) or (ARow.FPropInfo = nil) or
    (ARow.FPropInfo^.PropType^.Kind <> tkClass) then
    Exit;
  Value := GetObjectProp(ARow.Instance, ARow.FPropInfo);
  if Value is TPersistent then
    Result := TPersistent(Value);
end;

procedure TPropertyModel.AddEditorChildren(ARow: TPropertyRow; ALevel: Integer);
var
  Parent: TEditorRow;
  Children: TArray<IProperty>;
  Child: IProperty;
  ChildRow: TEditorRow;
begin
  if (ALevel > 2) or not (ARow is TEditorRow) then
    Exit;
  Parent := TEditorRow(ARow);
  if Parent.FMultiple or not (paSubProperties in Parent.Attributes) then
    Exit;
  if not EditorChildren(Parent.Prop, Children) then
    Exit;
  for Child in Children do
  begin
    ChildRow := TEditorRow.Create(Child, Parent.FDesigner, SubObjectOf(Parent),
      ALevel, False);
    Adopt(ChildRow);
    ARow.Children.Add(ChildRow);
    AddEditorChildren(ChildRow, ALevel + 1);
  end;
end;

procedure TPropertyModel.NoteFallback(AInstance: TPersistent);
begin
  if (FLog = nil) or (AInstance = nil) or
    (FLastFallback = AInstance.ClassName) then
    Exit;
  FLastFallback := AInstance.ClassName;
  FLog.AddFmt(lsWarn, 'the hosted editors did not describe %s - its rows come ' +
    'from type information instead', [AInstance.ClassName]);
end;

function TPropertyModel.BuildFromEditors(const AInstances: TArray<TPersistent>;
  const ADesigner: IDesigner; AEvents: Boolean): Boolean;
var
  Kinds: TTypeKinds;
  Props: TArray<IProperty>;
  Prop: IProperty;
  Row: TEditorRow;
begin
  if AEvents then
    Kinds := tkMethods
  else
    Kinds := tkProperties;
  Result := EditorProperties(AInstances, ADesigner, Kinds, Props);
  // An empty property list is a valid result and must not send the caller
  // back to RTTI, so Result stays True here.
  if not Result or (Length(Props) = 0) then
    Exit;
  for Prop in Props do
  begin
    Row := TEditorRow.Create(Prop, ADesigner, AInstances[0], 0,
      Length(AInstances) > 1);
    Adopt(Row);
    // The peers let a degraded row write the whole selection over the RTTI
    // path, where no editor applies the value to the other instances.
    if Length(AInstances) > 1 then
      Row.FPeers := Copy(AInstances, 1, Length(AInstances) - 1);
    FRows.Add(Row);
    AddEditorChildren(Row, 1);
  end;
  FRows.Sort(TComparer<TPropertyRow>.Construct(
    function(const A, B: TPropertyRow): Integer
    begin
      Result := CompareText(A.Name, B.Name);
    end));
  Flatten;
end;

procedure TPropertyModel.AddSetElements(Row: TPropertyRow);
var
  CompType: PTypeInfo;
  TypeData: PTypeData;
  I: Integer;
  Child: TPropertyRow;
begin
  CompType := GetTypeData(Row.FPropInfo^.PropType^)^.CompType^;
  TypeData := GetTypeData(CompType);
  for I := TypeData^.MinValue to TypeData^.MaxValue do
  begin
    Child := TPropertyRow.Create(Row.Instance, Row.FPropInfo,
      GetEnumName(CompType, I), prkSetElement, Row.Level + 1);
    Child.FElementIndex := I;
    Adopt(Child);
    Row.Children.Add(Child);
  end;
end;

procedure TPropertyModel.BuildInto(Instance: TPersistent; Level: Integer;
  Target: TObjectList<TPropertyRow>; Events: Boolean);
var
  PropList: PPropList;
  Count, I: Integer;
  PropInfo: PPropInfo;
  Kind: TPropertyRowKind;
  IsSubObject, IsMethod: Boolean;
  Row: TPropertyRow;
  SubInstance: TObject;
begin
  Count := GetPropList(Instance, PropList);
  if Count = 0 then
    Exit;
  try
    for I := 0 to Count - 1 do
    begin
      PropInfo := PropList^[I];
      IsMethod := PropInfo^.PropType^.Kind = tkMethod;
      if IsMethod <> Events then
        Continue;
      Kind := KindOf(PropInfo, string(PropInfo^.Name), IsSubObject);
      Row := TPropertyRow.Create(Instance, PropInfo, string(PropInfo^.Name),
        Kind, Level);
      Adopt(Row);
      Target.Add(Row);
      if FMultiple then
        Continue;
      if Kind = prkSet then
        AddSetElements(Row)
      else if IsSubObject and (Level < 2) then
      begin
        SubInstance := GetObjectProp(Instance, PropInfo);
        if SubInstance is TPersistent then
          BuildInto(TPersistent(SubInstance), Level + 1, Row.Children, False);
      end;
    end;
  finally
    FreeMem(PropList);
  end;
  Target.Sort(TComparer<TPropertyRow>.Construct(
    function(const A, B: TPropertyRow): Integer
    begin
      Result := CompareText(A.Name, B.Name);
    end));
end;

procedure TPropertyModel.Build(AInstance: TPersistent; ARoot: TComponent;
  AEventMap: TEventNameMap; AEvents: Boolean);
begin
  Clear;
  FRoot := ARoot;
  FEventMap := AEventMap;
  if AInstance = nil then
    Exit;
  BuildInto(AInstance, 0, FRows, AEvents);
  Flatten;
end;

procedure TPropertyModel.Flatten;

  procedure Walk(Rows: TObjectList<TPropertyRow>);
  var
    Row: TPropertyRow;
  begin
    for Row in Rows do
    begin
      FVisible.Add(Row);
      if Row.Expanded then
        Walk(Row.Children);
    end;
  end;

begin
  FVisible.Clear;
  Walk(FRows);
end;

procedure TPropertyModel.ToggleExpanded(Row: TPropertyRow);
begin
  if not Row.Expandable then
    Exit;
  Row.Expanded := not Row.Expanded;
  Flatten;
end;

end.
