// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Packages.Dependencies;

// Loads the packages that the package at a given path imports, deepest
// first, from the .bpl names in its PE import table read from disk. A module
// already mapped in the process is added to the chain but not loaded again;
// LoadPackage would run its unit initialization a second time. Import cycles
// are skipped, and recursion stops without an error past 16 levels.
//
// State is held in module-level variables without locking; concurrent or
// nested EnsureDependencies calls are not supported. Packages loaded by a
// successful call stay loaded for the lifetime of the process; only a failed
// call unloads what it loaded.

interface

uses
  Winapi.Windows,
  System.SysUtils;

type
  // One package on a dependency chain.
  TLoadedDependency = record
    // File name as the import table stores it, without a directory.
    Name: string;
    // File the package was loaded from; empty when the module was
    // already mapped.
    Path: string;
    // Module handle, from LoadPackage or from the module already mapped.
    Module: HMODULE;
  end;

// Loads every package the package at APath imports, deepest first; APath
// itself is not loaded. AChain also lists modules already mapped. On False,
// AMissing names the unresolved import, AChain is empty, and modules loaded
// by this call are unloaded after the optional ABeforeRollback runs.
function EnsureDependencies(const APath: string;
  out AChain: TArray<TLoadedDependency>; out AMissing: string;
  const ABeforeRollback: TProc): Boolean;

// Every package this unit has loaded since process start, in load order;
// modules that were already mapped are not among them, and entries are
// removed only by the rollback of a failed EnsureDependencies call. The
// result aliases the unit's array; element writes reach the unit state.
function LoadedDependencies: TArray<TLoadedDependency>;

implementation

uses
  System.IOUtils,
  Vallenta.FormEditor.Packages.PeImage,
  Vallenta.FormEditor.Packages.Discovery;

const
  // Package file extension, and the cap on nested dependency resolution.
  PackageExtension = '.bpl';
  MaxDependencyDepth = 16;

var
  // Modules loaded to satisfy dependencies, and the names being resolved.
  Dependencies: TArray<TLoadedDependency>;
  Walking: TArray<string>;

function IsWalking(const AName: string): Boolean;
var
  Name: string;
begin
  for Name in Walking do
    if SameText(Name, AName) then
      Exit(True);
  Result := False;
end;

procedure StopWalking(const AName: string);
var
  I: Integer;
begin
  for I := High(Walking) downto 0 do
    if SameText(Walking[I], AName) then
      Delete(Walking, I, 1);
end;

// Search order: the importing package's directory, the IDE bin directory,
// then the SearchPath API. Empty when nothing finds it.
function ResolveDependency(const AName, ADirectory: string): string;
var
  Buffer: array [0 .. MAX_PATH] of Char;
  FilePart: PChar;
  Candidate: string;
begin
  if ADirectory <> '' then
  begin
    Candidate := TPath.Combine(ADirectory, AName);
    if TFile.Exists(Candidate) then
      Exit(Candidate);
  end;
  if IdeBinDirectory <> '' then
  begin
    Candidate := TPath.Combine(IdeBinDirectory, AName);
    if TFile.Exists(Candidate) then
      Exit(Candidate);
  end;
  if SearchPath(nil, PChar(AName), nil, Length(Buffer), PChar(@Buffer[0]),
    FilePart) > 0 then
    Exit(string(PChar(@Buffer[0])));
  Result := '';
end;

function IsInChain(const AChain: TArray<TLoadedDependency>;
  AModule: HMODULE): Boolean;
var
  Entry: TLoadedDependency;
begin
  for Entry in AChain do
    if Entry.Module = AModule then
      Exit(True);
  Result := False;
end;

function EnsureFor(const APath: string; ADepth: Integer;
  var AChain: TArray<TLoadedDependency>; var AMissing: string): Boolean;
var
  Directory, Name, Resolved: string;
  Dependency: TLoadedDependency;
begin
  Result := True;
  if ADepth > MaxDependencyDepth then
    Exit;
  Directory := ExtractFileDir(APath);
  for Name in ImportedModuleNames(APath) do
  begin
    if not SameText(ExtractFileExt(Name), PackageExtension) then
      Continue;
    if IsWalking(Name) then
      Continue;
    Dependency.Module := GetModuleHandle(PChar(Name));
    if Dependency.Module <> 0 then
    begin
      if not IsInChain(AChain, Dependency.Module) then
      begin
        Dependency.Name := Name;
        Dependency.Path := '';
        AChain := AChain + [Dependency];
      end;
      Continue;
    end;
    Resolved := ResolveDependency(Name, Directory);
    if Resolved = '' then
    begin
      AMissing := Name;
      Exit(False);
    end;
    Walking := Walking + [Name];
    try
      if not EnsureFor(Resolved, ADepth + 1, AChain, AMissing) then
        Exit(False);
      Dependency.Name := Name;
      Dependency.Path := Resolved;
      Dependency.Module := LoadPackage(Resolved);
      Dependencies := Dependencies + [Dependency];
      AChain := AChain + [Dependency];
    finally
      StopWalking(Name);
    end;
  end;
end;

procedure UnloadDownTo(ACount: Integer);
var
  I: Integer;
begin
  for I := High(Dependencies) downto ACount do
  begin
    try
      UnloadPackage(Dependencies[I].Module);
    except
      // UnloadPackage can raise; the remaining modules must still be
      // unloaded.
    end;
    Delete(Dependencies, I, 1);
  end;
end;

function EnsureDependencies(const APath: string;
  out AChain: TArray<TLoadedDependency>; out AMissing: string;
  const ABeforeRollback: TProc): Boolean;
var
  Mark: Integer;
begin
  AChain := [];
  AMissing := '';
  Mark := Length(Dependencies);
  Result := EnsureFor(APath, 0, AChain, AMissing);
  if not Result then
  begin
    if Assigned(ABeforeRollback) then
      ABeforeRollback();
    UnloadDownTo(Mark);
    AChain := [];
  end;
end;

function LoadedDependencies: TArray<TLoadedDependency>;
begin
  Result := Dependencies;
end;

end.
