// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.SearchPath;

// Covers the search path that locates form files outside the document's own
// directory: SplitSearchPath, TakeSearchPathArgument, the per-document
// override and the ancestor chain resolved through it. Also covers
// DfmFileRootHeader on a binary resource .dfm and on ANSI text bytes, on a
// file in the test's own temp directory and with no search path set.
//
// The load tests start the designer session and copy the vfi_child and
// vfi_base fixtures into two separate directories below TPath.GetTempPath,
// which they delete again. The process-wide default search path is restored
// in a finally; the per-document overrides are removed by the tests that
// set them.

interface

uses
  DUnitX.TestFramework;

type
  // Covers quoted and empty list entries, a bare trailing option, an
  // override falling back to the default, an ancestor found and left
  // unfound, and a header read from a resource wrapper and from ANSI bytes.
  [TestFixture]
  TSearchPathTests = class
  public
    [Test]
    procedure AListSplitsAtSemicolonsAndKeepsSpaces;
    [Test]
    procedure QuotedAndEmptyEntriesAreCleanedUp;
    [Test]
    procedure TheOptionAndItsValueAreTakenOffTheArguments;
    // A bare option in last position is removed and yields an empty value;
    // the argument before it stays.
    [Test]
    procedure ATrailingOptionWithoutAValueEatsNoFileName;
    [Test]
    procedure ADocumentOverrideBeatsTheDefaultAndClearsBackToIt;
    // The child root is declared "inherited", so Prepare takes the root kind
    // from the resolved ancestor chain; a drForm result means vfi_base.dfm
    // was located through the search path.
    [Test]
    procedure AnAncestorIsFoundThroughTheSearchPath;
    [Test]
    procedure WithoutTheSearchPathTheAncestorStaysMissing;
    [Test]
    procedure AProbeReadsTheHeaderOfAClassicBinaryDfm;
    [Test]
    procedure AProbeReadsAnAnsiTextHeaderWithoutRaising;
    [Test]
    procedure ABinaryAncestorOnTheSearchPathIsStreamed;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Core.SearchPath,
  Vallenta.FormEditor.Streaming.Ancestors,
  Vallenta.FormEditor.Streaming.RootClassifier,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Tests.Environment;

procedure TSearchPathTests.AListSplitsAtSemicolonsAndKeepsSpaces;
var
  Paths: TArray<string>;
begin
  Paths := SplitSearchPath('C:\Base;D:\Shared Forms\User');
  Assert.AreEqual(2, Length(Paths));
  Assert.AreEqual('C:\Base', Paths[0]);
  Assert.AreEqual('D:\Shared Forms\User', Paths[1]);
end;

procedure TSearchPathTests.QuotedAndEmptyEntriesAreCleanedUp;
var
  Paths: TArray<string>;
begin
  Paths := SplitSearchPath(' "C:\Spaced Dir" ;;C:\Plain; ');
  Assert.AreEqual(2, Length(Paths));
  Assert.AreEqual('C:\Spaced Dir', Paths[0]);
  Assert.AreEqual('C:\Plain', Paths[1]);
end;

procedure TSearchPathTests.TheOptionAndItsValueAreTakenOffTheArguments;
var
  Arguments: TArray<string>;
begin
  Arguments := ['--search-path', 'C:\A;C:\B', 'C:\Work\Unit1.dfm'];
  Assert.AreEqual('C:\A;C:\B', TakeSearchPathArgument(Arguments));
  Assert.AreEqual(1, Length(Arguments), 'option and value were not removed');
  Assert.AreEqual('C:\Work\Unit1.dfm', Arguments[0]);
end;

procedure TSearchPathTests.ATrailingOptionWithoutAValueEatsNoFileName;
var
  Arguments: TArray<string>;
begin
  Arguments := ['C:\Work\Unit1.dfm', '--search-path'];
  Assert.AreEqual('', TakeSearchPathArgument(Arguments));
  Assert.AreEqual(1, Length(Arguments), 'the bare option was not removed');
  Assert.AreEqual('C:\Work\Unit1.dfm', Arguments[0]);
end;

procedure TSearchPathTests.ADocumentOverrideBeatsTheDefaultAndClearsBackToIt;
const
  Document = 'C:\Work\Unit1.dfm';
begin
  SetDefaultSearchPath(['C:\Default']);
  try
    Assert.AreEqual('C:\Default', SearchPathFor(Document)[0]);
    NoteSearchPathFor(Document, ['C:\Special']);
    Assert.AreEqual('C:\Special', SearchPathFor(Document)[0]);
    Assert.AreEqual('C:\Default', SearchPathFor('C:\Work\Other.dfm')[0],
      'the override leaked onto another document');
    NoteSearchPathFor(Document, nil);
    Assert.AreEqual('C:\Default', SearchPathFor(Document)[0],
      'clearing the override must fall back to the default');
  finally
    SetDefaultSearchPath(nil);
  end;
end;

// Copies the fixture child form and its base form, each with its companion
// .pas unit, into two separate temp directories: the load reaches the base
// only through a search path, and its class name only through that unit.
procedure CopyFixturePair(out AChildDir, ABaseDir, AChildFile: string);

  procedure CopyInto(const ADirectory, AName: string);
  begin
    TFile.Copy(FixtureFile(AName), TPath.Combine(ADirectory, AName), True);
  end;

begin
  AChildDir := TPath.Combine(TPath.GetTempPath, 'vsfe_searchpath_child');
  ABaseDir := TPath.Combine(TPath.GetTempPath, 'vsfe_searchpath_base');
  TDirectory.CreateDirectory(AChildDir);
  TDirectory.CreateDirectory(ABaseDir);
  CopyInto(AChildDir, 'vfi_child.dfm');
  CopyInto(AChildDir, 'vfi_child.pas');
  CopyInto(ABaseDir, 'vfi_base.dfm');
  CopyInto(ABaseDir, 'vfi_base.pas');
  AChildFile := TPath.Combine(AChildDir, 'vfi_child.dfm');
end;

procedure DropFixturePair(const AChildDir, ABaseDir: string);
begin
  TDirectory.Delete(AChildDir, True);
  TDirectory.Delete(ABaseDir, True);
end;

// Writes ASourceTextDfm to ATarget as a binary TPF0 stream inside the
// 16-bit resource header TStream.ReadResHeader skips: $FF marker, type
// word, NUL-terminated resource name, flags word, size.
procedure WriteBinaryResourceDfm(const ASourceTextDfm, ATarget: string);
var
  Text, Binary, Output: TMemoryStream;
  Name: TBytes;
  Marker: Byte;
  TypeWord, Flags: Word;
  Size: Cardinal;
begin
  Text := TMemoryStream.Create;
  Binary := TMemoryStream.Create;
  Output := TMemoryStream.Create;
  try
    Text.LoadFromFile(ASourceTextDfm);
    Text.Position := 0;
    ObjectTextToBinary(Text, Binary);
    Marker := $FF;
    Output.WriteBuffer(Marker, SizeOf(Marker));
    TypeWord := 10; // RT_RCDATA
    Output.WriteBuffer(TypeWord, SizeOf(TypeWord));
    Name := TEncoding.ANSI.GetBytes('TVFIBASE'#0);
    Output.WriteBuffer(Name[0], Length(Name));
    Flags := $1030;
    Output.WriteBuffer(Flags, SizeOf(Flags));
    Size := Binary.Size;
    Output.WriteBuffer(Size, SizeOf(Size));
    Binary.Position := 0;
    Output.CopyFrom(Binary, 0);
    Output.SaveToFile(ATarget);
  finally
    Output.Free;
    Binary.Free;
    Text.Free;
  end;
end;

procedure TSearchPathTests.AnAncestorIsFoundThroughTheSearchPath;
var
  ChildDir, BaseDir, ChildFile: string;
  Log: TDesignLog;
  Loader: TFormLoader;
begin
  BeginDesignerSession;
  CopyFixturePair(ChildDir, BaseDir, ChildFile);
  try
    NoteSearchPathFor(ChildFile, [BaseDir]);
    try
      Log := TDesignLog.Create;
      try
        Loader := TFormLoader.Create(Log);
        try
          Loader.Prepare(ChildFile);
          Assert.AreEqual(Ord(drForm), Ord(Loader.RootKind),
            'the chain did not reach the base class through the search path');
        finally
          Loader.Free;
        end;
      finally
        Log.Free;
      end;
    finally
      NoteSearchPathFor(ChildFile, nil);
    end;
  finally
    DropFixturePair(ChildDir, BaseDir);
  end;
end;

procedure TSearchPathTests.WithoutTheSearchPathTheAncestorStaysMissing;
var
  ChildDir, BaseDir, ChildFile: string;
  Log: TDesignLog;
  Loader: TFormLoader;
begin
  BeginDesignerSession;
  CopyFixturePair(ChildDir, BaseDir, ChildFile);
  try
    Log := TDesignLog.Create;
    try
      Loader := TFormLoader.Create(Log);
      try
        Assert.WillRaise(
          procedure
          begin
            Loader.Prepare(ChildFile);
          end, EAncestorChainError,
          'an ancestor in an unnamed directory must stay unfound');
      finally
        Loader.Free;
      end;
    finally
      Log.Free;
    end;
  finally
    DropFixturePair(ChildDir, BaseDir);
  end;
end;

procedure TSearchPathTests.AProbeReadsTheHeaderOfAClassicBinaryDfm;
var
  Dir, Target: string;
  Header: TDfmRootHeader;
begin
  Dir := TPath.Combine(TPath.GetTempPath, 'vsfe_searchpath_binary');
  TDirectory.CreateDirectory(Dir);
  try
    Target := TPath.Combine(Dir, 'vfi_base.dfm');
    WriteBinaryResourceDfm(FixtureFile('vfi_base.dfm'), Target);
    Header := DfmFileRootHeader(Target);
    Assert.AreEqual('TVfiBase', Header.ClassName,
      'the class behind the resource wrapper was not read');
    Assert.AreEqual(Ord(rkObject), Ord(Header.Kind),
      'a wrapped plain root was taken for something else');
  finally
    TDirectory.Delete(Dir, True);
  end;
end;

procedure TSearchPathTests.AProbeReadsAnAnsiTextHeaderWithoutRaising;
var
  Dir, Target: string;
  Header: TDfmRootHeader;
begin
  Dir := TPath.Combine(TPath.GetTempPath, 'vsfe_searchpath_ansi');
  TDirectory.CreateDirectory(Dir);
  try
    Target := TPath.Combine(Dir, 'ansi_form.dfm');
    // Raw bytes because TFile.WriteAllText encodes UTF-8: the file must
    // hold the umlaut as a single ANSI byte, which is not valid UTF-8.
    TFile.WriteAllBytes(Target, TEncoding.ANSI.GetBytes(
      'object Form1: TForm1'#13#10 +
      '  Caption = ''Gr'#246'sse'''#13#10 +
      'end'#13#10));
    Header := DfmFileRootHeader(Target);
    Assert.AreEqual('TForm1', Header.ClassName,
      'the header of an ANSI text form file was not read');
  finally
    TDirectory.Delete(Dir, True);
  end;
end;

procedure TSearchPathTests.ABinaryAncestorOnTheSearchPathIsStreamed;
var
  ChildDir, BaseDir, ChildFile: string;
  Log: TDesignLog;
  Loader: TFormLoader;
  Document: TDesignDocument;
  Sources: TArray<TSourceFile>;
begin
  BeginDesignerSession;
  CopyFixturePair(ChildDir, BaseDir, ChildFile);
  // No fixture is stored in the binary format, so the text base copied above
  // is overwritten with the same form written as a binary resource .dfm.
  WriteBinaryResourceDfm(FixtureFile('vfi_base.dfm'),
    TPath.Combine(BaseDir, 'vfi_base.dfm'));
  try
    NoteSearchPathFor(ChildFile, [BaseDir]);
    try
      Log := TDesignLog.Create;
      try
        Loader := TFormLoader.Create(Log);
        try
          Loader.Prepare(ChildFile);
          Document := CreateDesignDocument(Loader.RootKind);
          try
            Loader.StreamInto(Document.Root);
            Sources := Loader.SourceFiles;
          finally
            FreeDesignDocument(Document);
          end;
          Assert.AreEqual(1, Length(Sources),
            'exactly the base file is read besides the document');
          Assert.AreEqual('vfi_base.dfm',
            ExtractFileName(Sources[0].FileName));
          Assert.IsTrue(SameText(BaseDir, ExtractFileDir(Sources[0].FileName)),
            'the base was not read from the search-path directory');
        finally
          Loader.Free;
        end;
      finally
        Log.Free;
      end;
    finally
      NoteSearchPathFor(ChildFile, nil);
    end;
  finally
    DropFixturePair(ChildDir, BaseDir);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSearchPathTests);

end.
