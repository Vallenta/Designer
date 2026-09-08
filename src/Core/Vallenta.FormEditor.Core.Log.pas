// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Core.Log;

// In-memory log of entries carrying a severity field, so the same entry
// renders as a coloured row in the messages pane or as a prefixed console
// line. Appending notifies entry listeners; entries dropped under Limit
// notify trim listeners separately. No locking, and listeners run on the
// calling thread: an instance must not be used from more than one thread.

interface

uses
  System.Classes,
  System.Generics.Collections;

type
  // Severity of a log entry.
  TLogSeverity = (lsInfo, lsWarn, lsError);

  // One log entry; Text holds the message without a severity prefix.
  TDesignLogEntry = record
    Severity: TLogSeverity;
    Text: string;
  end;

  // Listener signature for one appended entry; Sender is the log.
  TLogEntryEvent = procedure(Sender: TObject; const Entry: TDesignLogEntry) of object;

  // Log of a session or of a document: entries in append order, with separate
  // notification for appends and for the drops Limit causes.
  TDesignLog = class
  private
    FEntries: TList<TDesignLogEntry>;
    FListeners: TList<TMethod>;
    FTrimListeners: TList<TMethod>;
    FLimit: Integer;
    function GetCount: Integer;
    function GetEntry(Index: Integer): TDesignLogEntry;
    function IndexOfListener(const AListener: TLogEntryEvent): Integer;
    procedure SetLimit(AValue: Integer);
    function Trim: Boolean;
    procedure AnnounceTrim;
  public
    constructor Create;
    destructor Destroy; override;
    // Appends an entry, applies Limit, and notifies the entry listeners.
    procedure Add(Severity: TLogSeverity; const Text: string);
    // Add with the entry text built from Format(Pattern, Args).
    procedure AddFmt(Severity: TLogSeverity; const Pattern: string;
      const Args: array of const);
    // Removes every entry without notifying listeners; an attached view must
    // re-read the log.
    procedure Clear;
    // Registers a handler called for each appended entry; registering the same
    // handler twice has no effect.
    procedure AddListener(const AListener: TLogEntryEvent);
    // Unregisters an entry handler; an unregistered handler is ignored.
    procedure RemoveListener(const AListener: TLogEntryEvent);
    // Maximum entry count, oldest dropped first; 0 removes the cap. Assigning
    // a limit trims immediately, and only lsInfo entries are ever dropped.
    property Limit: Integer read FLimit write SetLimit;
    // Registers a handler called once after each drop of the oldest entries;
    // the whole log must be re-read, as entry handlers report appends only.
    procedure AddTrimListener(const AListener: TNotifyEvent);
    // Unregisters a trim handler; an unregistered handler is ignored.
    procedure RemoveTrimListener(const AListener: TNotifyEvent);
    // Number of entries currently held.
    property Count: Integer read GetCount;
    // Entries in append order; index 0 is the oldest.
    property Entries[Index: Integer]: TDesignLogEntry read GetEntry; default;
  end;

// Formats an entry as a prefixed console line, e.g. "[warn] text".
function FormatLogLine(const Entry: TDesignLogEntry): string;

implementation

uses
  System.SysUtils;

const
  SeverityPrefix: array [TLogSeverity] of string = ('[info] ', '[warn] ', '[error] ');

function FormatLogLine(const Entry: TDesignLogEntry): string;
begin
  Result := SeverityPrefix[Entry.Severity] + Entry.Text;
end;

{ TDesignLog }

constructor TDesignLog.Create;
begin
  inherited Create;
  FEntries := TList<TDesignLogEntry>.Create;
  FListeners := TList<TMethod>.Create;
  FTrimListeners := TList<TMethod>.Create;
end;

destructor TDesignLog.Destroy;
begin
  FTrimListeners.Free;
  FListeners.Free;
  FEntries.Free;
  inherited Destroy;
end;

function TDesignLog.IndexOfListener(const AListener: TLogEntryEvent): Integer;
var
  Wanted: TMethod;
  I: Integer;
begin
  Wanted := TMethod(AListener);
  for I := 0 to FListeners.Count - 1 do
    if (FListeners[I].Code = Wanted.Code) and (FListeners[I].Data = Wanted.Data) then
      Exit(I);
  Result := -1;
end;

procedure TDesignLog.AddListener(const AListener: TLogEntryEvent);
begin
  if IndexOfListener(AListener) < 0 then
    FListeners.Add(TMethod(AListener));
end;

procedure TDesignLog.RemoveListener(const AListener: TLogEntryEvent);
var
  Index: Integer;
begin
  Index := IndexOfListener(AListener);
  if Index >= 0 then
    FListeners.Delete(Index);
end;

procedure TDesignLog.AddTrimListener(const AListener: TNotifyEvent);
begin
  if FTrimListeners.IndexOf(TMethod(AListener)) < 0 then
    FTrimListeners.Add(TMethod(AListener));
end;

procedure TDesignLog.RemoveTrimListener(const AListener: TNotifyEvent);
var
  Index: Integer;
begin
  Index := FTrimListeners.IndexOf(TMethod(AListener));
  if Index >= 0 then
    FTrimListeners.Delete(Index);
end;

procedure TDesignLog.SetLimit(AValue: Integer);
begin
  if AValue < 0 then
    AValue := 0;
  if FLimit = AValue then
    Exit;
  FLimit := AValue;
  if Trim then
    AnnounceTrim;
end;

function TDesignLog.Trim: Boolean;
var
  I: Integer;
begin
  Result := False;
  if FLimit <= 0 then
    Exit;
  I := 0;
  while (FEntries.Count > FLimit) and (I < FEntries.Count) do
    if FEntries[I].Severity = lsInfo then
    begin
      FEntries.Delete(I);
      Result := True;
    end
    else
      Inc(I);
end;

procedure TDesignLog.AnnounceTrim;
var
  Told: TArray<TMethod>;
  Listener: TNotifyEvent;
  I: Integer;
begin
  // A listener may unregister itself while being notified; the copy is walked
  // and membership re-checked before each call.
  Told := FTrimListeners.ToArray;
  for I := 0 to High(Told) do
  begin
    TMethod(Listener) := Told[I];
    if FTrimListeners.IndexOf(Told[I]) >= 0 then
      Listener(Self);
  end;
end;

function TDesignLog.GetCount: Integer;
begin
  Result := FEntries.Count;
end;

function TDesignLog.GetEntry(Index: Integer): TDesignLogEntry;
begin
  Result := FEntries[Index];
end;

procedure TDesignLog.Add(Severity: TLogSeverity; const Text: string);
var
  Entry: TDesignLogEntry;
  Listener: TLogEntryEvent;
  Told: TArray<TMethod>;
  I: Integer;
  Dropped: Boolean;
begin
  Entry.Severity := Severity;
  Entry.Text := Text;
  FEntries.Add(Entry);
  // Trimming precedes notification: a listener reading the log must find the
  // final entry count.
  Dropped := Trim;
  // A listener may unregister during notification and may already be freed;
  // the copy is walked and membership re-checked before each call.
  Told := FListeners.ToArray;
  for I := 0 to High(Told) do
  begin
    TMethod(Listener) := Told[I];
    if IndexOfListener(Listener) >= 0 then
      Listener(Self, Entry);
  end;
  if Dropped then
    AnnounceTrim;
end;

procedure TDesignLog.AddFmt(Severity: TLogSeverity; const Pattern: string;
  const Args: array of const);
begin
  Add(Severity, Format(Pattern, Args));
end;

procedure TDesignLog.Clear;
begin
  FEntries.Clear;
end;

end.
