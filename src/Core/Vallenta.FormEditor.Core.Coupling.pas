// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Core.Coupling;

// Sends the unit-side requests for one document - add or remove a field,
// ensure or remove a handler, rename - and applies the answers. The unit is
// never edited here; every change is a request the editor grants or refuses.
// Main thread only: requests go out through the session registry, and its
// answers arrive as marshalled calls.
//
// A pending request holds an interface reference to the coupling, which
// therefore outlives the window that created it. Close stops further requests
// and suppresses the callbacks and log writes of late answers; a late field
// answer still moves the ledger. The ledger moves on the answer, so an
// unconfirmed change is sent again at the next settle point.

interface

uses
  System.Classes,
  System.TypInfo,
  System.Generics.Collections,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Core.SingleInstance,
  Vallenta.FormEditor.Core.Sessions,
  Vallenta.FormEditor.Core.FieldLedger;

type
  // One event parameter. UnitName is the unit declaring TypeName, empty when
  // the RTTI name is unqualified.
  TEventParam = record
    Name: string;
    TypeName: string;
    UnitName: string;
    // 'const', 'var', 'out', or empty for by-value.
    Modifier: string;
  end;

  // Parameter list of one event type.
  TEventSignature = record
    Params: TArray<TEventParam>;
  end;

  // A handler the editor was asked to add for one history step. Carries the
  // signature so a redo or a resume replay can send the request again.
  TCreatedHandler = record
    Component: string;
    Event: string;
    Method: string;
    Signature: TEventSignature;
  end;

  // Fired when the editor reports a newly created handler. AStep is the
  // history step the request carried, returned unchanged.
  THandlerCreated = procedure(AStep: Integer;
    const AHandler: TCreatedHandler) of object;

  // Returns every handler the applied history had the editor create; these
  // are replayed at every Resume after the first.
  THandlerRoster = function: TArray<TCreatedHandler> of object;

  // One handler renamed with its component. OldName is the event map's
  // spelling; NewName is the default handler name built from the new one.
  TMethodRename = record
    OldName: string;
    NewName: string;
  end;

  TRenameKind = (
    rkComponent,  // renames the form field and its references
    rkRoot,       // renames the unit's own form variable
    rkHandler);   // renames only the method pairs

  // Result of a rename request. Reason is empty on success. PrimaryRenamed
  // False and SkippedMethods are informational, not refusals: a unit may
  // declare no field, variable or method to move and the rename still holds.
  TRenameAnswer = record
    Token: Integer;
    Ok: Boolean;
    Reason: string;
    PrimaryRenamed: Boolean;
    SkippedMethods: TArray<string>;
    // Class name the editor renamed with the root; empty when it renamed no
    // class.
    NewClassName: string;
  end;

  // Answer to a rename request. Token identifies it; several renames can be
  // in flight at once.
  TRenameAnswered = procedure(const AAnswer: TRenameAnswer) of object;

  // Returns the handler name a wired method pointer stands for, or empty for
  // a method the event map did not hand out.
  TWiredNameQuery = function(const AMethod: TMethod): string of object;

  // Applies an answered rename to the document. False when the rename could
  // not be applied here - no designer, a missing target, or a name now taken;
  // the recorded history step is then dropped.
  TRenameApply = function(AKind: TRenameKind; const AOldName, ANewName: string;
    const AMethods: TArray<TMethodRename>;
    const ANewClassName: string): Boolean of object;

  // Removes a recorded history entry whose step did not happen.
  TStepDrop = procedure(AStep: Integer) of object;

  // Rename entry point for the object inspector's Name row. Not reference
  // counted: the inspector clears the reference when the designer detaches.
  IComponentRename = interface
    ['{A81C6F3D-27B4-4E59-9C10-6D4F2A7E5B38}']
    // Validates and sends a rename of AComponent. Returns empty when the
    // request went out, otherwise the refusal text for the row.
    function BeginRename(AComponent: TComponent; const ANewName: string): string;
    // Whether a rename of AComponent is still awaiting its answer.
    function RenameInFlight(AComponent: TComponent): Boolean;
  end;

  // Returns the newest history step number; 0 when the history is empty.
  TStepQuery = function: Integer of object;

  // Answer to a compatible-methods request; an empty list is a valid answer.
  // ARequest is the caller's request id, returned unchanged, so a late answer
  // is never applied to a different event's drop-down.
  TMethodListCallback = procedure(ARequest: Integer;
    const AMethods: TArray<string>) of object;

  // Returns whether a session currently reaches the document's unit.
  TCodeCouplingQuery = function: Boolean of object;

  // Requests against the unit behind one document. Availability is read per
  // request; the answering session may have detached since the last one.
  ICodeCoupling = interface
    ['{5E2B9C74-1A63-4D08-9F45-3C7A16E8B902}']
    // Whether a session currently reaches this document.
    function Available: Boolean;
    // Requests the form class methods this event can be wired to. AWhen runs
    // later on the main thread with ARequest echoed back, and not at all when
    // no session is attached.
    procedure ListMethods(ARequest: Integer; const ASignature: TEventSignature;
      const AWhen: TMethodListCallback);
    // Requests the method declaration and body of a handler the caller has
    // already wired on the form side.
    procedure EnsureHandler(const AComponent, AEvent, AMethod: string;
      const ASignature: TEventSignature);
    // Requests removal of a handler whose creating step was undone. The
    // editor removes it only while still empty and unreferenced, and the
    // outcome is only logged. No foreground grant: an undo must not raise
    // the editor window.
    procedure RemoveHandler(const AMethod: string);
    // Requests that the editor show AMethod, raising its window.
    procedure GotoHandler(const AMethod: string);
    // Requests renaming the component's field, its references and its
    // pattern-named handlers; rkHandler sends an empty primary name and moves
    // only the method pairs. Returns empty when the request was sent,
    // otherwise the refusal text, and then no answer follows.
    function RenameComponent(AToken: Integer; AKind: TRenameKind;
      const AOldName, ANewName: string;
      const AMethods: TArray<TMethodRename>): string;
    // Moves the ledger key after a completed rename, so the next diff does
    // not report a remove plus an add.
    procedure NoteRenamed(const AOldName, ANewName: string);
  end;

  TSettleOutcome = (
    soNothing,    // nothing to send, or the ledger has no baseline yet
    soSent,       // the changes went out to the session
    soUncoupled); // changes exist but no session is attached

  // Kind of a pending request; selects what its answer does. rqPlain reports
  // a refusal and nothing else.
  TRequestKind = (rqPlain, rqField, rqMethods, rqEnsure, rqRemove, rqRename);

  // Completion data for one request; each kind uses only its own fields.
  TAnswerDuty = record
    Kind: TRequestKind;
    Change: TFieldChange;
    Handler: TCreatedHandler;
    Step: Integer;
    Token: Integer;
    Methods: TMethodListCallback;
  end;

  // Sends the unit-side requests for one document and applies the answers.
  // Each pending request holds a reference, so the object outlives its window.
  TDocumentCoupling = class(TInterfacedObject, ICodeCoupling)
  private
    FSessions: TSessionRegistry;
    FLedger: TFieldLedger;
    FFileName: string;
    FRootClass: string;
    FLog: TDesignLog;
    FClosed: Boolean;
    FOnCurrentStep: TStepQuery;
    FOnHandlerCreated: THandlerCreated;
    FOnHandlerRoster: THandlerRoster;
    FOnRenamed: TRenameAnswered;
    function Session: TDesignSession;
    procedure AskEnsure(const AHandler: TCreatedHandler; AReplay: Boolean);
    function AskRename(AToken: Integer; const AWhat: string;
      const AFields: TWireFields): string;
    procedure RenameAnswered(AToken: Integer; AOk: Boolean;
      const AReason: string; AAnswer: TWireMessage);
    procedure Ask(const ACommand, AWhat: string; const AFields: TWireFields;
      const ADuty: TAnswerDuty);
    procedure Send(const AChange: TFieldChange);
    function About(const AFields: TWireFields): TWireFields;
    function CurrentStep: Integer;
    procedure HandlerCreated(AStep: Integer; const AHandler: TCreatedHandler);
    procedure Refused(const AWhat, AReason: string);
    procedure Kept(ASeverity: TLogSeverity; const AMethod, AReason: string);
    procedure GrantForeground;
  public
    constructor Create(ASessions: TSessionRegistry);
    destructor Destroy; override;
    // Marks the document closed: no further request is sent, and a late
    // answer fires no callback and writes no log.
    procedure Close;
    // Sends every change since the last acknowledgement, one request per
    // change, in diff order. soNothing until the first Resume has seeded the
    // ledger baseline.
    function Settle(const AFields: TArray<TFieldEntry>): TSettleOutcome;
    // Called when a session becomes available. The first call seeds the
    // ledger baseline and sends nothing; a later one settles the diff, sends
    // every add since the baseline again, and replays the handler roster.
    procedure Resume(const AFields: TArray<TFieldEntry>);
    { ICodeCoupling }
    function Available: Boolean;
    procedure ListMethods(ARequest: Integer; const ASignature: TEventSignature;
      const AWhen: TMethodListCallback);
    procedure EnsureHandler(const AComponent, AEvent, AMethod: string;
      const ASignature: TEventSignature);
    procedure RemoveHandler(const AMethod: string);
    procedure GotoHandler(const AMethod: string);
    function RenameComponent(AToken: Integer; AKind: TRenameKind;
      const AOldName, ANewName: string;
      const AMethods: TArray<TMethodRename>): string;
    procedure NoteRenamed(const AOldName, ANewName: string);
    // The document's acknowledged field set.
    property Ledger: TFieldLedger read FLedger;
    // Full path of the form file; requests route by it, and none are sent
    // while it is empty.
    property FileName: string read FFileName write FFileName;
    // Name of the form class; sent with every request so the editor declares
    // fields and handlers in the right class.
    property RootClass: string read FRootClass write FRootClass;
    // Log target; nil after Close.
    property Log: TDesignLog read FLog write FLog;
    // Supplies the history step a handler request belongs to, read at send
    // time. Unset yields step 0, which suppresses OnHandlerCreated.
    property OnCurrentStep: TStepQuery read FOnCurrentStep write FOnCurrentStep;
    // Fired when the editor reports it created the handler, never for one
    // that already existed; the marked step lets an undo remove the method.
    property OnHandlerCreated: THandlerCreated read FOnHandlerCreated
      write FOnHandlerCreated;
    // Supplies the handlers to request again at every Resume after the first.
    // Optional; unset replays nothing.
    property OnHandlerRoster: THandlerRoster read FOnHandlerRoster
      write FOnHandlerRoster;
    // Fired once for every rename request handed to the registry - on answer,
    // timeout, session death or a failed post - so a waiting row is always
    // released. Silent after Close.
    property OnRenamed: TRenameAnswered read FOnRenamed write FOnRenamed;
  end;

type
  // One rename sent and not yet answered. Targets are held by name, not by
  // reference: a restore in between replaces every component object. Step is
  // the history entry recorded before the request went out.
  TPendingRename = record
    Token: Integer;
    Kind: TRenameKind;
    OldName: string;
    NewName: string;
    Methods: TArray<TMethodRename>;
    Step: Integer;
  end;

  // The renames one document has in flight, and the application of each
  // answer. Held by the document window, not by the designer, which a restore
  // rebuilds while answers to the old designer's requests are still due.
  TRenameRegister = class
  private
    FEntries: TList<TPendingRename>;
    FNext: Integer;
    FLog: TDesignLog;
    FOnCurrentStep: TStepQuery;
    FOnDropStep: TStepDrop;
    FOnApply: TRenameApply;
    FOnSettled: TNotifyEvent;
    function CurrentStep: Integer;
    function Take(AToken: Integer; out ARename: TPendingRename): Boolean;
    procedure NoteAside(const AAnswer: TRenameAnswer;
      const ARename: TPendingRename);
  public
    constructor Create;
    destructor Destroy; override;
    // Sends the request and records it. Returns empty when sent, otherwise
    // the refusal text; a request refused on the spot is not recorded, since
    // no answer follows it.
    function Start(const ACoupling: ICodeCoupling; AKind: TRenameKind;
      const AOldName, ANewName: string;
      const AMethods: TArray<TMethodRename>): string;
    // Whether a component or root rename of AName is pending, matched
    // case-insensitively. Handler renames are not counted.
    function InFlight(const AName: string): Boolean;
    // Applies the answer with a matching token and fires OnSettled; an
    // unknown token is ignored.
    procedure Answered(const AAnswer: TRenameAnswer);
    // Drops every pending rename unanswered.
    procedure Clear;
    // Number of pending renames.
    function Count: Integer;
    // Optional log target; nil suppresses the informational rename notes.
    property Log: TDesignLog read FLog write FLog;
    // Supplies the history step recorded with a request; unset yields 0.
    property OnCurrentStep: TStepQuery read FOnCurrentStep write FOnCurrentStep;
    // Removes the history entry of a rename that did not happen.
    property OnDropStep: TStepDrop read FOnDropStep write FOnDropStep;
    // Applies an answered rename to the document.
    property OnApply: TRenameApply read FOnApply write FOnApply;
    // Fired after each answer, applied or refused, so rows waiting on a
    // rename are rebuilt.
    property OnSettled: TNotifyEvent read FOnSettled write FOnSettled;
  end;

// Event parameters read from ATypeInfo; empty for anything that is not method
// type info, nil included.
function SignatureOf(ATypeInfo: PTypeInfo): TEventSignature;

// Wire form of the signature, as one JSON object.
function SignatureJson(const ASignature: TEventSignature): string;

// Declaration spelling of a parameter's passing mode: 'const', 'var' or
// 'out', and empty for by-value.
function ModifierOf(AFlags: TParamFlags): string;

// The IDE-style default handler name: component name plus event name without
// a leading 'On'. An event not starting with 'On' keeps its full name.
function DefaultHandlerName(const AComponent, AEvent: string): string;

// Whether AName is a Pascal identifier: an ASCII letter or underscore,
// followed by ASCII letters, digits or underscores.
function IsIdentifier(const AName: string): Boolean;

// Rename pairs for AComponent's handlers whose wired name matches the default
// handler name built from AOldName, compared case-insensitively. Hand-named
// handlers are excluded, and a handler wired to several events appears once.
function PatternHandlerRenames(AComponent: TComponent;
  const AWiredName: TWiredNameQuery;
  const AOldName, ANewName: string): TArray<TMethodRename>;

// Wire form of the rename pairs, as one JSON array.
function MethodRenamesJson(const AMethods: TArray<TMethodRename>): string;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.StrUtils,
  System.JSON,
  System.Rtti;

type
  // One request in flight. The interface reference keeps the coupling alive
  // while an answer is owed; Answered then frees the request.
  TCouplingRequest = class
  private
    FKeep: ICodeCoupling;
    FCoupling: TDocumentCoupling;
    FWhat: string;
    FDuty: TAnswerDuty;
  public
    constructor Create(ACoupling: TDocumentCoupling; const AWhat: string;
      const ADuty: TAnswerDuty);
    procedure Answered(AOk: Boolean; const AError: string; AAnswer: TWireMessage);
  end;

function ModifierOf(AFlags: TParamFlags): string;
begin
  // Check pfOut before pfVar: an out parameter carries both by-address flags.
  if pfOut in AFlags then
    Result := 'out'
  else if pfVar in AFlags then
    Result := 'var'
  else if pfConst in AFlags then
    Result := 'const'
  else
    Result := '';
end;

function UnitPartOf(const AQualifiedName: string): string;
var
  Cut: Integer;
begin
  Cut := LastDelimiter('.', AQualifiedName);
  if Cut <= 0 then
    Exit('');
  Result := Copy(AQualifiedName, 1, Cut - 1);
end;

function SignatureOf(ATypeInfo: PTypeInfo): TEventSignature;
var
  Context: TRttiContext;
  Found: TRttiType;
  Parameter: TRttiParameter;
  Param: TEventParam;
begin
  Result := Default(TEventSignature);
  if (ATypeInfo = nil) or (ATypeInfo^.Kind <> tkMethod) then
    Exit;
  Context := TRttiContext.Create;
  try
    Found := Context.GetType(ATypeInfo);
    if not (Found is TRttiMethodType) then
      Exit;
    for Parameter in TRttiMethodType(Found).GetParameters do
    begin
      Param := Default(TEventParam);
      Param.Name := Parameter.Name;
      Param.Modifier := ModifierOf(Parameter.Flags);
      if Parameter.ParamType <> nil then
      begin
        Param.TypeName := Parameter.ParamType.Name;
        Param.UnitName := UnitPartOf(Parameter.ParamType.QualifiedName);
      end;
      Result.Params := Result.Params + [Param];
    end;
  finally
    Context.Free;
  end;
end;

function SignatureJson(const ASignature: TEventSignature): string;
var
  Root: TJSONObject;
  List: TJSONArray;
  Item: TJSONObject;
  Param: TEventParam;
begin
  Root := TJSONObject.Create;
  try
    List := TJSONArray.Create;
    Root.AddPair(ParamsField, List);
    for Param in ASignature.Params do
    begin
      Item := TJSONObject.Create;
      Item.AddPair(NameField, Param.Name);
      Item.AddPair(TypeField, Param.TypeName);
      Item.AddPair(UnitField, Param.UnitName);
      Item.AddPair(ModifierField, Param.Modifier);
      List.AddElement(Item);
    end;
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function DefaultHandlerName(const AComponent, AEvent: string): string;
begin
  Result := AEvent;
  if StartsText('On', Result) and (Length(Result) > 2) then
    Result := Copy(Result, 3, MaxInt);
  Result := AComponent + Result;
end;

function IsIdentifier(const AName: string): Boolean;
var
  I: Integer;
begin
  if AName = '' then
    Exit(False);
  if not CharInSet(AName[Low(AName)], ['A' .. 'Z', 'a' .. 'z', '_']) then
    Exit(False);
  for I := Low(AName) + 1 to High(AName) do
    if not CharInSet(AName[I], ['A' .. 'Z', 'a' .. 'z', '0' .. '9', '_']) then
      Exit(False);
  Result := True;
end;

function PatternHandlerRenames(AComponent: TComponent;
  const AWiredName: TWiredNameQuery;
  const AOldName, ANewName: string): TArray<TMethodRename>;
var
  List: PPropList;
  Count, I: Integer;
  Method: TMethod;
  Event, Wired: string;
  Pair, Known: TMethodRename;
  Seen: Boolean;
begin
  Result := nil;
  if (AComponent = nil) or not Assigned(AWiredName) or (AOldName = '') or
     (ANewName = '') then
    Exit;
  Count := GetPropList(AComponent.ClassInfo, [tkMethod], nil);
  if Count = 0 then
    Exit;
  GetMem(List, Count * SizeOf(PPropInfo));
  try
    GetPropList(AComponent.ClassInfo, [tkMethod], List);
    for I := 0 to Count - 1 do
    begin
      Method := GetMethodProp(AComponent, List^[I]);
      if Method.Code = nil then
        Continue;
      Wired := AWiredName(Method);
      if Wired = '' then
        Continue;
      Event := string(List^[I]^.Name);
      if not SameText(Wired, DefaultHandlerName(AOldName, Event)) then
        Continue;
      Pair.OldName := Wired;
      Pair.NewName := DefaultHandlerName(ANewName, Event);
      // Two events (e.g. Click and OnClick) can wire the same handler and
      // both match the pattern; it must be renamed only once.
      Seen := False;
      for Known in Result do
        Seen := Seen or SameText(Known.OldName, Pair.OldName);
      if not Seen then
        Result := Result + [Pair];
    end;
  finally
    FreeMem(List);
  end;
end;

function MethodRenamesJson(const AMethods: TArray<TMethodRename>): string;
var
  List: TJSONArray;
  Item: TJSONObject;
  Pair: TMethodRename;
begin
  List := TJSONArray.Create;
  try
    for Pair in AMethods do
    begin
      Item := TJSONObject.Create;
      Item.AddPair(PairOldField, Pair.OldName);
      Item.AddPair(PairNewField, Pair.NewName);
      List.AddElement(Item);
    end;
    Result := List.ToJSON;
  finally
    List.Free;
  end;
end;

{ TRenameRegister }

constructor TRenameRegister.Create;
begin
  inherited Create;
  FEntries := TList<TPendingRename>.Create;
end;

destructor TRenameRegister.Destroy;
begin
  FEntries.Free;
  inherited Destroy;
end;

function TRenameRegister.CurrentStep: Integer;
begin
  Result := 0;
  if Assigned(FOnCurrentStep) then
    Result := FOnCurrentStep;
end;

function TRenameRegister.Count: Integer;
begin
  Result := FEntries.Count;
end;

procedure TRenameRegister.Clear;
begin
  FEntries.Clear;
end;

function TRenameRegister.Start(const ACoupling: ICodeCoupling;
  AKind: TRenameKind; const AOldName, ANewName: string;
  const AMethods: TArray<TMethodRename>): string;
var
  Entry: TPendingRename;
begin
  Result := '';
  if ACoupling = nil then
    Exit('this document is not coupled to an editor');
  Inc(FNext);
  Entry := Default(TPendingRename);
  Entry.Token := FNext;
  Entry.Kind := AKind;
  Entry.OldName := AOldName;
  Entry.NewName := ANewName;
  Entry.Methods := AMethods;
  Entry.Step := CurrentStep;
  Result := ACoupling.RenameComponent(Entry.Token, AKind, AOldName, ANewName,
    AMethods);
  if Result = '' then
    FEntries.Add(Entry);
end;

function TRenameRegister.InFlight(const AName: string): Boolean;
var
  Entry: TPendingRename;
begin
  for Entry in FEntries do
    if (Entry.Kind <> rkHandler) and SameText(Entry.OldName, AName) then
      Exit(True);
  Result := False;
end;

function TRenameRegister.Take(AToken: Integer;
  out ARename: TPendingRename): Boolean;
var
  I: Integer;
begin
  ARename := Default(TPendingRename);
  for I := 0 to FEntries.Count - 1 do
  begin
    if FEntries[I].Token <> AToken then
      Continue;
    ARename := FEntries[I];
    FEntries.Delete(I);
    Exit(True);
  end;
  Result := False;
end;

procedure TRenameRegister.NoteAside(const AAnswer: TRenameAnswer;
  const ARename: TPendingRename);
var
  Skipped: string;
begin
  if FLog = nil then
    Exit;
  if not AAnswer.PrimaryRenamed then
    case ARename.Kind of
      rkRoot:
        FLog.AddFmt(lsInfo, '%s was renamed here, but the unit declares no ' +
          'variable of this form to rename with it', [ARename.OldName]);
      rkComponent:
        FLog.AddFmt(lsInfo, '%s was renamed here, but the unit declares no ' +
          'field for it - nothing in the code refers to it by name',
          [ARename.OldName]);
    end;
  for Skipped in AAnswer.SkippedMethods do
    FLog.AddFmt(lsInfo, '%s was not renamed - the unit declares no such method',
      [Skipped]);
end;

procedure TRenameRegister.Answered(const AAnswer: TRenameAnswer);
var
  Entry: TPendingRename;
  Applied: Boolean;
begin
  if not Take(AAnswer.Token, Entry) then
    Exit;
  Applied := False;
  if AAnswer.Ok and Assigned(FOnApply) then
  begin
    NoteAside(AAnswer, Entry);
    Applied := FOnApply(Entry.Kind, Entry.OldName, Entry.NewName, Entry.Methods,
      AAnswer.NewClassName);
  end;
  if not Applied and Assigned(FOnDropStep) then
    FOnDropStep(Entry.Step);
  if Assigned(FOnSettled) then
    FOnSettled(Self);
end;

{ TCouplingRequest }

constructor TCouplingRequest.Create(ACoupling: TDocumentCoupling;
  const AWhat: string; const ADuty: TAnswerDuty);
begin
  inherited Create;
  FCoupling := ACoupling;
  FKeep := ACoupling;
  FWhat := AWhat;
  FDuty := ADuty;
end;

procedure TCouplingRequest.Answered(AOk: Boolean; const AError: string;
  AAnswer: TWireMessage);
var
  Methods: TArray<string>;
begin
  try
    if AOk and (AAnswer <> nil) then
      case FDuty.Kind of
        rqField:
          FCoupling.FLedger.Acknowledge(FDuty.Change);
        rqEnsure:
          // Only a newly created handler marks its step; an undo must not
          // remove a method that already existed.
          if AAnswer.FlagOf(CreatedField) then
            FCoupling.HandlerCreated(FDuty.Step, FDuty.Handler);
        rqRemove:
          if not AAnswer.FlagOf(RemovedField) then
            FCoupling.Kept(lsInfo, FDuty.Handler.Method,
              AAnswer.TextOf(ReasonField));
      end;
    if not AOk then
      if FDuty.Kind = rqRemove then
        FCoupling.Kept(lsWarn, FDuty.Handler.Method, AError)
      else
        FCoupling.Refused(FWhat, AError);
    if FDuty.Kind = rqRename then
      FCoupling.RenameAnswered(FDuty.Token, AOk, AError, AAnswer);
    if Assigned(FDuty.Methods) and not FCoupling.FClosed then
    begin
      Methods := nil;
      if AOk and (AAnswer <> nil) then
        Methods := AAnswer.ListOf(MethodsField);
      FDuty.Methods(FDuty.Token, Methods);
    end;
  finally
    Free;
  end;
end;

{ TDocumentCoupling }

constructor TDocumentCoupling.Create(ASessions: TSessionRegistry);
begin
  inherited Create;
  FSessions := ASessions;
  FLedger := TFieldLedger.Create;
end;

destructor TDocumentCoupling.Destroy;
begin
  FLedger.Free;
  inherited Destroy;
end;

procedure TDocumentCoupling.Close;
begin
  FClosed := True;
  // The window frees the log when it closes; late answers must not write to
  // it.
  FLog := nil;
end;

function TDocumentCoupling.Session: TDesignSession;
begin
  Result := nil;
  if FClosed or (FSessions = nil) or (FFileName = '') then
    Exit;
  Result := FSessions.RouteFor(FFileName);
end;

function TDocumentCoupling.Available: Boolean;
begin
  Result := Session <> nil;
end;

function TDocumentCoupling.About(const AFields: TWireFields): TWireFields;
var
  I: Integer;
begin
  SetLength(Result, Length(AFields) + 2);
  Result[0] := WireText(FileField, FFileName);
  Result[1] := WireText(ClassField, FRootClass);
  for I := 0 to High(AFields) do
    Result[I + 2] := AFields[I];
end;

procedure TDocumentCoupling.Refused(const AWhat, AReason: string);
begin
  if FLog <> nil then
    FLog.AddFmt(lsWarn, '%s was not written to the unit: %s', [AWhat, AReason]);
end;

procedure TDocumentCoupling.Kept(ASeverity: TLogSeverity;
  const AMethod, AReason: string);
var
  Reason: string;
begin
  if FLog = nil then
    Exit;
  Reason := AReason;
  if Reason = '' then
    Reason := 'the editor gave no reason';
  FLog.AddFmt(ASeverity, '%s was not taken out of the unit: %s',
    [AMethod, Reason]);
end;

function TDocumentCoupling.CurrentStep: Integer;
begin
  Result := 0;
  if Assigned(FOnCurrentStep) then
    Result := FOnCurrentStep;
end;

procedure TDocumentCoupling.HandlerCreated(AStep: Integer;
  const AHandler: TCreatedHandler);
begin
  if FClosed or (AStep = 0) or not Assigned(FOnHandlerCreated) then
    Exit;
  FOnHandlerCreated(AStep, AHandler);
end;

procedure TDocumentCoupling.GrantForeground;
begin
  AllowSetForegroundWindow(ASFW_ANY);
end;

procedure TDocumentCoupling.Ask(const ACommand, AWhat: string;
  const AFields: TWireFields; const ADuty: TAnswerDuty);
var
  Target: TDesignSession;
  Request: TCouplingRequest;
begin
  Target := Session;
  if Target = nil then
    Exit;
  Request := TCouplingRequest.Create(Self, AWhat, ADuty);
  FSessions.SendRequest(Target, ACommand, About(AFields), Request.Answered);
end;

procedure TDocumentCoupling.Send(const AChange: TFieldChange);
var
  Duty: TAnswerDuty;
begin
  Duty := Default(TAnswerDuty);
  Duty.Kind := rqField;
  Duty.Change := AChange;
  case AChange.Kind of
    fcAdd:
      Ask(AddFieldCommand, Format('the field %s: %s',
        [AChange.Entry.Name, AChange.Entry.TypeName]),
        [WireText(NameField, AChange.Entry.Name),
         WireText(TypeField, AChange.Entry.TypeName),
         WireText(UnitField, AChange.Entry.UnitName)], Duty);
    fcRemove:
      Ask(RemoveFieldCommand, Format('dropping the field %s', [AChange.Entry.Name]),
        [WireText(NameField, AChange.Entry.Name)], Duty);
  end;
end;

function TDocumentCoupling.Settle(const AFields: TArray<TFieldEntry>): TSettleOutcome;
var
  Changes: TArray<TFieldChange>;
  Change: TFieldChange;
begin
  if FClosed or not FLedger.HasBaseline then
    Exit(soNothing);
  Changes := FLedger.Diff(AFields);
  if Length(Changes) = 0 then
    Exit(soNothing);
  if Session = nil then
    Exit(soUncoupled);
  for Change in Changes do
    Send(Change);
  Result := soSent;
end;

procedure TDocumentCoupling.Resume(const AFields: TArray<TFieldEntry>);
var
  Entry: TFieldEntry;
  Change: TFieldChange;
  Handler: TCreatedHandler;
begin
  if FClosed or (Session = nil) then
    Exit;
  if not FLedger.HasBaseline then
  begin
    FLedger.Baseline(AFields);
    Exit;
  end;
  Settle(AFields);
  Change.Kind := fcAdd;
  for Entry in FLedger.AddsSinceBaseline do
  begin
    Change.Entry := Entry;
    Send(Change);
  end;
  if Assigned(FOnHandlerRoster) then
    for Handler in FOnHandlerRoster() do
      AskEnsure(Handler, True);
end;

procedure TDocumentCoupling.ListMethods(ARequest: Integer;
  const ASignature: TEventSignature; const AWhen: TMethodListCallback);
var
  Duty: TAnswerDuty;
begin
  Duty := Default(TAnswerDuty);
  Duty.Kind := rqMethods;
  Duty.Token := ARequest;
  Duty.Methods := AWhen;
  Ask(ListMethodsCommand, 'the methods this event could be wired to',
    [WireStructure(SignatureField, SignatureJson(ASignature))], Duty);
end;

procedure TDocumentCoupling.EnsureHandler(const AComponent, AEvent,
  AMethod: string; const ASignature: TEventSignature);
var
  Handler: TCreatedHandler;
begin
  Handler.Component := AComponent;
  Handler.Event := AEvent;
  Handler.Method := AMethod;
  Handler.Signature := ASignature;
  AskEnsure(Handler, False);
end;

procedure TDocumentCoupling.AskEnsure(const AHandler: TCreatedHandler;
  AReplay: Boolean);
var
  Duty: TAnswerDuty;
  Fields: TWireFields;
begin
  // Checked before the foreground grant: a grant with no request behind it
  // hands the foreground to the next process that asks for it.
  if Session = nil then
  begin
    if not AReplay and (FLog <> nil) then
      FLog.AddFmt(lsWarn, 'the handler %s was not requested - no attached ' +
        'editor covers this document', [AHandler.Method]);
    Exit;
  end;
  if not AReplay then
    GrantForeground;
  Duty := Default(TAnswerDuty);
  Duty.Kind := rqEnsure;
  Duty.Handler := AHandler;
  if not AReplay then
    Duty.Step := CurrentStep;
  Fields := [WireText(ComponentField, AHandler.Component),
    WireText(EventPropertyField, AHandler.Event),
    WireText(MethodField, AHandler.Method),
    WireStructure(SignatureField, SignatureJson(AHandler.Signature))];
  if AReplay then
    Fields := Fields + [WireFlag(QuietField, True)];
  Ask(EnsureHandlerCommand, Format('the handler %s', [AHandler.Method]),
    Fields, Duty);
end;

function TDocumentCoupling.AskRename(AToken: Integer; const AWhat: string;
  const AFields: TWireFields): string;
var
  Target: TDesignSession;
  Duty: TAnswerDuty;
  Request: TCouplingRequest;
begin
  Target := Session;
  if Target = nil then
    Exit('VS Code is not attached to this document');
  Result := '';
  Duty := Default(TAnswerDuty);
  Duty.Kind := rqRename;
  Duty.Token := AToken;
  Request := TCouplingRequest.Create(Self, AWhat, Duty);
  if not FSessions.SendRequest(Target, RenameComponentCommand, About(AFields),
    Request.Answered) then
    Result := 'the request could not be sent to VS Code';
end;

procedure TDocumentCoupling.RenameAnswered(AToken: Integer; AOk: Boolean;
  const AReason: string; AAnswer: TWireMessage);
var
  Answer: TRenameAnswer;
begin
  if FClosed or not Assigned(FOnRenamed) then
    Exit;
  Answer := Default(TRenameAnswer);
  Answer.Token := AToken;
  Answer.Ok := AOk;
  Answer.Reason := AReason;
  if AOk and (AAnswer <> nil) then
  begin
    // A missing field means renamed: only an editor with nothing to rename
    // sends False, and older editors omit the field entirely.
    Answer.PrimaryRenamed := not AAnswer.Has(PrimaryRenamedField) or
      AAnswer.FlagOf(PrimaryRenamedField);
    Answer.SkippedMethods := AAnswer.ListOf(SkippedMethodsField);
    Answer.NewClassName := AAnswer.TextOf(NewClassNameField);
  end;
  FOnRenamed(Answer);
end;

function TDocumentCoupling.RenameComponent(AToken: Integer; AKind: TRenameKind;
  const AOldName, ANewName: string;
  const AMethods: TArray<TMethodRename>): string;
var
  Primary, Wanted, What: string;
begin
  if AKind = rkHandler then
  begin
    Primary := '';
    Wanted := '';
    What := Format('renaming the handler %s to %s', [AOldName, ANewName]);
  end
  else
  begin
    Primary := AOldName;
    Wanted := ANewName;
    What := Format('renaming %s to %s', [AOldName, ANewName]);
  end;
  Result := AskRename(AToken, What,
    [WireText(OldNameField, Primary),
     WireText(NewNameField, Wanted),
     WireFlag(RootField, AKind = rkRoot),
     WireStructure(MethodsField, MethodRenamesJson(AMethods))]);
end;

procedure TDocumentCoupling.NoteRenamed(const AOldName, ANewName: string);
begin
  FLedger.RenameKey(AOldName, ANewName);
end;

procedure TDocumentCoupling.RemoveHandler(const AMethod: string);
var
  Duty: TAnswerDuty;
begin
  Duty := Default(TAnswerDuty);
  Duty.Kind := rqRemove;
  Duty.Handler.Method := AMethod;
  Ask(RemoveHandlerCommand, Format('taking the handler %s back out', [AMethod]),
    [WireText(MethodField, AMethod)], Duty);
end;

procedure TDocumentCoupling.GotoHandler(const AMethod: string);
var
  Duty: TAnswerDuty;
begin
  if Session = nil then
  begin
    if FLog <> nil then
      FLog.AddFmt(lsWarn, '%s was not opened - no attached editor covers ' +
        'this document', [AMethod]);
    Exit;
  end;
  GrantForeground;
  Duty := Default(TAnswerDuty);
  Duty.Kind := rqPlain;
  Ask(GotoHandlerCommand, Format('going to %s', [AMethod]),
    [WireText(MethodField, AMethod)], Duty);
end;

end.
