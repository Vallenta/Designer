// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Core.SingleInstance;

// Single-instance claim and the core's IPC. The claim is a named mutex whose
// holder serves a named pipe; both names embed a digest of the executable
// path and the logon session id, so two logons and two builds never answer
// each other. One accept thread gives every connection a thread of its own,
// and the core's handlers are serialized by running on the main thread.
//
// A connection whose first line is an attach becomes a session, many lines
// each way correlated by message id; every other connection speaks the v0
// handover, one JSON request and one answer. The v0 wire, refusal wordings
// included, is frozen: the test suite and the VS Code extension match on it.

interface

uses
  System.Classes,
  System.JSON,
  System.Generics.Collections;

const
  // Version field of every handover line; frozen at 0.
  ProtocolVersion = 0;
  // Version field of every session line, and the protocol reported in the
  // attach answer. Version 2 added the optional searchPath field on open.
  SessionProtocol = 2;

  // Wire command names.
  OpenCommand = 'open';
  AttachCommand = 'attach';
  FocusCommand = 'focus';
  CloseCommand = 'close';
  ReloadCommand = 'reloadFromDisk';
  AddFieldCommand = 'addFormField';
  RemoveFieldCommand = 'removeFormField';
  EnsureHandlerCommand = 'ensureEventHandler';
  RemoveHandlerCommand = 'removeEventHandler';
  GotoHandlerCommand = 'gotoHandler';
  RenameComponentCommand = 'renameComponent';
  ListMethodsCommand = 'listMethods';

  // Wire event names.
  OpenedEvent = 'opened';
  DirtyEvent = 'dirtyChanged';
  SavedEvent = 'saved';
  ClosedEvent = 'closed';

  // Wire field names.
  VersionField = 'v';
  CommandField = 'cmd';
  IdField = 'id';
  EventField = 'event';
  FileField = 'file';
  // Directories searched for ancestor and frame files beside the document's
  // own, semicolon-separated. Optional on open in both the handover and the
  // session scope, so its addition left ProtocolVersion at 0.
  SearchPathField = 'searchPath';
  OkField = 'ok';
  FocusedField = 'focused';
  ProcessField = 'pid';
  ErrorField = 'error';
  ProtocolField = 'protocol';
  ClientField = 'client';
  ClientVersionField = 'version';
  WorkspacesField = 'workspaces';
  CoreVersionField = 'coreVersion';
  DirtyField = 'dirty';
  ClassField = 'class';
  KindField = 'kind';
  NameField = 'name';
  TypeField = 'type';
  UnitField = 'unit';
  ComponentField = 'component';
  // Event property a handler is wired to. Shares the wire name with the
  // envelope's event field, and TWireMessage reads cmd before event, so a
  // request carrying this field is still classified as a request.
  EventPropertyField = 'event';
  MethodField = 'method';
  MethodsField = 'methods';
  // Set on a request the editor is to serve without raising its UI; sent on
  // a replayed handler request.
  QuietField = 'quiet';
  // Whether the handler was created, and whether it could be removed. Both
  // are answer details, not refusals: False is still a successful answer.
  CreatedField = 'created';
  RemovedField = 'removed';
  ReasonField = 'reason';
  SignatureField = 'signature';
  ParamsField = 'params';
  ModifierField = 'modifier';
  // Rename names, and whether the target is the document root, meaning the
  // form variable rather than a field of the form class.
  OldNameField = 'oldName';
  NewNameField = 'newName';
  RootField = 'root';
  // Old and new name of one handler, paired inside the methods array.
  PairOldField = 'old';
  PairNewField = 'new';
  // Rename answer details, neither of them a refusal. An absent
  // primaryRenamed counts as True, which is what an older editor sends.
  PrimaryRenamedField = 'primaryRenamed';
  SkippedMethodsField = 'skippedMethods';
  // Class name a root rename gave the form; the saved form file is patched
  // with it. Absent or empty means the class name is unchanged.
  NewClassNameField = 'newClassName';

  // AllowSetForegroundWindow wildcard; the RTL declares the function but not
  // this constant. The grant goes to any process: the process id behind the
  // pipe is not known before the answer arrives.
  ASFW_ANY = Cardinal(-1);

  // Maximum outbound lines queued for one session. A Post beyond it marks the
  // session broken rather than letting the queue grow without bound.
  OutboundLimit = 256;

type
  // What the core did with a handed-over file.
  TOpenOutcome = (ooOpened, ooFocused, ooRefused);

  // Opens a file handed over by a later start. Called on the main thread;
  // AReason is sent to the caller when the result is ooRefused.
  TOpenRequest = function(const AFileName: string;
    out AReason: string): TOpenOutcome of object;

  // Result of RouteToCore.
  TRouteOutcome = (
    roOpened,        // the core opened the file
    roFocused,       // the core focused an already open document
    roRefused,       // a core answered and refused; do not start a second one
    roUnreachable);  // no core answered; this process starts its own

  // Reports one non-fatal problem on a connection, on the main thread: a
  // connection that ended badly, or a line the designer ignored. AReason is
  // passed as an argument because connection threads complain concurrently.
  TCoreComplaint = procedure(Sender: TObject; const AReason: string) of object;

  // Classification of one wire line.
  TWireKind = (wkUnreadable, wkRequest, wkAnswer, wkEvent);

  // One parsed wire line, read in that order: a cmd field makes it a request,
  // else an event field makes it an event, else an ok field makes it an
  // answer. A JSON object with none of the three counts as a request.
  TWireMessage = class
  private
    FRoot: TJSONObject;
    FKind: TWireKind;
    FName: string;
    FId: Integer;
    FHasId: Boolean;
    FVersion: Integer;
    function ValueOf(const AField: string): TJSONValue;
  public
    constructor Create(const ALine: string);
    destructor Destroy; override;
    // Field accessors; a missing field yields False, '', 0 or nil. TextOf
    // renders a present field of any type as text, so IsText gates it; it
    // excludes JSON numbers, which pass a plain string test.
    function Has(const AField: string): Boolean;
    function IsText(const AField: string): Boolean;
    function TextOf(const AField: string): string;
    function NumberOf(const AField: string): Integer;
    function FlagOf(const AField: string): Boolean;
    function ListOf(const AField: string): TArray<string>;
    // Envelope form of the line; wkUnreadable when it was not a JSON object.
    property Kind: TWireKind read FKind;
    // Command or event name; empty for the other kinds.
    property Name: string read FName;
    // Correlation id the answer repeats; 0 unless HasId.
    property Id: Integer read FId;
    // True when the line carried a numeric id field.
    property HasId: Boolean read FHasId;
    // Protocol version the peer wrote; 0 when the line carried none.
    property Version: Integer read FVersion;
  end;

  // JSON value kind of a field; wfStructure holds JSON text that is parsed
  // and embedded as a nested value.
  TWireFieldKind = (wfText, wfNumber, wfFlag, wfStructure);

  // One field of an outgoing line, built by the Wire* functions below so that
  // callers do not assemble JSON objects themselves.
  TWireField = record
    Name: string;
    Kind: TWireFieldKind;
    Text: string;
    Number: Int64;
    Flag: Boolean;
  end;

  // The extra fields of one outgoing line, in the order they are written.
  TWireFields = TArray<TWireField>;

  // The only route to a session's peer, and the only part of a connection the
  // rest of the program holds. Reference counted so that a holder outliving
  // the connection posts into a closed outbox instead of freed memory.
  ISessionOutbox = interface
    ['{6C3E9D41-4B7A-4E52-9F0C-1D2A8B5E7A63}']
    // Queues one line. False when the outbox is closed, and reaching
    // OutboundLimit closes it. Callable from any thread.
    function Post(const ALine: string): Boolean;
    // False once the outbox is closed.
    function IsOpen: Boolean;
    // Dequeues the oldest queued line, FIFO. Called by the connection thread
    // only, and only while its writer is drained, so unsent output stays in
    // the queue and counts against OutboundLimit.
    function Take(out ALine: string): Boolean;
    // Closes the outbox; every later Post returns False.
    procedure Close;
  end;

  // Client identity read from the attach line. Every field is optional on the
  // wire and stays 0, empty or nil when the client omitted it.
  TAttachDetails = record
    Protocol: Integer;  // the client's own version; recorded, not negotiated
    ClientPid: Integer;
    Client: string;
    ClientVersion: string;
    Workspaces: TArray<string>;
  end;

  // Registers an attaching connection on the main thread and returns its
  // session id. A result of 0 refuses the attach and sends AReason.
  TAttachRequest = function(const ADetails: TAttachDetails;
    const AOutbox: ISessionOutbox; out AReason: string): Integer of object;

  // Serves one request of an established session, on the main thread. AFields
  // are added to the answer, the result becomes its ok flag, and AReason the
  // error text when that result is False.
  TSessionRequest = function(ASession: Integer; const ACommand: string;
    AMessage: TWireMessage; var AFields: TWireFields;
    out AReason: string): Boolean of object;

  // Delivers one answer to a request this core sent, on the main thread.
  TSessionAnswer = procedure(ASession: Integer; AMessage: TWireMessage) of object;

  // Called on the main thread once per registered session, from the single
  // exit that covers every way a session ends. A refused attach is not
  // reported here.
  TSessionEnded = procedure(ASession: Integer) of object;

  // Handler set passed to TCoreListener.ServeWith. Open serves the v0
  // handover only; the other four serve attached sessions.
  TCoreHandlers = record
    Open: TOpenRequest;
    Attach: TAttachRequest;
    Request: TSessionRequest;
    Answer: TSessionAnswer;
    Ended: TSessionEnded;
  end;

  TCoreListener = class;

  // Serves one accepted connection on its own thread: a handover from the
  // request to the answer, or the whole lifetime of a session. The thread per
  // connection keeps a slow open from stalling the connections behind it.
  TCoreConnection = class(TThread)
  private
    FListener: TCoreListener;
    FPipe: THandle;
    FRequestFile: string;
    FRequestSearchPath: string;
    FRequestHasSearchPath: Boolean;
    FRequestReason: string;
    FRequestOutcome: TOpenOutcome;
    function Stopping: Boolean;
    function AwaitReady(ADeadline: UInt64): Boolean;
    procedure CallOpen;
    procedure Serve;
  protected
    procedure Execute; override;
  public
    // Takes ownership of APipe, which this thread disconnects and closes on
    // every exit path.
    constructor Create(AListener: TCoreListener; APipe: THandle);
  end;

  // Accepts connections on the core pipe until it is stopped and hands each
  // one to a TCoreConnection; it serves no request itself. The accept thread
  // also frees finished connections.
  TCoreListener = class(TThread)
  private
    FPipeName: string;
    FHandlers: TCoreHandlers;
    FReady: Integer;
    FOnFailed: TNotifyEvent;
    FOnComplaint: TCoreComplaint;
    // Written by the accept thread only, hence unlocked; the main thread
    // reads it through Failure once OnFailed has been queued.
    FFailure: string;
    // Accept thread only, hence unlocked: it both adds and reaps entries.
    FServing: TList<TCoreConnection>;
    function OpenPipeInstance(out APipe: THandle): Boolean;
    procedure Track(AConnection: TCoreConnection);
    procedure Reap(AWaitForThem: Boolean);
    procedure ReportFailure;
    procedure Failed(const AReason: string);
  protected
    procedure Execute; override;
  public
    // Starts the accept thread at once; the pipe is opened there, before any
    // handler is set.
    constructor Create(const APipeName: string);
    destructor Destroy; override;
    // Publishes the handlers and makes the listener ready. A request that
    // arrives before this waits for a bounded time instead of being refused.
    procedure ServeWith(const AHandlers: TCoreHandlers);
    // True once ServeWith has run. Read from connection threads.
    function IsReady: Boolean;
    // Calls the Open handler for a file taken over from a later start.
    // Connection threads reach it through Synchronize, so this and the four
    // session methods below all run on the main thread.
    function Open(const AFileName: string; out AReason: string): TOpenOutcome;
    // Calls the Attach handler; 0 when the attach was refused or no handler
    // is set, with AReason holding the text sent to the client.
    function Attach(const ADetails: TAttachDetails; const AOutbox: ISessionOutbox;
      out AReason: string): Integer;
    // Calls the Request handler for one command of session ASession.
    function Request(ASession: Integer; const ACommand: string;
      AMessage: TWireMessage; var AFields: TWireFields;
      out AReason: string): Boolean;
    // Delivers one answer to a request this core sent; dropped when no
    // Answer handler is set.
    procedure Answered(ASession: Integer; AMessage: TWireMessage);
    // Reports the end of session ASession; a session id of 0 is dropped.
    procedure Ended(ASession: Integer);
    // Reports one non-fatal problem on a connection through OnComplaint;
    // serving continues. Callable from any thread.
    procedure Complain(const AReason: string);
    // Ends the accept wait and waits for the thread. False when it did not
    // finish in time; the caller must then leave the listener alive rather
    // than free a running thread. Main thread only: it pumps synchronized
    // calls while waiting, so a connection mid-answer still finishes.
    function Stop: Boolean;
    // Fired on the main thread when the listener stopped serving. The mutex
    // claim is unaffected and still held.
    property OnFailed: TNotifyEvent read FOnFailed write FOnFailed;
    // Fired on the main thread for a non-fatal problem on a connection;
    // serving continues.
    property OnComplaint: TCoreComplaint read FOnComplaint write FOnComplaint;
    // Why serving stopped; empty while serving.
    property Failure: string read FFailure;
  end;

// Takes the core claim, or reports that another process holds it. Repeated
// calls by the holder return True. The claim is held until ReleaseCore.
function ClaimCore: Boolean;

// Releases the core claim. Call it last at shutdown: once the name is free,
// the next start claims it and becomes the core.
procedure ReleaseCore;

// Name of the pipe this executable's core serves in this logon session.
function CorePipeName: string;

// Pipe name for a named executable and logon session. The derivation is part
// of the protocol contract: the VS Code extension computes the same name from
// the same two inputs.
function CorePipeNameFor(const AExecutable: string; ASession: Cardinal): string;

// Sends AFileName to the running core over the handover protocol. ADetail
// receives the refusal text or the reason the connection failed. ASearchPath,
// when not empty, is sent with the file and noted for that document by the
// core that performs the load.
function RouteToCore(const AFileName: string;
  out ADetail: string; const ASearchPath: string = ''): TRouteOutcome;

// Builders for the fields of an outgoing line.
function WireText(const AName, AValue: string): TWireField;
function WireNumber(const AName: string; AValue: Int64): TWireField;
function WireFlag(const AName: string; AValue: Boolean): TWireField;
// A field carrying nested JSON. AJson must parse as JSON; text that does not
// parse leaves the field out of the line.
function WireStructure(const AName, AJson: string): TWireField;

// Encoders for the three session envelope forms; each returns one wire line
// stamped with SessionProtocol.
function EncodeRequest(AId: Integer; const ACommand: string;
  const AFields: TWireFields): string;
// An AId of 0 or less is left out: the answer to a line that carried no id.
function EncodeAnswer(AId: Integer; AOk: Boolean; const AError: string;
  const AFields: TWireFields): string;
function EncodeEvent(const AEvent: string; const AFields: TWireFields): string;

// File version of this executable, reported in the attach answer. Read once
// and cached; '0.0.0.0' for a build without version info.
function CoreVersion: string;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.SyncObjs,
  System.Hash,
  Vallenta.FormEditor.Core.SearchPath;

type
  // Result of one line read.
  TReadOutcome = (rdLine, rdTimedOut, rdTooLong, rdBroken, rdStopping);

  // Ends a wait before its deadline. A method rather than the thread itself,
  // because TThread.Terminated is not visible from outside the thread.
  TAbortTest = function: Boolean of object;

  // Connection scope a command is served on. A handover ends with its single
  // answer, so a long-running command is csSession.
  TCommandScope = (csHandover, csSession, csBoth);

  // Validates a request before it reaches the core; AReason is the refusal
  // text used when the result is False.
  TCommandCheck = function(AMessage: TWireMessage; out AReason: string): Boolean;

  // One row of the command table.
  TCommandEntry = record
    Name: string;
    Scope: TCommandScope;
    Check: TCommandCheck;
  end;


const
  // Pipe name prefix before the session key; part of the protocol contract.
  PipePrefix = '\\.\pipe\VallentaDesigner.';
  // Timeouts and intervals, in milliseconds.
  ConnectTimeout = 2000;
  AnswerTimeout = 30000;
  RequestTimeout = 5000;
  // Reserved inside AnswerTimeout for writing the answer.
  AnswerMargin = 5000;
  // What is left of AnswerTimeout for the core to become ready, so that a
  // core still starting up refuses before the caller stops reading.
  ReadyTimeout = AnswerTimeout - RequestTimeout - AnswerMargin;
  StopTimeout = 5000;
  // Runs inside the StopTimeout wait, so it has to stay well under it.
  FarewellTimeout = 500;
  PollInterval = 10;
  // Bytes.
  PipeBuffer = 8192;
  // Bytes; a longer line is refused instead of buffered.
  LineLimit = 64 * 1024;
  // LF, the byte that separates wire lines.
  NewLine = 10;

type
  // Compile-time guard, never instantiated: the subrange fails to compile
  // once ReadyTimeout reaches zero, that is once RequestTimeout and
  // AnswerMargin together consume AnswerTimeout.
  TReadyBudget = 1 .. ReadyTimeout;

  // Lock-protected outbound queue of one session. Reaching OutboundLimit
  // closes it, so a peer that stopped reading ends the session rather than
  // letting the queue grow.
  TSessionOutbox = class(TInterfacedObject, ISessionOutbox)
  private
    FLock: TCriticalSection;
    FLines: TQueue<string>;
    FOpen: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function Post(const ALine: string): Boolean;
    function IsOpen: Boolean;
    function Take(out ALine: string): Boolean;
    procedure Close;
  end;

  // Inbound half of a session: reads bytes off the pipe and yields whole
  // lines. The buffer survives across polls, so a partial line is kept and
  // lines that arrived in one read are returned by the following polls
  // without reading again. Poll returns rdTimedOut, not an error, while no
  // whole line has arrived.
  TSessionReader = class
  private
    FPipe: THandle;
    FBuffer: TBytes;
    FScanned: Integer;
    FDropping: Boolean;
    function NextLine(out AText: string): TReadOutcome;
  public
    constructor Create(APipe: THandle);
    function Poll(out AText: string): TReadOutcome;
  end;

  // Outbound half of a session. The pipe is non-blocking, so whatever its
  // buffer cannot take is held here rather than parking the connection thread
  // in WriteFile; a partial write is not a failure, and Flush returns False
  // only for a broken pipe.
  TSessionWriter = class
  private
    FPipe: THandle;
    FPending: TBytes;
  public
    constructor Create(APipe: THandle);
    procedure Add(const ALine: string);
    function Flush: Boolean;
    function Drained: Boolean;
    function FlushBy(ADeadline: UInt64): Boolean;
  end;

  // Serves one attached connection until the client goes, on that
  // connection's own thread, alternating between polling the pipe for a line
  // and draining the outbound queue. That single thread is the only writer of
  // the pipe handle, so answers and events leave in queue order.
  TSessionServer = class
  private
    FListener: TCoreListener;
    FPipe: THandle;
    FStopping: TAbortTest;
    FSession: Integer;
    FOutbox: ISessionOutbox;
    FReader: TSessionReader;
    FWriter: TSessionWriter;
    FUnknownEvents: TStringList;
    FAttach: TAttachDetails;
    FAttachReason: string;
    FInbound: TWireMessage;
    FAnswerFields: TWireFields;
    FAnswerReason: string;
    FAnswerOk: Boolean;
    procedure Synchronize(AMethod: TThreadMethod);
    procedure CallAttach;
    procedure CallRequest;
    procedure CallAnswer;
    procedure CallEnded;
    function AwaitReady: Boolean;
    procedure Refuse(AId: Integer; const AReason: string);
    function ServeRequest(AMessage: TWireMessage): Boolean;
    function HandleInbound(const ALine: string): Boolean;
    procedure NoteUnknownEvent(const AEvent: string);
    procedure Loop;
  public
    constructor Create(AListener: TCoreListener; APipe: THandle;
      const AStopping: TAbortTest);
    destructor Destroy; override;
    procedure Run(AAttach: TWireMessage);
  end;

var
  CoreMutex: THandle = 0;
  // Computed on first use and never invalidated; executable path, logon
  // session and file version are fixed for the lifetime of the process, so
  // two threads computing concurrently produce the same value.
  KnownKey: string = '';
  KnownVersion: string = '';

function SessionKeyFor(const AExecutable: string; ASession: Cardinal): string;
begin
  Result := Copy(THashSHA2.GetHashString(
    LowerCase(ExpandFileName(AExecutable)) + '|' + IntToStr(ASession)), 1, 16);
end;

function SessionKey: string;
var
  Session: DWORD;
begin
  if KnownKey <> '' then
    Exit(KnownKey);
  Session := 0;
  ProcessIdToSessionId(GetCurrentProcessId, Session);
  KnownKey := SessionKeyFor(ParamStr(0), Session);
  Result := KnownKey;
end;

function CoreMutexName: string;
begin
  Result := 'Local\VallentaDesigner.' + SessionKey;
end;

function CorePipeName: string;
begin
  Result := PipePrefix + SessionKey;
end;

function CorePipeNameFor(const AExecutable: string; ASession: Cardinal): string;
begin
  Result := PipePrefix + SessionKeyFor(AExecutable, ASession);
end;

function ClaimCore: Boolean;
begin
  if CoreMutex <> 0 then
    Exit(True);
  CoreMutex := CreateMutex(nil, True, PChar(CoreMutexName));
  Result := (CoreMutex <> 0) and (GetLastError <> ERROR_ALREADY_EXISTS);
  if not Result and (CoreMutex <> 0) then
  begin
    // The handle refers to the other process's mutex; keeping it open would
    // hold the name alive after that process exits.
    CloseHandle(CoreMutex);
    CoreMutex := 0;
  end;
end;

procedure ReleaseCore;
begin
  if CoreMutex = 0 then
    Exit;
  ReleaseMutex(CoreMutex);
  CloseHandle(CoreMutex);
  CoreMutex := 0;
end;

// AAwaitRead calls FlushFileBuffers, which blocks without a deadline until
// the peer reads. Only the serving end may pass True, because it disconnects
// straight after and that would discard the unread answer.
function WriteLine(APipe: THandle; const AText: string;
  AAwaitRead: Boolean): Boolean;
var
  Bytes: TBytes;
  Written: DWORD;
begin
  Bytes := TEncoding.UTF8.GetBytes(AText + Char(NewLine));
  Result := WriteFile(APipe, Bytes[0], Length(Bytes), Written, nil) and
    (Integer(Written) = Length(Bytes));
  if Result and AAwaitRead then
    FlushFileBuffers(APipe);
end;

// AAbort ends the wait before ATimeout expires; without it a shutdown would
// have to wait out every open connection. The calling end passes nil.
function ReadLine(APipe: THandle; ATimeout: Cardinal; const AAbort: TAbortTest;
  out AText: string): TReadOutcome;
var
  Deadline: UInt64;
  Waiting, Read: DWORD;
  Chunk, Bytes: TBytes;
  Scanned, Split, I: Integer;
  TooLong: Boolean;
begin
  AText := '';
  Bytes := nil;
  Scanned := 0;
  TooLong := False;
  Deadline := GetTickCount64 + ATimeout;
  while GetTickCount64 <= Deadline do
  begin
    if Assigned(AAbort) and AAbort then
      Exit(rdStopping);
    if not PeekNamedPipe(APipe, nil, 0, nil, @Waiting, nil) then
      Exit(rdBroken);
    if Waiting = 0 then
    begin
      Sleep(PollInterval);
      Continue;
    end;
    SetLength(Chunk, Waiting);
    if not ReadFile(APipe, Chunk[0], Waiting, Read, nil) or (Read = 0) then
      Exit(rdBroken);
    SetLength(Chunk, Read);
    if TooLong then
    begin
      // Past the limit the bytes are still drained: a caller that is still
      // writing cannot read the refusal, so stopping here deadlocks both ends.
      for I := 0 to High(Chunk) do
        if Chunk[I] = NewLine then
          Exit(rdTooLong);
      Continue;
    end;
    Bytes := Bytes + Chunk;
    Split := Scanned;
    while (Split < Length(Bytes)) and (Bytes[Split] <> NewLine) do
      Inc(Split);
    if Split < Length(Bytes) then
    begin
      // Bytes already read past the line end are dropped, so a peer must not
      // pipeline anything behind the first line of a connection.
      SetLength(Bytes, Split);
      AText := TEncoding.UTF8.GetString(Bytes);
      Exit(rdLine);
    end;
    Scanned := Split;
    if Length(Bytes) > LineLimit then
    begin
      TooLong := True;
      Bytes := nil;
      Scanned := 0;
    end;
  end;
  if TooLong then
    Result := rdTooLong
  else
    Result := rdTimedOut;
end;

// Retried rather than waited on: WaitNamedPipe fails at once while the core
// has not created its first instance, and another caller can take the
// instance between the wait and CreateFile.
function ConnectToCore: THandle;
var
  Deadline: UInt64;
begin
  Result := INVALID_HANDLE_VALUE;
  Deadline := GetTickCount64 + ConnectTimeout;
  repeat
    if WaitNamedPipe(PChar(CorePipeName), PollInterval) then
      Result := CreateFile(PChar(CorePipeName), GENERIC_READ or GENERIC_WRITE,
        0, nil, OPEN_EXISTING, 0, 0);
    if Result = INVALID_HANDLE_VALUE then
      // Sleep on every failure, including another caller taking the instance
      // between the two calls above; without it this loop spins.
      Sleep(PollInterval);
  until (Result <> INVALID_HANDLE_VALUE) or (GetTickCount64 > Deadline);
end;

function RouteToCore(const AFileName: string;
  out ADetail: string; const ASearchPath: string): TRouteOutcome;
var
  Pipe: THandle;
  Answer: string;
  Request: TJSONObject;
  Parsed, Value: TJSONValue;
begin
  Result := roUnreachable;
  ADetail := '';
  Pipe := ConnectToCore;
  if Pipe = INVALID_HANDLE_VALUE then
  begin
    ADetail := 'no process answered the pipe';
    Exit;
  end;
  try
    // The grant has to precede the request: the core raises its window while
    // serving it, not after the answer arrives here.
    AllowSetForegroundWindow(ASFW_ANY);
    Request := TJSONObject.Create;
    try
      Request.AddPair(VersionField, TJSONNumber.Create(ProtocolVersion));
      Request.AddPair(CommandField, OpenCommand);
      Request.AddPair(FileField, AFileName);
      if ASearchPath <> '' then
        Request.AddPair(SearchPathField, ASearchPath);
      if not WriteLine(Pipe, Request.ToJSON, False) then
      begin
        ADetail := 'the core stopped listening during the handover';
        Exit;
      end;
    finally
      Request.Free;
    end;
    if ReadLine(Pipe, AnswerTimeout, nil, Answer) <> rdLine then
    begin
      ADetail := 'the core sent no answer';
      Exit;
    end;
    Parsed := TJSONObject.ParseJSONValue(Answer);
    try
      if not (Parsed is TJSONObject) then
      begin
        ADetail := 'the core''s answer could not be parsed';
        Exit;
      end;
      Value := TJSONObject(Parsed).GetValue(OkField);
      if not ((Value is TJSONBool) and TJSONBool(Value).AsBoolean) then
      begin
        Result := roRefused;
        Value := TJSONObject(Parsed).GetValue(ErrorField);
        if Value <> nil then
          ADetail := Value.Value
        else
          ADetail := 'the core refused without giving a reason';
        Exit;
      end;
      Value := TJSONObject(Parsed).GetValue(FocusedField);
      if (Value is TJSONBool) and TJSONBool(Value).AsBoolean then
        Result := roFocused
      else
        Result := roOpened;
    finally
      Parsed.Free;
    end;
  finally
    CloseHandle(Pipe);
  end;
end;

// Discards what already arrived behind the request, without ever waiting for
// more. Skipping it lets a caller that keeps writing deadlock against this
// end writing the answer.
procedure DropTrailing(APipe: THandle);
var
  Waiting, Read: DWORD;
  Discard: TBytes;
begin
  SetLength(Discard, PipeBuffer);
  while PeekNamedPipe(APipe, nil, 0, nil, @Waiting, nil) and (Waiting > 0) do
  begin
    if Waiting > DWORD(Length(Discard)) then
      Waiting := Length(Discard);
    if not ReadFile(APipe, Discard[0], Waiting, Read, nil) or (Read = 0) then
      Exit;
  end;
end;

{ the envelope }

function WireText(const AName, AValue: string): TWireField;
begin
  Result := Default(TWireField);
  Result.Name := AName;
  Result.Kind := wfText;
  Result.Text := AValue;
end;

function WireNumber(const AName: string; AValue: Int64): TWireField;
begin
  Result := Default(TWireField);
  Result.Name := AName;
  Result.Kind := wfNumber;
  Result.Number := AValue;
end;

function WireFlag(const AName: string; AValue: Boolean): TWireField;
begin
  Result := Default(TWireField);
  Result.Name := AName;
  Result.Kind := wfFlag;
  Result.Flag := AValue;
end;

function WireStructure(const AName, AJson: string): TWireField;
begin
  Result := Default(TWireField);
  Result.Name := AName;
  Result.Kind := wfStructure;
  Result.Text := AJson;
end;

procedure AddFields(ALine: TJSONObject; const AFields: TWireFields);
var
  Field: TWireField;
begin
  for Field in AFields do
    case Field.Kind of
      wfText: ALine.AddPair(Field.Name, Field.Text);
      wfNumber: ALine.AddPair(Field.Name, TJSONNumber.Create(Field.Number));
      wfFlag: ALine.AddPair(Field.Name, TJSONBool.Create(Field.Flag));
      wfStructure: ALine.AddPair(Field.Name,
        TJSONObject.ParseJSONValue(Field.Text));
    end;
end;

function EncodeRequest(AId: Integer; const ACommand: string;
  const AFields: TWireFields): string;
var
  Line: TJSONObject;
begin
  Line := TJSONObject.Create;
  try
    Line.AddPair(VersionField, TJSONNumber.Create(SessionProtocol));
    Line.AddPair(IdField, TJSONNumber.Create(AId));
    Line.AddPair(CommandField, ACommand);
    AddFields(Line, AFields);
    Result := Line.ToJSON;
  finally
    Line.Free;
  end;
end;

function EncodeAnswer(AId: Integer; AOk: Boolean; const AError: string;
  const AFields: TWireFields): string;
var
  Line: TJSONObject;
begin
  Line := TJSONObject.Create;
  try
    Line.AddPair(VersionField, TJSONNumber.Create(SessionProtocol));
    if AId > 0 then
      Line.AddPair(IdField, TJSONNumber.Create(AId));
    Line.AddPair(OkField, TJSONBool.Create(AOk));
    if not AOk then
      Line.AddPair(ErrorField, AError);
    AddFields(Line, AFields);
    Result := Line.ToJSON;
  finally
    Line.Free;
  end;
end;

function EncodeEvent(const AEvent: string; const AFields: TWireFields): string;
var
  Line: TJSONObject;
begin
  Line := TJSONObject.Create;
  try
    Line.AddPair(VersionField, TJSONNumber.Create(SessionProtocol));
    Line.AddPair(EventField, AEvent);
    AddFields(Line, AFields);
    Result := Line.ToJSON;
  finally
    Line.Free;
  end;
end;

function CoreVersion: string;
var
  Size, Ignored: DWORD;
  Block: TBytes;
  Fixed: Pointer;
  Taken: UINT;
  Info: PVSFixedFileInfo;
begin
  if KnownVersion <> '' then
    Exit(KnownVersion);
  Result := '0.0.0.0';
  Ignored := 0;
  Size := GetFileVersionInfoSize(PChar(ParamStr(0)), Ignored);
  if Size > 0 then
  begin
    SetLength(Block, Size);
    if GetFileVersionInfo(PChar(ParamStr(0)), Ignored, Size, Pointer(Block)) and
       VerQueryValue(Pointer(Block), '\', Fixed, Taken) and (Taken > 0) then
    begin
      Info := PVSFixedFileInfo(Fixed);
      Result := Format('%d.%d.%d.%d',
        [HiWord(Info.dwFileVersionMS), LoWord(Info.dwFileVersionMS),
         HiWord(Info.dwFileVersionLS), LoWord(Info.dwFileVersionLS)]);
    end;
  end;
  KnownVersion := Result;
end;

{ TWireMessage }

constructor TWireMessage.Create(const ALine: string);
var
  Parsed, Value: TJSONValue;
begin
  inherited Create;
  FKind := wkUnreadable;
  Parsed := TJSONObject.ParseJSONValue(ALine);
  if not (Parsed is TJSONObject) then
  begin
    Parsed.Free;
    Exit;
  end;
  FRoot := TJSONObject(Parsed);
  FVersion := NumberOf(VersionField);
  Value := FRoot.GetValue(IdField);
  FHasId := Value is TJSONNumber;
  if FHasId then
    FId := TJSONNumber(Value).AsInt;
  Value := FRoot.GetValue(CommandField);
  if Value is TJSONString then
  begin
    FKind := wkRequest;
    FName := Value.Value;
    Exit;
  end;
  Value := FRoot.GetValue(EventField);
  if Value is TJSONString then
  begin
    FKind := wkEvent;
    FName := Value.Value;
    Exit;
  end;
  if FRoot.GetValue(OkField) <> nil then
    FKind := wkAnswer
  else
    FKind := wkRequest;
end;

destructor TWireMessage.Destroy;
begin
  FRoot.Free;
  inherited Destroy;
end;

function TWireMessage.ValueOf(const AField: string): TJSONValue;
begin
  Result := nil;
  if FRoot <> nil then
    Result := FRoot.GetValue(AField);
end;

function TWireMessage.Has(const AField: string): Boolean;
begin
  Result := ValueOf(AField) <> nil;
end;

function TWireMessage.IsText(const AField: string): Boolean;
var
  Value: TJSONValue;
begin
  Value := ValueOf(AField);
  Result := (Value is TJSONString) and not (Value is TJSONNumber);
end;

function TWireMessage.TextOf(const AField: string): string;
var
  Value: TJSONValue;
begin
  Result := '';
  Value := ValueOf(AField);
  if Value <> nil then
    Result := Value.Value;
end;

function TWireMessage.NumberOf(const AField: string): Integer;
var
  Value: TJSONValue;
begin
  Result := 0;
  Value := ValueOf(AField);
  if Value is TJSONNumber then
    Result := TJSONNumber(Value).AsInt;
end;

function TWireMessage.FlagOf(const AField: string): Boolean;
var
  Value: TJSONValue;
begin
  Value := ValueOf(AField);
  Result := (Value is TJSONBool) and TJSONBool(Value).AsBoolean;
end;

function TWireMessage.ListOf(const AField: string): TArray<string>;
var
  Value: TJSONValue;
  Items: TJSONArray;
  I: Integer;
begin
  Result := nil;
  Value := ValueOf(AField);
  if not (Value is TJSONArray) then
    Exit;
  Items := TJSONArray(Value);
  SetLength(Result, Items.Count);
  for I := 0 to Items.Count - 1 do
    Result[I] := Items.Items[I].Value;
end;

{ TSessionOutbox }

constructor TSessionOutbox.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FLines := TQueue<string>.Create;
  FOpen := True;
end;

destructor TSessionOutbox.Destroy;
begin
  FLines.Free;
  FLock.Free;
  inherited Destroy;
end;

function TSessionOutbox.Post(const ALine: string): Boolean;
begin
  FLock.Enter;
  try
    Result := FOpen and (FLines.Count < OutboundLimit);
    if Result then
      FLines.Enqueue(ALine)
    else
      FOpen := False;
  finally
    FLock.Leave;
  end;
end;

function TSessionOutbox.IsOpen: Boolean;
begin
  FLock.Enter;
  try
    Result := FOpen;
  finally
    FLock.Leave;
  end;
end;

function TSessionOutbox.Take(out ALine: string): Boolean;
begin
  ALine := '';
  FLock.Enter;
  try
    Result := FLines.Count > 0;
    if Result then
      ALine := FLines.Dequeue;
  finally
    FLock.Leave;
  end;
end;

procedure TSessionOutbox.Close;
begin
  FLock.Enter;
  try
    FOpen := False;
  finally
    FLock.Leave;
  end;
end;

{ TSessionReader }

constructor TSessionReader.Create(APipe: THandle);
begin
  inherited Create;
  FPipe := APipe;
end;

// LineLimit applies per line, not to the buffer: pipelined short messages may
// exceed it together, a single long line may not.
function TSessionReader.NextLine(out AText: string): TReadOutcome;
var
  Split: Integer;
begin
  AText := '';
  Split := FScanned;
  while (Split < Length(FBuffer)) and (FBuffer[Split] <> NewLine) do
    Inc(Split);
  if Split >= Length(FBuffer) then
  begin
    FScanned := Split;
    if Split <= LineLimit then
      Exit(rdTimedOut);
    // Over the limit with no line end yet: draining has to continue, or a
    // peer that is still writing never gets to read its refusal.
    FDropping := True;
    FBuffer := nil;
    FScanned := 0;
    Exit(rdTimedOut);
  end;
  if Split > LineLimit then
  begin
    Delete(FBuffer, 0, Split + 1);
    FScanned := 0;
    Exit(rdTooLong);
  end;
  AText := TEncoding.UTF8.GetString(Copy(FBuffer, 0, Split));
  Delete(FBuffer, 0, Split + 1);
  FScanned := 0;
  Result := rdLine;
end;

function TSessionReader.Poll(out AText: string): TReadOutcome;
var
  Waiting, Read: DWORD;
  Chunk: TBytes;
  I: Integer;
begin
  Result := NextLine(AText);
  if Result <> rdTimedOut then
    Exit;
  if not PeekNamedPipe(FPipe, nil, 0, nil, @Waiting, nil) then
    Exit(rdBroken);
  if Waiting = 0 then
    Exit(rdTimedOut);
  SetLength(Chunk, Waiting);
  if not ReadFile(FPipe, Chunk[0], Waiting, Read, nil) or (Read = 0) then
    Exit(rdBroken);
  SetLength(Chunk, Read);
  if FDropping then
  begin
    for I := 0 to High(Chunk) do
      if Chunk[I] = NewLine then
      begin
        FDropping := False;
        Exit(rdTooLong);
      end;
    Exit(rdTimedOut);
  end;
  FBuffer := FBuffer + Chunk;
  Result := NextLine(AText);
end;

{ TSessionWriter }

constructor TSessionWriter.Create(APipe: THandle);
begin
  inherited Create;
  FPipe := APipe;
end;

procedure TSessionWriter.Add(const ALine: string);
begin
  FPending := FPending + TEncoding.UTF8.GetBytes(ALine + Char(NewLine));
end;

function TSessionWriter.Drained: Boolean;
begin
  Result := Length(FPending) = 0;
end;

function TSessionWriter.Flush: Boolean;
var
  Written: DWORD;
begin
  Result := True;
  while Length(FPending) > 0 do
  begin
    Written := 0;
    if not WriteFile(FPipe, FPending[0], Length(FPending), Written, nil) then
      // A broken pipe is reported by the reader instead; a full non-blocking
      // pipe surfaces below as a zero-byte write, not as a failure here.
      Exit(GetLastError = ERROR_NO_DATA);
    if Written = 0 then
      Exit;
    if Integer(Written) >= Length(FPending) then
      FPending := nil
    else
      Delete(FPending, 0, Integer(Written));
  end;
end;

function TSessionWriter.FlushBy(ADeadline: UInt64): Boolean;
begin
  repeat
    Result := Flush;
    if not Result or Drained then
      Break;
    Sleep(PollInterval);
  until GetTickCount64 > ADeadline;
  // FlushFileBuffers waits until the peer has read the data; the disconnect
  // that follows discards whatever it has not read.
  if Result and Drained then
    FlushFileBuffers(FPipe);
end;

{ the commands }

// The refusal wordings below are frozen wire; the test suite matches on them
// literally.
function NeedsFile(AMessage: TWireMessage; out AReason: string): Boolean;
begin
  Result := False;
  AReason := '';
  if not AMessage.Has(FileField) then
    AReason := 'the request named no file'
  else if not AMessage.IsText(FileField) then
    AReason := 'the file has to be given as text'
  else if AMessage.TextOf(FileField) = '' then
    AReason := 'the file name is empty'
  else
    Result := True;
end;

// Commands accepted from a peer, with the scope each is served on. A name
// outside the table, or one out of scope, is answered as an unknown command.
const
  Commands: array [0 .. 3] of TCommandEntry = (
    (Name: OpenCommand; Scope: csBoth; Check: NeedsFile),
    (Name: FocusCommand; Scope: csSession; Check: NeedsFile),
    (Name: CloseCommand; Scope: csSession; Check: NeedsFile),
    (Name: ReloadCommand; Scope: csSession; Check: NeedsFile));

function FindCommand(const AName: string; ASession: Boolean;
  out AEntry: TCommandEntry): Boolean;
var
  Entry: TCommandEntry;
begin
  for Entry in Commands do
    if SameText(Entry.Name, AName) and
       ((Entry.Scope = csBoth) or ((Entry.Scope = csSession) = ASession)) then
    begin
      AEntry := Entry;
      Exit(True);
    end;
  AEntry := Default(TCommandEntry);
  Result := False;
end;

{ TSessionServer }

constructor TSessionServer.Create(AListener: TCoreListener; APipe: THandle;
  const AStopping: TAbortTest);
begin
  inherited Create;
  FListener := AListener;
  FPipe := APipe;
  FStopping := AStopping;
  FOutbox := TSessionOutbox.Create;
  FReader := TSessionReader.Create(APipe);
  FWriter := TSessionWriter.Create(APipe);
  FUnknownEvents := TStringList.Create;
end;

destructor TSessionServer.Destroy;
begin
  FReader.Free;
  FWriter.Free;
  FUnknownEvents.Free;
  inherited Destroy;
end;

function TSessionServer.AwaitReady: Boolean;
var
  Deadline: UInt64;
begin
  Deadline := GetTickCount64 + ReadyTimeout;
  repeat
    Result := FListener.IsReady;
    if Result or FStopping then
      Exit;
    Sleep(PollInterval);
  until GetTickCount64 > Deadline;
  Result := False;
end;

procedure TSessionServer.Synchronize(AMethod: TThreadMethod);
begin
  TThread.Synchronize(nil, AMethod);
end;

procedure TSessionServer.CallAttach;
begin
  FSession := FListener.Attach(FAttach, FOutbox, FAttachReason);
end;

procedure TSessionServer.CallRequest;
begin
  // The path has to be noted before the handler runs, because the load reads
  // it from there. An open without the field leaves the noted path standing.
  if SameText(FInbound.Name, OpenCommand) and
     FInbound.Has(SearchPathField) then
    NoteSearchPathFor(FInbound.TextOf(FileField),
      SplitSearchPath(FInbound.TextOf(SearchPathField)));
  FAnswerOk := FListener.Request(FSession, FInbound.Name, FInbound,
    FAnswerFields, FAnswerReason);
end;

procedure TSessionServer.CallAnswer;
begin
  FListener.Answered(FSession, FInbound);
end;

procedure TSessionServer.CallEnded;
begin
  FListener.Ended(FSession);
end;

// Writes past the outbox, because Refuse runs where no loop is left to drain
// the queue.
procedure TSessionServer.Refuse(AId: Integer; const AReason: string);
begin
  FWriter.Add(EncodeAnswer(AId, False, AReason, nil));
  FWriter.FlushBy(GetTickCount64 + FarewellTimeout);
end;

procedure TSessionServer.Run(AAttach: TWireMessage);
var
  Mode: DWORD;
begin
  FAttach.Protocol := AAttach.Version;
  FAttach.ClientPid := AAttach.NumberOf(ProcessField);
  FAttach.Client := AAttach.TextOf(ClientField);
  FAttach.ClientVersion := AAttach.TextOf(ClientVersionField);
  FAttach.Workspaces := AAttach.ListOf(WorkspacesField);
  try
    if not AwaitReady then
    begin
      if FStopping then
        Refuse(AAttach.Id, 'the designer is closing')
      else
        Refuse(AAttach.Id, 'the designer is still starting up');
      Exit;
    end;
    Synchronize(CallAttach);
    if FSession = 0 then
    begin
      Refuse(AAttach.Id, FAttachReason);
      Exit;
    end;
    // Switched to non-blocking only once this is a session: a peer that stops
    // reading then fills the pipe instead of parking this thread in a write.
    Mode := PIPE_READMODE_BYTE or PIPE_NOWAIT;
    SetNamedPipeHandleState(FPipe, Mode, nil, nil);
    FWriter.Add(EncodeAnswer(AAttach.Id, True, '',
      [WireNumber(ProtocolField, SessionProtocol),
       WireNumber(ProcessField, GetCurrentProcessId),
       WireText(CoreVersionField, CoreVersion)]));
    Loop;
  finally
    // Synchronized rather than queued: a queued call can outlive the
    // listener. A refused attach passes here too and reports session id 0.
    FOutbox.Close;
    Synchronize(CallEnded);
  end;
end;

procedure TSessionServer.Loop;
var
  Line, Outgoing: string;
  Busy, Dropped: Boolean;
begin
  Dropped := False;
  while not (FStopping or Dropped) and FOutbox.IsOpen do
  begin
    Busy := False;
    case FReader.Poll(Line) of
      rdLine:
        begin
          Busy := True;
          Dropped := not HandleInbound(Line);
        end;
      rdTooLong:
        begin
          FWriter.Add(EncodeAnswer(0, False,
            'the request is longer than any of ours', nil));
          Dropped := True;
        end;
      rdBroken: Exit;
    end;
    // Taken only while the writer is drained, so that unsent output stays in
    // the queue, where it counts against OutboundLimit.
    if FWriter.Drained and FOutbox.Take(Outgoing) then
    begin
      FWriter.Add(Outgoing);
      Busy := True;
    end;
    if not FWriter.Flush then
      Exit;
    if not (Busy or Dropped) then
      Sleep(PollInterval);
  end;
  // The closing events distinguish a clean end from a crash for the peer, so
  // they are flushed unless the session was dropped for not reading.
  if not FOutbox.IsOpen then
    Exit;
  while FOutbox.Take(Outgoing) do
    FWriter.Add(Outgoing);
  FWriter.FlushBy(GetTickCount64 + FarewellTimeout);
end;

function TSessionServer.HandleInbound(const ALine: string): Boolean;
var
  Message: TWireMessage;
begin
  Result := True;
  Message := TWireMessage.Create(ALine);
  try
    case Message.Kind of
      wkRequest: Result := ServeRequest(Message);
      wkAnswer:
        begin
          // Synchronized rather than queued: a queued call can outlive both
          // the listener and this message.
          FInbound := Message;
          Synchronize(CallAnswer);
        end;
      wkEvent: NoteUnknownEvent(Message.Name);
      wkUnreadable:
        begin
          FWriter.Add(EncodeAnswer(0, False,
            'the request could not be understood', nil));
          Result := False;
        end;
    end;
  finally
    FInbound := nil;
    Message.Free;
  end;
end;

// Every request is answered and the session survives an unknown command,
// which indicates a newer client rather than a broken one.
function TSessionServer.ServeRequest(AMessage: TWireMessage): Boolean;
var
  Entry: TCommandEntry;
  Reason: string;
begin
  FAnswerFields := nil;
  FAnswerOk := False;
  FAnswerReason := '';
  if not FindCommand(AMessage.Name, True, Entry) then
    FAnswerReason := Format('unknown command "%s"', [AMessage.Name])
  else if not Entry.Check(AMessage, Reason) then
    FAnswerReason := Reason
  else
  begin
    FInbound := AMessage;
    Synchronize(CallRequest);
  end;
  if not FAnswerOk and (FAnswerReason = '') then
    FAnswerReason := 'the designer did not say why';
  // Posted through the outbox so the answer cannot overtake an event that was
  // queued before it.
  Result := FOutbox.Post(EncodeAnswer(AMessage.Id, FAnswerOk, FAnswerReason,
    FAnswerFields));
end;

procedure TSessionServer.NoteUnknownEvent(const AEvent: string);
begin
  if FUnknownEvents.IndexOf(AEvent) >= 0 then
    Exit;
  FUnknownEvents.Add(AEvent);
  FListener.Complain(Format('a session sent an event this designer does not ' +
    'know, and it was ignored: "%s"', [AEvent]));
end;

{ TCoreConnection }

constructor TCoreConnection.Create(AListener: TCoreListener; APipe: THandle);
begin
  FListener := AListener;
  FPipe := APipe;
  inherited Create(False);
end;

procedure TCoreConnection.Execute;
begin
  NameThreadForDebugging('Vallenta Designer handover');
  try
    try
      Serve;
    finally
      DisconnectNamedPipe(FPipe);
      CloseHandle(FPipe);
      FPipe := INVALID_HANDLE_VALUE;
    end;
  except
    on E: Exception do
      FListener.Complain(Format('a handover ended badly: %s: %s',
        [E.ClassName, E.Message]));
  end;
end;

function TCoreConnection.Stopping: Boolean;
begin
  Result := Terminated;
end;

function TCoreConnection.AwaitReady(ADeadline: UInt64): Boolean;
begin
  repeat
    Result := FListener.IsReady;
    if Result or Terminated then
      Exit;
    Sleep(PollInterval);
  until GetTickCount64 > ADeadline;
  Result := False;
end;

procedure TCoreConnection.CallOpen;
begin
  // The path has to be noted before the handler runs, because the load reads
  // it from there rather than from an argument.
  if FRequestHasSearchPath then
    NoteSearchPathFor(FRequestFile, SplitSearchPath(FRequestSearchPath));
  FRequestOutcome := FListener.Open(FRequestFile, FRequestReason);
end;

procedure TCoreConnection.Serve;
var
  Line, Failure: string;
  Message: TWireMessage;
  Session: TSessionServer;
  Entry: TCommandEntry;
  Outcome: TOpenOutcome;
  Answer: TJSONObject;
begin
  Outcome := ooRefused;
  Failure := '';
  try
    case ReadLine(FPipe, RequestTimeout, Stopping, Line) of
      rdTimedOut: Failure := 'nothing arrived to read';
      rdTooLong: Failure := 'the request is longer than any of ours';
      rdBroken: Failure := 'the caller went away mid-request';
      rdStopping: Failure := 'the designer is closing';
      rdLine:
      begin
        Message := TWireMessage.Create(Line);
        try
          if (Message.Kind = wkRequest) and
             SameText(Message.Name, AttachCommand) then
          begin
            // The session takes the pipe over from here: no DropTrailing and
            // no handover answer, both of which would corrupt its stream.
            Session := TSessionServer.Create(FListener, FPipe, Stopping);
            try
              try
                Session.Run(Message);
              except
                // Contained here: falling through would write a handover
                // answer into a connection speaking the session protocol.
                on E: Exception do
                  FListener.Complain(Format('a session ended badly: %s: %s',
                    [E.ClassName, E.Message]));
              end;
            finally
              Session.Free;
            end;
            Exit;
          end;
          DropTrailing(FPipe);
          Failure := 'the request could not be understood';
          if Message.Kind = wkRequest then
          begin
            if not FindCommand(Message.Name, False, Entry) then
              Failure := Format('unknown command "%s"', [Message.Name])
            else if Entry.Check(Message, Failure) then
            begin
              if not AwaitReady(GetTickCount64 + ReadyTimeout) then
              begin
                if Terminated then
                  Failure := 'the designer is closing'
                else
                  Failure := 'the designer is still starting up';
              end
              else
              begin
                FRequestFile := Message.TextOf(FileField);
                FRequestHasSearchPath := Message.Has(SearchPathField);
                FRequestSearchPath := Message.TextOf(SearchPathField);
                FRequestReason := '';
                FRequestOutcome := ooRefused;
                Synchronize(CallOpen);
                Outcome := FRequestOutcome;
                if Outcome = ooRefused then
                  Failure := FRequestReason;
              end;
            end;
          end;
        finally
          Message.Free;
        end;
      end;
    end;
  except
    // The handover answers on every path, including this one.
    on E: Exception do
    begin
      Outcome := ooRefused;
      Failure := Format('%s: %s', [E.ClassName, E.Message]);
    end;
  end;
  if (Outcome = ooRefused) and (Failure = '') then
    Failure := 'the core did not open it';
  Answer := TJSONObject.Create;
  try
    Answer.AddPair(VersionField, TJSONNumber.Create(ProtocolVersion));
    Answer.AddPair(OkField, TJSONBool.Create(Outcome <> ooRefused));
    Answer.AddPair(FocusedField, TJSONBool.Create(Outcome = ooFocused));
    Answer.AddPair(ProcessField, TJSONNumber.Create(GetCurrentProcessId));
    if Outcome = ooRefused then
      Answer.AddPair(ErrorField, Failure);
    WriteLine(FPipe, Answer.ToJSON, True);
  finally
    Answer.Free;
  end;
end;

{ TCoreListener }

constructor TCoreListener.Create(const APipeName: string);
begin
  FPipeName := APipeName;
  FServing := TList<TCoreConnection>.Create;
  inherited Create(False);
end;

destructor TCoreListener.Destroy;
begin
  inherited Destroy;
  // The inherited destructor waited for the thread, which empties the list.
  // Freeing before that races the accept thread.
  FServing.Free;
end;

procedure TCoreListener.ServeWith(const AHandlers: TCoreHandlers);
begin
  FHandlers := AHandlers;
  // Interlocked so that a connection thread reading the flag also sees the
  // handler assignment above it.
  TInterlocked.Exchange(FReady, 1);
end;

function TCoreListener.IsReady: Boolean;
begin
  Result := TInterlocked.CompareExchange(FReady, 0, 0) = 1;
end;

function TCoreListener.Open(const AFileName: string;
  out AReason: string): TOpenOutcome;
begin
  Result := FHandlers.Open(AFileName, AReason);
end;

function TCoreListener.Attach(const ADetails: TAttachDetails;
  const AOutbox: ISessionOutbox; out AReason: string): Integer;
begin
  if not Assigned(FHandlers.Attach) then
  begin
    AReason := 'this designer does not hold sessions';
    Exit(0);
  end;
  Result := FHandlers.Attach(ADetails, AOutbox, AReason);
end;

function TCoreListener.Request(ASession: Integer; const ACommand: string;
  AMessage: TWireMessage; var AFields: TWireFields;
  out AReason: string): Boolean;
begin
  Result := FHandlers.Request(ASession, ACommand, AMessage, AFields, AReason);
end;

procedure TCoreListener.Answered(ASession: Integer; AMessage: TWireMessage);
begin
  if Assigned(FHandlers.Answer) then
    FHandlers.Answer(ASession, AMessage);
end;

procedure TCoreListener.Ended(ASession: Integer);
begin
  if (ASession <> 0) and Assigned(FHandlers.Ended) then
    FHandlers.Ended(ASession);
end;

function TCoreListener.OpenPipeInstance(out APipe: THandle): Boolean;
begin
  APipe := CreateNamedPipe(PChar(FPipeName), PIPE_ACCESS_DUPLEX,
    PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT,
    PIPE_UNLIMITED_INSTANCES, PipeBuffer, PipeBuffer, 0, nil);
  Result := APipe <> INVALID_HANDLE_VALUE;
  if not Result then
    Failed(Format('the handover pipe could not be opened: %s',
      [SysErrorMessage(GetLastError)]));
end;

procedure TCoreListener.Failed(const AReason: string);
begin
  FFailure := AReason;
  Queue(ReportFailure);
end;

procedure TCoreListener.ReportFailure;
begin
  if Assigned(FOnFailed) then
    FOnFailed(Self);
end;

// AReason is captured by the closure, so concurrent complaints cannot
// overwrite one another. Queued against this thread, so that entries still
// pending are removed when the listener is freed first.
procedure TCoreListener.Complain(const AReason: string);
begin
  Queue(
    procedure
    begin
      if Assigned(FOnComplaint) then
        FOnComplaint(Self, AReason);
    end);
end;

procedure TCoreListener.Track(AConnection: TCoreConnection);
begin
  FServing.Add(AConnection);
end;

// With AWaitForThem every connection is terminated before any of them is
// waited for, so their deadlines run in parallel rather than in sequence.
procedure TCoreListener.Reap(AWaitForThem: Boolean);
var
  Connection: TCoreConnection;
  I: Integer;
begin
  if AWaitForThem then
    for I := 0 to FServing.Count - 1 do
      FServing[I].Terminate;
  for I := FServing.Count - 1 downto 0 do
  begin
    Connection := FServing[I];
    if not (AWaitForThem or Connection.Finished) then
      Continue;
    // A connection waiting mid-answer on the main thread still finishes,
    // because Stop keeps pumping synchronized calls.
    Connection.WaitFor;
    Connection.Free;
    FServing.Delete(I);
  end;
end;

procedure TCoreListener.Execute;
var
  Pipe, Next: THandle;
  Connected: Boolean;
begin
  NameThreadForDebugging('Vallenta Designer core listener');
  Pipe := INVALID_HANDLE_VALUE;
  Next := INVALID_HANDLE_VALUE;
  try
    try
      if not OpenPipeInstance(Pipe) then
        Exit;
      while not Terminated do
      begin
        Connected := ConnectNamedPipe(Pipe, nil) or
          (GetLastError = ERROR_PIPE_CONNECTED);
        // The next instance is opened before this one is handed on, so the
        // pipe name never ceases to exist; a start falling into that gap
        // would find no core and become one.
        if not OpenPipeInstance(Next) then
          Next := INVALID_HANDLE_VALUE;
        // Not while terminating: that connection is Stop's own wake-up call.
        if Connected and not Terminated then
          Track(TCoreConnection.Create(Self, Pipe))
        else
        begin
          if Connected then
            DisconnectNamedPipe(Pipe);
          CloseHandle(Pipe);
        end;
        Pipe := Next;
        Next := INVALID_HANDLE_VALUE;
        if Pipe = INVALID_HANDLE_VALUE then
          Exit;
        Reap(False);
      end;
    except
      on E: Exception do
        Failed(Format('%s: %s', [E.ClassName, E.Message]));
    end;
  finally
    if Pipe <> INVALID_HANDLE_VALUE then
      CloseHandle(Pipe);
    if Next <> INVALID_HANDLE_VALUE then
      CloseHandle(Next);
    // Reaped last and with waiting: connections still hold pipe instances and
    // may be mid-answer.
    Reap(True);
  end;
end;

function TCoreListener.Stop: Boolean;
var
  Deadline: UInt64;
  Waking: THandle;
begin
  Terminate;
  Deadline := GetTickCount64 + StopTimeout;
  repeat
    // Nothing but a connection ends ConnectNamedPipe, so one is opened and
    // discarded. Repeated, because the thread may be between two instances.
    Waking := CreateFile(PChar(FPipeName), GENERIC_READ or GENERIC_WRITE, 0,
      nil, OPEN_EXISTING, 0, 0);
    if Waking <> INVALID_HANDLE_VALUE then
      CloseHandle(Waking);
    // Synchronized calls are pumped while waiting: a connection may be inside
    // a request that this thread has to answer.
    CheckSynchronize(PollInterval);
    Result := Finished;
  until Result or (GetTickCount64 > Deadline);
  if Result then
    WaitFor;
end;

end.
