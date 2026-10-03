// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.RaisedDialogs;

// Dialog boxes shown while a bracket of Core.RaisedDialogs is open: made
// topmost and reported once, to the innermost bracket; left unchanged once
// the outermost bracket is closed.
//
// Each case shows a real message box on the desktop. A timer on the test
// thread finds it from inside its modal loop, records whether it was
// topmost, and closes it, so no case waits for user input. A box still open
// AnswerLimit after it was found fails the case.

interface

uses
  DUnitX.TestFramework;

type
  // Covers BeginRaisingDialogs and EndRaisingDialogs.
  [TestFixture]
  TRaisedDialogTests = class
  private
    FReports: TArray<string>;
    procedure NoteShown(const ATitle, AText: string);
    // Shows a message box, waits for the timer to close it, and returns
    // whether it was topmost when found. Fails when the box stays open longer
    // than AnswerLimit after it was found.
    function ShowAndAnswer(const ATitle, AText: string): Boolean;
  public
    [Setup]
    procedure Setup;
    [Test]
    procedure AMessageBoxInsideABracketIsRaisedAndReported;
    [Test]
    procedure AMessageBoxOutsideABracketIsLeftAsItIs;
    // Only the innermost bracket reports a box; the outer bracket still
    // raises boxes after the inner one closes, and closing it removes the hook.
    [Test]
    procedure BracketsNestAndTheLastOneRemovesTheHook;
  end;

implementation

uses
  Winapi.Windows,
  Winapi.Messages,
  System.SysUtils,
  System.Diagnostics,
  Vallenta.FormEditor.Core.RaisedDialogs;

const
  // Longest time a box may stay open after the timer found it, in ms.
  AnswerLimit = 2000;

var
  // Set by AnswerBox, read by ShowAndAnswer. BoxFoundAt is in ms on
  // BoxClock, which ShowAndAnswer starts.
  BoxFound: Boolean;
  BoxWasTopmost: Boolean;
  BoxFoundAt: Int64;
  BoxClock: TStopwatch;

function FindBox(AWindow: HWND; AParam: LPARAM): BOOL; stdcall;
var
  Name: array [0 .. 15] of Char;
begin
  Result := True;
  if IsWindowVisible(AWindow) and
     (GetClassName(AWindow, Name, Length(Name)) > 0) and
     (string(Name) = '#32770') then
  begin
    PHandle(AParam)^ := AWindow;
    Result := False;
  end;
end;

procedure AnswerBox(AWindow: HWND; AMessage: UINT; AId: UINT_PTR;
  ATime: DWORD); stdcall;
var
  Box: HWND;
begin
  Box := 0;
  EnumThreadWindows(GetCurrentThreadId, @FindBox, LPARAM(@Box));
  if Box = 0 then
    Exit;
  KillTimer(0, AId);
  BoxFound := True;
  BoxFoundAt := BoxClock.ElapsedMilliseconds;
  BoxWasTopmost := GetWindowLong(Box, GWL_EXSTYLE) and WS_EX_TOPMOST <> 0;
  // The only button of an MB_OK box carries the ID IDCANCEL, so a
  // WM_COMMAND with IDOK is ignored and the box stays open.
  PostMessage(Box, WM_CLOSE, 0, 0);
end;

procedure TRaisedDialogTests.Setup;
begin
  FReports := nil;
end;

procedure TRaisedDialogTests.NoteShown(const ATitle, AText: string);
begin
  FReports := FReports + [ATitle + ': ' + AText];
end;

function TRaisedDialogTests.ShowAndAnswer(const ATitle, AText: string): Boolean;
var
  OpenAfterFound: Int64;
begin
  BoxFound := False;
  BoxWasTopmost := False;
  BoxFoundAt := 0;
  BoxClock := TStopwatch.StartNew;
  SetTimer(0, 0, 100, @AnswerBox);
  MessageBox(0, PChar(AText), PChar(ATitle), MB_OK);
  OpenAfterFound := BoxClock.ElapsedMilliseconds - BoxFoundAt;
  Assert.IsTrue(BoxFound, 'the message box was not found to be answered');
  Assert.IsTrue(OpenAfterFound < AnswerLimit, Format('the message box stayed ' +
    'open %d ms after the timer found it', [OpenAfterFound]));
  Result := BoxWasTopmost;
end;

procedure TRaisedDialogTests.AMessageBoxInsideABracketIsRaisedAndReported;
var
  Topmost: Boolean;
begin
  BeginRaisingDialogs(NoteShown);
  try
    Topmost := ShowAndAnswer('Probe title', 'Probe text');
  finally
    EndRaisingDialogs;
  end;
  Assert.IsTrue(Topmost, 'the box was not brought in front');
  Assert.AreEqual('Probe title: Probe text', string.Join('|', FReports));
end;

procedure TRaisedDialogTests.AMessageBoxOutsideABracketIsLeftAsItIs;
begin
  Assert.IsFalse(ShowAndAnswer('Probe title', 'Probe text'),
    'a box shown outside any bracket was brought in front');
  Assert.AreEqual(0, Length(FReports));
end;

procedure TRaisedDialogTests.BracketsNestAndTheLastOneRemovesTheHook;
var
  Inner, Outer, After: Boolean;
begin
  BeginRaisingDialogs(nil);
  try
    BeginRaisingDialogs(NoteShown);
    try
      Inner := ShowAndAnswer('Inner', 'first box');
    finally
      EndRaisingDialogs;
    end;
    Outer := ShowAndAnswer('Outer', 'second box');
  finally
    EndRaisingDialogs;
  end;
  After := ShowAndAnswer('After', 'third box');
  Assert.IsTrue(Inner, 'the box in the inner bracket was not brought in front');
  Assert.IsTrue(Outer, 'the box in the outer bracket was not brought in front');
  Assert.IsFalse(After, 'the hook outlived the outermost bracket');
  Assert.AreEqual('Inner: first box', string.Join('|', FReports),
    'only the innermost bracket was to hear of its box');
end;

initialization
  TDUnitX.RegisterTestFixture(TRaisedDialogTests);

end.
