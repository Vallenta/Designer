// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Core.Console;

// Console output for a GUI process, which starts without a console of its
// own. TryAttachParentConsole resolves the output target once: the inherited
// stdout handle when one exists (terminal or redirection), otherwise the
// console of the parent process. ConsoleWriteLn writes nothing before that
// call has succeeded. The resolved handle is process-wide and unsynchronized.

interface

// Resolves the output target on the first call and caches it; later calls
// return the cached result. False when no target could be resolved.
function TryAttachParentConsole: Boolean;

// Writes Text followed by a line break to the target resolved by
// TryAttachParentConsole, encoded in the active ANSI code page. No-op while
// no target is resolved.
procedure ConsoleWriteLn(const Text: string);

implementation

uses
  Winapi.Windows,
  System.SysUtils;

var
  Target: THandle = 0;
  Attempted: Boolean = False;

function HandleUsable(H: THandle): Boolean;
begin
  Result := (H <> 0) and (H <> INVALID_HANDLE_VALUE);
end;

function TryAttachParentConsole: Boolean;
begin
  if not Attempted then
  begin
    Attempted := True;
    Target := GetStdHandle(STD_OUTPUT_HANDLE);
    if not HandleUsable(Target) and AttachConsole(ATTACH_PARENT_PROCESS) then
      Target := GetStdHandle(STD_OUTPUT_HANDLE);
    if not HandleUsable(Target) then
      Target := 0;
  end;
  Result := Target <> 0;
end;

procedure ConsoleWriteLn(const Text: string);
var
  Bytes: TBytes;
  Written: DWORD;
begin
  if Target = 0 then
    Exit;
  Bytes := TEncoding.ANSI.GetBytes(Text + sLineBreak);
  if Length(Bytes) > 0 then
    WriteFile(Target, Bytes[0], Length(Bytes), Written, nil);
end;

end.
