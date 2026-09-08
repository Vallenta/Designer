// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Core.FieldLedger;

// Acknowledged field set of one document, diffed against the components the
// document holds now to yield the add and remove requests sent to the editor
// holding the unit. Entries are added and removed only on acknowledgement,
// not by the diff, so an unconfirmed change is reported again. Names match
// case-insensitively; the ledger holds no lock and runs on the main thread.
//
// Diff before Baseline reports every field as an add; callers gate on
// HasBaseline.

interface

uses
  System.Classes,
  System.Generics.Collections;

type
  // One form field. UnitName is the unit declaring TypeName, sent with an add
  // so the editor can complete the unit's uses clause.
  TFieldEntry = record
    Name: string;
    TypeName: string;
    UnitName: string;
  end;

  // Whether a change adds a field or removes one.
  TFieldChangeKind = (fcAdd, fcRemove);

  // One field change. Held with the pending request and passed to Acknowledge
  // when the editor confirms it.
  TFieldChange = record
    Kind: TFieldChangeKind;
    Entry: TFieldEntry;
  end;

  // One document's acknowledged field set. The entries seeded by Baseline are
  // tracked apart from those acknowledged later.
  TFieldLedger = class
  private
    FEntries: TList<TFieldEntry>;
    FSeeded: TStringList;
    FHasBaseline: Boolean;
    function IndexOf(const AName: string): Integer;
    function GetCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    // Seeds the set with the fields the document already holds, discarding any
    // previous content. Seeded entries are never reported as adds; blank and
    // duplicate names are skipped.
    procedure Baseline(const AFields: TArray<TFieldEntry>);
    // Changes since the last acknowledgement: adds in the order of AFields
    // first, then removals in ledger order. Leaves the ledger unchanged.
    function Diff(const AFields: TArray<TFieldEntry>): TArray<TFieldChange>;
    // Applies an answered change: an add inserts the entry, a remove drops it
    // and its baseline mark. Diff reports a change until it is acknowledged.
    procedure Acknowledge(const AChange: TFieldChange);
    // Acknowledged entries that were not in the baseline. The coupling resends
    // these as adds when a session attaches.
    function AddsSinceBaseline: TArray<TFieldEntry>;
    // Renames an entry in place, keeping its baseline mark, so a component
    // rename is not reported as a remove plus an add. Unknown name: no-op.
    procedure RenameKey(const AOldName, ANewName: string);
    // Copy of the acknowledged entries, in ledger order.
    function Entries: TArray<TFieldEntry>;
    // True once Baseline has run. Count cannot stand in for it: a document
    // with no components leaves the ledger empty either way.
    property HasBaseline: Boolean read FHasBaseline;
    // Number of acknowledged entries, seeded ones included.
    property Count: Integer read GetCount;
  end;

// Builds the field entry of a component from its name, its class name and the
// unit declaring that class. Returns an empty entry for nil.
function FieldOf(AComponent: TComponent): TFieldEntry;

implementation

uses
  System.SysUtils;

function FieldOf(AComponent: TComponent): TFieldEntry;
begin
  Result := Default(TFieldEntry);
  if AComponent = nil then
    Exit;
  Result.Name := AComponent.Name;
  Result.TypeName := AComponent.ClassName;
  Result.UnitName := AComponent.ClassType.UnitName;
end;

{ TFieldLedger }

constructor TFieldLedger.Create;
begin
  inherited Create;
  FEntries := TList<TFieldEntry>.Create;
  FSeeded := TStringList.Create;
  FSeeded.CaseSensitive := False;
  FSeeded.Sorted := True;
end;

destructor TFieldLedger.Destroy;
begin
  FSeeded.Free;
  FEntries.Free;
  inherited Destroy;
end;

function TFieldLedger.IndexOf(const AName: string): Integer;
var
  I: Integer;
begin
  for I := 0 to FEntries.Count - 1 do
    if SameText(FEntries[I].Name, AName) then
      Exit(I);
  Result := -1;
end;

function TFieldLedger.GetCount: Integer;
begin
  Result := FEntries.Count;
end;

procedure TFieldLedger.Baseline(const AFields: TArray<TFieldEntry>);
var
  Entry: TFieldEntry;
begin
  FEntries.Clear;
  FSeeded.Clear;
  for Entry in AFields do
  begin
    if (Entry.Name = '') or (IndexOf(Entry.Name) >= 0) then
      Continue;
    FEntries.Add(Entry);
    FSeeded.Add(Entry.Name);
  end;
  FHasBaseline := True;
end;

function TFieldLedger.Diff(const AFields: TArray<TFieldEntry>): TArray<TFieldChange>;
var
  Live: TStringList;
  Entry: TFieldEntry;
  Change: TFieldChange;
  I: Integer;
begin
  Result := nil;
  Live := TStringList.Create;
  try
    Live.CaseSensitive := False;
    Live.Sorted := True;
    for Entry in AFields do
      if (Entry.Name <> '') and (Live.IndexOf(Entry.Name) < 0) then
        Live.Add(Entry.Name);
    for Entry in AFields do
    begin
      if (Entry.Name = '') or (IndexOf(Entry.Name) >= 0) then
        Continue;
      Change.Kind := fcAdd;
      Change.Entry := Entry;
      Result := Result + [Change];
    end;
    for I := 0 to FEntries.Count - 1 do
    begin
      if Live.IndexOf(FEntries[I].Name) >= 0 then
        Continue;
      Change.Kind := fcRemove;
      Change.Entry := FEntries[I];
      Result := Result + [Change];
    end;
  finally
    Live.Free;
  end;
end;

procedure TFieldLedger.Acknowledge(const AChange: TFieldChange);
var
  At: Integer;
begin
  At := IndexOf(AChange.Entry.Name);
  case AChange.Kind of
    fcAdd:
      if At < 0 then
        FEntries.Add(AChange.Entry);
    fcRemove:
      if At >= 0 then
      begin
        FEntries.Delete(At);
        At := FSeeded.IndexOf(AChange.Entry.Name);
        if At >= 0 then
          FSeeded.Delete(At);
      end;
  end;
end;

function TFieldLedger.AddsSinceBaseline: TArray<TFieldEntry>;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to FEntries.Count - 1 do
    if FSeeded.IndexOf(FEntries[I].Name) < 0 then
      Result := Result + [FEntries[I]];
end;

procedure TFieldLedger.RenameKey(const AOldName, ANewName: string);
var
  At: Integer;
  Entry: TFieldEntry;
begin
  At := IndexOf(AOldName);
  if At < 0 then
    Exit;
  Entry := FEntries[At];
  Entry.Name := ANewName;
  FEntries[At] := Entry;
  At := FSeeded.IndexOf(AOldName);
  if At < 0 then
    Exit;
  FSeeded.Delete(At);
  FSeeded.Add(ANewName);
end;

function TFieldLedger.Entries: TArray<TFieldEntry>;
begin
  Result := FEntries.ToArray;
end;

end.
