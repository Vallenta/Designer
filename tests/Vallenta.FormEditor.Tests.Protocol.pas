// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.Protocol;

// Covers the session protocol on the core pipe: attach, the four session
// commands, event routing to sessions, requests the core sends, and the
// field coupling and renames carried on it. The fixture supplies the core
// handlers, so the cases measure the wire alone: the fields a request
// carries, the id an answer echoes, and the wording of a refusal.
//
// The listener is created directly and each client runs on a thread of its
// own. The core answers on the main thread, which the cases keep pumping
// with CheckSynchronize while they wait. Two cases leave a search path in
// the process-wide store of Vallenta.FormEditor.Core.SearchPath and clear
// it again in a finally.

interface

uses
  System.SysUtils,
  System.Classes,
  System.TypInfo,
  System.Generics.Collections,
  DUnitX.TestFramework,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Core.SingleInstance,
  Vallenta.FormEditor.Core.FieldLedger,
  Vallenta.FormEditor.Core.Coupling,
  Vallenta.FormEditor.Core.Sessions,
  Vallenta.FormEditor.Streaming.Preserved,
  Vallenta.FormEditor.Surface.Undo,
  Vallenta.FormEditor.Core.SearchPath;

type
  TSessionClient = class;

  // The session protocol over a live core pipe, from attach to rename.
  [TestFixture]
  TProtocolTests = class
  private
    FListener: TCoreListener;
    FSessions: TSessionRegistry;
    FLog: TDesignLog;
    FClients: TObjectList<TSessionClient>;
    FComplaints: TStringList;
    FOpened: TStringList;
    FServed: TStringList;
    FAttached: TList<Integer>;
    FEnded: TList<Integer>;
    FOpenOutcome: TOpenOutcome;
    FRefuseClose: Boolean;
    FDirtyDocument: string;
    FAnswers: TStringList;
    FAnswerCount: Integer;
    // Count of OnHandlerCreated callbacks, and the step and handler the last
    // one carried.
    FMarks: Integer;
    FMarkedStep: Integer;
    FMarkedHandler: TCreatedHandler;
    FStep: Integer;
    // Undo history the marking cases drive, wired as the main window wires
    // it. OnCapture yields an empty snapshot and OnRestore only counts
    // restores; the cases measure the requests an undo sends, not document
    // state.
    FUndo: TUndoStack;
    FRestores: Integer;
    // Count of OnRenamed callbacks and the answer the last one carried.
    FRenameAnswers: Integer;
    FRenameAnswer: TRenameAnswer;
    // Coupling that StepUndone and StepRedone call; held in a field because
    // the undo stack raises them long after WireHistory returns.
    FCoupling: ICodeCoupling;
    function CoreOpen(const AFileName: string;
      out AReason: string): TOpenOutcome;
    function CoreAttach(const ADetails: TAttachDetails;
      const AOutbox: ISessionOutbox; out AReason: string): Integer;
    // Stands in for the shell's handler of the four session commands: it
    // records what was served and refuses focus, close and reload in the
    // wordings Vallenta.FormEditor.Shell.Core uses.
    function CoreRequest(ASession: Integer; const ACommand: string;
      AMessage: TWireMessage; var AFields: TWireFields;
      out AReason: string): Boolean;
    procedure CoreAnswered(ASession: Integer; AMessage: TWireMessage);
    procedure CoreEnded(ASession: Integer);
    procedure Complained(Sender: TObject; const AReason: string);
    // Answer callback handed to SendRequest; records the outcome in FAnswers
    // and counts it in FAnswerCount.
    procedure Answered(AOk: Boolean; const AError: string;
      AAnswer: TWireMessage);
    procedure Listening(ABody: TProc);
    // Polls ATest until it holds or AnswerWait elapses, running queued
    // synchronised calls meanwhile.
    function Await(const ATest: TFunc<Boolean>): Boolean;
    procedure Pump(AMillis: Cardinal);
    function NewClient(AReads: Boolean = True): TSessionClient;
    // A client that has attached and been answered, with the workspaces given.
    function Attached(const AWorkspaces: array of string): TSessionClient;
    // The matching message, or nil when none arrived within AnswerWait. The
    // caller frees the result.
    function AwaitAnswer(AClient: TSessionClient; AId: Integer): TWireMessage;
    function AwaitEvent(AClient: TSessionClient;
      const AEvent: string): TWireMessage;
    function AwaitRequest(AClient: TSessionClient;
      const ACommand: string; AOrdinal: Integer = 1): TWireMessage;
    function CountRequests(AClient: TSessionClient;
      const ACommand: string): Integer;
    // A coupling for AFile over the live registry, with TForm1 as its root
    // class. The object is reference counted: the caller holds AHeld for as
    // long as the case uses it.
    function CouplingFor(const AFile: string;
      out AHeld: ICodeCoupling): TDocumentCoupling;
    // Wires the coupling's OnCurrentStep, OnHandlerCreated and
    // OnHandlerRoster to this fixture's undo stack, as the main window wires
    // them, and holds the coupling in FCoupling.
    procedure WireHistory(ACoupling: TDocumentCoupling);
    function CurrentStep: Integer;
    procedure HandlerCreated(AStep: Integer; const AHandler: TCreatedHandler);
    function HandlerRoster: TArray<TCreatedHandler>;
    procedure Renamed(const AAnswer: TRenameAnswer);
    function TakeImage(Sender: TObject): TDocumentSnapshot;
    procedure PutImageBack(Sender: TObject; ASnapshot: TDocumentSnapshot);
    procedure StepUndone(Sender: TObject; const AHandler: TCreatedHandler);
    procedure StepRedone(Sender: TObject; const AHandler: TCreatedHandler);
    // Pushes a property step on the undo stack and leaves its number in
    // FStep.
    procedure PushStep;
    // Answers the AOrdinal'th ensureHandler request the client was sent, with
    // ACreated as the created flag. A case that asks for two handlers must
    // count: answering the first id twice leaves the second request waiting.
    procedure AnswerEnsure(AClient: TSessionClient; ACreated: Boolean;
      AOrdinal: Integer = 1);
    function LogHolds(const AText: string): Boolean;
    // Names of the events the client was sent, in arrival order; answers and
    // requests are not included.
    function EventsFor(AClient: TSessionClient): TArray<string>;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;
    [Test]
    procedure AnAttachIsAnsweredWithWhatThisCoreIs;
    [Test]
    procedure AnOpenOverASessionReachesTheCoreAndEchoesItsId;
    [Test]
    procedure AnAlreadyOpenFileComesBackFocusedOverASession;
    [Test]
    procedure AnUnknownCommandIsRefusedAndTheSessionSurvives;
    [Test]
    procedure AnUnknownEventIsIgnoredOnceAndTheSessionSurvives;
    [Test]
    procedure ALineThatIsNotJsonEndsTheSession;
    [Test]
    procedure TwoSessionsAndAHandoverAreAllAnswered;
    [Test]
    procedure AHandoverCarriesTheSearchPathToTheCore;
    [Test]
    procedure AnOpenOverASessionNotesItsSearchPath;
    [Test]
    procedure TheOpenerHearsAboutItsDocument;
    [Test]
    procedure AWorkspaceMatchHearsAboutADocumentTheOpenerLeftBehind;
    [Test]
    procedure AnEventNobodyHasAClaimOnIsDropped;
    [Test]
    procedure TheClosestWorkspaceHearsAboutTheFile;
    [Test]
    procedure TheLatestOfTwoEqualClaimsHearsAboutTheFile;
    [Test]
    procedure AWorkspaceThatOnlyStartsTheSameWayHoldsNothing;
    [Test]
    procedure ASessionCommandThatNamesNoFileIsRefusedBeforeTheCore;
    [Test]
    procedure ALineLongerThanAnyOfOursEndsTheSession;
    [Test]
    procedure EventsArriveInTheOrderTheyWereEmitted;
    [Test]
    procedure ASessionThatStopsReadingIsDisconnected;
    [Test]
    procedure ARequestTheCoreSendsIsAnsweredOnTheMainThread;
    [Test]
    procedure ARequestNobodyAnswersIsRefusedByTheBeat;
    [Test]
    procedure ASessionThatDiesRefusesWhatItWasAsked;
    [Test]
    procedure AFileThatIsNotOpenCannotBeFocused;
    [Test]
    procedure ACloseTheUserCancelledIsRefusedInThoseWords;
    [Test]
    procedure ADirtyDocumentIsNotReloadedFromDisk;
    [Test]
    procedure ThePipeNameIsTheOneTheExtensionAlsoDerives;
    [Test]
    procedure TheFirstSessionSeedsTheLedgerAndAsksForNothing;
    [Test]
    procedure ASettlePointAsksForTheFieldThatAppeared;
    [Test]
    procedure ASettlePointAsksForTheFieldThatWent;
    [Test]
    procedure AnAddThatWasRefusedIsAskedForAgainAtTheNextSettlePoint;
    [Test]
    procedure AResumeAsksAgainForWhatThisDesignerAdded;
    [Test]
    procedure AResumeAsksAgainForTheHandlersTheHistoryMade;
    [Test]
    procedure ADocumentWithNoSessionKeepsItsChangesForLater;
    [Test]
    procedure AnAnswerForADocumentThatHasGoneIsReadAndDropped;
    [Test]
    procedure AHandlerTheEditorHadToMakeMarksTheStepThatAskedForIt;
    [Test]
    procedure AHandlerThatWasAlreadyThereMarksNothing;
    [Test]
    procedure AnAnswerMarksItsOwnStepAndNotWhateverIsOnTop;
    [Test]
    procedure TakingAMarkedStepBackAsksForTheHandlerToGo;
    [Test]
    procedure TakingAStepThatMadeNothingBackAsksForNothing;
    [Test]
    procedure PuttingAMarkedStepBackAsksForTheHandlerAgain;
    [Test]
    procedure AHandlerTheEditorKeptIsSaidInTheMessagesPane;
    [Test]
    procedure AnUndoWithNothingAttachedAsksForNothingAndKeepsNothing;
    [Test]
    procedure AStepThatMadeTwoHandlersTakesBothBackOut;
    [Test]
    procedure ARenameGoesOutWithTheHandlersRidingWithIt;
    [Test]
    procedure ARootRenameSaysSoOnTheWire;
    [Test]
    procedure AHandlerRenameNamesNoPrimarySymbol;
    [Test]
    procedure TheNotesBesideARenameTravelBackWithIt;
    [Test]
    procedure ARenameWithNowhereToSendItIsRefusedOnTheSpot;
    [Test]
    procedure ARenameOnASessionThatDiesStopsTheRowWaiting;
  end;

  // Pipe client on a thread of its own: it connects to the core pipe, writes
  // the lines it is given and collects the lines it is sent, until the case
  // frees it. AReads False never reads, which is what the outbound queue
  // bound OutboundLimit is measured with.
  TSessionClient = class(TThread)
  private
    FLock: TObject;
    FPipe: THandle;
    FReads: Boolean;
    FOutgoing: TStringList;
    FIncoming: TStringList;
    FBuffer: TBytes;
    FConnected: Boolean;
    FGone: Boolean;
    procedure TakeWhatArrived;
    procedure WriteWhatIsQueued;
    function Reached: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AReads: Boolean);
    destructor Destroy; override;
    procedure Send(const ALine: string);
    function Received: TArray<string>;
    function Connected: Boolean;
    // True once the core dropped this end; only a reading client detects it.
    function Gone: Boolean;
  end;

implementation

uses
  Winapi.Windows,
  System.JSON,
  System.SyncObjs;

const
  // Waits in milliseconds, matching the timeouts of
  // Vallenta.FormEditor.Core.SingleInstance so that the two do not drift.
  AnswerWait = 30000;
  PipeUpWait = 5000;
  PollWait = 10;
  // Milliseconds to keep pumping before a line that has not arrived counts
  // as never sent.
  SettleWait = 400;
  // Far enough past OutboundLimit that the pipe's own buffer cannot account
  // for the difference, and bounded so that a queue which never fills fails
  // the case rather than hanging it.
  FloodLimit = 4000;

  WorkA = 'C:\WorkA';
  WorkB = 'C:\WorkB';

{ TSessionClient }

constructor TSessionClient.Create(AReads: Boolean);
begin
  FLock := TObject.Create;
  FReads := AReads;
  FOutgoing := TStringList.Create;
  FIncoming := TStringList.Create;
  FPipe := INVALID_HANDLE_VALUE;
  inherited Create(False);
end;

destructor TSessionClient.Destroy;
begin
  inherited Destroy;
  FOutgoing.Free;
  FIncoming.Free;
  FLock.Free;
end;

procedure TSessionClient.Send(const ALine: string);
begin
  TMonitor.Enter(FLock);
  try
    FOutgoing.Add(ALine);
  finally
    TMonitor.Exit(FLock);
  end;
end;

function TSessionClient.Received: TArray<string>;
begin
  TMonitor.Enter(FLock);
  try
    Result := FIncoming.ToStringArray;
  finally
    TMonitor.Exit(FLock);
  end;
end;

function TSessionClient.Connected: Boolean;
begin
  TMonitor.Enter(FLock);
  try
    Result := FConnected;
  finally
    TMonitor.Exit(FLock);
  end;
end;

function TSessionClient.Gone: Boolean;
begin
  TMonitor.Enter(FLock);
  try
    Result := FGone;
  finally
    TMonitor.Exit(FLock);
  end;
end;

function TSessionClient.Reached: Boolean;
begin
  Result := False;
  if not WaitNamedPipe(PChar(CorePipeName), PipeUpWait) then
    Exit;
  FPipe := CreateFile(PChar(CorePipeName), GENERIC_READ or GENERIC_WRITE, 0, nil,
    OPEN_EXISTING, 0, 0);
  Result := FPipe <> INVALID_HANDLE_VALUE;
  TMonitor.Enter(FLock);
  try
    FConnected := Result;
  finally
    TMonitor.Exit(FLock);
  end;
end;

procedure TSessionClient.TakeWhatArrived;
var
  Waiting, Read: DWORD;
  Chunk: TBytes;
  Split: Integer;
  Line: TBytes;
begin
  if not PeekNamedPipe(FPipe, nil, 0, nil, @Waiting, nil) then
  begin
    TMonitor.Enter(FLock);
    try
      FGone := True;
    finally
      TMonitor.Exit(FLock);
    end;
    Terminate;
    Exit;
  end;
  if Waiting = 0 then
    Exit;
  SetLength(Chunk, Waiting);
  if not ReadFile(FPipe, Chunk[0], Waiting, Read, nil) or (Read = 0) then
    Exit;
  SetLength(Chunk, Read);
  FBuffer := FBuffer + Chunk;
  repeat
    Split := 0;
    while (Split < Length(FBuffer)) and (FBuffer[Split] <> 10) do
      Inc(Split);
    if Split >= Length(FBuffer) then
      Break;
    Line := Copy(FBuffer, 0, Split);
    Delete(FBuffer, 0, Split + 1);
    TMonitor.Enter(FLock);
    try
      FIncoming.Add(TEncoding.UTF8.GetString(Line));
    finally
      TMonitor.Exit(FLock);
    end;
  until False;
end;

procedure TSessionClient.WriteWhatIsQueued;
var
  Lines: TArray<string>;
  Text: string;
  Bytes: TBytes;
  Written: DWORD;
begin
  TMonitor.Enter(FLock);
  try
    Lines := FOutgoing.ToStringArray;
    FOutgoing.Clear;
  finally
    TMonitor.Exit(FLock);
  end;
  for Text in Lines do
  begin
    Bytes := TEncoding.UTF8.GetBytes(Text + Char(10));
    if not WriteFile(FPipe, Bytes[0], Length(Bytes), Written, nil) then
      Exit;
  end;
end;

procedure TSessionClient.Execute;
begin
  if not Reached then
    Exit;
  try
    while not Terminated do
    begin
      if FReads then
        TakeWhatArrived;
      WriteWhatIsQueued;
      Sleep(PollWait div 2);
    end;
  finally
    CloseHandle(FPipe);
    FPipe := INVALID_HANDLE_VALUE;
  end;
end;

{ TProtocolTests }

procedure TProtocolTests.Setup;
begin
  FLog := TDesignLog.Create;
  FClients := TObjectList<TSessionClient>.Create(False);
  FComplaints := TStringList.Create;
  FOpened := TStringList.Create;
  FServed := TStringList.Create;
  FAnswers := TStringList.Create;
  FAttached := TList<Integer>.Create;
  FEnded := TList<Integer>.Create;
  FOpenOutcome := ooOpened;
  FRefuseClose := False;
  FDirtyDocument := '';
  FAnswerCount := 0;
  FMarks := 0;
  FMarkedStep := 0;
  FMarkedHandler := Default(TCreatedHandler);
  FRenameAnswers := 0;
  FRenameAnswer := Default(TRenameAnswer);
  FStep := 0;
  FRestores := 0;
  FUndo := TUndoStack.Create;
  FUndo.OnCapture := TakeImage;
  FUndo.OnRestore := PutImageBack;
  FUndo.OnStepUndone := StepUndone;
  FUndo.OnStepRedone := StepRedone;
end;

procedure TProtocolTests.TearDown;
begin
  FCoupling := nil;
  FUndo.Free;
  FEnded.Free;
  FAttached.Free;
  FAnswers.Free;
  FServed.Free;
  FOpened.Free;
  FComplaints.Free;
  FClients.Free;
  FLog.Free;
end;

function TProtocolTests.CoreOpen(const AFileName: string;
  out AReason: string): TOpenOutcome;
begin
  AReason := '';
  FOpened.Add(AFileName);
  Result := FOpenOutcome;
end;

function TProtocolTests.CoreAttach(const ADetails: TAttachDetails;
  const AOutbox: ISessionOutbox; out AReason: string): Integer;
begin
  AReason := '';
  Result := FSessions.Attach(ADetails, AOutbox).Id;
  FAttached.Add(Result);
end;

function TProtocolTests.CoreRequest(ASession: Integer; const ACommand: string;
  AMessage: TWireMessage; var AFields: TWireFields;
  out AReason: string): Boolean;
var
  Wanted: string;
begin
  AReason := '';
  Wanted := AMessage.TextOf(FileField);
  FServed.Add(Format('%d %s %s', [ASession, ACommand, Wanted]));
  Result := True;
  if SameText(ACommand, OpenCommand) then
  begin
    FOpened.Add(Wanted);
    FSessions.NoteOpener(Wanted, ASession);
    SetLength(AFields, 1);
    AFields[0] := WireFlag(FocusedField, FOpenOutcome = ooFocused);
    Result := FOpenOutcome <> ooRefused;
  end
  else if SameText(ACommand, FocusCommand) then
  begin
    Result := FOpened.IndexOf(Wanted) >= 0;
    if not Result then
      AReason := 'not open';
  end
  else if SameText(ACommand, CloseCommand) then
  begin
    Result := not FRefuseClose;
    if not Result then
      AReason := 'cancelled by the user';
  end
  else if SameText(ACommand, ReloadCommand) then
  begin
    Result := not SameText(Wanted, FDirtyDocument);
    if not Result then
      AReason := 'the document has unsaved changes';
  end;
end;

procedure TProtocolTests.CoreAnswered(ASession: Integer;
  AMessage: TWireMessage);
begin
  FSessions.Answered(ASession, AMessage);
end;

procedure TProtocolTests.CoreEnded(ASession: Integer);
begin
  FEnded.Add(ASession);
  FSessions.Detach(ASession);
end;

procedure TProtocolTests.Complained(Sender: TObject; const AReason: string);
begin
  FComplaints.Add(AReason);
end;

procedure TProtocolTests.Answered(AOk: Boolean; const AError: string;
  AAnswer: TWireMessage);
begin
  Inc(FAnswerCount);
  if AOk then
    FAnswers.Add('ok ' + AAnswer.TextOf('found'))
  else
    FAnswers.Add('refused ' + AError);
end;

procedure TProtocolTests.Listening(ABody: TProc);
var
  Handlers: TCoreHandlers;
  Client: TSessionClient;
  Stopped: Boolean;
  Deadline: UInt64;
  Up: Boolean;
begin
  FSessions := TSessionRegistry.Create;
  FSessions.Log := FLog;
  FListener := TCoreListener.Create(CorePipeName);
  FListener.OnComplaint := Complained;
  Handlers := Default(TCoreHandlers);
  Handlers.Open := CoreOpen;
  Handlers.Attach := CoreAttach;
  Handlers.Request := CoreRequest;
  Handlers.Answer := CoreAnswered;
  Handlers.Ended := CoreEnded;
  FListener.ServeWith(Handlers);
  try
    Deadline := GetTickCount64 + PipeUpWait;
    repeat
      Up := WaitNamedPipe(PChar(CorePipeName), PollWait);
      if not Up then
        Sleep(PollWait);
    until Up or (GetTickCount64 > Deadline);
    Assert.IsTrue(Up, 'the listener never opened its pipe');
    ABody();
  finally
    // The clients first: each holds an instance of the pipe name, and the
    // listener cannot stop while one is open.
    for Client in FClients do
    begin
      Client.Terminate;
      Client.WaitFor;
      Client.Free;
    end;
    FClients.Clear;
    Stopped := FListener.Stop;
    if Stopped then
      FreeAndNil(FListener);
    // After the listener, never before: its threads reach the registry.
    FreeAndNil(FSessions);
  end;
  Assert.IsTrue(Stopped, 'the listener would not stop');
end;

function TProtocolTests.Await(const ATest: TFunc<Boolean>): Boolean;
var
  Deadline: UInt64;
begin
  Deadline := GetTickCount64 + AnswerWait;
  repeat
    Result := ATest();
    if Result then
      Exit;
    CheckSynchronize(PollWait);
  until GetTickCount64 > Deadline;
  Result := ATest();
end;

procedure TProtocolTests.Pump(AMillis: Cardinal);
var
  Deadline: UInt64;
begin
  Deadline := GetTickCount64 + AMillis;
  while GetTickCount64 < Deadline do
    CheckSynchronize(PollWait);
end;

function TProtocolTests.NewClient(AReads: Boolean): TSessionClient;
begin
  Result := TSessionClient.Create(AReads);
  FClients.Add(Result);
end;

function TProtocolTests.Attached(
  const AWorkspaces: array of string): TSessionClient;
var
  Client: TSessionClient;
  Line, Folders: string;
  I, Sessions: Integer;
  Answer: TWireMessage;
begin
  Sessions := FAttached.Count;
  Folders := '';
  for I := 0 to High(AWorkspaces) do
  begin
    if Folders <> '' then
      Folders := Folders + ',';
    Folders := Folders + '"' + StringReplace(AWorkspaces[I], '\', '\\',
      [rfReplaceAll]) + '"';
  end;
  Client := NewClient;
  Line := Format('{"v":1,"id":1,"cmd":"attach","pid":%d,"client":"suite",' +
    '"version":"1.0.0","workspaces":[%s]}', [GetCurrentProcessId, Folders]);
  Client.Send(Line);
  Assert.IsTrue(Await(
    function: Boolean
    begin
      Result := FAttached.Count > Sessions;
    end), 'the attach never reached the core');
  Answer := AwaitAnswer(Client, 1);
  try
    Assert.IsNotNull(Answer, 'the attach was never answered');
    Assert.IsTrue(Answer.FlagOf(OkField), 'the attach was refused');
  finally
    Answer.Free;
  end;
  Result := Client;
end;

function TProtocolTests.AwaitAnswer(AClient: TSessionClient;
  AId: Integer): TWireMessage;
var
  Found: TWireMessage;
begin
  Found := nil;
  Await(
    function: Boolean
    var
      Line: string;
      Message: TWireMessage;
    begin
      for Line in AClient.Received do
      begin
        Message := TWireMessage.Create(Line);
        if (Message.Kind = wkAnswer) and (Message.Id = AId) then
        begin
          Found := Message;
          Exit(True);
        end;
        Message.Free;
      end;
      Result := False;
    end);
  Result := Found;
end;

function TProtocolTests.AwaitEvent(AClient: TSessionClient;
  const AEvent: string): TWireMessage;
var
  Found: TWireMessage;
begin
  Found := nil;
  Await(
    function: Boolean
    var
      Line: string;
      Message: TWireMessage;
    begin
      for Line in AClient.Received do
      begin
        Message := TWireMessage.Create(Line);
        if (Message.Kind = wkEvent) and SameText(Message.Name, AEvent) then
        begin
          Found := Message;
          Exit(True);
        end;
        Message.Free;
      end;
      Result := False;
    end);
  Result := Found;
end;

function TProtocolTests.AwaitRequest(AClient: TSessionClient;
  const ACommand: string; AOrdinal: Integer): TWireMessage;
var
  Found: TWireMessage;
begin
  Found := nil;
  Await(
    function: Boolean
    var
      Line: string;
      Message: TWireMessage;
      Seen: Integer;
    begin
      Seen := 0;
      for Line in AClient.Received do
      begin
        Message := TWireMessage.Create(Line);
        if (Message.Kind = wkRequest) and SameText(Message.Name, ACommand) then
        begin
          Inc(Seen);
          if Seen >= AOrdinal then
          begin
            Found := Message;
            Exit(True);
          end;
        end;
        Message.Free;
      end;
      Result := False;
    end);
  Result := Found;
end;

function TProtocolTests.EventsFor(AClient: TSessionClient): TArray<string>;
var
  Line: string;
  Message: TWireMessage;
  Seen: Integer;
begin
  Result := nil;
  Seen := 0;
  for Line in AClient.Received do
  begin
    Message := TWireMessage.Create(Line);
    try
      if Message.Kind <> wkEvent then
        Continue;
      SetLength(Result, Seen + 1);
      Result[Seen] := Message.Name;
      Inc(Seen);
    finally
      Message.Free;
    end;
  end;
end;

procedure TProtocolTests.AnAttachIsAnsweredWithWhatThisCoreIs;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Answer: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Answer := AwaitAnswer(Client, 1);
      try
        Assert.AreEqual(SessionProtocol, Answer.NumberOf(ProtocolField),
          'the answer names the protocol this core speaks');
        Assert.AreEqual(Integer(GetCurrentProcessId),
          Answer.NumberOf(ProcessField),
          'the client needs the core''s pid to hand it the foreground');
        Assert.IsNotEmpty(Answer.TextOf(CoreVersionField),
          'a build that declares no version still answers with one');
      finally
        Answer.Free;
      end;
    end);
end;

procedure TProtocolTests.AnOpenOverASessionReachesTheCoreAndEchoesItsId;
const
  Wanted = 'C:\WorkA\Unit1.dfm';
begin
  FOpenOutcome := ooOpened;
  Listening(
    procedure
    var
      Client: TSessionClient;
      Answer: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Client.Send('{"v":1,"id":7,"cmd":"open","file":"C:\\WorkA\\Unit1.dfm"}');
      Answer := AwaitAnswer(Client, 7);
      try
        Assert.IsNotNull(Answer, 'the open was never answered');
        Assert.IsTrue(Answer.FlagOf(OkField), Answer.TextOf(ErrorField));
        Assert.IsFalse(Answer.FlagOf(FocusedField),
          'a file that was not open is opened, not focused');
        Assert.AreEqual(Wanted, FOpened[FOpened.Count - 1],
          'the core was told about another file');
      finally
        Answer.Free;
      end;
    end);
end;

procedure TProtocolTests.AnAlreadyOpenFileComesBackFocusedOverASession;
begin
  FOpenOutcome := ooFocused;
  Listening(
    procedure
    var
      Client: TSessionClient;
      Answer: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Client.Send('{"v":1,"id":8,"cmd":"open","file":"C:\\WorkA\\Unit1.dfm"}');
      Answer := AwaitAnswer(Client, 8);
      try
        Assert.IsNotNull(Answer, 'the open was never answered');
        Assert.IsTrue(Answer.FlagOf(FocusedField),
          'a window that was already open is raised, not opened again');
      finally
        Answer.Free;
      end;
    end);
end;

// The refusal names the unknown command, which is how a client one version
// ahead of this core tells which command is missing.
procedure TProtocolTests.AnUnknownCommandIsRefusedAndTheSessionSurvives;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Answer: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Client.Send('{"v":1,"id":2,"cmd":"dance","file":"C:\\WorkA\\Unit1.dfm"}');
      Answer := AwaitAnswer(Client, 2);
      try
        Assert.IsNotNull(Answer, 'a command this core does not have is still ' +
          'answered');
        Assert.IsFalse(Answer.FlagOf(OkField), 'it cannot have been carried out');
        Assert.AreEqual('unknown command "dance"', Answer.TextOf(ErrorField),
          'the refusal names what was asked for');
      finally
        Answer.Free;
      end;
      Client.Send('{"v":1,"id":3,"cmd":"open","file":"C:\\WorkA\\Unit1.dfm"}');
      Answer := AwaitAnswer(Client, 3);
      try
        Assert.IsNotNull(Answer, 'the session did not survive being asked for ' +
          'something this core does not have');
        Assert.IsTrue(Answer.FlagOf(OkField), Answer.TextOf(ErrorField));
      finally
        Answer.Free;
      end;
    end);
end;

procedure TProtocolTests.AnUnknownEventIsIgnoredOnceAndTheSessionSurvives;
var
  Complaints: Integer;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Answer: TWireMessage;
      Line: string;
    begin
      Client := Attached([WorkA]);
      Client.Send('{"v":1,"event":"somethingNewer","file":"x.dfm"}');
      Client.Send('{"v":1,"event":"somethingNewer","file":"y.dfm"}');
      Client.Send('{"v":1,"id":4,"cmd":"open","file":"C:\\WorkA\\Unit1.dfm"}');
      Answer := AwaitAnswer(Client, 4);
      try
        Assert.IsNotNull(Answer,
          'an event this core does not know may not cost the session');
        Assert.IsTrue(Answer.FlagOf(OkField), Answer.TextOf(ErrorField));
      finally
        Answer.Free;
      end;
      Complaints := 0;
      for Line in FComplaints do
        if Pos('somethingNewer', Line) > 0 then
          Inc(Complaints);
      Assert.AreEqual(1, Complaints,
        'one line for the name, not one per event carrying it');
    end);
end;

procedure TProtocolTests.ALineThatIsNotJsonEndsTheSession;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Answer: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Client.Send('this is not a message');
      Answer := AwaitAnswer(Client, 0);
      try
        Assert.IsNotNull(Answer, 'silence is the one thing this may not do');
        Assert.IsFalse(Answer.FlagOf(OkField), 'it was not carried out');
        Assert.IsFalse(Answer.HasId,
          'there was no id to echo, so the answer carries none');
        Assert.Contains(Answer.TextOf(ErrorField), 'could not be understood',
          'the answer says what was wrong with it');
      finally
        Answer.Free;
      end;
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := FEnded.Count = 1;
        end), 'a client that sends nonsense is dropped');
    end);
end;

// Two session connections and one handover connection at the same time: the
// handover is served while both sessions are attached.
procedure TProtocolTests.TwoSessionsAndAHandoverAreAllAnswered;
var
  Routed: TRouteOutcome;
  Detail: string;
begin
  FOpenOutcome := ooOpened;
  Routed := roUnreachable;
  Listening(
    procedure
    var
      First, Second: TSessionClient;
      Answer: TWireMessage;
      Route: TThread;
    begin
      First := Attached([WorkA]);
      Second := Attached([WorkB]);
      Route := TThread.CreateAnonymousThread(
        procedure
        begin
          Routed := RouteToCore('C:\WorkA\Handed.dfm', Detail);
        end);
      Route.FreeOnTerminate := False;
      try
        Route.Start;
        First.Send('{"v":1,"id":5,"cmd":"open","file":"C:\\WorkA\\One.dfm"}');
        Second.Send('{"v":1,"id":6,"cmd":"open","file":"C:\\WorkB\\Two.dfm"}');
        Answer := AwaitAnswer(First, 5);
        try
          Assert.IsNotNull(Answer, 'the first session was not answered');
          Assert.IsTrue(Answer.FlagOf(OkField), Answer.TextOf(ErrorField));
        finally
          Answer.Free;
        end;
        Answer := AwaitAnswer(Second, 6);
        try
          Assert.IsNotNull(Answer, 'the second session was not answered');
          Assert.IsTrue(Answer.FlagOf(OkField), Answer.TextOf(ErrorField));
        finally
          Answer.Free;
        end;
        Assert.IsTrue(Await(
          function: Boolean
          begin
            Result := Route.Finished;
          end), 'the handover never came back');
        Assert.AreEqual(Ord(roOpened), Ord(Routed), Detail);
      finally
        Route.Free;
      end;
    end);
end;

// The search path given to a second start travels with the handover and is
// noted for the file; a directory containing a space survives the trip.
procedure TProtocolTests.AHandoverCarriesTheSearchPathToTheCore;
var
  Routed: TRouteOutcome;
  Detail: string;
  Noted: TArray<string>;
begin
  FOpenOutcome := ooOpened;
  Routed := roUnreachable;
  try
    Listening(
      procedure
      var
        Route: TThread;
      begin
        Route := TThread.CreateAnonymousThread(
          procedure
          begin
            Routed := RouteToCore('C:\WorkA\Handed.dfm', Detail,
              'C:\Base;C:\Shared Forms');
          end);
        Route.FreeOnTerminate := False;
        try
          Route.Start;
          Assert.IsTrue(Await(
            function: Boolean
            begin
              Result := Route.Finished;
            end), 'the handover never came back');
        finally
          Route.Free;
        end;
        Assert.AreEqual(Ord(roOpened), Ord(Routed), Detail);
      end);
    Noted := SearchPathFor('C:\WorkA\Handed.dfm');
    Assert.AreEqual(2, Length(Noted),
      'the noted path does not hold both directories');
    Assert.AreEqual('C:\Shared Forms', Noted[1],
      'a directory with a space did not survive the trip');
  finally
    NoteSearchPathFor('C:\WorkA\Handed.dfm', nil);
  end;
end;

// An open carrying searchPath notes it for that document; a later open
// without the field leaves the noted path standing, so an editor need not
// repeat it on every open.
procedure TProtocolTests.AnOpenOverASessionNotesItsSearchPath;
begin
  FOpenOutcome := ooOpened;
  try
    Listening(
      procedure
      var
        Client: TSessionClient;
        Answer: TWireMessage;
      begin
        Client := Attached([WorkA]);
        Client.Send('{"v":1,"id":9,"cmd":"open","file":"C:\\WorkA\\One.dfm",' +
          '"searchPath":"C:\\Base"}');
        Answer := AwaitAnswer(Client, 9);
        try
          Assert.IsNotNull(Answer, 'the open was not answered');
          Assert.IsTrue(Answer.FlagOf(OkField), Answer.TextOf(ErrorField));
        finally
          Answer.Free;
        end;
        Assert.AreEqual(1, Length(SearchPathFor('C:\WorkA\One.dfm')),
          'the searchPath sent with the open was not noted');
        Client.Send('{"v":1,"id":10,"cmd":"open","file":"C:\\WorkA\\One.dfm"}');
        Answer := AwaitAnswer(Client, 10);
        try
          Assert.IsNotNull(Answer, 'the second open was not answered');
        finally
          Answer.Free;
        end;
        Assert.AreEqual(1, Length(SearchPathFor('C:\WorkA\One.dfm')),
          'an open without the field must leave the noted path standing');
      end);
  finally
    NoteSearchPathFor('C:\WorkA\One.dfm', nil);
  end;
end;

procedure TProtocolTests.TheOpenerHearsAboutItsDocument;
const
  // In the other session's workspace on purpose: the session that opened the
  // document is served ahead of the one whose workspace holds it.
  Wanted = 'C:\WorkB\Shared.dfm';
begin
  Listening(
    procedure
    var
      Opener, Neighbour: TSessionClient;
      Answer, Event: TWireMessage;
    begin
      Opener := Attached([WorkA]);
      Neighbour := Attached([WorkB]);
      Opener.Send('{"v":1,"id":9,"cmd":"open","file":"C:\\WorkB\\Shared.dfm"}');
      Answer := AwaitAnswer(Opener, 9);
      try
        Assert.IsNotNull(Answer, 'the open was never answered');
      finally
        Answer.Free;
      end;
      Assert.IsTrue(FSessions.EmitEvent(Wanted, DirtyEvent,
        [WireFlag(DirtyField, True)]), 'the event went nowhere');
      Event := AwaitEvent(Opener, DirtyEvent);
      try
        Assert.IsNotNull(Event, 'the session that opened it heard nothing');
        Assert.AreEqual(Wanted, Event.TextOf(FileField),
          'the event names the document it is about');
        Assert.IsTrue(Event.FlagOf(DirtyField), 'and what became of it');
      finally
        Event.Free;
      end;
      Assert.AreEqual(0, Length(EventsFor(Neighbour)),
        'an event goes to one session, not to everybody');
    end);
end;

procedure TProtocolTests.AWorkspaceMatchHearsAboutADocumentTheOpenerLeftBehind;
const
  Wanted = 'C:\WorkB\Shared.dfm';
begin
  Listening(
    procedure
    var
      Opener, Neighbour: TSessionClient;
      Answer, Event: TWireMessage;
      Ends: Integer;
    begin
      Opener := Attached([WorkA]);
      Neighbour := Attached([WorkB]);
      Opener.Send('{"v":1,"id":10,"cmd":"open","file":"C:\\WorkB\\Shared.dfm"}');
      Answer := AwaitAnswer(Opener, 10);
      try
        Assert.IsNotNull(Answer, 'the open was never answered');
      finally
        Answer.Free;
      end;
      Ends := FEnded.Count;
      Opener.Terminate;
      Opener.WaitFor;
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := FEnded.Count > Ends;
        end), 'the core never noticed the session go');
      Assert.IsTrue(FSessions.EmitEvent(Wanted, SavedEvent, nil),
        'the document is in a workspace somebody still holds');
      Event := AwaitEvent(Neighbour, SavedEvent);
      try
        Assert.IsNotNull(Event,
          'the session whose workspace holds it picks it up');
      finally
        Event.Free;
      end;
    end);
end;

procedure TProtocolTests.AnEventNobodyHasAClaimOnIsDropped;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
    begin
      Client := Attached([WorkA]);
      Assert.IsFalse(FSessions.EmitEvent('C:\Elsewhere\Lonely.dfm', SavedEvent,
        nil), 'nothing has a claim on this document');
      Pump(SettleWait);
      Assert.AreEqual(0, Length(EventsFor(Client)),
        'a session that has no claim on a document hears nothing about it');
    end);
end;

// The two attached workspaces are nested and both hold the file, so the
// deeper one is the closer claim.
procedure TProtocolTests.TheClosestWorkspaceHearsAboutTheFile;
const
  Inner = WorkA + '\Inner';
begin
  Listening(
    procedure
    var
      Wide, Close: TSessionClient;
      Event: TWireMessage;
    begin
      Wide := Attached([WorkA]);
      Close := Attached([Inner]);
      Assert.IsTrue(FSessions.EmitEvent(Inner + '\Unit1.dfm', SavedEvent, nil),
        'both of them hold this file');
      Event := AwaitEvent(Close, SavedEvent);
      try
        Assert.IsNotNull(Event, 'the closer workspace heard nothing');
      finally
        Event.Free;
      end;
      Assert.AreEqual(0, Length(EventsFor(Wide)),
        'the wider workspace is not the answer while a closer one is attached');
    end);
end;

procedure TProtocolTests.TheLatestOfTwoEqualClaimsHearsAboutTheFile;
begin
  Listening(
    procedure
    var
      Earlier, Later: TSessionClient;
      Event: TWireMessage;
    begin
      Earlier := Attached([WorkA]);
      Later := Attached([WorkA]);
      Assert.IsTrue(FSessions.EmitEvent(WorkA + '\Unit1.dfm', SavedEvent, nil),
        'both of them hold this file');
      Event := AwaitEvent(Later, SavedEvent);
      try
        Assert.IsNotNull(Event,
          'two equally good claims are settled by which attached last');
      finally
        Event.Free;
      end;
      Assert.AreEqual(0, Length(EventsFor(Earlier)),
        'and only one of them hears it');
    end);
end;

procedure TProtocolTests.AWorkspaceThatOnlyStartsTheSameWayHoldsNothing;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
    begin
      Client := Attached([WorkA]);
      Assert.IsFalse(FSessions.EmitEvent(WorkA + 'lpha\Unit1.dfm', SavedEvent,
        nil), 'C:\WorkA does not hold C:\WorkAlpha');
      Pump(SettleWait);
      Assert.AreEqual(0, Length(EventsFor(Client)),
        'a folder that shares a prefix is a different folder');
    end);
end;

procedure TProtocolTests.ASessionCommandThatNamesNoFileIsRefusedBeforeTheCore;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Answer: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Client.Send('{"v":1,"id":15,"cmd":"focus"}');
      Answer := AwaitAnswer(Client, 15);
      try
        Assert.IsNotNull(Answer, 'the focus was never answered');
        Assert.IsFalse(Answer.FlagOf(OkField), 'there was nothing to focus');
        Assert.AreEqual('the request named no file', Answer.TextOf(ErrorField),
          'and the answer says what was missing');
      finally
        Answer.Free;
      end;
      Assert.AreEqual(0, FServed.Count,
        'nothing the core cannot act on may reach it');
    end);
end;

// The session reader drains the over-long line instead of stopping at the
// limit: the client blocks in its write until the bytes are taken, and cannot
// read the refusal before that.
procedure TProtocolTests.ALineLongerThanAnyOfOursEndsTheSession;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Answer: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Client.Send(StringOfChar('x', 256 * 1024));
      Answer := AwaitAnswer(Client, 0);
      try
        Assert.IsNotNull(Answer, 'the core never answered');
        Assert.IsFalse(Answer.FlagOf(OkField), 'it was not carried out');
        Assert.Contains(Answer.TextOf(ErrorField), 'longer than any of ours',
          'a line past the limit has its own answer');
      finally
        Answer.Free;
      end;
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := FEnded.Count = 1;
        end), 'a client that sends one is dropped');
    end);
end;

procedure TProtocolTests.EventsArriveInTheOrderTheyWereEmitted;
const
  Wanted = 'C:\WorkA\Ordered.dfm';
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Order: string;
      Name: string;
    begin
      Client := Attached([WorkA]);
      FSessions.EmitEvent(Wanted, OpenedEvent, [WireText(ClassField, 'TForm1'),
        WireText(KindField, 'form')]);
      FSessions.EmitEvent(Wanted, DirtyEvent, [WireFlag(DirtyField, True)]);
      FSessions.EmitEvent(Wanted, SavedEvent, nil);
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := Length(EventsFor(Client)) >= 3;
        end), 'the three events did not arrive');
      Order := '';
      for Name in EventsFor(Client) do
        Order := Order + Name + ' ';
      Assert.AreEqual(Format('%s %s %s ', [OpenedEvent, DirtyEvent, SavedEvent]),
        Order, 'one writer, one queue, and what goes in first comes out first');
    end);
end;

// The session is dropped once its outbound queue reaches OutboundLimit, and
// the core goes on serving other clients.
procedure TProtocolTests.ASessionThatStopsReadingIsDisconnected;
var
  Posted: Integer;
begin
  Listening(
    procedure
    var
      Deaf: TSessionClient;
      Alive: TSessionClient;
      Session: TDesignSession;
      Answer: TWireMessage;
      Full: Boolean;
    begin
      Deaf := NewClient(False);
      Deaf.Send(Format('{"v":1,"id":1,"cmd":"attach","pid":%d,"client":"deaf",' +
        '"version":"1.0.0","workspaces":["C:\\Deaf"]}', [GetCurrentProcessId]));
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := FAttached.Count = 1;
        end), 'the deaf client never attached');
      Session := FSessions.Find(FAttached[0]);
      Full := False;
      Posted := 0;
      while (Posted < FloodLimit) and not Full do
      begin
        Full := not FSessions.EmitEvent('C:\Deaf\Unit1.dfm', SavedEvent, nil);
        Inc(Posted);
        CheckSynchronize(1);
      end;
      Assert.IsTrue(Full, Format('the queue took %d messages without a bound',
        [Posted]));
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := FEnded.IndexOf(Session.Id) >= 0;
        end), 'the session was not dropped once the bound was reached');
      Alive := Attached([WorkA]);
      Alive.Send('{"v":1,"id":11,"cmd":"open","file":"C:\\WorkA\\Still.dfm"}');
      Answer := AwaitAnswer(Alive, 11);
      try
        Assert.IsNotNull(Answer, 'the core stopped serving');
        Assert.IsTrue(Answer.FlagOf(OkField), Answer.TextOf(ErrorField));
      finally
        Answer.Free;
      end;
    end);
end;

procedure TProtocolTests.ARequestTheCoreSendsIsAnsweredOnTheMainThread;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Session: TDesignSession;
      Sent: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Session := FSessions.Find(FAttached[0]);
      Assert.IsTrue(FSessions.SendRequest(Session, GotoHandlerCommand,
        [WireText(FileField, 'C:\WorkA\Unit1.dfm'),
         WireText('method', 'Button1Click')], Answered),
        'the request did not go out');
      Sent := AwaitRequest(Client, GotoHandlerCommand);
      try
        Assert.IsNotNull(Sent, 'the client never saw the request');
        Assert.IsTrue(Sent.HasId, 'a request the core sends carries an id');
        Assert.AreEqual('Button1Click', Sent.TextOf('method'),
          'the request carries what it was given');
        Client.Send(Format('{"v":1,"id":%d,"ok":true,"found":"yes"}',
          [Sent.Id]));
      finally
        Sent.Free;
      end;
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := FAnswerCount = 1;
        end), 'the answer never reached what asked for it');
      Assert.AreEqual('ok yes', FAnswers[0],
        'the callback is handed the answer''s own fields');
      Assert.AreEqual(0, FSessions.Pending,
        'an answered request is no longer waiting');
    end);
end;

procedure TProtocolTests.ARequestNobodyAnswersIsRefusedByTheBeat;
const
  ShortWait = 50;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Session: TDesignSession;
      Sent: TWireMessage;
      Late: Integer;
    begin
      Client := Attached([WorkA]);
      Session := FSessions.Find(FAttached[0]);
      FSessions.SendRequest(Session, ListMethodsCommand, nil, Answered,
        ShortWait);
      Sent := AwaitRequest(Client, ListMethodsCommand);
      try
        Assert.IsNotNull(Sent, 'the client never saw the request');
        Late := Sent.Id;
      finally
        Sent.Free;
      end;
      Pump(ShortWait * 4);
      FSessions.Beat;
      Assert.AreEqual(1, FAnswerCount, 'the beat has to answer what expired');
      Assert.AreEqual('refused the editor did not answer', FAnswers[0],
        'and say that nothing came back');
      Client.Send(Format('{"v":1,"id":%d,"ok":true,"found":"late"}', [Late]));
      Pump(SettleWait);
      Assert.AreEqual(1, FAnswerCount, 'a late answer is not a second one');
    end);
end;

procedure TProtocolTests.ASessionThatDiesRefusesWhatItWasAsked;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Session: TDesignSession;
      Sent: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Session := FSessions.Find(FAttached[0]);
      FSessions.SendRequest(Session, EnsureHandlerCommand,
        [WireText('method', 'Button1Click')], Answered);
      Sent := AwaitRequest(Client, EnsureHandlerCommand);
      try
        Assert.IsNotNull(Sent, 'the client never saw the request');
      finally
        Sent.Free;
      end;
      Client.Terminate;
      Client.WaitFor;
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := FAnswerCount = 1;
        end), 'a request whose session died has to be refused, not forgotten');
      Assert.AreEqual('refused connection lost', FAnswers[0],
        'and the refusal says what happened');
      Assert.AreEqual(0, FSessions.Pending, 'nothing is left waiting');
    end);
end;

procedure TProtocolTests.AFileThatIsNotOpenCannotBeFocused;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Answer: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Client.Send('{"v":1,"id":12,"cmd":"focus","file":"C:\\WorkA\\Cold.dfm"}');
      Answer := AwaitAnswer(Client, 12);
      try
        Assert.IsNotNull(Answer, 'the focus was never answered');
        Assert.IsFalse(Answer.FlagOf(OkField), 'nothing was focused');
        Assert.AreEqual('not open', Answer.TextOf(ErrorField),
          'the refusal says why in the words the shell gives');
      finally
        Answer.Free;
      end;
    end);
end;

procedure TProtocolTests.ACloseTheUserCancelledIsRefusedInThoseWords;
begin
  FRefuseClose := True;
  Listening(
    procedure
    var
      Client: TSessionClient;
      Answer: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Client.Send('{"v":1,"id":13,"cmd":"close","file":"C:\\WorkA\\Unit1.dfm"}');
      Answer := AwaitAnswer(Client, 13);
      try
        Assert.IsNotNull(Answer, 'the close was never answered');
        Assert.IsFalse(Answer.FlagOf(OkField), 'the window is still open');
        Assert.AreEqual('cancelled by the user', Answer.TextOf(ErrorField),
          'a person said no, and the client is told so');
      finally
        Answer.Free;
      end;
      Assert.AreEqual(Format('%d %s C:\WorkA\Unit1.dfm',
        [FAttached[0], CloseCommand]), FServed[0],
        'the command reached the core on its own session, naming its file');
    end);
end;

procedure TProtocolTests.ADirtyDocumentIsNotReloadedFromDisk;
begin
  FDirtyDocument := 'C:\WorkA\Unit1.dfm';
  Listening(
    procedure
    var
      Client: TSessionClient;
      Answer: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Client.Send('{"v":1,"id":14,"cmd":"reloadFromDisk",' +
        '"file":"C:\\WorkA\\Unit1.dfm"}');
      Answer := AwaitAnswer(Client, 14);
      try
        Assert.IsNotNull(Answer, 'the reload was never answered');
        Assert.IsFalse(Answer.FlagOf(OkField),
          'the designer never drops edits because it was asked to');
        Assert.AreEqual('the document has unsaved changes',
          Answer.TextOf(ErrorField), 'and says which of its rules that is');
      finally
        Answer.Free;
      end;
    end);
end;

procedure TProtocolTests.ThePipeNameIsTheOneTheExtensionAlsoDerives;
begin
  Assert.AreEqual('\\.\pipe\VallentaDesigner.21a7215a56f5220d',
    CorePipeNameFor('C:\Program Files\Vallenta\VallentaDesigner.exe', 1), False,
    'the pipe name derivation is a protocol contract, not an implementation detail');
end;

{ the field coupling on the wire }

function Button(const AName: string): TFieldEntry;
begin
  Result.Name := AName;
  Result.TypeName := 'TButton';
  Result.UnitName := 'Vcl.StdCtrls';
end;

function TProtocolTests.CountRequests(AClient: TSessionClient;
  const ACommand: string): Integer;
var
  Line: string;
  Message: TWireMessage;
begin
  Result := 0;
  for Line in AClient.Received do
  begin
    Message := TWireMessage.Create(Line);
    try
      if (Message.Kind = wkRequest) and SameText(Message.Name, ACommand) then
        Inc(Result);
    finally
      Message.Free;
    end;
  end;
end;

function TProtocolTests.CouplingFor(const AFile: string;
  out AHeld: ICodeCoupling): TDocumentCoupling;
begin
  Result := TDocumentCoupling.Create(FSessions);
  AHeld := Result;
  Result.FileName := AFile;
  Result.RootClass := 'TForm1';
  Result.Log := FLog;
end;

procedure TProtocolTests.WireHistory(ACoupling: TDocumentCoupling);
begin
  FCoupling := ACoupling;
  ACoupling.OnCurrentStep := CurrentStep;
  ACoupling.OnHandlerCreated := HandlerCreated;
  ACoupling.OnHandlerRoster := HandlerRoster;
end;

function TProtocolTests.CurrentStep: Integer;
begin
  Result := FUndo.LastStep;
end;

procedure TProtocolTests.HandlerCreated(AStep: Integer;
  const AHandler: TCreatedHandler);
begin
  Inc(FMarks);
  FMarkedStep := AStep;
  FMarkedHandler := AHandler;
  FUndo.MarkCreatedHandler(AStep, AHandler);
end;

function TProtocolTests.HandlerRoster: TArray<TCreatedHandler>;
begin
  Result := FUndo.CreatedHandlers;
end;

procedure TProtocolTests.Renamed(const AAnswer: TRenameAnswer);
begin
  Inc(FRenameAnswers);
  FRenameAnswer := AAnswer;
end;

function TProtocolTests.TakeImage(Sender: TObject): TDocumentSnapshot;
begin
  Result := TDocumentSnapshot.Create(TMemoryStream.Create, '',
    TPreservedModel.Create);
end;

procedure TProtocolTests.PutImageBack(Sender: TObject;
  ASnapshot: TDocumentSnapshot);
begin
  Inc(FRestores);
end;

procedure TProtocolTests.StepUndone(Sender: TObject;
  const AHandler: TCreatedHandler);
begin
  if FCoupling <> nil then
    FCoupling.RemoveHandler(AHandler.Method);
end;

procedure TProtocolTests.StepRedone(Sender: TObject;
  const AHandler: TCreatedHandler);
begin
  if FCoupling <> nil then
    FCoupling.EnsureHandler(AHandler.Component, AHandler.Event,
      AHandler.Method, AHandler.Signature);
end;

procedure TProtocolTests.PushStep;
begin
  FUndo.Push(uoProperty, 'Button1');
  FStep := FUndo.LastStep;
end;

procedure TProtocolTests.AnswerEnsure(AClient: TSessionClient;
  ACreated: Boolean; AOrdinal: Integer);
var
  Id: Integer;
begin
  Id := 0;
  Assert.IsTrue(Await(
    function: Boolean
    var
      Line: string;
      Message: TWireMessage;
      Seen: Integer;
    begin
      Seen := 0;
      for Line in AClient.Received do
      begin
        Message := TWireMessage.Create(Line);
        try
          if (Message.Kind <> wkRequest) or
             not SameText(Message.Name, EnsureHandlerCommand) then
            Continue;
          Inc(Seen);
          if Seen < AOrdinal then
            Continue;
          Id := Message.Id;
          Exit(True);
        finally
          Message.Free;
        end;
      end;
      Result := False;
    end), 'the editor was never asked for the handler');
  AClient.Send(Format('{"v":1,"id":%d,"ok":true,"created":%s}',
    [Id, BoolToStr(ACreated, True).ToLower]));
  Assert.IsTrue(Await(
    function: Boolean
    begin
      Result := FSessions.Pending = 0;
    end), 'the answer never came back');
end;

function TProtocolTests.LogHolds(const AText: string): Boolean;
var
  I: Integer;
begin
  for I := 0 to FLog.Count - 1 do
    if Pos(AText, FLog[I].Text) > 0 then
      Exit(True);
  Result := False;
end;

procedure TProtocolTests.TheFirstSessionSeedsTheLedgerAndAsksForNothing;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      Coupling.Resume([Button('Ok'), Button('Cancel')]);
      Assert.IsTrue(Coupling.Ledger.HasBaseline, 'the first session did not seed');
      Assert.AreEqual(2, Coupling.Ledger.Count, 'the seed is what was there');
      Pump(SettleWait);
      Assert.AreEqual(0, CountRequests(Client, AddFieldCommand),
        'the coupling back-filled fields for a form it merely found');
      Assert.AreEqual(Ord(soNothing),
        Ord(Coupling.Settle([Button('Ok'), Button('Cancel')])),
        'a document nothing had happened to was reported as changed');
    end);
end;

procedure TProtocolTests.ASettlePointAsksForTheFieldThatAppeared;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Sent: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      Coupling.Resume([]);
      Assert.AreEqual(Ord(soSent), Ord(Coupling.Settle([Button('Button1')])),
        'the settle point sent nothing');
      Sent := AwaitRequest(Client, AddFieldCommand);
      try
        Assert.IsNotNull(Sent, 'the editor was never asked for the field');
        Assert.AreEqual('Button1', Sent.TextOf(NameField),
          'the field is named after the component, exactly');
        Assert.AreEqual('TButton', Sent.TextOf(TypeField), 'the field''s type');
        Assert.AreEqual('Vcl.StdCtrls', Sent.TextOf(UnitField),
          'the unit its class comes from, which is what the uses clause needs');
        Assert.AreEqual('C:\WorkA\Unit1.dfm', Sent.TextOf(FileField),
          'every request says which document it is about');
        Assert.AreEqual('TForm1', Sent.TextOf(ClassField),
          'and which class in it');
        Assert.AreEqual(0, Coupling.Ledger.Count,
          'the ledger moved before anybody had answered');
        Client.Send(Format('{"v":1,"id":%d,"ok":true}', [Sent.Id]));
      finally
        Sent.Free;
      end;
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := Coupling.Ledger.Count = 1;
        end), 'the confirmed add never reached the ledger');
      Assert.AreEqual(Ord(soNothing), Ord(Coupling.Settle([Button('Button1')])),
        'the field was asked for a second time');
    end);
end;

procedure TProtocolTests.ASettlePointAsksForTheFieldThatWent;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Sent: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      Coupling.Resume([Button('Button1')]);
      Assert.AreEqual(Ord(soSent), Ord(Coupling.Settle([])),
        'deleting the only component sent nothing');
      Sent := AwaitRequest(Client, RemoveFieldCommand);
      try
        Assert.IsNotNull(Sent, 'the editor was never asked to drop the field');
        Assert.AreEqual('Button1', Sent.TextOf(NameField),
          'the wrong field was named');
      finally
        Sent.Free;
      end;
    end);
end;

// A refused add is not written into the ledger, which is what makes the next
// settle point send it again.
procedure TProtocolTests.AnAddThatWasRefusedIsAskedForAgainAtTheNextSettlePoint;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Sent: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      Coupling.Resume([]);
      Coupling.Settle([Button('Button1')]);
      Sent := AwaitRequest(Client, AddFieldCommand);
      try
        Assert.IsNotNull(Sent, 'the editor was never asked for the field');
        Client.Send(Format('{"v":1,"id":%d,"ok":false,"error":"no companion unit"}',
          [Sent.Id]));
      finally
        Sent.Free;
      end;
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := FSessions.Pending = 0;
        end), 'the refusal never came back');
      Assert.AreEqual(0, Coupling.Ledger.Count,
        'a refused add was written into the ledger anyway');
      Assert.AreEqual(Ord(soSent), Ord(Coupling.Settle([Button('Button1')])),
        'the refused add was not made again');
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := CountRequests(Client, AddFieldCommand) = 2;
        end), 'the second attempt never reached the editor');
    end);
end;

// A resume sends the adds since the baseline again, and not the fields the
// baseline merely found.
procedure TProtocolTests.AResumeAsksAgainForWhatThisDesignerAdded;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Sent: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      Coupling.Resume([Button('Ok')]);
      Coupling.Settle([Button('Ok'), Button('Button1')]);
      Sent := AwaitRequest(Client, AddFieldCommand);
      try
        Client.Send(Format('{"v":1,"id":%d,"ok":true}', [Sent.Id]));
      finally
        Sent.Free;
      end;
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := Coupling.Ledger.Count = 2;
        end), 'the confirmed add never reached the ledger');
      Coupling.Resume([Button('Ok'), Button('Button1')]);
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := CountRequests(Client, AddFieldCommand) = 2;
        end), 'the resume did not make sure of the field it had added');
      Pump(SettleWait);
      Assert.AreEqual(2, CountRequests(Client, AddFieldCommand),
        'the resume asked for the component it had merely found as well');
      Assert.AreEqual(2, Coupling.Ledger.Count, 'the resume re-seeded the ledger');
    end);
end;

// The replayed ensureHandler carries the quiet flag and marks no step: the
// step that made the handler carries its mark already.
procedure TProtocolTests.AResumeAsksAgainForTheHandlersTheHistoryMade;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Sent: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      WireHistory(Coupling);
      Coupling.Ledger.Baseline([]);
      PushStep;
      Coupling.EnsureHandler('ButtonB', 'OnClick', 'ButtonBClick',
        SignatureOf(TypeInfo(TNotifyEvent)));
      AnswerEnsure(Client, True);
      Assert.AreEqual(1, FMarks, 'the making itself did not mark its step');
      Coupling.Resume([]);
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := CountRequests(Client, EnsureHandlerCommand) = 2;
        end), 'the resume never asked for the handler again');
      Sent := AwaitRequest(Client, EnsureHandlerCommand, 2);
      try
        Assert.AreEqual('ButtonBClick', Sent.TextOf(MethodField),
          'the resume asked for a different method');
        Assert.IsTrue(Sent.FlagOf(QuietField),
          'a replay asks for the text, never for attention');
        Client.Send(Format('{"v":1,"id":%d,"ok":true,"created":true}',
          [Sent.Id]));
      finally
        Sent.Free;
      end;
      Pump(SettleWait);
      Assert.AreEqual(1, FMarks, 'the replay marked a step of its own');
    end);
end;

// With no session attached the first Resume seeds no baseline, and a settle
// point over a seeded ledger reports soUncoupled rather than nothing.
procedure TProtocolTests.ADocumentWithNoSessionKeepsItsChangesForLater;
begin
  Listening(
    procedure
    var
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
    begin
      Coupling := CouplingFor('C:\WorkB\Unit9.dfm', Held);
      Coupling.Resume([]);
      Assert.IsFalse(Coupling.Ledger.HasBaseline,
        'a document nothing is attached to was seeded by nobody');
      Assert.AreEqual(Ord(soNothing), Ord(Coupling.Settle([Button('Button1')])),
        'a document that was never coupled reported a difference');
      Coupling.Ledger.Baseline([]);
      Assert.AreEqual(Ord(soUncoupled), Ord(Coupling.Settle([Button('Button1')])),
        'a change with nowhere to go has to say so, not look like nothing');
    end);
end;

// An answer arriving after Coupling.Close is still consumed, so nothing stays
// pending, and a settle point on the closed document reports soNothing.
procedure TProtocolTests.AnAnswerForADocumentThatHasGoneIsReadAndDropped;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Sent: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      Coupling.Resume([]);
      Coupling.Settle([Button('Button1')]);
      Sent := AwaitRequest(Client, AddFieldCommand);
      try
        Assert.IsNotNull(Sent, 'the editor was never asked for the field');
        Coupling.Close;
        Client.Send(Format('{"v":1,"id":%d,"ok":true}', [Sent.Id]));
      finally
        Sent.Free;
      end;
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := FSessions.Pending = 0;
        end), 'the answer never came back');
      Assert.AreEqual(Ord(soNothing), Ord(Coupling.Settle([Button('Button2')])),
        'a closed document went on reporting differences');
    end);
end;

// A handler the editor reports as created marks exactly one step, the step
// that asked for it rather than the top of the history, and the mark carries
// the method and event names.
procedure TProtocolTests.AHandlerTheEditorHadToMakeMarksTheStepThatAskedForIt;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      WireHistory(Coupling);
      PushStep;
      Coupling.EnsureHandler('Button1', 'OnClick', 'Button1Click',
        SignatureOf(TypeInfo(TNotifyEvent)));
      AnswerEnsure(Client, True);
      Assert.AreEqual(1, FMarks, 'the step was not marked exactly once');
      Assert.AreEqual(FStep, FMarkedStep,
        'the mark landed on a step nobody asked about');
      Assert.AreEqual('Button1Click', FMarkedHandler.Method,
        'the mark does not name the method that was made');
      Assert.AreEqual('OnClick', FMarkedHandler.Event,
        'the mark has to carry the event, or a redo cannot ask for it again');
    end);
end;

// A method the editor did not create marks no step, so undoing that step
// sends no removeHandler.
procedure TProtocolTests.AHandlerThatWasAlreadyThereMarksNothing;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      WireHistory(Coupling);
      PushStep;
      Coupling.EnsureHandler('Button1', 'OnClick', 'HandleSave',
        SignatureOf(TypeInfo(TNotifyEvent)));
      AnswerEnsure(Client, False);
      Assert.AreEqual(0, FMarks, 'a method that was already there marked a step');
      FUndo.Undo;
      Pump(SettleWait);
      Assert.AreEqual(0, CountRequests(Client, RemoveHandlerCommand),
        'undoing a step that made nothing asked for a removal anyway');
    end);
end;

// Two further steps are pushed before the answer arrives, so the step that
// asked is no longer the top of the history.
procedure TProtocolTests.AnAnswerMarksItsOwnStepAndNotWhateverIsOnTop;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Asking: Integer;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      WireHistory(Coupling);
      PushStep;
      Asking := FStep;
      Coupling.EnsureHandler('Button1', 'OnClick', 'Button1Click',
        SignatureOf(TypeInfo(TNotifyEvent)));
      FUndo.Push(uoMove, 'Button1');
      FUndo.Push(uoMove, 'Button1');
      AnswerEnsure(Client, True);
      Assert.AreEqual(Asking, FMarkedStep,
        'the answer marked the newest step instead of the one that asked');
      Assert.AreNotEqual(FUndo.LastStep, FMarkedStep,
        'the mark landed on the top of the history');
    end);
end;

procedure TProtocolTests.TakingAMarkedStepBackAsksForTheHandlerToGo;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Sent: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      WireHistory(Coupling);
      PushStep;
      Coupling.EnsureHandler('Button1', 'OnClick', 'Button1Click',
        SignatureOf(TypeInfo(TNotifyEvent)));
      AnswerEnsure(Client, True);
      FUndo.Undo;
      Sent := AwaitRequest(Client, RemoveHandlerCommand);
      try
        Assert.IsNotNull(Sent, 'the editor was never asked to take the method out');
        Assert.AreEqual('Button1Click', Sent.TextOf(MethodField),
          'the wrong method was named');
        Assert.AreEqual('C:\WorkA\Unit1.dfm', Sent.TextOf(FileField),
          'the request does not say which document it is about');
        Assert.AreEqual('TForm1', Sent.TextOf(ClassField),
          'the request does not say which class the method is in');
      finally
        Sent.Free;
      end;
      Assert.AreEqual(1, FRestores,
        'the request went out without the document having been restored');
    end);
end;

procedure TProtocolTests.TakingAStepThatMadeNothingBackAsksForNothing;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      WireHistory(Coupling);
      FUndo.Push(uoMove, 'Button1');
      FUndo.Undo;
      Pump(SettleWait);
      Assert.AreEqual(0, CountRequests(Client, RemoveHandlerCommand),
        'an ordinary step asked the editor to remove a method');
    end);
end;

// A redo of a marked step sends a second ensureHandler request. Only the
// count of requests is pinned here: the method and event fields are read
// from the first request, not from the replay.
procedure TProtocolTests.PuttingAMarkedStepBackAsksForTheHandlerAgain;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Sent: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      WireHistory(Coupling);
      PushStep;
      Coupling.EnsureHandler('Button1', 'OnClick', 'Button1Click',
        SignatureOf(TypeInfo(TNotifyEvent)));
      AnswerEnsure(Client, True);
      FUndo.Undo;
      FUndo.Redo;
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := CountRequests(Client, EnsureHandlerCommand) = 2;
        end), 'the redo never asked for the handler again');
      Sent := AwaitRequest(Client, EnsureHandlerCommand);
      try
        Assert.AreEqual('Button1Click', Sent.TextOf(MethodField),
          'the redo asked for a different method');
        Assert.AreEqual('OnClick', Sent.TextOf(EventPropertyField),
          'the redo lost the event the handler belongs to');
      finally
        Sent.Free;
      end;
    end);
end;

// An editor that keeps a non-empty method answers ok with removed False and
// a reason; the reason and the method name both reach the log.
procedure TProtocolTests.AHandlerTheEditorKeptIsSaidInTheMessagesPane;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Sent: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      WireHistory(Coupling);
      PushStep;
      Coupling.EnsureHandler('Button1', 'OnClick', 'Button1Click',
        SignatureOf(TypeInfo(TNotifyEvent)));
      AnswerEnsure(Client, True);
      FUndo.Undo;
      Sent := AwaitRequest(Client, RemoveHandlerCommand);
      try
        Assert.IsNotNull(Sent, 'the editor was never asked to take the method out');
        Client.Send(Format('{"v":1,"id":%d,"ok":true,"removed":false,' +
          '"reason":"it is no longer empty"}', [Sent.Id]));
      finally
        Sent.Free;
      end;
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := LogHolds('it is no longer empty');
        end), 'the reason the method stayed was never said');
      Assert.IsTrue(LogHolds('Button1Click was not taken out of the unit'),
        'the line does not name the method that stayed');
    end);
end;

procedure TProtocolTests.AnUndoWithNothingAttachedAsksForNothingAndKeepsNothing;
begin
  Listening(
    procedure
    var
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Handler: TCreatedHandler;
    begin
      Coupling := CouplingFor('C:\WorkB\Unit9.dfm', Held);
      WireHistory(Coupling);
      PushStep;
      Handler := Default(TCreatedHandler);
      Handler.Component := 'Button1';
      Handler.Event := 'OnClick';
      Handler.Method := 'Button1Click';
      Assert.IsTrue(FUndo.MarkCreatedHandler(FStep, Handler),
        'the step could not be marked');
      Assert.IsFalse(Coupling.Available,
        'the case is not measuring what it says - something was attached');
      FUndo.Undo;
      Pump(SettleWait);
      Assert.AreEqual(0, FSessions.Pending,
        'a removal with nowhere to go was queued instead of skipped');
      Assert.IsFalse(LogHolds('was not taken out of the unit'),
        'a request that was never sent was reported as answered');
    end);
end;

procedure TProtocolTests.AStepThatMadeTwoHandlersTakesBothBackOut;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Asked: TStringList;
      Sent: TWireMessage;
      Line: string;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      WireHistory(Coupling);
      PushStep;
      Coupling.EnsureHandler('Button1', 'OnClick', 'Button1Click',
        SignatureOf(TypeInfo(TNotifyEvent)));
      AnswerEnsure(Client, True);
      Coupling.EnsureHandler('Button1', 'OnEnter', 'Button1Enter',
        SignatureOf(TypeInfo(TNotifyEvent)));
      AnswerEnsure(Client, True, 2);
      FUndo.Undo;
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := CountRequests(Client, RemoveHandlerCommand) = 2;
        end), 'both handlers of the one step were not asked for');
      Asked := TStringList.Create;
      try
        for Line in Client.Received do
        begin
          Sent := TWireMessage.Create(Line);
          try
            if (Sent.Kind = wkRequest) and
               SameText(Sent.Name, RemoveHandlerCommand) then
              Asked.Add(Sent.TextOf(MethodField));
          finally
            Sent.Free;
          end;
        end;
        Assert.IsTrue(Asked.IndexOf('Button1Click') >= 0,
          'the first handler the step made was never asked for');
        Assert.IsTrue(Asked.IndexOf('Button1Enter') >= 0,
          'the second handler the step made was never asked for');
      finally
        Asked.Free;
      end;
    end);
end;

{ a rename on the wire }

// The method pairs of the rename request as 'old->new', joined with '; ';
// '(none)' for an empty list, '(no list)' when the request carries no
// methods array, and '(no request)' when none was sent. Parsed from the raw
// line because TWireMessage reads no array of objects.
function PairsOf(AClient: TSessionClient): string;
var
  Line: string;
  Root: TJSONObject;
  List: TJSONArray;
  Item: TJSONValue;
begin
  Result := '(no request)';
  for Line in AClient.Received do
  begin
    Root := TJSONObject.ParseJSONValue(Line) as TJSONObject;
    if Root = nil then
      Continue;
    try
      if Root.GetValue<string>(CommandField, '') <> RenameComponentCommand then
        Continue;
      List := Root.GetValue<TJSONArray>(MethodsField);
      if List = nil then
        Exit('(no list)');
      Result := '';
      for Item in List do
      begin
        if Result <> '' then
          Result := Result + '; ';
        Result := Result + Item.GetValue<string>(PairOldField) + '->' +
          Item.GetValue<string>(PairNewField);
      end;
      if Result = '' then
        Result := '(none)';
      Exit;
    finally
      Root.Free;
    end;
  end;
end;

procedure TProtocolTests.ARenameGoesOutWithTheHandlersRidingWithIt;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Sent: TWireMessage;
      Pair: TMethodRename;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      Pair.OldName := 'Button1Click';
      Pair.NewName := 'Button2Click';
      Coupling.RenameComponent(1, rkComponent, 'Button1', 'Button2', [Pair]);
      Sent := AwaitRequest(Client, RenameComponentCommand);
      try
        Assert.IsNotNull(Sent, 'the editor was never asked for the rename');
        Assert.AreEqual('Button1', Sent.TextOf(OldNameField), 'the old name');
        Assert.AreEqual('Button2', Sent.TextOf(NewNameField), 'the new name');
        Assert.IsFalse(Sent.FlagOf(RootField),
          'a component was sent as though it were the root');
        Assert.AreEqual('Button1Click->Button2Click', PairsOf(Client),
          'the handlers riding with the rename');
        Assert.AreEqual('C:\WorkA\Unit1.dfm', Sent.TextOf(FileField),
          'every request says which document it is about');
        Assert.AreEqual('TForm1', Sent.TextOf(ClassField), 'and which class');
      finally
        Sent.Free;
      end;
    end);
end;

procedure TProtocolTests.ARootRenameSaysSoOnTheWire;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Sent: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      Coupling.RenameComponent(1, rkRoot, 'Form1', 'FormMain', []);
      Sent := AwaitRequest(Client, RenameComponentCommand);
      try
        Assert.IsNotNull(Sent, 'the editor was never asked');
        Assert.IsTrue(Sent.FlagOf(RootField),
          'the root was sent as though it were an ordinary component');
        Assert.AreEqual('(none)', PairsOf(Client),
          'a rename taking no handler with it did not say so as an empty list');
      finally
        Sent.Free;
      end;
    end);
end;

// A handler rename moves no field and no variable: the primary names go out
// empty and the method pairs are the whole of the request.
procedure TProtocolTests.AHandlerRenameNamesNoPrimarySymbol;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Sent: TWireMessage;
      Pair: TMethodRename;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      Pair.OldName := 'HandleSave';
      Pair.NewName := 'StoreAll';
      Coupling.RenameComponent(1, rkHandler, 'HandleSave', 'StoreAll', [Pair]);
      Sent := AwaitRequest(Client, RenameComponentCommand);
      try
        Assert.IsNotNull(Sent, 'the editor was never asked');
        Assert.AreEqual('', Sent.TextOf(OldNameField),
          'a handler rename named a primary symbol');
        Assert.AreEqual('', Sent.TextOf(NewNameField),
          'a handler rename named a new primary symbol');
        Assert.AreEqual('HandleSave->StoreAll', PairsOf(Client),
          'the pair is the whole of a handler rename');
      finally
        Sent.Free;
      end;
    end);
end;

procedure TProtocolTests.TheNotesBesideARenameTravelBackWithIt;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Sent: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      Coupling.OnRenamed := Renamed;
      Coupling.RenameComponent(7, rkRoot, 'Form1', 'FormMain', []);
      Sent := AwaitRequest(Client, RenameComponentCommand);
      try
        Assert.IsNotNull(Sent, 'the editor was never asked');
        Client.Send(Format('{"v":1,"id":%d,"ok":true,"primaryRenamed":false,' +
          '"skippedMethods":["Button1Click"]}', [Sent.Id]));
      finally
        Sent.Free;
      end;
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := FRenameAnswers = 1;
        end), 'the answer never reached the document');
      Assert.AreEqual(7, FRenameAnswer.Token,
        'the answer came back under another token than it went out with');
      Assert.IsTrue(FRenameAnswer.Ok, 'a rename that happened read as refused');
      Assert.IsFalse(FRenameAnswer.PrimaryRenamed,
        'a form with no variable to rename was reported as having had one');
      Assert.AreEqual(1, Length(FRenameAnswer.SkippedMethods),
        'the handler the unit has not got was not reported as skipped');
      Assert.AreEqual('Button1Click', FRenameAnswer.SkippedMethods[0], False,
        'and it was reported under another name');
    end);
end;

// A rename with no session attached is refused through the return value of
// RenameComponent and raises no OnRenamed behind the caller.
procedure TProtocolTests.ARenameWithNowhereToSendItIsRefusedOnTheSpot;
begin
  Listening(
    procedure
    var
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
    begin
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      Coupling.OnRenamed := Renamed;
      Assert.AreNotEqual('',
        Coupling.RenameComponent(3, rkComponent, 'Button1', 'Button2', []),
        'a rename nobody could take was reported as having gone out');
      Assert.AreEqual(0, FRenameAnswers,
        'it was answered behind the caller as well as refused to it');
      Assert.AreEqual(0, FSessions.Pending, 'and something was left waiting');
    end);
end;

procedure TProtocolTests.ARenameOnASessionThatDiesStopsTheRowWaiting;
begin
  Listening(
    procedure
    var
      Client: TSessionClient;
      Coupling: TDocumentCoupling;
      Held: ICodeCoupling;
      Sent: TWireMessage;
    begin
      Client := Attached([WorkA]);
      Coupling := CouplingFor('C:\WorkA\Unit1.dfm', Held);
      Coupling.OnRenamed := Renamed;
      Coupling.RenameComponent(4, rkComponent, 'Button1', 'Button2', []);
      Sent := AwaitRequest(Client, RenameComponentCommand);
      try
        Assert.IsNotNull(Sent, 'the editor was never asked');
      finally
        Sent.Free;
      end;
      Client.Terminate;
      Client.WaitFor;
      Assert.IsTrue(Await(
        function: Boolean
        begin
          Result := FRenameAnswers = 1;
        end), 'a rename whose session died left the row waiting for ever');
      Assert.IsFalse(FRenameAnswer.Ok, 'it was reported as having happened');
      Assert.AreEqual(0, FSessions.Pending, 'nothing is left waiting');
    end);
end;

initialization
  TDUnitX.RegisterTestFixture(TProtocolTests);

end.
