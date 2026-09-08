// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Streaming.Clipboard;

// Writes a set of components as DFM text and reads that text back into a live
// document. A fragment is a sequence of top-level blocks rather than one root
// object. This unit reads and writes text only; the clipboard itself is accessed by the caller.
// Main thread only.

interface

uses
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
  Vallenta.FormEditor.Streaming.EventNames;

type
  // Raised when a fragment cannot be written or read.
  EComponentFragmentError = class(Exception);

  // Returns the name a pasted component takes. AName is the name held in the
  // fragment; an empty result or AName unchanged keeps it.
  TFragmentNaming = function(const AName: string): string of object;

  // Returns the handler name an event of a pasted component takes; called for
  // every event read, whether or not the component was renamed. AOldComponent
  // is the name held in the fragment, ANewComponent the name the component was
  // given; an empty or unchanged AMethod keeps the fragment's handler name.
  TFragmentHandlerNaming = procedure(const AOldComponent, ANewComponent,
    AEvent: string; var AMethod: string) of object;

  // One handler name a read changed. Component and Method are the new names,
  // Event the published property name; declaring the method in the source
  // unit is left to the caller.
  TFragmentHandler = record
    Component: string;
    Event: string;
    Method: string;
  end;

  // Reads one component fragment into a live document, renaming components
  // and handlers through the two callbacks. Read may be called more than once;
  // each call clears the mapping and the handler list of the previous one.
  TFragmentReader = class
  private
    FRoot: TComponent;
    FEventMap: TEventNameMap;
    FNaming: TFragmentNaming;
    FHandlerNaming: TFragmentHandlerNaming;
    // Fragment name per component read, still needed by the handler callback
    // after Name has been replaced.
    FOldNames: TDictionary<TComponent, string>;
    // Old name to new, case-insensitive, for the components this read renamed.
    FMapping: TDictionary<string, string>;
    FTopLevel: TArray<TComponent>;
    FHandlers: TArray<TFragmentHandler>;
    FBefore: TArray<TComponent>;
    procedure NoteExisting;
    procedure DiscardCreated;
    function BuildBinary(const AText: string): TMemoryStream;
    procedure HandleSetName(Reader: TReader; Component: TComponent;
      var Name: string);
    procedure HandleReferenceName(Reader: TReader; var Name: string);
    procedure HandleFindComponentClass(Reader: TReader; const AClassName: string;
      var ComponentClass: TComponentClass);
    procedure HandleHandlerName(AInstance: TComponent; const AEvent: string;
      var AName: string);
    procedure Collect(Component: TComponent);
  public
    // Both arguments are required; nil raises EComponentFragmentError.
    constructor Create(ARoot: TComponent; AEventMap: TEventNameMap);
    destructor Destroy; override;
    // Streams AText into the document; the components are owned by the root
    // given to the constructor and controls are parented into AParent, and the
    // top-level ones are returned. Any failure - a block naming a class this
    // process cannot create, among others - frees them again and raises.
    function Read(const AText: string; AParent: TComponent): TArray<TComponent>;
    // Optional; renames each component as it is read. Unassigned keeps every
    // name the fragment holds.
    property OnNaming: TFragmentNaming read FNaming write FNaming;
    // Optional; renames the handler of each event as it is read. Unassigned
    // keeps every handler name the fragment holds.
    property OnHandlerNaming: TFragmentHandlerNaming read FHandlerNaming
      write FHandlerNaming;
    // Handler names changed by the last read, one entry per method name.
    property Handlers: TArray<TFragmentHandler> read FHandlers;
  end;

// Returns the text form of AComponents, one block each, in the order given.
// ARoot is the document they belong to; references from those components to
// components outside AComponents write as plain names. AEventMap resolves the
// handler markers back to their names. Both are required; nil raises
// EComponentFragmentError.
function WriteComponentFragment(const AComponents: TArray<TComponent>;
  ARoot: TComponent; AEventMap: TEventNameMap): string;

implementation

uses
  System.Generics.Defaults,
  Vallenta.FormEditor.Streaming.TextSpans;

function WriteOneComponent(AComponent, ARoot: TComponent;
  AEventMap: TEventNameMap): string;
var
  Binary, Text: TMemoryStream;
  Writer: TWriter;
begin
  Binary := TMemoryStream.Create;
  try
    Writer := TWriter.Create(Binary, 4096);
    try
      // Root sets the writer's LookupRoot: without it a reference to a
      // component outside the copied set writes as a qualified name.
      Writer.Root := ARoot;
      Writer.OnFindMethodName := AEventMap.FindMethodName;
      Writer.WriteSignature;
      Writer.WriteComponent(AComponent);
      Writer.FlushBuffer;
    finally
      Writer.Free;
    end;
    Binary.Position := 0;
    Text := TMemoryStream.Create;
    try
      ObjectBinaryToText(Binary, Text);
      Result := DfmStreamToText(Text);
    finally
      Text.Free;
    end;
  finally
    Binary.Free;
  end;
end;

function WriteComponentFragment(const AComponents: TArray<TComponent>;
  ARoot: TComponent; AEventMap: TEventNameMap): string;
var
  Component: TComponent;
  Builder: TStringBuilder;
begin
  if AEventMap = nil then
    raise EComponentFragmentError.Create(
      'Writing a fragment needs the event name map of the document.');
  if ARoot = nil then
    raise EComponentFragmentError.Create(
      'Writing a fragment needs the document the components belong to.');
  Builder := TStringBuilder.Create;
  try
    for Component in AComponents do
      Builder.Append(WriteOneComponent(Component, ARoot, AEventMap));
    Result := Builder.ToString;
  finally
    Builder.Free;
  end;
end;

{ TFragmentReader }

constructor TFragmentReader.Create(ARoot: TComponent; AEventMap: TEventNameMap);
begin
  inherited Create;
  if ARoot = nil then
    raise EComponentFragmentError.Create(
      'Reading a fragment needs the document to read it into.');
  if AEventMap = nil then
    raise EComponentFragmentError.Create(
      'Reading a fragment needs the event name map of the document.');
  FRoot := ARoot;
  FEventMap := AEventMap;
  FOldNames := TDictionary<TComponent, string>.Create;
  FMapping := TDictionary<string, string>.Create(TIStringComparer.Ordinal);
end;

destructor TFragmentReader.Destroy;
begin
  FMapping.Free;
  FOldNames.Free;
  inherited Destroy;
end;

procedure TFragmentReader.NoteExisting;
var
  I: Integer;
begin
  SetLength(FBefore, FRoot.ComponentCount);
  for I := 0 to FRoot.ComponentCount - 1 do
    FBefore[I] := FRoot.Components[I];
end;

function ListHolds(const AList: TArray<TComponent>;
  AComponent: TComponent): Boolean;
var
  Present: TComponent;
begin
  for Present in AList do
    if Present = AComponent then
      Exit(True);
  Result := False;
end;

// Freeing a container also frees the controls it holds, so the root is
// rescanned after every free rather than iterated over a list built once.
procedure TFragmentReader.DiscardCreated;
var
  Doomed: TComponent;
  I: Integer;
begin
  repeat
    Doomed := nil;
    for I := 0 to FRoot.ComponentCount - 1 do
      if not ListHolds(FBefore, FRoot.Components[I]) then
      begin
        Doomed := FRoot.Components[I];
        Break;
      end;
    if Doomed <> nil then
      Doomed.Free;
  until Doomed = nil;
end;

// ObjectTextToBinary converts one top-level object per call, each block
// carrying its own TPF0 signature, and writes no terminator for the
// component list, so the zero byte TReader.ReadComponents stops at is
// appended once at the end.
function TFragmentReader.BuildBinary(const AText: string): TMemoryStream;
var
  Fragment: TDfmFragment;
  Source, Block: TMemoryStream;
  Bytes: TBytes;
  Terminator: Byte;
  I: Integer;
begin
  Result := TMemoryStream.Create;
  try
    Fragment := TDfmFragment.Create(AText);
    try
      if Fragment.Count = 0 then
        raise EComponentFragmentError.Create(
          'The text holds no component block.');
      for I := 0 to Fragment.Count - 1 do
      begin
        Bytes := TEncoding.UTF8.GetBytes(Fragment[I].Span.TextIn(Fragment.Text));
        Source := TMemoryStream.Create;
        try
          if Length(Bytes) > 0 then
            Source.WriteBuffer(Bytes[0], Length(Bytes));
          Source.Position := 0;
          Block := TMemoryStream.Create;
          try
            ObjectTextToBinary(Source, Block);
            Block.Position := 0;
            Result.CopyFrom(Block, Block.Size);
          finally
            Block.Free;
          end;
        finally
          Source.Free;
        end;
      end;
    finally
      Fragment.Free;
    end;
    Terminator := 0;
    Result.WriteBuffer(Terminator, SizeOf(Terminator));
    Result.Position := 0;
  except
    Result.Free;
    raise;
  end;
end;

procedure TFragmentReader.HandleSetName(Reader: TReader; Component: TComponent;
  var Name: string);
var
  Wanted: string;
begin
  FOldNames.AddOrSetValue(Component, Name);
  Wanted := '';
  if Assigned(FNaming) then
    Wanted := FNaming(Name);
  if (Wanted = '') or SameStr(Wanted, Name) then
    Exit;
  FMapping.AddOrSetValue(Name, Wanted);
  Name := Wanted;
end;

procedure TFragmentReader.HandleReferenceName(Reader: TReader; var Name: string);
var
  Mapped: string;
begin
  if FMapping.TryGetValue(Name, Mapped) then
    Name := Mapped;
end;

procedure TFragmentReader.HandleFindComponentClass(Reader: TReader;
  const AClassName: string; var ComponentClass: TComponentClass);
begin
  if ComponentClass = nil then
    raise EComponentFragmentError.CreateFmt(
      '%s is not a class this designer can create.', [AClassName]);
end;

procedure TFragmentReader.HandleHandlerName(AInstance: TComponent;
  const AEvent: string; var AName: string);
var
  Old, Wanted: string;
  Entry, Known: TFragmentHandler;
begin
  if not Assigned(FHandlerNaming) or (AInstance = nil) or
     not FOldNames.TryGetValue(AInstance, Old) then
    Exit;
  Wanted := AName;
  FHandlerNaming(Old, AInstance.Name, AEvent, Wanted);
  if (Wanted = '') or SameStr(Wanted, AName) then
    Exit;
  AName := Wanted;
  for Known in FHandlers do
    if SameText(Known.Method, Wanted) then
      Exit;
  Entry.Component := AInstance.Name;
  Entry.Event := AEvent;
  Entry.Method := Wanted;
  FHandlers := FHandlers + [Entry];
end;

procedure TFragmentReader.Collect(Component: TComponent);
begin
  FTopLevel := FTopLevel + [Component];
end;

function TFragmentReader.Read(const AText: string;
  AParent: TComponent): TArray<TComponent>;
var
  Binary: TMemoryStream;
  Reader: TDesignReader;
begin
  FTopLevel := nil;
  FHandlers := nil;
  FMapping.Clear;
  FOldNames.Clear;
  NoteExisting;
  try
    Binary := BuildBinary(AText);
    try
      Reader := TDesignReader.Create(Binary, 4096);
      try
        Reader.EventMap := FEventMap;
        Reader.OnFindComponentClass := HandleFindComponentClass;
        Reader.OnSetName := HandleSetName;
        Reader.OnReferenceName := HandleReferenceName;
        Reader.OnHandlerName := HandleHandlerName;
        // All blocks are read in one call: a reference between two fragment
        // components is fixed up within it, where a call per block would bind
        // that reference to a component the document already holds.
        Reader.ReadComponents(FRoot, AParent, Collect);
      finally
        Reader.Free;
      end;
    finally
      Binary.Free;
    end;
  except
    DiscardCreated;
    FTopLevel := nil;
    FHandlers := nil;
    raise;
  end;
  Result := FTopLevel;
end;

end.
