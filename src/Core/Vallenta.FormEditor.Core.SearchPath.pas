// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Core.SearchPath;

// Directories searched for form files beyond the document's own directory,
// needed when an ancestor form or frame class lives elsewhere in a project.
// Paths arrive from --search-path or an open request, semicolon-separated. 
// Holds one process-wide default plus an optional
// per-document override; every entry point is lock-serialized.
//
// Paths must already be macro-expanded. $(BDSCOMMONDIR) and the rest resolve
// from the IDE's registry keys, which this process does not read.

interface

// Splits a semicolon-separated directory list. Entries
// are trimmed, surrounding double quotes are removed, empty entries dropped.
// No macro expansion and no existence check.
function SplitSearchPath(const AList: string): TArray<string>;

// Removes '--search-path <value>' from AArguments and returns the value. The
// option is matched case-insensitively at any position. Returns an empty
// string when the option is absent, or stands last with no value after it.
function TakeSearchPathArgument(var AArguments: TArray<string>): string;

// Sets the process-wide search path used for documents without an override.
procedure SetDefaultSearchPath(const APaths: TArray<string>);

// Sets the search path for one document; empty APaths removes the override.
// ADocumentFile is expanded to an absolute path, matched case-insensitively.
procedure NoteSearchPathFor(const ADocumentFile: string;
  const APaths: TArray<string>);

// The search path for a load of ADocumentFile: the document's override when
// one is set, the process-wide default otherwise. The result is a copy.
function SearchPathFor(const ADocumentFile: string): TArray<string>;

const
  // Command-line options.
  SearchPathOption = '--search-path';

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  Vallenta.FormEditor.Core.ArgumentFile;

var
  Lock: TObject;
  DefaultPath: TArray<string>;
  PerDocument: TDictionary<string, TArray<string>>;

function SplitSearchPath(const AList: string): TArray<string>;
var
  Entry, Cleaned: string;
begin
  Result := nil;
  for Entry in AList.Split([';']) do
  begin
    Cleaned := Entry.Trim;
    if (Cleaned.Length >= 2) and Cleaned.StartsWith('"') and
       Cleaned.EndsWith('"') then
      Cleaned := Cleaned.Substring(1, Cleaned.Length - 2).Trim;
    if Cleaned <> '' then
      Result := Result + [Cleaned];
  end;
end;

function TakeSearchPathArgument(var AArguments: TArray<string>): string;
begin
  Result := TakeOptionArgument(AArguments, SearchPathOption);
end;

function KeyFor(const ADocumentFile: string): string;
begin
  Result := ExpandFileName(ADocumentFile);
end;

procedure SetDefaultSearchPath(const APaths: TArray<string>);
begin
  TMonitor.Enter(Lock);
  try
    DefaultPath := Copy(APaths);
  finally
    TMonitor.Exit(Lock);
  end;
end;

procedure NoteSearchPathFor(const ADocumentFile: string;
  const APaths: TArray<string>);
begin
  TMonitor.Enter(Lock);
  try
    if Length(APaths) = 0 then
      PerDocument.Remove(KeyFor(ADocumentFile))
    else
      PerDocument.AddOrSetValue(KeyFor(ADocumentFile), Copy(APaths));
  finally
    TMonitor.Exit(Lock);
  end;
end;

function SearchPathFor(const ADocumentFile: string): TArray<string>;
begin
  TMonitor.Enter(Lock);
  try
    if not PerDocument.TryGetValue(KeyFor(ADocumentFile), Result) then
      Result := DefaultPath;
    // A dynamic array assignment shares storage; the result must not alias
    // the array held in the table.
    Result := Copy(Result);
  finally
    TMonitor.Exit(Lock);
  end;
end;

initialization
  Lock := TObject.Create;
  PerDocument := TDictionary<string, TArray<string>>.Create(
    TIStringComparer.Ordinal);

finalization
  PerDocument.Free;
  Lock.Free;

end.
