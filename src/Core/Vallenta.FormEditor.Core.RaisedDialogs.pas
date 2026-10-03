// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Core.RaisedDialogs;

// Brings to the front the dialog boxes shown by component code while a form is
// streamed, such as a message box from an ActiveX control or a data component.
// Windows lets a background process neither activate a window nor bring one to
// the front, so such a box otherwise opens behind the editor, has no taskbar
// button when a hidden window owns it, and blocks the load unnoticed.
//
// While a bracket is open, a WH_CBT hook makes every dialog box activated on
// the calling thread topmost without activating it, and reports each box once.
// Main thread only: the hook is installed for the thread that opens the
// outermost bracket. Brackets nest.

interface

type
  // Reports a dialog box shown inside a bracket. ATitle is its caption; AText
  // is the message text of a message box, empty for any other dialog.
  TDialogShownEvent = procedure(const ATitle, AText: string) of object;

// Opens a bracket; the outermost one installs the hook. AOnShown may be nil
// and is called for each dialog box shown while this bracket is the innermost.
procedure BeginRaisingDialogs(const AOnShown: TDialogShownEvent);

// Closes the innermost bracket; closing the outermost removes the hook.
procedure EndRaisingDialogs;

implementation

uses
  Winapi.Windows;

const
  // Window class of a dialog box, message boxes included.
  DialogClass = '#32770';
  // Control id of the message text in a message box.
  MessageTextId = $FFFF;

var
  // Handle of the WH_CBT hook; 0 while no bracket is open.
  Hook: HHOOK = 0;
  // The handler of each open bracket, innermost last.
  Brackets: TArray<TDialogShownEvent>;
  // The dialog box reported last; a repeated activation of it is not reported.
  Reported: HWND = 0;

function IsDialogBox(AWindow: HWND): Boolean;
var
  Name: array [0 .. 15] of Char;
begin
  Result := (GetClassName(AWindow, Name, Length(Name)) > 0) and
    (string(Name) = DialogClass);
end;

function CaptionOf(AWindow: HWND): string;
var
  Len: Integer;
begin
  Len := GetWindowTextLength(AWindow);
  SetLength(Result, Len);
  if Len > 0 then
    GetWindowText(AWindow, PChar(Result), Len + 1);
end;

function MessageOf(AWindow: HWND): string;
var
  Text: HWND;
begin
  Text := GetDlgItem(AWindow, MessageTextId);
  if Text = 0 then
    Exit('');
  Result := CaptionOf(Text);
end;

procedure BringForward(AWindow: HWND);
var
  Shown: TDialogShownEvent;
begin
  SetWindowPos(AWindow, HWND_TOPMOST, 0, 0, 0, 0,
    SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  if AWindow = Reported then
    Exit;
  Reported := AWindow;
  Shown := Brackets[High(Brackets)];
  if Assigned(Shown) then
    Shown(CaptionOf(AWindow), MessageOf(AWindow));
end;

function DialogHook(ACode: Integer; AWParam: WPARAM; ALParam: LPARAM): LRESULT; stdcall;
begin
  // HCBT_ACTIVATE is sent even when the process may not take the foreground,
  // which is the case this hook exists for.
  if (ACode = HCBT_ACTIVATE) and (Length(Brackets) > 0) and
     IsDialogBox(HWND(AWParam)) then
    BringForward(HWND(AWParam));
  Result := CallNextHookEx(Hook, ACode, AWParam, ALParam);
end;

procedure BeginRaisingDialogs(const AOnShown: TDialogShownEvent);
begin
  if Length(Brackets) = 0 then
  begin
    Hook := SetWindowsHookEx(WH_CBT, @DialogHook, 0, GetCurrentThreadId);
    Reported := 0;
  end;
  SetLength(Brackets, Length(Brackets) + 1);
  Brackets[High(Brackets)] := AOnShown;
end;

procedure EndRaisingDialogs;
begin
  if Length(Brackets) = 0 then
    Exit;
  SetLength(Brackets, Length(Brackets) - 1);
  if (Length(Brackets) = 0) and (Hook <> 0) then
  begin
    UnhookWindowsHookEx(Hook);
    Hook := 0;
  end;
end;

end.
