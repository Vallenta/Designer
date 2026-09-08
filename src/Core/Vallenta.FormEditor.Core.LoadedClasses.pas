// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Core.LoadedClasses;

// Resolves a class name against the classes present in this process,
// including those in the design packages loaded this session, and names what
// such a class is built on, taken from ClassParent: a form file names its
// own class but not its ancestor. Lookup order: the streaming registry, the
// qualified name built from the unit hint, then a one-time RTTI walk.
//
// One lock serializes the walk and every table access; the registry and RTTI
// lookups ahead of it are serialized by the RTL. Packages load before the
// first document and none afterwards, so one walk covers the session; a walk
// that raises leaves the table partial and is not retried. AUnitHint
// disambiguates a bare name that two units both declare.

interface

// The loaded class named AName, nil when no loaded class carries the name.
// AUnitHint is the unit the class is expected in - for a form, its file name
// without directory or extension; an empty or wrong hint only skips the
// qualified lookup.
function LoadedClass(const AName: string;
  const AUnitHint: string = ''): TClass;

// Name of the class AName is built on, empty when no loaded class carries
// the name or the class has no parent (TObject). AUnitHint is as for
// LoadedClass.
function LoadedAncestorClass(const AName: string;
  const AUnitHint: string = ''): string;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Rtti,
  System.Generics.Collections,
  System.Generics.Defaults;

var
  Lock: TObject;
  Walked: TDictionary<string, TClass>;
  HasWalked: Boolean;

function MetaclassOf(AType: TRttiType): TClass;
begin
  if AType is TRttiInstanceType then
    Result := TRttiInstanceType(AType).MetaclassType
  else
    Result := nil;
end;

function ClassInUnit(const AName, AUnitHint: string): TClass;
var
  Context: TRttiContext;
begin
  Result := nil;
  if AUnitHint = '' then
    Exit;
  Context := TRttiContext.Create;
  try
    Result := MetaclassOf(Context.FindType(AUnitHint + '.' + AName));
  finally
    Context.Free;
  end;
end;

procedure WalkEveryClass;
var
  Context: TRttiContext;
  Found: TRttiType;
  Meta: TClass;
begin
  Walked.Clear;
  Context := TRttiContext.Create;
  try
    try
      for Found in Context.GetTypes do
      begin
        Meta := MetaclassOf(Found);
        if (Meta <> nil) and not Walked.ContainsKey(Found.Name) then
          Walked.Add(Found.Name, Meta);
      end;
    except
      on E: Exception do
        ;
    end;
  finally
    Context.Free;
  end;
end;

function LoadedClass(const AName, AUnitHint: string): TClass;
begin
  Result := nil;
  if AName = '' then
    Exit;
  Result := GetClass(AName);
  if Result <> nil then
    Exit;
  Result := ClassInUnit(AName, AUnitHint);
  if Result <> nil then
    Exit;
  TMonitor.Enter(Lock);
  try
    if not HasWalked then
    begin
      HasWalked := True;
      WalkEveryClass;
    end;
    if not Walked.TryGetValue(AName, Result) then
      Result := nil;
  finally
    TMonitor.Exit(Lock);
  end;
end;

function LoadedAncestorClass(const AName, AUnitHint: string): string;
var
  Found: TClass;
begin
  Result := '';
  Found := LoadedClass(AName, AUnitHint);
  if (Found = nil) or (Found.ClassParent = nil) then
    Exit;
  Result := Found.ClassParent.ClassName;
end;

initialization
  Lock := TObject.Create;
  Walked := TDictionary<string, TClass>.Create(TIStringComparer.Ordinal);

finalization
  Walked.Free;
  Lock.Free;

end.
