// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.ClassIndex;

// Resolution of a class name to a form file and a unit when the search path
// holds several candidates: selection by the units in scope, units read from
// the search path, classification of an undescribed plain ancestor from its
// properties, uses clause parsing, duplicate directories, re-reading a changed
// file, the report of an undecided choice, and the file of a linked module.
//
// The layout reproduces a project whose form files are also copied, without
// their units, into a directory ahead of the sources on the search path.
// Setup creates three directories under the temp path - the document's, the
// copy and the sources - and TearDown deletes them. No designer session is
// started; nothing is streamed.

interface

uses
  DUnitX.TestFramework;

type
  // Covers TDfmClassIndex.FileFor, FileForInstance, UnitFiles and SearchIn,
  // ReadUnitDeclaration, and TAncestorChain across those directories.
  [TestFixture]
  TClassIndexTests = class
  private
    FDocumentDir: string;
    FCopyDir: string;
    FSourceDir: string;
    FClashes: TArray<string>;
    function Put(const ADirectory, AName, AContent: string): string;
    procedure NoteClash(const AName: string; AByInstance: Boolean;
      const AFiles: TArray<string>);
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;
    // Two files declare the ancestor class; the file in the copy directory,
    // searched before the source directory, is passed over for the file
    // named after a unit in the child's uses clause.
    [Test]
    procedure TheUnitInScopePicksAmongFilesDeclaringTheClass;
    // The ancestor form files are read from the copy directory and their
    // units from the source directory; the base's unit declares a data
    // module, which its properties do not identify.
    [Test]
    procedure AnAncestorsUnitIsReadFromTheSearchPath;
    // No loaded package and no unit declares the base class of the plain
    // ancestor; a size without a client area classifies it as a data module.
    [Test]
    procedure APlainAncestorNothingNamesIsClassifiedFromItsProperties;
    [Test]
    procedure AUsesClauseIsReadPastCommentsStringsAndPaths;
    [Test]
    procedure ADirectoryListedTwiceIsKeptOnce;
    // Root headers are cached for the process; a file rewritten after its
    // header was read is read again.
    [Test]
    procedure AFileChangedSinceItWasReadIsReadAgain;
    // Two files declare the class and no unit decides: the first is taken
    // and the choice reported once. A unit in scope decides without a report.
    [Test]
    procedure AChoiceNoUnitDecidesIsReportedOnce;
    // Two files have a root of the module's name; the one named after a unit
    // in scope is taken although the other comes first in search order.
    [Test]
    procedure AModuleIsTakenFromTheFileOfAUnitInScope;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  Vallenta.FormEditor.Streaming.Ancestors,
  Vallenta.FormEditor.Streaming.RootClassifier;

const
  // Form files and units written by the cases.
  PickChildDfm =
    'inherited PickChild: TCiPickChild'#13#10 +
    'end'#13#10;

  PickChildUnit =
    'unit ci_pick_child;'#13#10 +
    'interface'#13#10 +
    'uses Vcl.Forms, ci_pick_main;'#13#10 +
    'type'#13#10 +
    '  TCiPickChild = class(TCiPickMain)'#13#10 +
    '  end;'#13#10 +
    'implementation'#13#10 +
    'end.'#13#10;

  // The same body serves both files declaring TCiPickMain; only the file
  // names and object names tell them apart.
  PickMainDfm =
    'object %s: TCiPickMain'#13#10 +
    '  Left = 0'#13#10 +
    '  Top = 0'#13#10 +
    '  Caption = ''Pick'''#13#10 +
    '  ClientHeight = 120'#13#10 +
    '  ClientWidth = 200'#13#10 +
    '  TextHeight = 15'#13#10 +
    'end'#13#10;

  PickMainUnit =
    'unit %s;'#13#10 +
    'interface'#13#10 +
    'uses Vcl.Forms;'#13#10 +
    'type'#13#10 +
    '  TCiPickMain = class(TForm)'#13#10 +
    '  end;'#13#10 +
    'implementation'#13#10 +
    'end.'#13#10;

  PathChildDfm =
    'inherited PathChild: TCiPathChild'#13#10 +
    'end'#13#10;

  PathChildUnit =
    'unit ci_path_child;'#13#10 +
    'interface'#13#10 +
    'uses System.Classes, ci_path_middle;'#13#10 +
    'type'#13#10 +
    '  TCiPathChild = class(TCiPathMiddle)'#13#10 +
    '  end;'#13#10 +
    'implementation'#13#10 +
    'end.'#13#10;

  PathMiddleDfm =
    'inherited PathMiddle: TCiPathMiddle'#13#10 +
    'end'#13#10;

  PathMiddleUnit =
    'unit ci_path_middle;'#13#10 +
    'interface'#13#10 +
    'uses System.Classes, ci_path_base;'#13#10 +
    'type'#13#10 +
    '  TCiPathMiddle = class(TCiPathBase)'#13#10 +
    '  end;'#13#10 +
    'implementation'#13#10 +
    'end.'#13#10;

  // No property identifies a root kind, so classification by properties
  // alone yields an assumed form.
  PathBaseDfm =
    'object PathBase: TCiPathBase'#13#10 +
    '  Tag = 1'#13#10 +
    'end'#13#10;

  PathBaseUnit =
    'unit ci_path_base;'#13#10 +
    'interface'#13#10 +
    'uses System.Classes;'#13#10 +
    'type'#13#10 +
    '  TCiPathBase = class(TDataModule)'#13#10 +
    '  end;'#13#10 +
    'implementation'#13#10 +
    'end.'#13#10;

  ModChildDfm =
    'inherited ModChild: TCiModChild'#13#10 +
    'end'#13#10;

  ModChildUnit =
    'unit ci_mod_child;'#13#10 +
    'interface'#13#10 +
    'uses System.Classes, ci_mod_base;'#13#10 +
    'type'#13#10 +
    '  TCiModChild = class(TCiModBase)'#13#10 +
    '  end;'#13#10 +
    'implementation'#13#10 +
    'end.'#13#10;

  ModBaseDfm =
    'object ModBase: TCiModBase'#13#10 +
    '  Height = 150'#13#10 +
    '  Width = 215'#13#10 +
    'end'#13#10;

  // A class declaration or unit name in every position where it is not one: a
  // line comment, a brace comment, a directive, a parenthesis-star comment, a
  // string literal, an "in" path, and the implementation's own uses clause,
  // which is not in scope for a class declared in the interface.
  TrickyUnit =
    'unit ci_tricky;'#13#10 +
    '// TCiTricky = class(TCommentedOut)'#13#10 +
    'interface'#13#10 +
    'uses'#13#10 +
    '  {$IFDEF MSWINDOWS} Winapi.Windows, {$ENDIF}'#13#10 +
    '  Vcl.Forms, ci_tricky_base in ''..\base\ci_tricky_base.pas'','#13#10 +
    '  (* ci_retired, *) ci_frames // , ci_not_a_unit'#13#10 +
    '  ;'#13#10 +
    'const'#13#10 +
    '  Decoy = ''uses ci_in_a_string; TCiTricky = class(TInAString)'';'#13#10 +
    'type'#13#10 +
    '  { TCiTricky = class(TInABrace) }'#13#10 +
    '  TCiTricky = class(ci_tricky_base.TCiTrickyBase)'#13#10 +
    '  end;'#13#10 +
    'implementation'#13#10 +
    'uses ci_implementation_only;'#13#10 +
    'end.'#13#10;

  // Two unrelated forms of one class name.
  TwinDfm =
    'object %s: TCiTwin'#13#10 +
    'end'#13#10;

  // A module root; the class differs, the object name does not.
  ModuleDfm =
    'object CiModule: %s'#13#10 +
    '  Height = 150'#13#10 +
    '  Width = 215'#13#10 +
    'end'#13#10;

procedure TClassIndexTests.Setup;
begin
  FClashes := nil;
  FDocumentDir := TPath.Combine(TPath.GetTempPath, 'vsfe_classindex_document');
  FCopyDir := TPath.Combine(TPath.GetTempPath, 'vsfe_classindex_copy');
  FSourceDir := TPath.Combine(TPath.GetTempPath, 'vsfe_classindex_source');
  TDirectory.CreateDirectory(FDocumentDir);
  TDirectory.CreateDirectory(FCopyDir);
  TDirectory.CreateDirectory(FSourceDir);
end;

procedure TClassIndexTests.TearDown;
begin
  if TDirectory.Exists(FDocumentDir) then
    TDirectory.Delete(FDocumentDir, True);
  if TDirectory.Exists(FCopyDir) then
    TDirectory.Delete(FCopyDir, True);
  if TDirectory.Exists(FSourceDir) then
    TDirectory.Delete(FSourceDir, True);
end;

function TClassIndexTests.Put(const ADirectory, AName, AContent: string): string;
begin
  Result := TPath.Combine(ADirectory, AName);
  TFile.WriteAllText(Result, AContent);
end;

procedure TClassIndexTests.NoteClash(const AName: string; AByInstance: Boolean;
  const AFiles: TArray<string>);
var
  Kind: string;
begin
  if AByInstance then
    Kind := 'root'
  else
    Kind := 'class';
  FClashes := FClashes + [Kind + ' ' + AName + ': ' + string.Join(',', AFiles)];
end;

procedure TClassIndexTests.TheUnitInScopePicksAmongFilesDeclaringTheClass;
var
  Index: TDfmClassIndex;
  Chain: TAncestorChain;
  ChildFile, Named: string;
begin
  ChildFile := Put(FDocumentDir, 'ci_pick_child.dfm', PickChildDfm);
  Put(FDocumentDir, 'ci_pick_child.pas', PickChildUnit);
  Put(FCopyDir, 'ci_sample.dfm', Format(PickMainDfm, ['SampleForm']));
  Put(FCopyDir, 'ci_sample.pas', Format(PickMainUnit, ['ci_sample']));
  Named := Put(FSourceDir, 'ci_pick_main.dfm', Format(PickMainDfm, ['MainForm']));
  Put(FSourceDir, 'ci_pick_main.pas', Format(PickMainUnit, ['ci_pick_main']));
  Index := TDfmClassIndex.Create;
  try
    Index.SearchIn(FDocumentDir, [FCopyDir, FSourceDir]);
    Chain := TAncestorChain.Create(nil, Index);
    try
      Chain.Resolve(ChildFile, 'TCiPickChild');
      Assert.AreEqual(1, Length(Chain.Files),
        'the ancestor form file was not taken into the chain');
      Assert.AreEqual(Named, Chain.Files[0],
        'the file named after the unit the child uses was passed over');
      Assert.AreEqual('TForm', Chain.BaseClass);
    finally
      Chain.Free;
    end;
  finally
    Index.Free;
  end;
end;

procedure TClassIndexTests.AnAncestorsUnitIsReadFromTheSearchPath;
var
  Index: TDfmClassIndex;
  Chain: TAncestorChain;
  ChildFile, CopiedBase, CopiedMiddle: string;
begin
  ChildFile := Put(FDocumentDir, 'ci_path_child.dfm', PathChildDfm);
  Put(FDocumentDir, 'ci_path_child.pas', PathChildUnit);
  CopiedMiddle := Put(FCopyDir, 'ci_path_middle.dfm', PathMiddleDfm);
  CopiedBase := Put(FCopyDir, 'ci_path_base.dfm', PathBaseDfm);
  Put(FSourceDir, 'ci_path_middle.dfm', PathMiddleDfm);
  Put(FSourceDir, 'ci_path_middle.pas', PathMiddleUnit);
  Put(FSourceDir, 'ci_path_base.dfm', PathBaseDfm);
  Put(FSourceDir, 'ci_path_base.pas', PathBaseUnit);
  Index := TDfmClassIndex.Create;
  try
    Index.SearchIn(FDocumentDir, [FCopyDir, FSourceDir]);
    Chain := TAncestorChain.Create(nil, Index);
    try
      Chain.Resolve(ChildFile, 'TCiPathChild');
      Assert.AreEqual(2, Length(Chain.Files),
        'the chain did not reach the base through the copied middle form');
      Assert.AreEqual(CopiedBase, Chain.Files[0]);
      Assert.AreEqual(CopiedMiddle, Chain.Files[1]);
      Assert.AreEqual('TDataModule', Chain.BaseClass,
        'the base''s unit on the search path was not read');
      Assert.AreEqual(Ord(drDataModule), Ord(Chain.BaseKind));
    finally
      Chain.Free;
    end;
  finally
    Index.Free;
  end;
end;

procedure TClassIndexTests.APlainAncestorNothingNamesIsClassifiedFromItsProperties;
var
  Index: TDfmClassIndex;
  Chain: TAncestorChain;
  ChildFile, BaseFile: string;
begin
  ChildFile := Put(FDocumentDir, 'ci_mod_child.dfm', ModChildDfm);
  Put(FDocumentDir, 'ci_mod_child.pas', ModChildUnit);
  BaseFile := Put(FCopyDir, 'ci_mod_base.dfm', ModBaseDfm);
  Index := TDfmClassIndex.Create;
  try
    Index.SearchIn(FDocumentDir, [FCopyDir, FSourceDir]);
    Chain := TAncestorChain.Create(nil, Index);
    try
      Chain.Resolve(ChildFile, 'TCiModChild');
      Assert.AreEqual(1, Length(Chain.Files));
      Assert.AreEqual(BaseFile, Chain.Files[0]);
      Assert.AreEqual(Ord(drDataModule), Ord(Chain.BaseKind),
        'a sized root without a client area was not read as a data module');
      Assert.AreEqual('TDataModule', Chain.BaseClass);
    finally
      Chain.Free;
    end;
  finally
    Index.Free;
  end;
end;

procedure TClassIndexTests.AUsesClauseIsReadPastCommentsStringsAndPaths;
var
  Declaration: TUnitDeclaration;
  UnitFile: string;
begin
  UnitFile := Put(FSourceDir, 'ci_tricky.pas', TrickyUnit);
  Assert.IsTrue(ReadUnitDeclaration(UnitFile, 'TCiTricky', Declaration),
    'the class declaration was not found');
  Assert.AreEqual(UnitFile, Declaration.FileName);
  Assert.AreEqual('TCiTrickyBase', Declaration.AncestorClass);
  // Units are listed in reverse declaration order, the order in which the
  // compiler resolves a name.
  Assert.AreEqual('ci_frames,ci_tricky_base,Vcl.Forms,Winapi.Windows',
    string.Join(',', Declaration.UsedUnits));
  Assert.IsFalse(ReadUnitDeclaration(UnitFile, 'TCiNotDeclared', Declaration));
  Assert.AreEqual(0, Length(Declaration.UsedUnits),
    'a failed read left units behind');
end;

procedure TClassIndexTests.ADirectoryListedTwiceIsKeptOnce;
var
  Index: TDfmClassIndex;
begin
  Index := TDfmClassIndex.Create;
  try
    Index.SearchIn('C:\Work\Forms', ['C:\Work\Lib', 'c:\work\lib\',
      'C:\Work\Forms\', '', 'C:\Work\Other', 'C:\Work\Lib']);
    Assert.AreEqual('C:\Work\Lib,C:\Work\Other',
      string.Join(',', Index.ExtraDirectories));
  finally
    Index.Free;
  end;
end;

procedure TClassIndexTests.AFileChangedSinceItWasReadIsReadAgain;
var
  Index: TDfmClassIndex;
  FileName: string;
begin
  FileName := Put(FCopyDir, 'ci_changing.dfm',
    'object Changing: TCiBefore'#13#10'end'#13#10);
  Index := TDfmClassIndex.Create;
  try
    Index.SearchIn(FDocumentDir, [FCopyDir]);
    Assert.AreEqual(FileName, Index.FileFor('TCiBefore', [rkObject], []).FileName);
    // The longer class name changes the file size as well as the write time.
    Put(FCopyDir, 'ci_changing.dfm',
      'object Changing: TCiAfterTheChange'#13#10'end'#13#10);
    Index.SearchIn(FDocumentDir, [FCopyDir]);
    Assert.AreEqual('', Index.FileFor('TCiBefore', [rkObject], []).FileName,
      'the header read before the change was answered again');
    Assert.AreEqual(FileName,
      Index.FileFor('TCiAfterTheChange', [rkObject], []).FileName);
  finally
    Index.Free;
  end;
end;

procedure TClassIndexTests.AChoiceNoUnitDecidesIsReportedOnce;
var
  Index: TDfmClassIndex;
  First, Second: string;
begin
  First := Put(FDocumentDir, 'ci_twin_one.dfm', Format(TwinDfm, ['TwinOne']));
  Second := Put(FCopyDir, 'ci_twin_two.dfm', Format(TwinDfm, ['TwinTwo']));
  Index := TDfmClassIndex.Create;
  try
    Index.OnClash := NoteClash;
    Index.SearchIn(FDocumentDir, [FCopyDir]);
    Assert.AreEqual(First, Index.FileFor('TCiTwin', [rkObject], []).FileName);
    Assert.AreEqual(First, Index.FileFor('TCiTwin', [rkObject], []).FileName);
    Assert.AreEqual('class TCiTwin: ' + First + ',' + Second,
      string.Join('|', FClashes), 'the choice was not reported exactly once');
    FClashes := nil;
    Assert.AreEqual(Second,
      Index.FileFor('TCiTwin', [rkObject], ['ci_twin_two']).FileName);
    Assert.AreEqual(0, Length(FClashes), 'a choice a unit made was reported');
  finally
    Index.Free;
  end;
end;

procedure TClassIndexTests.AModuleIsTakenFromTheFileOfAUnitInScope;
var
  Index: TDfmClassIndex;
  First, Named: string;
begin
  First := Put(FDocumentDir, 'ci_module_copy.dfm',
    Format(ModuleDfm, ['TCiModuleCopy']));
  Named := Put(FCopyDir, 'ci_module.dfm', Format(ModuleDfm, ['TCiModule']));
  Index := TDfmClassIndex.Create;
  try
    Index.OnClash := NoteClash;
    Index.SearchIn(FDocumentDir, [FCopyDir]);
    Assert.AreEqual(Named,
      Index.FileForInstance('CiModule', ['System.Classes', 'ci_module']));
    Assert.AreEqual(0, Length(FClashes), 'a choice a unit made was reported');
    Index.SearchIn(FDocumentDir, [FCopyDir]);
    Assert.AreEqual(First, Index.FileForInstance('CiModule', []));
    Assert.AreEqual('root CiModule: ' + First + ',' + Named,
      string.Join('|', FClashes), 'the choice by walk order was not reported');
  finally
    Index.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TClassIndexTests);

end.
