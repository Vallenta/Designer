// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Surface.Undo;

// Undo and redo history for one document. An entry holds the whole document
// image from before an editing step, with the selection name and preserved
// model of that state. Capture and restore run through OnCapture and
// OnRestore; a snapshot holds a streamed image and names only, never a
// component reference.
//
// Push runs before the step it records is applied. Nothing in this unit is
// synchronized.

interface

uses
  System.Classes,
  System.Generics.Collections,
  Vallenta.FormEditor.Core.Coupling,
  Vallenta.FormEditor.Streaming.Preserved;

type
  // Operation an entry was pushed for; with the target name it forms the
  // coalescing tag.
  TUndoOperation = (uoMove, uoResize, uoNudge, uoCreate, uoDelete, uoProperty,
    uoRootResize, uoEditor, uoZOrder); // uoEditor: pushed by PushImage

  // Set of operations, as used by CoalescingOperations.
  TUndoOperations = set of TUndoOperation;

  // One editing step: the document image to restore, with the selection and
  // preserved model recorded with it. The selection is held by name because a
  // restore frees the components it refers to and builds new ones.
  TDocumentSnapshot = class
  private
    FData: TMemoryStream;
    FSelectionName: string;
    FTag: string;
    FStep: Integer;
    FHandlers: TArray<TCreatedHandler>;
    FPreserved: TPreservedModel;
  public
    // Takes ownership of AData and APreserved.
    constructor Create(AData: TMemoryStream; const ASelectionName: string;
      APreserved: TPreservedModel);
    destructor Destroy; override;
    // Streamed document image; freed with the snapshot.
    property Data: TMemoryStream read FData;
    // Name of the selected component; empty when the root was selected.
    property SelectionName: string read FSelectionName;
    // Editing step this image belongs to. Undo and redo copy the number to the
    // image that replaces it, so one step keeps one number on either list.
    property Step: Integer read FStep;
    // Handlers the editor created for this step, at most one per method name;
    // empty for a step that created none.
    property Handlers: TArray<TCreatedHandler> read FHandlers;
    // Preserved components of the step. The image holds only components that
    // were loaded, so this model is carried beside it.
    property Preserved: TPreservedModel read FPreserved;
  end;

  // Captures the current document as a snapshot. A nil result reports a failed
  // capture and leaves the history unchanged.
  TSnapshotEvent = function(Sender: TObject): TDocumentSnapshot of object;
  // Rebuilds the document from ASnapshot, which the stack frees after the
  // event returns.
  TRestoreEvent = procedure(Sender: TObject; ASnapshot: TDocumentSnapshot) of object;

  // Reports one created handler of a step that was undone or redone; called
  // once per handler, after the restore has finished.
  TStepHandlerEvent = procedure(Sender: TObject;
    const AHandler: TCreatedHandler) of object;

  // Undo/redo history of one document, held as document images and driven
  // through the capture and restore events.
  TUndoStack = class
  private
    FUndo: TObjectList<TDocumentSnapshot>;
    FRedo: TObjectList<TDocumentSnapshot>;
    FOnCapture: TSnapshotEvent;
    FOnRestore: TRestoreEvent;
    FOnStepUndone: TStepHandlerEvent;
    FOnStepRedone: TStepHandlerEvent;
    FLastTag: string;
    FSavedDepth: Integer;
    FNextStep: Integer;
    function TagFor(AOperation: TUndoOperation; const ATarget: string): string;
    function Capture(const ATag: string): TDocumentSnapshot;
    procedure Store(AEntry: TDocumentSnapshot; const ATag: string);
    procedure Restore(ASnapshot: TDocumentSnapshot);
    procedure Carry(AFrom, ATo: TDocumentSnapshot);
    procedure Announce(const AEvent: TStepHandlerEvent;
      AEntry: TDocumentSnapshot);
    function EntryOfStep(AStep: Integer): TDocumentSnapshot;
    procedure DiscardRedo;
    procedure TrimOldest;
  public
    constructor Create;
    destructor Destroy; override;
    // Records the pre-change state through OnCapture, before the step is
    // applied. A repeat of a coalescing operation on the same target records
    // nothing.
    procedure Push(AOperation: TUndoOperation; const ATarget: string);
    // Adds an image captured earlier, for a step reported only after it was
    // applied. Takes ownership of AEntry; nil is ignored and coalescing is
    // never applied.
    procedure PushImage(AEntry: TDocumentSnapshot; AOperation: TUndoOperation;
      const ATarget: string);
    // Removes the newest undo entry, for a step that was pushed and then did
    // not happen.
    procedure DropLast;
    // Removes the entry of AStep from the undo list wherever it sits and
    // returns True when one was found. The redo list is left untouched, so an
    // already-undone step stays redoable.
    function DropStep(AStep: Integer): Boolean;
    // Restores the newest undo entry; the current state is captured onto the
    // redo list first. A failed capture leaves both lists unchanged.
    procedure Undo;
    // Restores the newest redo entry; the current state is captured onto the
    // undo list first. A failed capture leaves both lists unchanged.
    procedure Redo;
    // Empties both lists and marks the state as saved; step numbers keep
    // counting up from where they were.
    procedure Clear;
    // Records the current undo depth as the saved state.
    procedure MarkSaved;
    // Marks the saved state as unreachable, so IsDirty stays True until the
    // next MarkSaved.
    procedure MarkNeverSaved;
    // True while the undo list holds entries.
    function CanUndo: Boolean;
    // True while the redo list holds entries.
    function CanRedo: Boolean;
    // True while the undo depth differs from the one recorded by MarkSaved.
    function IsDirty: Boolean;
    // Step number of the newest undo entry; 0 without history.
    function LastStep: Integer;
    // Records a created handler on the entry of AStep, searching both lists; a
    // handler with an empty Method is ignored. False when no entry carries
    // that step number.
    function MarkCreatedHandler(AStep: Integer;
      const AHandler: TCreatedHandler): Boolean;
    // Handlers of every entry on the undo list. Undone steps sit on the redo
    // list and are not included.
    function CreatedHandlers: TArray<TCreatedHandler>;
    // Replaces the handler method name AOldName with ANewName on both lists,
    // matched case-insensitively.
    procedure RenameCreatedHandler(const AOldName, ANewName: string);
    // Captures the current document state; required for Push, Undo and Redo.
    property OnCapture: TSnapshotEvent read FOnCapture write FOnCapture;
    // Applies a snapshot to the document; without it Undo and Redo only move
    // entries between the lists.
    property OnRestore: TRestoreEvent read FOnRestore write FOnRestore;
    // Fired after an undo restore has finished, once per created handler of
    // the step.
    property OnStepUndone: TStepHandlerEvent read FOnStepUndone
      write FOnStepUndone;
    // Redo counterpart of OnStepUndone.
    property OnStepRedone: TStepHandlerEvent read FOnStepRedone
      write FOnStepRedone;
  end;

const
  // Maximum number of undo entries; the oldest is dropped beyond it.
  UndoStackLimit = 100;

  // Operations whose repeats on the same target are not recorded again; the
  // entry from the start of the run reverts the whole run.
  CoalescingOperations: TUndoOperations = [uoNudge];

  // Saved-depth value for a state no longer in the history; IsDirty then
  // stays True.
  UnreachableDepth = -1;

implementation

uses
  System.SysUtils;

{ TDocumentSnapshot }

constructor TDocumentSnapshot.Create(AData: TMemoryStream;
  const ASelectionName: string; APreserved: TPreservedModel);
begin
  inherited Create;
  FData := AData;
  FSelectionName := ASelectionName;
  FPreserved := APreserved;
end;

destructor TDocumentSnapshot.Destroy;
begin
  FPreserved.Free;
  FData.Free;
  inherited Destroy;
end;

{ TUndoStack }

constructor TUndoStack.Create;
begin
  inherited Create;
  FUndo := TObjectList<TDocumentSnapshot>.Create(True);
  FRedo := TObjectList<TDocumentSnapshot>.Create(True);
end;

destructor TUndoStack.Destroy;
begin
  FRedo.Free;
  FUndo.Free;
  inherited Destroy;
end;

function TUndoStack.CanUndo: Boolean;
begin
  Result := FUndo.Count > 0;
end;

function TUndoStack.CanRedo: Boolean;
begin
  Result := FRedo.Count > 0;
end;

function TUndoStack.IsDirty: Boolean;
begin
  Result := FUndo.Count <> FSavedDepth;
end;

procedure TUndoStack.MarkSaved;
begin
  FSavedDepth := FUndo.Count;
end;

procedure TUndoStack.MarkNeverSaved;
begin
  FSavedDepth := UnreachableDepth;
end;

procedure TUndoStack.Clear;
begin
  FUndo.Clear;
  FRedo.Clear;
  FLastTag := '';
  FSavedDepth := 0;
end;

function TUndoStack.LastStep: Integer;
begin
  if FUndo.Count = 0 then
    Exit(0);
  Result := FUndo.Last.FStep;
end;

function TUndoStack.EntryOfStep(AStep: Integer): TDocumentSnapshot;
var
  Entry: TDocumentSnapshot;
begin
  if AStep <> 0 then
  begin
    for Entry in FUndo do
      if Entry.FStep = AStep then
        Exit(Entry);
    for Entry in FRedo do
      if Entry.FStep = AStep then
        Exit(Entry);
  end;
  Result := nil;
end;

function TUndoStack.MarkCreatedHandler(AStep: Integer;
  const AHandler: TCreatedHandler): Boolean;
var
  Entry: TDocumentSnapshot;
  Known: TCreatedHandler;
begin
  Entry := EntryOfStep(AStep);
  Result := Entry <> nil;
  if not Result or (AHandler.Method = '') then
    Exit;
  for Known in Entry.FHandlers do
    if SameText(Known.Method, AHandler.Method) then
      Exit;
  Entry.FHandlers := Entry.FHandlers + [AHandler];
end;

function TUndoStack.CreatedHandlers: TArray<TCreatedHandler>;
var
  Entry: TDocumentSnapshot;
begin
  Result := nil;
  for Entry in FUndo do
    Result := Result + Entry.FHandlers;
end;

procedure TUndoStack.RenameCreatedHandler(const AOldName, ANewName: string);

  procedure Sweep(AList: TObjectList<TDocumentSnapshot>);
  var
    Entry: TDocumentSnapshot;
    I: Integer;
  begin
    for Entry in AList do
      for I := 0 to High(Entry.FHandlers) do
        if SameText(Entry.FHandlers[I].Method, AOldName) then
          Entry.FHandlers[I].Method := ANewName;
  end;

begin
  Sweep(FUndo);
  Sweep(FRedo);
end;

function TUndoStack.Capture(const ATag: string): TDocumentSnapshot;
begin
  Result := nil;
  if not Assigned(FOnCapture) then
    Exit;
  Result := FOnCapture(Self);
  if Result <> nil then
    Result.FTag := ATag;
end;

procedure TUndoStack.Restore(ASnapshot: TDocumentSnapshot);
begin
  if Assigned(FOnRestore) then
    FOnRestore(Self, ASnapshot);
end;

procedure TUndoStack.Carry(AFrom, ATo: TDocumentSnapshot);
begin
  ATo.FStep := AFrom.FStep;
  ATo.FHandlers := Copy(AFrom.FHandlers);
end;

procedure TUndoStack.Announce(const AEvent: TStepHandlerEvent;
  AEntry: TDocumentSnapshot);
var
  Handler: TCreatedHandler;
begin
  if not Assigned(AEvent) then
    Exit;
  for Handler in AEntry.FHandlers do
    AEvent(Self, Handler);
end;

procedure TUndoStack.DiscardRedo;
begin
  if FRedo.Count = 0 then
    Exit;
  if FSavedDepth > FUndo.Count then
    FSavedDepth := UnreachableDepth;
  FRedo.Clear;
end;

procedure TUndoStack.TrimOldest;
begin
  while FUndo.Count > UndoStackLimit do
  begin
    FUndo.Delete(0);
    if FSavedDepth >= 0 then
      Dec(FSavedDepth);
  end;
end;

function TUndoStack.TagFor(AOperation: TUndoOperation;
  const ATarget: string): string;
begin
  Result := Format('%d:%s', [Ord(AOperation), ATarget]);
end;

procedure TUndoStack.Store(AEntry: TDocumentSnapshot; const ATag: string);
begin
  DiscardRedo;
  Inc(FNextStep);
  AEntry.FStep := FNextStep;
  FUndo.Add(AEntry);
  FLastTag := ATag;
  TrimOldest;
end;

procedure TUndoStack.Push(AOperation: TUndoOperation; const ATarget: string);
var
  Tag: string;
  Entry: TDocumentSnapshot;
begin
  Tag := TagFor(AOperation, ATarget);
  if (AOperation in CoalescingOperations) and (Tag = FLastTag) then
    Exit;
  Entry := Capture(Tag);
  if Entry = nil then
    Exit;
  Store(Entry, Tag);
end;

procedure TUndoStack.PushImage(AEntry: TDocumentSnapshot;
  AOperation: TUndoOperation; const ATarget: string);
var
  Tag: string;
begin
  if AEntry = nil then
    Exit;
  Tag := TagFor(AOperation, ATarget);
  AEntry.FTag := Tag;
  Store(AEntry, Tag);
end;

procedure TUndoStack.DropLast;
begin
  if FUndo.Count = 0 then
    Exit;
  FUndo.Delete(FUndo.Count - 1);
  FLastTag := '';
end;

function TUndoStack.DropStep(AStep: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  if AStep = 0 then
    Exit;
  for I := FUndo.Count - 1 downto 0 do
  begin
    if FUndo[I].FStep <> AStep then
      Continue;
    FUndo.Delete(I);
    if (FSavedDepth >= 0) and (I < FSavedDepth) then
      Dec(FSavedDepth);
    FLastTag := '';
    Exit(True);
  end;
end;

procedure TUndoStack.Undo;
var
  Entry, Current: TDocumentSnapshot;
begin
  if not CanUndo then
    Exit;
  Current := Capture(FUndo.Last.FTag);
  if Current = nil then
    Exit;
  Entry := FUndo.Extract(FUndo.Last);
  try
    Carry(Entry, Current);
    FRedo.Add(Current);
    Restore(Entry);
    FLastTag := '';
    Announce(FOnStepUndone, Entry);
  finally
    Entry.Free;
  end;
end;

procedure TUndoStack.Redo;
var
  Entry, Current: TDocumentSnapshot;
begin
  if not CanRedo then
    Exit;
  Current := Capture(FRedo.Last.FTag);
  if Current = nil then
    Exit;
  Entry := FRedo.Extract(FRedo.Last);
  try
    Carry(Entry, Current);
    FUndo.Add(Current);
    Restore(Entry);
    FLastTag := '';
    Announce(FOnStepRedone, Entry);
  finally
    Entry.Free;
  end;
end;

end.
