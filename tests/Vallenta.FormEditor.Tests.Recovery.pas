// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.Recovery;

// Covers Vallenta.FormEditor.Core.Recovery: the copy and note a journal
// writes for a loaded document, the entries a scan offers for ended sessions,
// loading a copy back, discarding an entry, and the interval read from the
// registry. Every case except the interval cases starts the process-wide
// designer session and loads a fixture form file through the designer path.
//
// The cases write into the product's own recovery root below LOCALAPPDATA;
// there is no test root to redirect them to, so each case deletes the
// entries it wrote. A scan skips a folder whose lock file is still open, so
// a case that expects its own entry releases the journal before scanning.

interface

uses
  DUnitX.TestFramework;

type
  // TRecoveryJournal and the unit-level RecoverableDocuments, DropRecovered
  // and RecoveryInterval functions.
  [TestFixture]
  TRecoveryTests = class
  public
    [Test]
    procedure TheCopyIsWhatASaveOfTheSameDocumentWrites;
    [Test]
    procedure ASessionStillRunningIsNotOffered;
    [Test]
    procedure ASessionThatIsOverIsOfferedWhatItLeft;
    [Test]
    procedure ANoteWhoseCopyIsGoneIsNotOfferedAndIsCleanedUp;
    [Test]
    procedure ANoteFromAnotherVersionIsLeftWhereItIs;
    [Test]
    procedure ARecoveredDocumentSavesTheBytesTheSessionWouldHave;
    [Test]
    procedure DiscardingTakesTheEntryAway;
    [Test]
    procedure NothingIsLeftWhenEverythingWasForgotten;

    [Test]
    [TestCase('nothing configured', '|30', '|')]
    [TestCase('switched off', '0|0', '|')]
    [TestCase('below the floor', '1|5', '|')]
    [TestCase('as configured', '90|90', '|')]
    procedure TheIntervalIsReadFromTheSettings(const AConfigured: string;
      AExpected: Integer);
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.IOUtils,
  System.Win.Registry,
  Vallenta.FormEditor.Core.Settings,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Core.Recovery,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Streaming.RootClassifier,
  Vallenta.FormEditor.Surface.FormDesigner,
  Vallenta.FormEditor.Tests.Environment;

const
  // Form file the journal cases load. Tests.RoundTrip asserts it is written
  // back byte for byte, so a byte difference here comes from the journal.
  Fixture = 'basic_form.dfm';
  // Settings subkey the interval cases create and delete, below SettingsRoot.
  // Separate from the product's Recovery key, which a run must not modify.
  IntervalTestKey = 'Tests\RecoveryInterval';
  // Must match the value name RecoveryInterval reads.
  IntervalValue = 'IntervalSeconds';

type
  // One form file loaded through the designer path - loader, design document
  // and designer - and held alive while a case writes it out again.
  TLoadedDocument = class
  private
    FLog: TDesignLog;
    FLoader: TFormLoader;
    FDocument: TDesignDocument;
    FDesigner: TFormDesigner;
    procedure Build(const ADocumentFile: string);
  public
    constructor Create(const ADocumentFile: string);
    // Loads the journal's copy ACopyFile as the document ADocumentFile. Root
    // class and kind come from the note: the class is not read out of the
    // image, and the kind is classified from the companion .pas unit beside
    // the form file, which the copy in the recovery folder does not have.
    constructor CreateRecovered(const ADocumentFile, ACopyFile,
      ARootClassName: string; ARootKind: TDesignRootClass);
    destructor Destroy; override;
    property Designer: TFormDesigner read FDesigner;
  end;

constructor TLoadedDocument.Create(const ADocumentFile: string);
begin
  inherited Create;
  FLog := TDesignLog.Create;
  FLoader := TFormLoader.Create(FLog);
  FLoader.Prepare(ADocumentFile);
  Build(ADocumentFile);
end;

constructor TLoadedDocument.CreateRecovered(const ADocumentFile, ACopyFile,
  ARootClassName: string; ARootKind: TDesignRootClass);
var
  State: TLoadedFormState;
begin
  inherited Create;
  FLog := TDesignLog.Create;
  FLoader := TFormLoader.Create(FLog);
  State := Default(TLoadedFormState);
  State.RootClassName := ARootClassName;
  State.RootKind := ARootKind;
  FLoader.PrepareRecovered(ACopyFile, State, ADocumentFile);
  Build(ADocumentFile);
end;

procedure TLoadedDocument.Build(const ADocumentFile: string);
begin
  FDocument := CreateDesignDocument(FLoader.RootKind);
  FDesigner := TFormDesigner.Create(FDocument.HostForm, FDocument.Root, FLog);
  FLoader.StreamInto(FDocument.Root);
  if FLoader.RootKind = drFrame then
    AttachFrameToHost(FDocument);
  FDesigner.AttachLoaded(ADocumentFile, FLoader.ExtractEventMap,
    FLoader.ExtractPreserved, FLoader.ExtractFrames, FLoader.ExtractAncestor,
    FLoader.LoadedState);
  // A placeholder takes the tab slot of the preserved block it stands for; a
  // document streamed without them is written with shifted TabOrders.
  FDesigner.ShowPlaceholders;
end;

destructor TLoadedDocument.Destroy;
begin
  // The designer holds the placeholders parented into the document; freeing
  // the document first frees them twice.
  FDesigner.Free;
  FreeDesignDocument(FDocument);
  FLoader.Free;
  FLog.Free;
  inherited Destroy;
end;

function TemporaryFile(const AName: string): string;
begin
  Result := TPath.Combine(TPath.GetTempPath, 'vsfe_recovery_' + AName);
end;

// True when a scan offers ASourceFile from AFolder. Matching the source file
// alone is not enough: the scan covers every session folder under the shared
// recovery root, including ones an aborted run left for the same fixture.
function OfferedFor(const AFolder, ASourceFile: string;
  out AEntry: TRecoveryEntry): Boolean;
var
  Entry: TRecoveryEntry;
  Wanted: string;
begin
  AEntry := Default(TRecoveryEntry);
  Result := False;
  Wanted := ExcludeTrailingPathDelimiter(AFolder);
  for Entry in RecoverableDocuments do
    if SameText(Entry.SourceFile, ASourceFile) and
       SameText(ExtractFileDir(Entry.NoteFile), Wanted) then
    begin
      AEntry := Entry;
      Exit(True);
    end;
end;

// Writes one copy of ADocument and frees the journal, leaving the entry of a
// session that ended without saving. AFolder receives the session folder
// holding the copy and its note.
procedure KeepAndEndSession(ADocument: TLoadedDocument;
  const ASourceFile: string; out AFolder: string);
var
  Journal: TRecoveryJournal;
  Failure: string;
begin
  Journal := TRecoveryJournal.Create;
  try
    Assert.IsTrue(Journal.Active, Journal.Failure);
    AFolder := Journal.Folder;
    Assert.IsTrue(Journal.Keep(ASourceFile, ADocument.Designer.RootClassName,
      ADocument.Designer.RootKind, ADocument.Designer.WriteTo, Failure),
      Failure);
  finally
    Journal.Free;
  end;
end;

procedure TRecoveryTests.TheCopyIsWhatASaveOfTheSameDocumentWrites;
var
  Document: TLoadedDocument;
  Source, Written, Folder, Where: string;
  Entry: TRecoveryEntry;
begin
  BeginDesignerSession;
  Source := FixtureFile(Fixture);
  Written := TemporaryFile('written.dfm');
  Document := TLoadedDocument.Create(Source);
  try
    KeepAndEndSession(Document, Source, Folder);
    Assert.IsTrue(OfferedFor(Folder, Source, Entry),
      'the journal kept a copy that a later scan cannot find');
    try
      Document.Designer.WriteTo(Written);
      Assert.IsTrue(SameBytes(Entry.CopyFile, Written, Where),
        'the copy is not what a save of the same document writes: ' + Where);
      Assert.AreEqual(Document.Designer.RootClassName, Entry.RootClassName);
      Assert.AreEqual(RootKindName(Document.Designer.RootKind),
        RootKindName(Entry.RootKind));
    finally
      DropRecovered(Entry);
      DeleteFile(Written);
    end;
  finally
    Document.Free;
  end;
end;

// The only case that scans while its own journal is still open: the lock file
// is held without sharing, so the scan reads the session as running and skips
// its folder.
procedure TRecoveryTests.ASessionStillRunningIsNotOffered;
var
  Document: TLoadedDocument;
  Journal: TRecoveryJournal;
  Source, Folder, Failure: string;
  Entry: TRecoveryEntry;
begin
  BeginDesignerSession;
  Source := FixtureFile(Fixture);
  Document := TLoadedDocument.Create(Source);
  try
    Journal := TRecoveryJournal.Create;
    try
      Folder := Journal.Folder;
      Assert.IsTrue(Journal.Keep(Source, Document.Designer.RootClassName,
        Document.Designer.RootKind, Document.Designer.WriteTo, Failure),
        Failure);
      Assert.IsFalse(OfferedFor(Folder, Source, Entry),
        'a session that is still running was offered for recovery');
    finally
      Journal.Forget(Source);
      Journal.Free;
    end;
  finally
    Document.Free;
  end;
end;

procedure TRecoveryTests.ASessionThatIsOverIsOfferedWhatItLeft;
var
  Document: TLoadedDocument;
  Source, Folder: string;
  Entry: TRecoveryEntry;
begin
  BeginDesignerSession;
  Source := FixtureFile(Fixture);
  Document := TLoadedDocument.Create(Source);
  try
    KeepAndEndSession(Document, Source, Folder);
    Assert.IsTrue(OfferedFor(Folder, Source, Entry),
      'what an ended session left was not offered');
    Assert.IsTrue(TFile.Exists(Entry.CopyFile), 'the copy itself is gone');
    Assert.AreEqual(Source, Entry.SourceFile);
    DropRecovered(Entry);
  finally
    Document.Free;
  end;
end;

procedure TRecoveryTests.ANoteWhoseCopyIsGoneIsNotOfferedAndIsCleanedUp;
var
  Document: TLoadedDocument;
  Source, Folder, NoteFile: string;
  Entry: TRecoveryEntry;
begin
  BeginDesignerSession;
  Source := FixtureFile(Fixture);
  Document := TLoadedDocument.Create(Source);
  try
    KeepAndEndSession(Document, Source, Folder);
    Assert.IsTrue(OfferedFor(Folder, Source, Entry), 'nothing was kept');
    NoteFile := Entry.NoteFile;
    DeleteFile(Entry.CopyFile);
    Assert.IsFalse(OfferedFor(Folder, Source, Entry),
      'a note describing a copy that is not there was offered');
    Assert.IsFalse(TFile.Exists(NoteFile),
      'the note was left to be looked at again on every start from now on');
  finally
    Document.Free;
  end;
end;

// The journal's own note is overwritten with note version 99. A scan neither
// offers nor deletes such a note, so the case removes both files itself.
procedure TRecoveryTests.ANoteFromAnotherVersionIsLeftWhereItIs;
var
  Document: TLoadedDocument;
  Source, Folder: string;
  Entry, Foreign: TRecoveryEntry;
begin
  BeginDesignerSession;
  Source := FixtureFile(Fixture);
  Document := TLoadedDocument.Create(Source);
  try
    KeepAndEndSession(Document, Source, Folder);
    Assert.IsTrue(OfferedFor(Folder, Source, Entry), 'nothing was kept');
    Foreign := Entry;
    TFile.WriteAllText(Foreign.NoteFile,
      '{"v":99,"file":"' + StringReplace(Source, '\', '\\', [rfReplaceAll]) +
      '","class":"TSomething","kind":"holodeck"}');
    try
      Assert.IsFalse(OfferedFor(Folder, Source, Entry),
        'an entry this designer cannot read was offered anyway');
      Assert.IsTrue(TFile.Exists(Foreign.NoteFile),
        'a note from another version was taken away');
      Assert.IsTrue(TFile.Exists(Foreign.CopyFile),
        'the copy a note from another version describes was taken away');
    finally
      DropRecovered(Foreign);
    end;
  finally
    Document.Free;
  end;
end;

// The comparison is against the journal's copy; that the copy equals a save
// of the live document is pinned by TheCopyIsWhatASaveOfTheSameDocumentWrites.
procedure TRecoveryTests.ARecoveredDocumentSavesTheBytesTheSessionWouldHave;
var
  Document, Recovered: TLoadedDocument;
  Source, Written, Folder, Where: string;
  Entry: TRecoveryEntry;
begin
  BeginDesignerSession;
  Source := FixtureFile(Fixture);
  Written := TemporaryFile('recovered.dfm');
  Document := TLoadedDocument.Create(Source);
  try
    KeepAndEndSession(Document, Source, Folder);
  finally
    Document.Free;
  end;
  Assert.IsTrue(OfferedFor(Folder, Source, Entry), 'nothing was left to recover');
  try
    Recovered := TLoadedDocument.CreateRecovered(Entry.SourceFile,
      Entry.CopyFile, Entry.RootClassName, Entry.RootKind);
    try
      Recovered.Designer.WriteTo(Written);
    finally
      Recovered.Free;
    end;
    Assert.IsTrue(SameBytes(Entry.CopyFile, Written, Where),
      'a recovered document does not save what it was recovered from: ' + Where);
  finally
    DropRecovered(Entry);
    TFile.Delete(Written);
  end;
end;

procedure TRecoveryTests.DiscardingTakesTheEntryAway;
var
  Document: TLoadedDocument;
  Source, Folder: string;
  Entry: TRecoveryEntry;
begin
  BeginDesignerSession;
  Source := FixtureFile(Fixture);
  Document := TLoadedDocument.Create(Source);
  try
    KeepAndEndSession(Document, Source, Folder);
    Assert.IsTrue(OfferedFor(Folder, Source, Entry), 'nothing was left to discard');
    DropRecovered(Entry);
    Assert.IsFalse(TFile.Exists(Entry.CopyFile), 'the copy is still there');
    Assert.IsFalse(TFile.Exists(Entry.NoteFile), 'the note is still there');
    Assert.IsFalse(TDirectory.Exists(Folder),
      'the last entry went but its session folder stayed');
  finally
    Document.Free;
  end;
end;

procedure TRecoveryTests.NothingIsLeftWhenEverythingWasForgotten;
var
  Document: TLoadedDocument;
  Journal: TRecoveryJournal;
  Source, Failure, Folder: string;
  Entry: TRecoveryEntry;
begin
  BeginDesignerSession;
  Source := FixtureFile(Fixture);
  Document := TLoadedDocument.Create(Source);
  try
    Journal := TRecoveryJournal.Create;
    try
      Folder := Journal.Folder;
      Assert.IsTrue(Journal.Keep(Source, Document.Designer.RootClassName,
        Document.Designer.RootKind, Document.Designer.WriteTo, Failure),
        Failure);
      Journal.Forget(Source);
    finally
      Journal.Free;
    end;
    Assert.IsFalse(TDirectory.Exists(Folder),
      'a session that ended with nothing unsaved left its folder behind');
    Assert.IsFalse(OfferedFor(Folder, Source, Entry),
      'a document nobody lost was offered back');
  finally
    Document.Free;
  end;
end;

// AConfigured is the IntervalSeconds value written under the test key, empty
// for a key that does not exist at all; AExpected covers the 30-second
// default, zero for switched off, the 5-second floor, and a configured value
// at or above the floor read back unchanged.
procedure TRecoveryTests.TheIntervalIsReadFromTheSettings(
  const AConfigured: string; AExpected: Integer);
var
  Registry: TRegistry;
  KeyPath: string;

  procedure DropKey;
  begin
    Registry := TRegistry.Create(KEY_READ or KEY_WRITE);
    try
      Registry.RootKey := HKEY_CURRENT_USER;
      Registry.DeleteKey(KeyPath);
    finally
      Registry.Free;
    end;
  end;

begin
  KeyPath := SettingsKey(IntervalTestKey);
  DropKey;
  try
    if AConfigured <> '' then
    begin
      Registry := TRegistry.Create(KEY_READ or KEY_WRITE);
      try
        Registry.RootKey := HKEY_CURRENT_USER;
        Assert.IsTrue(Registry.OpenKey(KeyPath, True), 'the test key opens');
        Registry.WriteInteger(IntervalValue, StrToInt(AConfigured));
      finally
        Registry.Free;
      end;
    end;
    Assert.AreEqual(AExpected, RecoveryInterval(KeyPath));
  finally
    DropKey;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TRecoveryTests);

end.
