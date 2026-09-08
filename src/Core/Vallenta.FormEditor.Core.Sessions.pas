// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Core.Sessions;

// Holds the attached client sessions, the session that opened each document,
// and the requests this core sent that still await an answer; also the rule
// deciding when an unused core ends itself. Main thread only: connection
// threads reach it through TThread.Synchronize, and ISessionOutbox.Post is
// the only call permitted from another thread.

interface

uses
  System.Classes,
  System.Generics.Collections,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Core.SingleInstance;

const
  // Default timeout of SendRequest, in milliseconds.
  RequestLifetime = 10000;

  // Grace periods before an unused core ends itself, in milliseconds.
  AbandonedGrace = 60 * 1000;
  UnusedServeGrace = 5 * 60 * 1000;

type
  // Outcome of a request sent by this core. AOk is False unless the answer
  // carries the ok flag; AError is then non-empty. AAnswer is nil when no
  // answer arrived: timeout, lost connection, or registry teardown.
  TAnswerCallback = procedure(AOk: Boolean; const AError: string;
    AAnswer: TWireMessage) of object;

  // One attached client session; created and freed by TSessionRegistry.
  TDesignSession = class
  private
    FId: Integer;
    FOrder: Integer;
    FProtocol: Integer;
    FClientPid: Integer;
    FClient: string;
    FClientVersion: string;
    FWorkspaces: TArray<string>;
    FOutbox: ISessionOutbox;
  public
    constructor Create(AId, AOrder: Integer; const ADetails: TAttachDetails;
      const AOutbox: ISessionOutbox);
    // Length of the longest workspace folder that is a case-insensitive
    // prefix of AFile, trailing separator included, or 0 when no workspace
    // contains AFile. Sessions are ranked against each other by this length.
    function Reaches(const AFile: string): Integer;
    // Registry-assigned id, never reused after the session detaches.
    property Id: Integer read FId;
    // Attach sequence number, counted from 1; RouteFor breaks ties by the
    // higher value.
    property Order: Integer read FOrder;
    // Session protocol version the client reported; not read by the core.
    property Protocol: Integer read FProtocol;
    // Client process id from the attach line.
    property ClientPid: Integer read FClientPid;
    // Client product name from the attach line.
    property Client: string read FClient;
    // Client product version from the attach line.
    property ClientVersion: string read FClientVersion;
    // Workspace root folders from the attach line; matched by Reaches.
    property Workspaces: TArray<string> read FWorkspaces;
    // Outbound queue of the connection; Post may be called from any thread.
    property Outbox: ISessionOutbox read FOutbox;
  end;

  // A request sent by this core that still awaits an answer.
  TPendingRequest = record
    Id: Integer;       // request id, matched against the answer's id
    Session: Integer;  // id of the session the request went to
    Command: string;   // command name; used in the refusal message
    Deadline: UInt64;  // GetTickCount64 value in milliseconds
    Callback: TAnswerCallback;  // invoked exactly once, on any outcome
  end;

  // Registry of the attached sessions, the opener of each document, and the
  // requests awaiting an answer. Creates and frees its TDesignSession
  // instances.
  TSessionRegistry = class
  private
    FSessions: TObjectList<TDesignSession>;
    // Lowercased document path -> session id of its opener. Entries outlive
    // the session; RouteFor checks the opener is still attached.
    FOpeners: TDictionary<string, Integer>;
    FPending: TList<TPendingRequest>;
    FLog: TDesignLog;
    FNextSession: Integer;
    FNextRequest: Integer;
    FAttaches: Integer;
    procedure OnlyMainThread;
    procedure Note(ASeverity: TLogSeverity; const AText: string);
    procedure Resolve(const APending: TPendingRequest; const AError: string;
      AAnswer: TWireMessage);
    function Take(AId, ASession: Integer; out APending: TPendingRequest): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    // Registers an attached connection. The result is freed by Detach, so
    // callers must keep its Id rather than the instance.
    function Attach(const ADetails: TAttachDetails;
      const AOutbox: ISessionOutbox): TDesignSession;
    // Frees the session and refuses its pending requests through their
    // callbacks. An id that is not attached is ignored.
    procedure Detach(AId: Integer);
    // The session with AId, or nil.
    function Find(AId: Integer): TDesignSession;
    // Number of attached sessions.
    function Count: Integer;
    // True once any client has attached; never reset.
    function EverAttached: Boolean;
    // Records ASession as the opener of AFile, read only by RouteFor. AFile
    // is keyed case-insensitively and not expanded; callers must pass the
    // absolute path RouteFor is later given.
    procedure NoteOpener(const AFile: string; ASession: Integer);
    // Drops the opener entry of AFile.
    procedure ForgetDocument(const AFile: string);
    // The session AFile's events route to: its opener while still attached,
    // otherwise the session with the longest Reaches match, ties going to the
    // later attach. Nil when no session matches.
    function RouteFor(const AFile: string): TDesignSession;
    // Sends AEvent to the one session RouteFor selects, with AFile added as
    // the file field; events are never broadcast. False when no session
    // routes AFile or the outbox refused the line.
    function EmitEvent(const AFile, AEvent: string;
      const AFields: TWireFields): Boolean;
    // Sends a request to ASession, ATimeout in milliseconds. ACallback is
    // invoked exactly once: on answer, timeout, detach, or registry
    // destruction. False when the line could not be posted, ACallback having
    // already run.
    function SendRequest(ASession: TDesignSession; const ACommand: string;
      const AFields: TWireFields; const ACallback: TAnswerCallback;
      ATimeout: Cardinal = RequestLifetime): Boolean;
    // Passes an answer to the callback of the matching request. An id that is
    // not pending for ASession, such as one already timed out, is logged as a
    // warning and dropped.
    procedure Answered(ASession: Integer; AMessage: TWireMessage);
    // Refuses every request past its deadline; call periodically.
    procedure Beat;
    // Number of unanswered requests.
    function Pending: Integer;
    // Optional log target; the only entry written is the warning in Answered.
    property Log: TDesignLog read FLog write FLog;
  end;

  // Why a self-end grace period is running.
  TOrphanClause = (
    ocNone,          // no grace period applies
    ocAbandoned,     // a session was attached earlier: AbandonedGrace
    ocUnusedServe);  // a --serve start that never had one: UnusedServeGrace

  // Core state sampled for one EvaluateOrphan call. Now is supplied by the
  // caller so tests can advance time.
  TOrphanInputs = record
    HadSession: Boolean;  // True once any session has attached
    Sessions: Integer;    // number of attached sessions
    Windows: Integer;     // number of open designer windows
    ServeStart: Boolean;  // the process was started with --serve
    Now: UInt64;          // GetTickCount64 value in milliseconds
  end;

  // Grace-period state the caller stores between EvaluateOrphan calls.
  // Deadline is a GetTickCount64 value in milliseconds.
  TOrphanWatch = record
    Clause: TOrphanClause;
    Deadline: UInt64;
  end;

  // The step EvaluateOrphan asks the caller to take.
  TOrphanAction = (
    oaStand,   // no grace period expired
    oaArm,     // a grace period started; Watch holds its deadline
    oaDisarm,  // the grace period no longer applies; Watch is cleared
    oaEnd);    // end the process; Watch stays armed, so the verdict repeats

  // EvaluateOrphan's result. Watch is the state to store whatever the action.
  TOrphanVerdict = record
    Action: TOrphanAction;
    Watch: TOrphanWatch;
  end;

// Decides whether an idle core ends itself. With neither sessions nor
// windows, a core that ever had a session waits AbandonedGrace and a --serve
// start that never had one waits UnusedServeGrace; any other core stands. A
// session or window disarms the watch, and a change of clause restarts the
// grace period from AInputs.Now.
function EvaluateOrphan(const AInputs: TOrphanInputs;
  const AWatch: TOrphanWatch): TOrphanVerdict;

implementation

uses
  Winapi.Windows,
  System.SysUtils;

function EvaluateOrphan(const AInputs: TOrphanInputs;
  const AWatch: TOrphanWatch): TOrphanVerdict;
const
  Grace: array [TOrphanClause] of Cardinal =
    (0, AbandonedGrace, UnusedServeGrace);
var
  Clause: TOrphanClause;

  function ClauseNow: TOrphanClause;
  begin
    if (AInputs.Sessions > 0) or (AInputs.Windows > 0) then
      Exit(ocNone);
    if AInputs.HadSession then
      Exit(ocAbandoned);
    if AInputs.ServeStart then
      Exit(ocUnusedServe);
    Result := ocNone;
  end;

begin
  Result.Watch := AWatch;
  Clause := ClauseNow;
  if Clause = ocNone then
  begin
    if AWatch.Clause = ocNone then
      Result.Action := oaStand
    else
    begin
      Result.Action := oaDisarm;
      Result.Watch := Default(TOrphanWatch);
    end;
    Exit;
  end;
  if AWatch.Clause <> Clause then
  begin
    Result.Action := oaArm;
    Result.Watch.Clause := Clause;
    Result.Watch.Deadline := AInputs.Now + Grace[Clause];
    Exit;
  end;
  if AInputs.Now >= AWatch.Deadline then
    Result.Action := oaEnd
  else
    Result.Action := oaStand;
end;

{ TDesignSession }

constructor TDesignSession.Create(AId, AOrder: Integer;
  const ADetails: TAttachDetails; const AOutbox: ISessionOutbox);
begin
  inherited Create;
  FId := AId;
  FOrder := AOrder;
  FProtocol := ADetails.Protocol;
  FClientPid := ADetails.ClientPid;
  FClient := ADetails.Client;
  FClientVersion := ADetails.ClientVersion;
  FWorkspaces := ADetails.Workspaces;
  FOutbox := AOutbox;
end;

function TDesignSession.Reaches(const AFile: string): Integer;
var
  Workspace, Folder: string;
begin
  Result := 0;
  for Workspace in FWorkspaces do
  begin
    if Workspace = '' then
      Continue;
    // The trailing separator must be part of the comparison; without it
    // C:\Work matches C:\Workshop\Unit1.dfm.
    Folder := IncludeTrailingPathDelimiter(Workspace);
    if (Length(Folder) > Result) and
       (Length(AFile) > Length(Folder)) and
       SameText(Copy(AFile, 1, Length(Folder)), Folder) then
      Result := Length(Folder);
  end;
end;

{ TSessionRegistry }

constructor TSessionRegistry.Create;
begin
  inherited Create;
  FSessions := TObjectList<TDesignSession>.Create(True);
  FOpeners := TDictionary<string, Integer>.Create;
  FPending := TList<TPendingRequest>.Create;
end;

destructor TSessionRegistry.Destroy;
var
  Entry: TPendingRequest;
  Left: TArray<TPendingRequest>;
begin
  // The list is emptied before any callback runs; a callback may enter the
  // registry again and must not find an entry being resolved.
  Left := FPending.ToArray;
  FPending.Clear;
  FSessions.Clear;
  for Entry in Left do
    Resolve(Entry, 'the designer is closing', nil);
  FPending.Free;
  FOpeners.Free;
  FSessions.Free;
  inherited Destroy;
end;

procedure TSessionRegistry.OnlyMainThread;
begin
  Assert(GetCurrentThreadId = MainThreadID,
    'the session registry is the main thread''s');
end;

procedure TSessionRegistry.Note(ASeverity: TLogSeverity; const AText: string);
begin
  if FLog <> nil then
    FLog.Add(ASeverity, AText);
end;

function TSessionRegistry.Attach(const ADetails: TAttachDetails;
  const AOutbox: ISessionOutbox): TDesignSession;
begin
  OnlyMainThread;
  Inc(FNextSession);
  Inc(FAttaches);
  Result := TDesignSession.Create(FNextSession, FAttaches, ADetails, AOutbox);
  FSessions.Add(Result);
end;

procedure TSessionRegistry.Detach(AId: Integer);
var
  Session: TDesignSession;
  Lost: TArray<TPendingRequest>;
  Entry: TPendingRequest;
  I, Taken: Integer;
begin
  OnlyMainThread;
  // The session and its requests are removed before any callback runs; a
  // callback may address this session again and must find it gone already.
  Session := Find(AId);
  if Session <> nil then
    FSessions.Remove(Session);
  SetLength(Lost, FPending.Count);
  Taken := 0;
  for I := FPending.Count - 1 downto 0 do
    if FPending[I].Session = AId then
    begin
      Lost[Taken] := FPending[I];
      Inc(Taken);
      FPending.Delete(I);
    end;
  SetLength(Lost, Taken);
  for Entry in Lost do
    Resolve(Entry, 'connection lost', nil);
end;

function TSessionRegistry.Find(AId: Integer): TDesignSession;
var
  Session: TDesignSession;
begin
  for Session in FSessions do
    if Session.Id = AId then
      Exit(Session);
  Result := nil;
end;

function TSessionRegistry.Count: Integer;
begin
  Result := FSessions.Count;
end;

function TSessionRegistry.EverAttached: Boolean;
begin
  Result := FAttaches > 0;
end;

procedure TSessionRegistry.NoteOpener(const AFile: string; ASession: Integer);
begin
  OnlyMainThread;
  FOpeners.AddOrSetValue(LowerCase(AFile), ASession);
end;

procedure TSessionRegistry.ForgetDocument(const AFile: string);
begin
  OnlyMainThread;
  FOpeners.Remove(LowerCase(AFile));
end;

function TSessionRegistry.RouteFor(const AFile: string): TDesignSession;
var
  Opener, Reach, Longest: Integer;
  Session, Best: TDesignSession;
begin
  if FOpeners.TryGetValue(LowerCase(AFile), Opener) then
  begin
    Result := Find(Opener);
    if Result <> nil then
      Exit;
  end;
  Best := nil;
  Longest := 0;
  for Session in FSessions do
  begin
    Reach := Session.Reaches(AFile);
    if Reach = 0 then
      Continue;
    if (Best = nil) or (Reach > Longest) or
       ((Reach = Longest) and (Session.Order > Best.Order)) then
    begin
      Longest := Reach;
      Best := Session;
    end;
  end;
  Result := Best;
end;

function TSessionRegistry.EmitEvent(const AFile, AEvent: string;
  const AFields: TWireFields): Boolean;
var
  Session: TDesignSession;
  Fields: TWireFields;
  I: Integer;
begin
  OnlyMainThread;
  Session := RouteFor(AFile);
  if Session = nil then
    Exit(False);
  SetLength(Fields, Length(AFields) + 1);
  Fields[0] := WireText(FileField, AFile);
  for I := 0 to High(AFields) do
    Fields[I + 1] := AFields[I];
  Result := Session.Outbox.Post(EncodeEvent(AEvent, Fields));
end;

function TSessionRegistry.SendRequest(ASession: TDesignSession;
  const ACommand: string; const AFields: TWireFields;
  const ACallback: TAnswerCallback; ATimeout: Cardinal): Boolean;
var
  Entry: TPendingRequest;
begin
  OnlyMainThread;
  Inc(FNextRequest);
  Entry := Default(TPendingRequest);
  Entry.Id := FNextRequest;
  Entry.Session := ASession.Id;
  Entry.Command := ACommand;
  Entry.Deadline := GetTickCount64 + ATimeout;
  Entry.Callback := ACallback;
  Result := ASession.Outbox.Post(EncodeRequest(Entry.Id, ACommand, AFields));
  if Result then
    FPending.Add(Entry)
  else
    Resolve(Entry, 'connection lost', nil);
end;

procedure TSessionRegistry.Answered(ASession: Integer; AMessage: TWireMessage);
var
  Entry: TPendingRequest;
begin
  OnlyMainThread;
  if not Take(AMessage.Id, ASession, Entry) then
  begin
    Note(lsWarn, Format('a session answered request %d, which is not one this ' +
      'designer is waiting for', [AMessage.Id]));
    Exit;
  end;
  Resolve(Entry, AMessage.TextOf(ErrorField), AMessage);
end;

procedure TSessionRegistry.Beat;
var
  Now: UInt64;
  Late: TArray<TPendingRequest>;
  Entry: TPendingRequest;
  I, Taken: Integer;
begin
  OnlyMainThread;
  if FPending.Count = 0 then
    Exit;
  Now := GetTickCount64;
  SetLength(Late, FPending.Count);
  Taken := 0;
  // Expired entries leave the list before any callback runs; a callback may
  // add new requests to FPending.
  for I := FPending.Count - 1 downto 0 do
    if Now > FPending[I].Deadline then
    begin
      Late[Taken] := FPending[I];
      Inc(Taken);
      FPending.Delete(I);
    end;
  SetLength(Late, Taken);
  for Entry in Late do
    Resolve(Entry, 'the editor did not answer', nil);
end;

function TSessionRegistry.Pending: Integer;
begin
  Result := FPending.Count;
end;

function TSessionRegistry.Take(AId, ASession: Integer;
  out APending: TPendingRequest): Boolean;
var
  I: Integer;
begin
  APending := Default(TPendingRequest);
  for I := 0 to FPending.Count - 1 do
    if (FPending[I].Id = AId) and (FPending[I].Session = ASession) then
    begin
      APending := FPending[I];
      FPending.Delete(I);
      Exit(True);
    end;
  Result := False;
end;

procedure TSessionRegistry.Resolve(const APending: TPendingRequest;
  const AError: string; AAnswer: TWireMessage);
var
  Ok: Boolean;
  Reason: string;
begin
  Ok := (AAnswer <> nil) and AAnswer.FlagOf(OkField);
  Reason := AError;
  if not Ok and (Reason = '') then
    Reason := Format('%s was refused without a reason', [APending.Command]);
  if Assigned(APending.Callback) then
    APending.Callback(Ok, Reason, AAnswer);
end;

end.
