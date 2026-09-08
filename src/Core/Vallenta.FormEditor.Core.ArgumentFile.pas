// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Core.ArgumentFile;

// Command-line arguments read from a file named with --config-file, for
// arguments a command line cannot hold: Windows caps one at 32767 characters,
// which a project's search path can reach alone. One argument per line, an
// option and its value on two lines as on the command line, lines trimmed and
// empty ones skipped, read as UTF-8 with or without a byte order mark.
//
// The routines hold no state; arguments from the file are appended after
// those already in the array.

interface

const
  // Command-line options.
  ConfigFileOption = '--config-file';

// Removes AOption and the argument following it from AArguments and returns
// that argument; empty when the option is absent or is the last argument.
// Matching is case-insensitive and only the first occurrence is removed.
function TakeOptionArgument(var AArguments: TArray<string>;
  const AOption: string): string;

// Appends to AArguments one argument per line of AFileName that is non-empty
// after trimming. False when the file cannot be read, with AError naming the
// file and the reason.
function AppendArgumentsFromFile(const AFileName: string;
  var AArguments: TArray<string>; out AError: string): Boolean;

// Removes the --config-file option and appends the arguments its file holds.
// True when no file was named, including a trailing option without a value.
// False when the named file could not be read, with AError set. Every further
// --config-file, from the file or the command line, is removed and not
// followed.
function ExpandConfigFileArgument(var AArguments: TArray<string>;
  out AError: string): Boolean;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Classes;

function TakeOptionArgument(var AArguments: TArray<string>;
  const AOption: string): string;
var
  I, Last: Integer;
begin
  Result := '';
  for I := 0 to High(AArguments) do
    if SameText(AArguments[I], AOption) then
    begin
      Last := I;
      if I < High(AArguments) then
      begin
        Result := AArguments[I + 1];
        Last := I + 1;
      end;
      Delete(AArguments, I, Last - I + 1);
      Exit;
    end;
end;

function AppendArgumentsFromFile(const AFileName: string;
  var AArguments: TArray<string>; out AError: string): Boolean;
var
  Lines: TArray<string>;
  Line, Argument: string;
begin
  AError := '';
  try
    Lines := TFile.ReadAllLines(AFileName, TEncoding.UTF8);
  except
    on E: Exception do
    begin
      AError := Format('the argument file %s could not be read: %s',
        [AFileName, E.Message]);
      Exit(False);
    end;
  end;
  for Line in Lines do
  begin
    Argument := Line.Trim;
    if Argument <> '' then
      AArguments := AArguments + [Argument];
  end;
  Result := True;
end;

function ExpandConfigFileArgument(var AArguments: TArray<string>;
  out AError: string): Boolean;
var
  FileName: string;
begin
  AError := '';
  FileName := TakeOptionArgument(AArguments, ConfigFileOption);
  if FileName = '' then
    Exit(True);
  Result := AppendArgumentsFromFile(FileName, AArguments, AError);
  if not Result then
    Exit;
  repeat
  until TakeOptionArgument(AArguments, ConfigFileOption) = '';
end;

end.
