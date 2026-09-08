// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Streaming.Frames;

// Frame classes of one document, the form file each is declared in, the live
// instances, and one untouched instance per class kept as the diff base a
// save writes against. A host form file records only what an instance
// differs in from the frame's own file, so a load builds the instance from
// that file before the host's properties are read over it.
//
// Streaming is performed by the OnLoadFrame handler, which must be assigned
// before the first CreateInstance. Destroy frees only the untouched
// instances; a live instance is owned by the document it streamed into.

interface

uses
  System.Classes,
  System.SysUtils,
  System.Generics.Collections,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Streaming.TextSpans,
  Vallenta.FormEditor.Streaming.RootClassifier;

type
  // Raised when a frame instance cannot be built, by this unit when no
  // OnLoadFrame handler is assigned or no form file is registered for the
  // class, and by the handler for a frame file that uses a frame of its own.
  EFrameInstanceError = class(Exception);

  // Builds a TFrame stub standing for the frame class ADeclaredClass and
  // streams AFileName into it, so the result's class is TFrame, not
  // ADeclaredClass. AOwner is the component owner, nil for the untouched
  // diff base.
  TFrameLoadEvent = function(const AFileName, ADeclaredClass: string;
    AOwner: TComponent): TComponent of object;

  // Frame registry of one document. Class names are matched
  // case-insensitively; live instances are keyed by object reference.
  TFrameInstances = class
  private
    FLog: TDesignLog;
    FIndex: TDfmClassIndex;
    FFrameClasses: TDictionary<string, string>;
    FInstances: TDictionary<TComponent, string>;
    FPristine: TDictionary<string, TComponent>;
    FOnLoadFrame: TFrameLoadEvent;
    function LoadFrame(const ADeclaredClass: string; AOwner: TComponent): TComponent;
  public
    // Neither ALog nor AIndex is freed here; both must outlive the registry.
    // ALog may be nil.
    constructor Create(ALog: TDesignLog; AIndex: TDfmClassIndex);
    destructor Destroy; override;
    // Registers each class in AClasses that a form file with a plain
    // "object" root declares; one without such a file stays unregistered.
    procedure RegisterInlineClasses(const AClasses: TArray<string>);
    // True when AClassName is a registered frame class.
    function IsFrameClass(const AClassName: string): Boolean;
    // Builds a live instance of ADeclaredClass and records it, plus on first
    // use for that class the untouched instance used as its diff base. The
    // caller sets the inline flag on the result; TReader sets it only on
    // components it creates itself.
    function CreateInstance(const ADeclaredClass: string;
      AOwner: TComponent): TComponent;
    // Unregisters a frame class, e.g. after its file failed to stream.
    // Instances already created stay recorded.
    procedure Withdraw(const ADeclaredClass: string);
    // Drops a live instance from the registry; the component is not freed.
    procedure Forget(AInstance: TComponent);
    // True when AComponent is a recorded live instance; False for nil.
    function IsInstance(AComponent: TComponent): Boolean;
    // Declared class of a live instance; empty for any other component.
    function DeclaredClassOf(AInstance: TComponent): string;
    // Component name and declared class of every live instance, in no defined
    // order. The writer emits the TFrame stub's class name, which
    // RestoreDeclaredClasses overwrites with these.
    function Declarations: TArray<TDfmDeclaredClass>;
    // TWriter.OnFindAncestor handler: reports the untouched instance of the
    // same frame as both ancestor and ancestor root, so only differences are
    // written. Leaves both unchanged for any other component.
    procedure FindAncestor(Writer: TWriter; Component: TComponent;
      const Name: string; var Ancestor: TComponent; var AncestorRoot: TComponent);
    // Number of recorded live instances.
    function Count: Integer;
    // Streams one frame file into an instance. CreateInstance raises
    // EFrameInstanceError while it is unassigned.
    property OnLoadFrame: TFrameLoadEvent read FOnLoadFrame write FOnLoadFrame;
  end;

// Nearest owner of AComponent carrying the inline flag, or nil when there is
// none. Searches the owner chain only, so a frame instance returns nil for
// itself: the instance belongs to the document, its owned components to the
// frame.
function FrameInstanceHolding(AComponent: TComponent): TComponent;

// True when AComponent is a frame instance or is owned, directly or through
// further owners, by one. A frame's contents come from the frame's file; the
// document records only the instance's overrides.
function BelongsToFrame(AComponent: TComponent): Boolean;

implementation

uses
  System.Generics.Defaults;

function FrameInstanceHolding(AComponent: TComponent): TComponent;
var
  Owner: TComponent;
begin
  Result := nil;
  if AComponent = nil then
    Exit;
  Owner := AComponent.Owner;
  while Owner <> nil do
  begin
    if csInline in Owner.ComponentState then
      Exit(Owner);
    Owner := Owner.Owner;
  end;
end;

function BelongsToFrame(AComponent: TComponent): Boolean;
begin
  Result := (AComponent <> nil) and
    ((csInline in AComponent.ComponentState) or
     (FrameInstanceHolding(AComponent) <> nil));
end;

{ TFrameInstances }

constructor TFrameInstances.Create(ALog: TDesignLog; AIndex: TDfmClassIndex);
begin
  inherited Create;
  FLog := ALog;
  FIndex := AIndex;
  FFrameClasses := TDictionary<string, string>.Create(TIStringComparer.Ordinal);
  FInstances := TDictionary<TComponent, string>.Create;
  FPristine := TDictionary<string, TComponent>.Create(TIStringComparer.Ordinal);
end;

destructor TFrameInstances.Destroy;
var
  Instance: TComponent;
begin
  for Instance in FPristine.Values do
    Instance.Free;
  FPristine.Free;
  FInstances.Free;
  FFrameClasses.Free;
  inherited Destroy;
end;

function TFrameInstances.Count: Integer;
begin
  Result := FInstances.Count;
end;

procedure TFrameInstances.RegisterInlineClasses(const AClasses: TArray<string>);
var
  DeclaredClass, FileName: string;
begin
  for DeclaredClass in AClasses do
  begin
    if FFrameClasses.ContainsKey(DeclaredClass) then
      Continue;
    FileName := FIndex.FileFor(DeclaredClass, [rkObject]);
    if FileName <> '' then
    begin
      FFrameClasses.Add(DeclaredClass, FileName);
      if FLog <> nil then
        FLog.AddFmt(lsInfo, 'frame "%s" is in %s',
          [DeclaredClass, ExtractFileName(FileName)]);
    end
    else if FLog <> nil then
    begin
      if Length(FIndex.ExtraDirectories) > 0 then
        FLog.AddFmt(lsWarn, 'no form file beside the document or on the ' +
          'search path declares "%s" as a plain root - the frame cannot be ' +
          'built and its text is preserved', [DeclaredClass])
      else
        FLog.AddFmt(lsWarn, 'no form file beside the document declares "%s" ' +
          'as a plain root - the frame cannot be built and its text is ' +
          'preserved', [DeclaredClass]);
    end;
  end;
end;

function TFrameInstances.IsFrameClass(const AClassName: string): Boolean;
begin
  Result := FFrameClasses.ContainsKey(AClassName);
end;

procedure TFrameInstances.Withdraw(const ADeclaredClass: string);
begin
  FFrameClasses.Remove(ADeclaredClass);
end;

function TFrameInstances.LoadFrame(const ADeclaredClass: string;
  AOwner: TComponent): TComponent;
var
  FileName: string;
begin
  if not Assigned(FOnLoadFrame) then
    raise EFrameInstanceError.Create(
      'Building a frame instance needs the loader to supply how one is streamed.');
  if not FFrameClasses.TryGetValue(ADeclaredClass, FileName) then
    raise EFrameInstanceError.CreateFmt(
      'No form file is known for the frame "%s".', [ADeclaredClass]);
  Result := FOnLoadFrame(FileName, ADeclaredClass, AOwner);
end;

function TFrameInstances.CreateInstance(const ADeclaredClass: string;
  AOwner: TComponent): TComponent;
var
  Pristine: TComponent;
begin
  // The diff base is built first so a frame file that fails to stream leaves
  // no live instance owned by the document and unrecorded here.
  if not FPristine.TryGetValue(ADeclaredClass, Pristine) then
  begin
    Pristine := LoadFrame(ADeclaredClass, nil);
    FPristine.Add(ADeclaredClass, Pristine);
  end;
  Result := LoadFrame(ADeclaredClass, AOwner);
  FInstances.Add(Result, ADeclaredClass);
end;

procedure TFrameInstances.Forget(AInstance: TComponent);
begin
  FInstances.Remove(AInstance);
end;

function TFrameInstances.IsInstance(AComponent: TComponent): Boolean;
begin
  Result := (AComponent <> nil) and FInstances.ContainsKey(AComponent);
end;

function TFrameInstances.DeclaredClassOf(AInstance: TComponent): string;
begin
  if not FInstances.TryGetValue(AInstance, Result) then
    Result := '';
end;

function TFrameInstances.Declarations: TArray<TDfmDeclaredClass>;
var
  Pair: TPair<TComponent, string>;
  Next: Integer;
begin
  SetLength(Result, FInstances.Count);
  Next := 0;
  for Pair in FInstances do
  begin
    Result[Next].ComponentName := Pair.Key.Name;
    Result[Next].DeclaredClass := Pair.Value;
    Inc(Next);
  end;
end;

procedure TFrameInstances.FindAncestor(Writer: TWriter; Component: TComponent;
  const Name: string; var Ancestor: TComponent; var AncestorRoot: TComponent);
var
  DeclaredClass: string;
  Pristine: TComponent;
begin
  if not FInstances.TryGetValue(Component, DeclaredClass) then
    Exit;
  if not FPristine.TryGetValue(DeclaredClass, Pristine) then
    Exit;
  Ancestor := Pristine;
  // TWriter collects the ancestor's children with AncestorRoot as the owner
  // filter, so it must be the untouched instance as well.
  AncestorRoot := Pristine;
end;

end.
