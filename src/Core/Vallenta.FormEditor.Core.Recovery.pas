// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Core.Recovery;

// Maintains one recovery folder per designer process: a copy of each document
// with unsaved changes, a JSON note beside it, and a lock file held open while
// the journal is active, marking the session as running. The copy is written
// by the caller through TDocumentWriter, the note by this unit, which also
// lists and deletes the copies left by ended sessions. No internal locking.
//
// Only files below the recovery folder are written or deleted; the document's
// own file is never touched.

interface

uses
  Vallenta.FormEditor.Streaming.RootClassifier;

type
  // One document copy offered for recovery, read from its note file.
  TRecoveryEntry = record
    // Path of the document as recorded when the copy was written.
    SourceFile: string;
    // Class name of the design root held in the copy.
    RootClassName: string;
    // Whether that root is a form, a frame or a data module.
    RootKind: TDesignRootClass;
    // Local time the copy was written; 0 when the note holds no valid time.
    CapturedAt: TDateTime;
    // The copy, a complete form file inside the session folder.
    CopyFile: string;
    // The note describing the copy; DropRecovered deletes both files.
    NoteFile: string;
  end;

  // Writes the document as a complete form file at APath, overwriting an
  // existing one. An exception reaches Keep, which reports its message.
  TDocumentWriter = procedure(const APath: string) of object;

  // The recovery folder of the running process: the lock file marking the
  // session as running plus a copy and note per document passed to Keep.
  TRecoveryJournal = class
  private
    FFolder: string;
    FLock: THandle;
    FFailure: string;
    function PathFor(const ASourceFile, AExtension: string): string;
    procedure WriteNote(const ANoteFile, ASourceFile, ARootClassName: string;
      ARootKind: TDesignRootClass);
  public
    // Creates the session folder and opens the lock file. Failures are
    // caught: the journal is then not Active and Failure holds the message.
    constructor Create;
    destructor Destroy; override;
    // Writes the copy of one document and its note, replacing an earlier pair
    // for the same path. False when the journal is inactive or a write
    // failed, with AFailure holding the message.
    function Keep(const ASourceFile, ARootClassName: string;
      ARootKind: TDesignRootClass; const AWrite: TDocumentWriter;
      out AFailure: string): Boolean;
    // Deletes the copy and note of ASourceFile; does nothing when none exist.
    procedure Forget(const ASourceFile: string);
    // Closes the lock file and deletes the session folder when no note is
    // left in it. Called by the destructor; a second call does nothing.
    procedure Release;
    // True while the lock file is open. Keep fails and Forget does nothing
    // otherwise.
    function Active: Boolean;
    // Message of the failure that left the journal inactive; empty when
    // Create succeeded.
    property Failure: string read FFailure;
    // Path of the session folder, ending with a path delimiter.
    property Folder: string read FFolder;
  end;

// The copies left behind by sessions that are no longer running. A note whose
// copy is missing is deleted during the scan, and a session folder is removed
// only when no note is left in it, offered or unreadable.
function RecoverableDocuments: TArray<TRecoveryEntry>;

// Deletes the entry's copy and note, and the session folder with them when
// the entry was the last one in it.
procedure DropRecovered(const AEntry: TRecoveryEntry);

// Seconds between copies, read from the IntervalSeconds value under
// ASettingsKey below HKEY_CURRENT_USER. 30 when the value is not set, 0 when
// it is zero or negative; any other value is raised to at least 5.
function RecoveryInterval(const ASettingsKey: string): Integer;

implementation

uses
  Winapi.Windows,
  Winapi.ShlObj,
  System.SysUtils,
  System.IOUtils,
  System.DateUtils,
  System.Win.Registry,
  System.Hash,
  System.JSON,
  Vallenta.FormEditor.Streaming.Saver;

const
  // Session folder layout and note fields; NoteVersion is the only note
  // version read back.
  LockFile = 'core.lock';
  CopyExtension = '.dfm';
  NoteExtension = '.json';
  NoteVersion = 0;
  VersionField = 'v';
  FileField = 'file';
  ClassField = 'class';
  KindField = 'kind';
  TimeField = 'at';

  // Copy interval: the registry value name, the default and the floor, in
  // seconds.
  IntervalValue = 'IntervalSeconds';
  DefaultInterval = 30;
  ShortestInterval = 5;

type
  TNoteVerdict = (
    nvOffer,     // the note is readable and its copy exists
    nvOrphaned,  // readable, but the copy is missing; the note is deleted
    nvForeign);  // unreadable or another note version; both files are kept

function RecoveryRoot: string;
var
  Buffer: array [0 .. MAX_PATH] of Char;
  Local: string;
begin
  if not Succeeded(SHGetFolderPath(0, CSIDL_LOCAL_APPDATA or CSIDL_FLAG_CREATE,
    0, SHGFP_TYPE_CURRENT, @Buffer[0])) then
    raise Exception.Create('The local application data folder cannot be found.');
  // The PChar conversion stops at the terminator; assigning the array itself
  // would carry the unused buffer characters into the string.
  Local := PChar(@Buffer[0]);
  Result := TPath.Combine(TPath.Combine(TPath.Combine(Local, 'Vallenta'),
    'VallentaDesigner'), 'recovery');
end;

function SessionFolderName: string;
var
  Created, Exited, Kernel, User: TFileTime;
begin
  if not GetProcessTimes(GetCurrentProcess, Created, Exited, Kernel, User) then
    RaiseLastOSError;
  // Process ids are reused: the creation time must stay part of the name.
  Result := Format('%d-%.16x', [GetCurrentProcessId,
    UInt64(Created.dwHighDateTime) shl 32 or Created.dwLowDateTime]);
end;

function DocumentKey(const ASourceFile: string): string;
begin
  Result := Copy(THashSHA2.GetHashString(
    LowerCase(ExpandFileName(ASourceFile))), 1, 16);
end;

function SessionIsOver(const AFolder: string): Boolean;
var
  Lock: THandle;
begin
  Lock := CreateFile(PChar(TPath.Combine(AFolder, LockFile)), GENERIC_READ, 0,
    nil, OPEN_EXISTING, 0, 0);
  if Lock <> INVALID_HANDLE_VALUE then
  begin
    CloseHandle(Lock);
    Exit(True);
  end;
  Result := GetLastError = ERROR_FILE_NOT_FOUND;
end;

procedure RemoveSessionFolder(const AFolder: string);
begin
  try
    TDirectory.Delete(AFolder, True);
  except
  end;
end;

function NoteCount(const AFolder: string): Integer;
begin
  Result := 0;
  if TDirectory.Exists(AFolder) then
    Result := Length(TDirectory.GetFiles(AFolder, '*' + NoteExtension));
end;

function ReadNote(const ANoteFile: string;
  out AEntry: TRecoveryEntry): TNoteVerdict;
var
  Parsed, Version: TJSONValue;
  Note: TJSONObject;
  Kind: string;

  function Text(const AName: string): string;
  var
    Value: TJSONValue;
  begin
    Result := '';
    Value := Note.GetValue(AName);
    if Value is TJSONString then
      Result := Value.Value;
  end;

begin
  Result := nvForeign;
  AEntry := Default(TRecoveryEntry);
  try
    Parsed := TJSONObject.ParseJSONValue(TFile.ReadAllText(ANoteFile,
      TEncoding.UTF8));
  except
    Parsed := nil;
  end;
  try
    if not (Parsed is TJSONObject) then
      Exit;
    Note := TJSONObject(Parsed);
    Version := Note.GetValue(VersionField);
    if not ((Version is TJSONNumber) and
            (TJSONNumber(Version).AsInt = NoteVersion)) then
      Exit;
    AEntry.SourceFile := Text(FileField);
    AEntry.RootClassName := Text(ClassField);
    Kind := Text(KindField);
    if (AEntry.SourceFile = '') or (AEntry.RootClassName = '') or
       not TryRootKind(Kind, AEntry.RootKind) then
      Exit;
    if not TryISO8601ToDate(Text(TimeField), AEntry.CapturedAt, False) then
      AEntry.CapturedAt := 0;
    AEntry.NoteFile := ANoteFile;
    AEntry.CopyFile := ChangeFileExt(ANoteFile, CopyExtension);
    if TFile.Exists(AEntry.CopyFile) then
      Result := nvOffer
    else
      Result := nvOrphaned;
  finally
    Parsed.Free;
  end;
end;

procedure DeleteQuietly(const AFileName: string);
begin
  if AFileName <> '' then
    System.SysUtils.DeleteFile(AFileName);
end;

function RecoverableDocuments: TArray<TRecoveryEntry>;
var
  Root, Folder, Note: string;
  Entry: TRecoveryEntry;
  Standing: Integer;
begin
  Result := nil;
  Root := RecoveryRoot;
  if not TDirectory.Exists(Root) then
    Exit;
  for Folder in TDirectory.GetDirectories(Root) do
  begin
    if not SessionIsOver(Folder) then
      Continue;
    Standing := 0;
    for Note in TDirectory.GetFiles(Folder, '*' + NoteExtension) do
      case ReadNote(Note, Entry) of
        nvOffer:
          begin
            Result := Result + [Entry];
            Inc(Standing);
          end;
        nvOrphaned:
          begin
            DeleteQuietly(Note);
            DeleteQuietly(ChangeFileExt(Note, CopyExtension));
          end;
        nvForeign:
          Inc(Standing);
      end;
    if Standing = 0 then
      RemoveSessionFolder(Folder);
  end;
end;

procedure DropRecovered(const AEntry: TRecoveryEntry);
var
  Folder: string;
begin
  DeleteQuietly(AEntry.CopyFile);
  DeleteQuietly(AEntry.NoteFile);
  Folder := ExtractFileDir(AEntry.NoteFile);
  if TDirectory.Exists(Folder) and (NoteCount(Folder) = 0) then
    RemoveSessionFolder(Folder);
end;

function RecoveryInterval(const ASettingsKey: string): Integer;
var
  Registry: TRegistry;
begin
  Result := DefaultInterval;
  Registry := TRegistry.Create(KEY_READ);
  try
    Registry.RootKey := HKEY_CURRENT_USER;
    if Registry.OpenKeyReadOnly(ASettingsKey) and
      Registry.ValueExists(IntervalValue) then
      Result := Registry.ReadInteger(IntervalValue);
  finally
    Registry.Free;
  end;
  if Result <= 0 then
    Exit(0);
  if Result < ShortestInterval then
    Result := ShortestInterval;
end;

{ TRecoveryJournal }

constructor TRecoveryJournal.Create;
begin
  inherited Create;
  FLock := INVALID_HANDLE_VALUE;
  try
    FFolder := IncludeTrailingPathDelimiter(
      TPath.Combine(RecoveryRoot, SessionFolderName));
    TDirectory.CreateDirectory(FFolder);
    // The share mode must stay 0 and the handle must stay open: SessionIsOver
    // reads a successful open as proof that the session ended.
    FLock := CreateFile(PChar(FFolder + LockFile), GENERIC_WRITE, 0, nil,
      CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if FLock = INVALID_HANDLE_VALUE then
      RaiseLastOSError;
  except
    on E: Exception do
      FFailure := Format('%s: %s', [E.ClassName, E.Message]);
  end;
end;

destructor TRecoveryJournal.Destroy;
begin
  Release;
  inherited Destroy;
end;

function TRecoveryJournal.Active: Boolean;
begin
  Result := FLock <> INVALID_HANDLE_VALUE;
end;

function TRecoveryJournal.PathFor(const ASourceFile,
  AExtension: string): string;
begin
  Result := FFolder + DocumentKey(ASourceFile) + AExtension;
end;

procedure TRecoveryJournal.WriteNote(const ANoteFile, ASourceFile,
  ARootClassName: string; ARootKind: TDesignRootClass);
var
  Note: TJSONObject;
begin
  Note := TJSONObject.Create;
  try
    Note.AddPair(VersionField, TJSONNumber.Create(NoteVersion));
    Note.AddPair(FileField, ASourceFile);
    Note.AddPair(ClassField, ARootClassName);
    Note.AddPair(KindField, RootKindName(ARootKind));
    Note.AddPair(TimeField, DateToISO8601(Now, False));
    WriteTextAtomically(Note.ToJSON, ANoteFile);
  finally
    Note.Free;
  end;
end;

function TRecoveryJournal.Keep(const ASourceFile, ARootClassName: string;
  ARootKind: TDesignRootClass; const AWrite: TDocumentWriter;
  out AFailure: string): Boolean;
var
  CopyPath, NotePath: string;
begin
  AFailure := '';
  if not Active then
  begin
    AFailure := FFailure;
    Exit(False);
  end;
  CopyPath := PathFor(ASourceFile, CopyExtension);
  NotePath := PathFor(ASourceFile, NoteExtension);
  Result := False;
  try
    // The note is written after the copy so that a note never describes a
    // file still being written.
    AWrite(CopyPath);
    WriteNote(NotePath, ASourceFile, ARootClassName, ARootKind);
    Result := True;
  except
    on E: Exception do
    begin
      AFailure := Format('%s: %s', [E.ClassName, E.Message]);
      // The copy may be incomplete or stale, and a copy whose note is gone is
      // never offered.
      DeleteQuietly(NotePath);
    end;
  end;
end;

procedure TRecoveryJournal.Forget(const ASourceFile: string);
begin
  if not Active then
    Exit;
  DeleteQuietly(PathFor(ASourceFile, NoteExtension));
  DeleteQuietly(PathFor(ASourceFile, CopyExtension));
end;

procedure TRecoveryJournal.Release;
begin
  if not Active then
    Exit;
  CloseHandle(FLock);
  FLock := INVALID_HANDLE_VALUE;
  if NoteCount(FFolder) = 0 then
    RemoveSessionFolder(FFolder);
end;

end.
