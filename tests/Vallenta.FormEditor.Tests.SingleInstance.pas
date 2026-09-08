// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.SingleInstance;

// Covers the single-instance claim and the v0 handover of
// Vallenta.FormEditor.Core.SingleInstance: a file routed to a running core,
// and the refusals returned for a request the core cannot serve. Open runs
// on the main thread, so a case that reaches a listener drives the pipe
// from a worker thread while the main thread pumps synchronized calls.
//
// The pipe name is derived from the running executable's path and the logon
// session, so these cases reach the test runner's own listener and never a
// designer running beside it.

interface

uses
  System.SysUtils,
  DUnitX.TestFramework,
  Vallenta.FormEditor.Core.SingleInstance;

type
  // Covers ClaimCore and ReleaseCore, and the routed and raw handover
  // requests served by a listener created per case.
  [TestFixture]
  TSingleInstanceTests = class
  private
    FOpened: string;
    // Every file passed to RecordOpen, each followed by '|'; read by
    // SeveralCallersAtOnceAreAllAnswered.
    FOpenedAll: string;
    FAnswer: TOpenOutcome;
    function RecordOpen(const AFileName: string;
      out AReason: string): TOpenOutcome;
    // Runs ABody with a listener on the core pipe serving RecordOpen as its
    // only handler, then stops it.
    procedure Listening(ABody: TProc);
  public
    [Test]
    procedure TheClaimCanBeTakenGivenBackAndTakenAgain;
    [Test]
    procedure RoutingFailsWhenNothingIsListening;
    [Test]
    procedure ARoutedFileReachesTheCore;
    [Test]
    procedure AFileAlreadyOpenIsReportedAsFocused;
    [Test]
    procedure ARefusalReachesTheCallerWithAReason;
    [Test]
    procedure APathOutsideAsciiSurvivesTheWire;
    // The refusal wordings are frozen wire, so each case names the fragment
    // of the refusal it expects rather than only that a refusal arrived. The
    // separator is declared as '|' because the default comma would split
    // every JSON request below at its first comma.
    [Test]
    // The reason is embedded in the JSON answer, so its quotes arrive
    // backslash-escaped.
    [TestCase('unknown command', '{"v":0,"cmd":"dance","file":"x.dfm"}|unknown command \"dance\"', '|')]
    [TestCase('no file named', '{"v":0,"cmd":"open"}|named no file', '|')]
    [TestCase('file is not a string', '{"v":0,"cmd":"open","file":42}|has to be given as text', '|')]
    [TestCase('empty file name', '{"v":0,"cmd":"open","file":""}|file name is empty', '|')]
    // focus and reloadFromDisk are session-scope commands, out of scope for
    // a handover, so they are refused as unknown.
    [TestCase('a session command over a handover', '{"v":0,"cmd":"focus","file":"x.dfm"}|unknown command \"focus\"', '|')]
    [TestCase('another session command over a handover', '{"v":0,"cmd":"reloadFromDisk","file":"x.dfm"}|unknown command \"reloadFromDisk\"', '|')]
    [TestCase('not an object', '"open Unit1.dfm"|could not be understood', '|')]
    [TestCase('not even JSON', 'open Unit1.dfm|could not be understood', '|')]
    [TestCase('nothing at all', ' |could not be understood', '|')]
    procedure AMalformedRequestIsRefusedRatherThanIgnored(const ARequest,
      AExpected: string);
    [Test]
    procedure ACallerThatSaysNothingIsToldSo;
    [Test]
    procedure ARequestLongerThanAnyOfOursIsRefused;
    [Test]
    procedure SeveralCallersAtOnceAreAllAnswered;
    // Pins the thread per connection: the silent caller holds its connection
    // for the core's full 5000 ms request timeout, and a caller arriving
    // 300 ms behind it is answered while that connection is unfinished.
    [Test]
    procedure ACallerThatSaysNothingDoesNotHoldUpAnother;
  end;

implementation

uses
  Winapi.Windows,
  System.Classes;

const
  // Waits in milliseconds. AnswerWait matches AnswerTimeout in the unit
  // under test.
  AnswerWait = 30000;
  PipeUpWait = 5000;
  PollWait = 10;

type
  // Calls RouteToCore on a worker thread, leaving the main thread free to
  // run the core's synchronized Open handler.
  TRouteThread = class(TThread)
  private
    FFileName: string;
  protected
    procedure Execute; override;
  public
    Routed: TRouteOutcome;
    Detail: string;
    constructor Create(const AFileName: string);
  end;

  // Writes ARequest to the core pipe verbatim and reads back the answer.
  // ATerminated False omits the trailing newline, so the line never ends; an
  // empty ARequest then connects and writes nothing at all.
  TRawThread = class(TThread)
  private
    FRequest: string;
    FLineTerminated: Boolean;
  protected
    procedure Execute; override;
  public
    Answer: string;
    constructor Create(const ARequest: string; ATerminated: Boolean = True);
  end;

constructor TRouteThread.Create(const AFileName: string);
begin
  FFileName := AFileName;
  inherited Create(False);
end;

procedure TRouteThread.Execute;
begin
  Routed := RouteToCore(FFileName, Detail);
end;

constructor TRawThread.Create(const ARequest: string; ATerminated: Boolean);
begin
  FRequest := ARequest;
  FLineTerminated := ATerminated;
  inherited Create(False);
end;

procedure TRawThread.Execute;
var
  Pipe: THandle;
  Bytes, Buffer: TBytes;
  Written, Read, Waiting: DWORD;
  Deadline: UInt64;
begin
  Answer := '';
  if not WaitNamedPipe(PChar(CorePipeName), AnswerWait) then
    Exit;
  Pipe := CreateFile(PChar(CorePipeName), GENERIC_READ or GENERIC_WRITE, 0, nil,
    OPEN_EXISTING, 0, 0);
  if Pipe = INVALID_HANDLE_VALUE then
    Exit;
  try
    if FLineTerminated then
      Bytes := TEncoding.UTF8.GetBytes(FRequest + Char(10))
    else
      Bytes := TEncoding.UTF8.GetBytes(FRequest);
    if Length(Bytes) > 0 then
    begin
      if not WriteFile(Pipe, Bytes[0], Length(Bytes), Written, nil) then
        Exit;
      FlushFileBuffers(Pipe);
    end;
    // Polled to a deadline instead of a blocking ReadFile: a core that never
    // answers would hang the read rather than fail the case.
    Deadline := GetTickCount64 + AnswerWait;
    repeat
      if not PeekNamedPipe(Pipe, nil, 0, nil, @Waiting, nil) then
        Exit;
      if Waiting = 0 then
        Sleep(PollWait);
    until (Waiting > 0) or (GetTickCount64 > Deadline);
    if Waiting = 0 then
      Exit;
    SetLength(Buffer, Waiting);
    if ReadFile(Pipe, Buffer[0], Waiting, Read, nil) and (Read > 0) then
    begin
      SetLength(Buffer, Read);
      Answer := TEncoding.UTF8.GetString(Buffer);
    end;
  finally
    CloseHandle(Pipe);
  end;
end;

// WaitNamedPipe fails immediately while the name does not exist, and the
// listener creates its first pipe instance on its own thread, so the wait is
// retried to a deadline.
function PipeIsUp: Boolean;
var
  Deadline: UInt64;
begin
  Deadline := GetTickCount64 + PipeUpWait;
  repeat
    Result := WaitNamedPipe(PChar(CorePipeName), PollWait);
    if not Result then
      Sleep(PollWait);
  until Result or (GetTickCount64 > Deadline);
end;

// Pumps synchronized calls until AThread finishes or AnswerWait expires. The
// core reaches its Open handler through Synchronize, so the main thread has
// to keep calling CheckSynchronize while a case waits.
function Served(AThread: TThread): Boolean;
var
  Deadline: UInt64;
begin
  Deadline := GetTickCount64 + AnswerWait;
  while not AThread.Finished and (GetTickCount64 < Deadline) do
    CheckSynchronize(PollWait);
  Result := AThread.Finished;
end;

const
  // Reason RecordOpen returns on ooRefused; deliberately unlike 'the core
  // did not open it', which the core substitutes for a refusal without one.
  RefusalReason = 'the designer says no';
  CallersAtOnce = 3;
  // ms; delay before the second caller connects, so the silent caller is
  // certainly the connection already being served.
  SettleWait = 300;

function TSingleInstanceTests.RecordOpen(const AFileName: string;
  out AReason: string): TOpenOutcome;
begin
  FOpened := AFileName;
  FOpenedAll := FOpenedAll + AFileName + '|';
  Result := FAnswer;
  if Result = ooRefused then
    AReason := RefusalReason
  else
    AReason := '';
end;

procedure TSingleInstanceTests.Listening(ABody: TProc);
var
  Listener: TCoreListener;
  Handlers: TCoreHandlers;
  Stopped: Boolean;
begin
  Listener := TCoreListener.Create(CorePipeName);
  Handlers := Default(TCoreHandlers);
  Handlers.Open := RecordOpen;
  Listener.ServeWith(Handlers);
  try
    Assert.IsTrue(PipeIsUp, 'the listener never opened its pipe');
    ABody();
  finally
    // Freed only when Stop reported success: the destructor waits for the
    // listener thread, which still runs when Stop timed out.
    Stopped := Listener.Stop;
    if Stopped then
      Listener.Free;
  end;
  // Asserted after the body, so a failing body reports its own assertion
  // rather than this one.
  Assert.IsTrue(Stopped, 'the listener would not stop');
end;

procedure TSingleInstanceTests.TheClaimCanBeTakenGivenBackAndTakenAgain;
begin
  Assert.IsTrue(ClaimCore, 'nothing else holds the claim in this process');
  try
    Assert.IsTrue(ClaimCore, 'the holder asking again is still the holder');
  finally
    ReleaseCore;
  end;
  try
    Assert.IsTrue(ClaimCore, 'a claim given back can be taken again');
  finally
    ReleaseCore;
  end;
end;

procedure TSingleInstanceTests.RoutingFailsWhenNothingIsListening;
var
  Detail: string;
begin
  Assert.AreEqual(Ord(roUnreachable),
    Ord(RouteToCore('C:\nowhere\Unit1.dfm', Detail)),
    'there is no core to reach');
  Assert.IsNotEmpty(Detail, 'a route that failed has to say what happened');
end;

procedure TSingleInstanceTests.ARoutedFileReachesTheCore;
const
  Wanted = 'C:\forms\Unit1.dfm';
begin
  FOpened := '';
  FAnswer := ooOpened;
  Listening(
    procedure
    var
      Router: TRouteThread;
    begin
      Router := TRouteThread.Create(Wanted);
      try
        Assert.IsTrue(Served(Router), 'the route never came back');
        Assert.AreEqual(Ord(roOpened), Ord(Router.Routed), Router.Detail);
        Assert.AreEqual(Wanted, FOpened, 'the core was told about another file');
      finally
        Router.Free;
      end;
    end);
end;

procedure TSingleInstanceTests.AFileAlreadyOpenIsReportedAsFocused;
begin
  FOpened := '';
  FAnswer := ooFocused;
  Listening(
    procedure
    var
      Router: TRouteThread;
    begin
      Router := TRouteThread.Create('C:\forms\Unit1.dfm');
      try
        Assert.IsTrue(Served(Router), 'the route never came back');
        Assert.AreEqual(Ord(roFocused), Ord(Router.Routed),
          'a window that was already open is raised, not opened again');
      finally
        Router.Free;
      end;
    end);
end;

procedure TSingleInstanceTests.APathOutsideAsciiSurvivesTheWire;
const
  Wanted = 'C:\Formulare\Größe & Maß\Übersicht.dfm';
begin
  FOpened := '';
  FAnswer := ooOpened;
  Listening(
    procedure
    var
      Router: TRouteThread;
    begin
      Router := TRouteThread.Create(Wanted);
      try
        Assert.IsTrue(Served(Router), 'the route never came back');
        Assert.AreEqual(Wanted, FOpened, 'the path did not survive the wire');
      finally
        Router.Free;
      end;
    end);
end;

procedure TSingleInstanceTests.ARefusalReachesTheCallerWithAReason;
begin
  FOpened := '';
  FAnswer := ooRefused;
  Listening(
    procedure
    var
      Router: TRouteThread;
    begin
      Router := TRouteThread.Create('C:\forms\Unit2.dfm');
      try
        Assert.IsTrue(Served(Router), 'the route never came back');
        Assert.AreEqual(Ord(roRefused), Ord(Router.Routed),
          'a core that answered is not an unreachable one');
        Assert.AreEqual(RefusalReason, Router.Detail,
          'the core''s own words have to reach the caller');
      finally
        Router.Free;
      end;
    end);
end;

procedure TSingleInstanceTests.ACallerThatSaysNothingIsToldSo;
begin
  Listening(
    procedure
    var
      Raw: TRawThread;
    begin
      Raw := TRawThread.Create('', False);
      try
        Assert.IsTrue(Served(Raw), 'the core never gave up on a silent caller');
        Assert.Contains(Raw.Answer, 'nothing arrived to read',
          'silence has its own answer');
      finally
        Raw.Free;
      end;
    end);
end;

procedure TSingleInstanceTests.ARequestLongerThanAnyOfOursIsRefused;
begin
  Listening(
    procedure
    var
      Raw: TRawThread;
    begin
      // Four times the core's 64 KB line limit and no newline anywhere: the
      // core has to keep draining the bytes it discards, or this thread's
      // own write never completes and it never reads the answer.
      Raw := TRawThread.Create(StringOfChar('x', 256 * 1024), False);
      try
        Assert.IsTrue(Served(Raw), 'the core never answered');
        Assert.Contains(Raw.Answer, 'longer than any of ours',
          'a request past the limit has its own answer');
      finally
        Raw.Free;
      end;
    end);
end;

procedure TSingleInstanceTests.AMalformedRequestIsRefusedRatherThanIgnored(
  const ARequest, AExpected: string);
begin
  FOpened := '';
  FAnswer := ooOpened;
  Listening(
    procedure
    var
      Raw: TRawThread;
    begin
      Raw := TRawThread.Create(ARequest);
      try
        Assert.IsTrue(Served(Raw), 'the core never answered');
        Assert.Contains(Raw.Answer, '"ok":false',
          'a request the core cannot serve still gets an answer');
        Assert.Contains(Raw.Answer, AExpected,
          'the answer names the reason this request was refused for');
        Assert.AreEqual('', FOpened,
          'nothing the core could not read may reach it');
      finally
        Raw.Free;
      end;
    end);
end;

procedure TSingleInstanceTests.SeveralCallersAtOnceAreAllAnswered;
begin
  FOpenedAll := '';
  FAnswer := ooOpened;
  Listening(
    procedure
    var
      Routers: array [0 .. CallersAtOnce - 1] of TRouteThread;
      I: Integer;
    begin
      for I := 0 to CallersAtOnce - 1 do
        Routers[I] := TRouteThread.Create(Format('C:\forms\Unit%d.dfm', [I]));
      try
        for I := 0 to CallersAtOnce - 1 do
        begin
          Assert.IsTrue(Served(Routers[I]),
            Format('caller %d never came back', [I]));
          Assert.AreEqual(Ord(roOpened), Ord(Routers[I].Routed),
            Routers[I].Detail);
          Assert.Contains(FOpenedAll, Format('C:\forms\Unit%d.dfm', [I]),
            'every caller''s file has to reach the core');
        end;
      finally
        for I := 0 to CallersAtOnce - 1 do
          Routers[I].Free;
      end;
    end);
end;

procedure TSingleInstanceTests.ACallerThatSaysNothingDoesNotHoldUpAnother;
begin
  FOpened := '';
  FAnswer := ooOpened;
  Listening(
    procedure
    var
      Raw: TRawThread;
      Router: TRouteThread;
    begin
      Raw := TRawThread.Create('', False);
      try
        Sleep(SettleWait);
        Router := TRouteThread.Create('C:\forms\Unit9.dfm');
        try
          Assert.IsTrue(Served(Router), 'the route never came back');
          Assert.AreEqual(Ord(roOpened), Ord(Router.Routed), Router.Detail);
          Assert.IsFalse(Raw.Finished,
            'the route was not answered until the silent caller had been');
        finally
          Router.Free;
        end;
      finally
        // Waited out before the listener is stopped: this connection stays
        // open until the core's request timeout expires, and Stop waits for
        // the connection threads within its own 5000 ms deadline.
        Served(Raw);
        Raw.Free;
      end;
    end);
end;

initialization
  TDUnitX.RegisterTestFixture(TSingleInstanceTests);

end.
