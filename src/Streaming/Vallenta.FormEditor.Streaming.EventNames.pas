// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Streaming.EventNames;

// Interning of DFM event handler names. The designer links no user code, so
// an event assignment in a form file is only a name, and streaming discards a
// method whose Code is nil; loading substitutes a marker method instead and
// the writer translates it back to the name on save. Thunk code and anchor
// objects are process-wide and outlive every map. No synchronization.
//
// A marker's Code is a thunk emitted for the event's own method type: a
// design-mode component may call its events, and under the Win32 register
// convention the callee pops the stack parameters, so a thunk of the wrong
// shape unbalances the caller's stack. CPUX86 only; compilation for any other
// target fails.

interface

uses
  System.Classes,
  System.TypInfo,
  System.Generics.Collections,
  Vallenta.FormEditor.Core.Log;

type
  // Interns DFM event handler names, matched case-sensitively. A marker's
  // Data identifies the name and its Code the event type, so one handler on
  // two components of the same event type yields the same marker.
  TEventNameMap = class
  private
    FNames: TStringList;
    // Identity object per interned name, indexed like FNames and used as a
    // marker's Data. The process-wide list holds every anchor and frees it at
    // finalization.
    FAnchors: TList<TObject>;
    // Anchor pointer to 1-based name index. A method whose Data is absent
    // here is not a marker of this map; the pointer is never dereferenced.
    FIndexByAnchor: TDictionary<Pointer, Integer>;
    function GetCount: Integer;
    function GetName(Index: Integer): string;
    function AnchorFor(AIndex: Integer): TObject;
  public
    constructor Create;
    destructor Destroy; override;
    // Marker for AName as an event of AEventType, which must be method type
    // info. Interns the name when it is new, so the same name and type always
    // yield the same marker.
    function MarkerFor(const AName: string; AEventType: PTypeInfo): TMethod;
    // 1-based index of the name behind AMethod; 0 for a method this map did
    // not hand out.
    function MarkerIndex(const AMethod: TMethod): Integer;
    // Interned name behind a marker; empty for a non-marker method.
    function NameFor(const AMethod: TMethod): string;
    // Replaces AOldName with ANewName, matched case-sensitively; False when
    // the name is not interned. Every component wired to the old name
    // resolves to the new one; the name is held once per anchor.
    function Rename(const AOldName, ANewName: string): Boolean;
    // True when AName is already interned, matched case-sensitively.
    function Holds(const AName: string): Boolean;
    // TWriter.OnFindMethodName callback; answers the interned name for a
    // marker and an empty string for any other method.
    procedure FindMethodName(Writer: TWriter; AMethod: TMethod; var MethodName: string);
    // Number of interned names.
    property Count: Integer read GetCount;
    // Interned name at a 0-based index.
    property Names[Index: Integer]: string read GetName;
  end;

  // Maps a handler name read from the stream before it is interned. AInstance
  // is the component the event belongs to, AEvent the property name.
  TReadHandlerName = procedure(AInstance: TComponent; const AEvent: string;
    var AName: string) of object;

  // TReader that resolves every event name to a marker interned in EventMap
  // instead of a real method address.
  TDesignReader = class(TReader)
  private
    FEventMap: TEventNameMap;
    FLog: TDesignLog;
    FOnHandlerName: TReadHandlerName;
    // Component whose properties are being read; nil while the root's own
    // properties are read. TReader calls SetName only for the components read
    // inside the root.
    FInstance: TComponent;
    function EventTypeFor(AInstance: TPersistent; const AName: string;
      ADepth: Integer): PTypeInfo;
  protected
    // Records the component whose properties follow, which
    // FindMethodInstance searches for the event type.
    procedure SetName(Component: TComponent; var Name: string); override;
  public
    // Interns the handler name as a marker for the event type of PropName;
    // reports a reader error and answers a nil method when that type is not
    // found.
    function FindMethodInstance(Root: TComponent; const MethodName: string): TMethod; override;
    // Republishes TReader's protected PropName: the property whose value is
    // being read, for an error handler to name it.
    property PropName;
    // Map every event name is interned in; must be assigned before reading.
    property EventMap: TEventNameMap read FEventMap write FEventMap;
    // Optional log target; nil disables the per-handler log lines.
    property Log: TDesignLog read FLog write FLog;
    // Optional rename of a handler name on the way in; nil interns every name
    // as the stream holds it.
    property OnHandlerName: TReadHandlerName read FOnHandlerName
      write FOnHandlerName;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Rtti;

{$IFNDEF CPUX86}
  {$MESSAGE Fatal 'Marker thunks implement the Win32 register convention only'}
{$ENDIF}

type
  TEventAnchor = class
  end;

  // Marker thunk shape: the byte count in its ret operand, and whether the
  // result is returned in ST(0).
  TThunkShape = record
    PopBytes: Integer;
    FpuResult: Boolean;
  end;

const
  // Levels of published sub-objects searched for the event being read.
  EventSearchDepth = 3;

  // Bytes reserved per thunk in a code page; the longest thunk is nine bytes.
  ThunkSlotSize = 16;
  ThunkPageSize = 4096;

var
  Thunks: TDictionary<PTypeInfo, Pointer> = nil;
  ThunkPages: TList<Pointer> = nil;
  ThunkPageUsed: Integer = 0;
  Anchors: TObjectList<TObject> = nil;
  Context: TRttiContext;

function ShapeFor(AMethodType: TRttiMethodType): TThunkShape;
var
  Convention: TCallConv;
  Regs: Integer;
  Param: TRttiParameter;
  ReturnType: TRttiType;

  procedure AddStack(ASize: Integer);
  begin
    Inc(Result.PopBytes, (ASize + 3) and not 3);
  end;

  procedure AddSlot;
  begin
    if Regs > 0 then
      Dec(Regs)
    else
      AddStack(SizeOf(Pointer));
  end;

  function PassedAsPointer(AType: TRttiType; AConst: Boolean): Boolean;
  var
    ByValueOnStack: Boolean;
  begin
    ByValueOnStack := (Convention in [ccCdecl, ccStdCall, ccSafeCall]) and
      not AConst;
    case AType.TypeKind of
      tkArray:
        Result := AType.TypeSize > SizeOf(Pointer);
      tkRecord:
        Result := not ByValueOnStack and (AType.TypeSize > SizeOf(Pointer));
      tkSet:
        Result := AType.TypeSize > SizeOf(Pointer);
      tkMRecord, tkString:
        Result := True;
      tkVariant:
        Result := not ByValueOnStack;
    else
      Result := False;
    end;
  end;

  function AnsweredThroughPointer(AType: TRttiType): Boolean;
  begin
    case AType.TypeKind of
      tkMethod, tkInterface, tkDynArray, tkUString, tkLString, tkWString,
      tkString, tkVariant:
        Result := True;
      tkRecord, tkMRecord, tkArray:
        case AType.TypeSize of
          1, 2: Result := False;
          4: Result := IsManaged(AType.Handle);
        else
          Result := True;
        end;
      tkSet:
        Result := AType.TypeSize > SizeOf(Pointer);
    else
      Result := False;
    end;
  end;

begin
  Result.PopBytes := 0;
  Result.FpuResult := False;
  Convention := AMethodType.CallingConvention;
  if Convention = ccReg then
    Regs := 3
  else
    Regs := 0;
  AddSlot; // Self
  for Param in AMethodType.GetParameters do
  begin
    if pfArray in Param.Flags then
    begin
      // Open array: data pointer plus the hidden High.
      AddSlot;
      AddSlot;
    end
    else if (Param.ParamType = nil) or
      ([pfVar, pfOut, pfReference] * Param.Flags <> []) or
      PassedAsPointer(Param.ParamType, pfConst in Param.Flags) then
      AddSlot
    else if Param.ParamType.TypeKind = tkVariant then
      AddStack(SizeOf(Variant))
    else if (Param.ParamType.TypeKind <> tkFloat) and
      (Param.ParamType.TypeSize <= SizeOf(Pointer)) then
      AddSlot
    else
      AddStack(Param.ParamType.TypeSize);
  end;
  ReturnType := AMethodType.ReturnType;
  if ReturnType <> nil then
  begin
    if Convention = ccSafeCall then
      // Safecall answers through a trailing pointer, plus an HRESULT in EAX.
      AddSlot
    else if ReturnType.TypeKind = tkFloat then
      Result.FpuResult := True
    else if AnsweredThroughPointer(ReturnType) then
      AddSlot;
  end;
  // Under cdecl the caller pops its own arguments.
  if Convention = ccCdecl then
    Result.PopBytes := 0;
end;

function NewThunkSlot: Pointer;
var
  Page: Pointer;
begin
  if (ThunkPages.Count = 0) or
    (ThunkPageUsed + ThunkSlotSize > ThunkPageSize) then
  begin
    Page := VirtualAlloc(nil, ThunkPageSize, MEM_COMMIT or MEM_RESERVE,
      PAGE_EXECUTE_READWRITE);
    if Page = nil then
      RaiseLastOSError;
    ThunkPages.Add(Page);
    ThunkPageUsed := 0;
  end;
  Result := PByte(ThunkPages.Last) + ThunkPageUsed;
  Inc(ThunkPageUsed, ThunkSlotSize);
end;

function EmitThunk(const AShape: TThunkShape): Pointer;
var
  Code: PByte;
begin
  Result := NewThunkSlot;
  Code := Result;
  // xor eax, eax / xor edx, edx: a register-returned result is zero.
  Code[0] := $31;
  Code[1] := $C0;
  Code[2] := $31;
  Code[3] := $D2;
  Inc(Code, 4);
  if AShape.FpuResult then
  begin
    // fldz
    Code[0] := $D9;
    Code[1] := $EE;
    Inc(Code, 2);
  end;
  if AShape.PopBytes = 0 then
    Code[0] := $C3 // ret
  else
  begin
    // ret imm16
    Code[0] := $C2;
    PWord(@Code[1])^ := Word(AShape.PopBytes);
  end;
  FlushInstructionCache(GetCurrentProcess, Result, ThunkSlotSize);
end;

function ThunkFor(AEventType: PTypeInfo): Pointer;
begin
  if not Thunks.TryGetValue(AEventType, Result) then
  begin
    Result := EmitThunk(ShapeFor(
      Context.GetType(AEventType) as TRttiMethodType));
    Thunks.Add(AEventType, Result);
  end;
end;

procedure ReleaseThunkPages;
var
  Page: Pointer;
begin
  for Page in ThunkPages do
    VirtualFree(Page, 0, MEM_RELEASE);
  ThunkPages.Free;
end;

function NewAnchor: TObject;
begin
  Result := TEventAnchor.Create;
  Anchors.Add(Result);
end;

{ TEventNameMap }

constructor TEventNameMap.Create;
begin
  inherited Create;
  FNames := TStringList.Create;
  // Case-insensitive matching would collapse two spellings onto one marker
  // and rename a handler on save.
  FNames.CaseSensitive := True;
  FAnchors := TList<TObject>.Create;
  FIndexByAnchor := TDictionary<Pointer, Integer>.Create;
end;

destructor TEventNameMap.Destroy;
begin
  FIndexByAnchor.Free;
  FAnchors.Free;
  FNames.Free;
  inherited Destroy;
end;

function TEventNameMap.GetCount: Integer;
begin
  Result := FNames.Count;
end;

function TEventNameMap.GetName(Index: Integer): string;
begin
  Result := FNames[Index];
end;

function TEventNameMap.AnchorFor(AIndex: Integer): TObject;
var
  Anchor: TObject;
begin
  while FAnchors.Count <= AIndex do
  begin
    Anchor := NewAnchor;
    FAnchors.Add(Anchor);
    FIndexByAnchor.Add(Anchor, FAnchors.Count);
  end;
  Result := FAnchors[AIndex];
end;

function TEventNameMap.MarkerFor(const AName: string;
  AEventType: PTypeInfo): TMethod;
var
  Index: Integer;
begin
  Index := FNames.IndexOf(AName);
  if Index < 0 then
    Index := FNames.Add(AName);
  Result.Code := ThunkFor(AEventType);
  Result.Data := AnchorFor(Index);
end;

function TEventNameMap.MarkerIndex(const AMethod: TMethod): Integer;
begin
  if not FIndexByAnchor.TryGetValue(AMethod.Data, Result) then
    Result := 0;
end;

function TEventNameMap.NameFor(const AMethod: TMethod): string;
var
  Index: Integer;
begin
  Index := MarkerIndex(AMethod) - 1;
  if (Index >= 0) and (Index < FNames.Count) then
    Result := FNames[Index]
  else
    Result := '';
end;

function TEventNameMap.Holds(const AName: string): Boolean;
begin
  Result := FNames.IndexOf(AName) >= 0;
end;

function TEventNameMap.Rename(const AOldName, ANewName: string): Boolean;
var
  Index: Integer;
begin
  Index := FNames.IndexOf(AOldName);
  Result := Index >= 0;
  if Result then
    FNames[Index] := ANewName;
end;

procedure TEventNameMap.FindMethodName(Writer: TWriter; AMethod: TMethod;
  var MethodName: string);
begin
  MethodName := NameFor(AMethod);
end;

{ TDesignReader }

procedure TDesignReader.SetName(Component: TComponent; var Name: string);
begin
  // Properties precede nested components in every block, so the component
  // named last is the one whose properties are being read.
  FInstance := Component;
  inherited SetName(Component, Name);
end;

function TDesignReader.EventTypeFor(AInstance: TPersistent; const AName: string;
  ADepth: Integer): PTypeInfo;
var
  Info: PPropInfo;
  List: PPropList;
  Count, I, J: Integer;
  Sub: TObject;
begin
  Result := nil;
  if AInstance = nil then
    Exit;
  Info := GetPropInfo(AInstance.ClassInfo, AName);
  if (Info <> nil) and (Info^.PropType^.Kind = tkMethod) then
    Exit(Info^.PropType^);
  if ADepth <= 0 then
    Exit;
  Count := GetPropList(AInstance.ClassInfo, [tkClass], nil);
  if Count = 0 then
    Exit;
  GetMem(List, Count * SizeOf(PPropInfo));
  try
    GetPropList(AInstance.ClassInfo, [tkClass], List);
    for I := 0 to Count - 1 do
    begin
      Sub := GetObjectProp(AInstance, List^[I]);
      if (Sub = nil) or (Sub is TComponent) then
        Continue;
      if Sub is TCollection then
        for J := 0 to TCollection(Sub).Count - 1 do
        begin
          Result := EventTypeFor(TCollection(Sub).Items[J], AName, ADepth - 1);
          if Result <> nil then
            Exit;
        end
      else if Sub is TPersistent then
      begin
        Result := EventTypeFor(TPersistent(Sub), AName, ADepth - 1);
        if Result <> nil then
          Exit;
      end;
    end;
  finally
    FreeMem(List);
  end;
end;

function TDesignReader.FindMethodInstance(Root: TComponent;
  const MethodName: string): TMethod;
var
  Instance: TComponent;
  EventType: PTypeInfo;
  Wanted: string;
begin
  Result.Code := nil;
  Result.Data := nil;
  Instance := FInstance;
  if Instance = nil then
    Instance := Root;
  EventType := EventTypeFor(Instance, PropName, EventSearchDepth);
  if EventType = nil then
  begin
    Error(Format('the type of event "%s" was not found on %s, so "%s" is ' +
      'not wired', [PropName, Instance.ClassName, MethodName]));
    Exit;
  end;
  Wanted := MethodName;
  if Assigned(FOnHandlerName) then
    FOnHandlerName(Instance, PropName, Wanted);
  Result := FEventMap.MarkerFor(Wanted, EventType);
  if FLog <> nil then
    FLog.AddFmt(lsInfo, 'event handler "%s" -> marker #%d',
      [Wanted, FEventMap.MarkerIndex(Result)]);
end;

initialization
  Thunks := TDictionary<PTypeInfo, Pointer>.Create;
  ThunkPages := TList<Pointer>.Create;
  Anchors := TObjectList<TObject>.Create(True);
  Context := TRttiContext.Create;

finalization
  // The thunk pages are unmapped here; a component still holding a marker
  // must already be destroyed.
  Thunks.Free;
  ReleaseThunkPages;
  Context.Free;
  Anchors.Free;

end.
