// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.SourceFiles;

// Covers TFormLoader.SourceFiles: the ancestor and frame files a load reads
// besides the document - each an absolute path listed once and tagged
// skAncestor or skFrame.
//
// No fixture names those files: the ancestor chain and the frame file are
// resolved by indexing the fixture directory for the form file declaring
// the class, so each case needs its fixtures in that one directory.

interface

uses
  DUnitX.TestFramework;

type
  // Covers the source files a load reports for a plain form, a descendant,
  // a form holding a frame and a frame holding a frame.
  [TestFixture]
  TSourceFilesTests = class
  public
    [Test]
    procedure ADocumentBuiltOnNothingIsMadeOfNothingElse;
    [Test]
    procedure ADescendantNamesTheFormItIsBuiltOn;
    [Test]
    procedure AHostNamesTheFileItsFrameComesFrom;
    [Test]
    procedure AFileReadTwiceIsNamedOnce;
  end;

implementation

uses
  System.SysUtils,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Tests.Environment;

// Prepare leaves the list empty; ancestors and frame files are read during
// StreamInto.
function SourceFilesOf(const AFixture: string): TArray<TSourceFile>;
var
  Log: TDesignLog;
  Loader: TFormLoader;
  Document: TDesignDocument;
begin
  BeginDesignerSession;
  Log := TDesignLog.Create;
  try
    Loader := TFormLoader.Create(Log);
    try
      Loader.Prepare(FixtureFile(AFixture));
      Document := CreateDesignDocument(Loader.RootKind);
      try
        Loader.StreamInto(Document.Root);
        Result := Loader.SourceFiles;
      finally
        FreeDesignDocument(Document);
      end;
    finally
      Loader.Free;
    end;
  finally
    Log.Free;
  end;
end;

function NamedOnce(const ASources: TArray<TSourceFile>;
  const AFileName: string; out AKind: TSourceKind): Boolean;
var
  Source: TSourceFile;
  Found: Integer;
begin
  Found := 0;
  AKind := skAncestor;
  for Source in ASources do
    if SameText(ExtractFileName(Source.FileName), AFileName) then
    begin
      AKind := Source.Kind;
      Inc(Found);
    end;
  Result := Found = 1;
end;

procedure TSourceFilesTests.ADocumentBuiltOnNothingIsMadeOfNothingElse;
begin
  Assert.AreEqual(0, Length(SourceFilesOf('basic_form.dfm')),
    'a form that descends from nothing and holds no frame named another file');
end;

procedure TSourceFilesTests.ADescendantNamesTheFormItIsBuiltOn;
var
  Kind: TSourceKind;
begin
  Assert.IsTrue(NamedOnce(SourceFilesOf('vfi_child.dfm'), 'vfi_base.dfm', Kind),
    'the form this one is built on was not named exactly once');
  Assert.AreEqual(Ord(skAncestor), Ord(Kind),
    'the form it is built on was named as something else');
end;

procedure TSourceFilesTests.AHostNamesTheFileItsFrameComesFrom;
var
  Kind: TSourceKind;
begin
  Assert.IsTrue(NamedOnce(SourceFilesOf('frame_host.dfm'), 'frame_child.dfm',
    Kind), 'the file the frame comes from was not named exactly once');
  Assert.AreEqual(Ord(skFrame), Ord(Kind),
    'the file the frame comes from was named as something else');
end;

// TFrameInstances streams the file of one frame instance twice: once as the
// pristine diff base, once as the instance. frame_outer.dfm holds one.
procedure TSourceFilesTests.AFileReadTwiceIsNamedOnce;
var
  Sources: TArray<TSourceFile>;
  Source: TSourceFile;
  Seen: TArray<string>;
  Present: string;
begin
  Sources := SourceFilesOf('frame_outer.dfm');
  for Source in Sources do
  begin
    for Present in Seen do
      Assert.IsFalse(SameText(Present, Source.FileName),
        'the same file was named twice: ' + Source.FileName);
    Seen := Seen + [Source.FileName];
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSourceFilesTests);

end.
