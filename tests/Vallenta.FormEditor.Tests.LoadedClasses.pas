// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.LoadedClasses;

// Ancestor class names resolved from the classes present in this process:
// LoadedClass, LoadedAncestorClass, and TAncestorChain over form files without
// a companion .pas unit, including the choice among several declaring files
// by the unit of a loaded class. TProbeLoadedBase and TProbeLoadedChild stand
// in for form classes supplied by a loaded design package.
//
// Setup registers TProbeRegistered in the streaming registry and creates two
// directories under the temp path; TearDown unregisters the class and
// deletes both directories.

interface

uses
  Vcl.Forms,
  System.Classes,
  DUnitX.TestFramework;

type
  // Form probe resolved by name through the RTTI walk in LoadedClass.
  TProbeLoadedBase = class(TForm)
  end;

  // Descendant form probe, resolved through the same RTTI walk.
  TProbeLoadedChild = class(TProbeLoadedBase)
  end;

  // Registered with RegisterClass in Setup, so GetClass resolves it before
  // the RTTI walk is reached.
  TProbeRegistered = class(TComponent)
  end;

  // Covers LoadedClass, LoadedAncestorClass and TAncestorChain resolution.
  [TestFixture]
  TLoadedClassesTests = class
  private
    FDocumentDir: string;
    FAncestorDir: string;
    function WriteDfm(const ADirectory, AName, AContent: string): string;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;
    [Test]
    procedure TheParentOfALoadedClassIsNamed;
    [Test]
    procedure ANameNothingLoadedCarriesIsNotNamed;
    [Test]
    procedure AClassWithoutAParentIsNotNamed;
    [Test]
    procedure ARegisteredClassIsNamedToo;
    [Test]
    procedure TheUnitHintFindsTheClassInThatUnit;
    [Test]
    procedure AUnitHintNamingAnotherUnitStillFindsTheClass;
    [Test]
    procedure AnAncestorWithNoUnitBesideItIsResolved;
    [Test]
    procedure AnAncestorThatIsNeitherLoadedNorBesideAUnitIsRefused;
    // Two files declare the loaded base class; the file named after the
    // class's unit is taken although the other comes first in search order.
    [Test]
    procedure TheUnitOfALoadedAncestorPicksItsFile;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Core.LoadedClasses,
  Vallenta.FormEditor.Streaming.Ancestors,
  Vallenta.FormEditor.Streaming.RootClassifier;

const
  // Name of this unit, in which the probe classes are compiled. A mismatch
  // makes TheUnitHintFindsTheClassInThatUnit pass without testing the hint.
  ThisUnit = 'Vallenta.FormEditor.Tests.LoadedClasses';

  // Text form fixtures for the probe classes. Only the first line is parsed
  // for the root declaration; the property lines below it are filler.
  BaseDfm =
    'object ProbeBaseForm: TProbeLoadedBase'#13#10 +
    '  Left = 0'#13#10 +
    '  Top = 0'#13#10 +
    '  Caption = ''Probe base'''#13#10 +
    '  ClientHeight = 240'#13#10 +
    '  ClientWidth = 400'#13#10 +
    '  TextHeight = 15'#13#10 +
    'end'#13#10;

  ChildDfm =
    'inherited ProbeChildForm: TProbeLoadedChild'#13#10 +
    '  Caption = ''Probe child'''#13#10 +
    '  TextHeight = 15'#13#10 +
    'end'#13#10;

  // Another form of the same class name, as an unrelated project would
  // declare it.
  DecoyBaseDfm =
    'object DecoyForm: TProbeLoadedBase'#13#10 +
    '  Left = 0'#13#10 +
    '  Top = 0'#13#10 +
    '  Caption = ''Decoy'''#13#10 +
    '  ClientHeight = 120'#13#10 +
    '  ClientWidth = 200'#13#10 +
    '  TextHeight = 15'#13#10 +
    'end'#13#10;

  // Same shape for class names not declared by any unit in this executable.
  StrangerBaseDfm =
    'object StrangerBaseForm: TProbeStrangerBase'#13#10 +
    '  Left = 0'#13#10 +
    '  Top = 0'#13#10 +
    '  Caption = ''Stranger base'''#13#10 +
    '  ClientHeight = 240'#13#10 +
    '  ClientWidth = 400'#13#10 +
    '  TextHeight = 15'#13#10 +
    'end'#13#10;

  StrangerChildDfm =
    'inherited StrangerChildForm: TProbeStrangerChild'#13#10 +
    '  Caption = ''Stranger child'''#13#10 +
    '  TextHeight = 15'#13#10 +
    'end'#13#10;

procedure TLoadedClassesTests.Setup;
begin
  RegisterClass(TProbeRegistered);
  FDocumentDir := TPath.Combine(TPath.GetTempPath, 'vsfe_loaded_document');
  FAncestorDir := TPath.Combine(TPath.GetTempPath, 'vsfe_loaded_ancestor');
  TDirectory.CreateDirectory(FDocumentDir);
  TDirectory.CreateDirectory(FAncestorDir);
end;

procedure TLoadedClassesTests.TearDown;
begin
  UnRegisterClass(TProbeRegistered);
  if TDirectory.Exists(FDocumentDir) then
    TDirectory.Delete(FDocumentDir, True);
  if TDirectory.Exists(FAncestorDir) then
    TDirectory.Delete(FAncestorDir, True);
end;

function TLoadedClassesTests.WriteDfm(const ADirectory, AName,
  AContent: string): string;
begin
  Result := TPath.Combine(ADirectory, AName);
  TFile.WriteAllText(Result, AContent, TEncoding.UTF8);
end;

procedure TLoadedClassesTests.TheParentOfALoadedClassIsNamed;
begin
  // TProbeLoadedBase and TProbeLoadedChild must be referenced by code
  // somewhere in the suite: smart linking drops an unreferenced class, and its
  // RTTI with it.
  Assert.AreEqual(TProbeLoadedBase, TClass(TProbeLoadedChild.ClassParent));
  Assert.AreEqual('TProbeLoadedBase',
    LoadedAncestorClass('TProbeLoadedChild'));
  Assert.AreEqual('TForm', LoadedAncestorClass('TProbeLoadedBase'));
end;

procedure TLoadedClassesTests.ANameNothingLoadedCarriesIsNotNamed;
begin
  Assert.AreEqual('', LoadedAncestorClass('TNoSuchClassIsCompiledHere'));
  Assert.IsNull(TObject(LoadedClass('TNoSuchClassIsCompiledHere')));
end;

procedure TLoadedClassesTests.AClassWithoutAParentIsNotNamed;
begin
  Assert.IsNotNull(TObject(LoadedClass('TObject')));
  Assert.AreEqual('', LoadedAncestorClass('TObject'));
end;

procedure TLoadedClassesTests.ARegisteredClassIsNamedToo;
begin
  Assert.AreEqual('TComponent', LoadedAncestorClass('TProbeRegistered'));
end;

procedure TLoadedClassesTests.TheUnitHintFindsTheClassInThatUnit;
begin
  Assert.AreEqual('TProbeLoadedBase',
    LoadedAncestorClass('TProbeLoadedChild', ThisUnit));
end;

procedure TLoadedClassesTests.AUnitHintNamingAnotherUnitStillFindsTheClass;
begin
  Assert.AreEqual('TProbeLoadedBase',
    LoadedAncestorClass('TProbeLoadedChild', 'SomeUnitThatDoesNotExist'));
end;

procedure TLoadedClassesTests.AnAncestorWithNoUnitBesideItIsResolved;
var
  Index: TDfmClassIndex;
  Chain: TAncestorChain;
  ChildFile: string;
begin
  // No .pas file is written beside either form file, so every ancestor name
  // comes from the loaded classes.
  ChildFile := WriteDfm(FDocumentDir, 'ProbeChild.dfm', ChildDfm);
  WriteDfm(FAncestorDir, 'ProbeBase.dfm', BaseDfm);
  Index := TDfmClassIndex.Create;
  try
    Index.SearchIn(FDocumentDir, [FAncestorDir]);
    Chain := TAncestorChain.Create(nil, Index);
    try
      Chain.Resolve(ChildFile, 'TProbeLoadedChild');
      Assert.AreEqual('TForm', Chain.BaseClass);
      Assert.AreEqual(Ord(drForm), Ord(Chain.BaseKind));
      Assert.AreEqual(1, Length(Chain.Files),
        'the ancestor form file was not taken into the chain');
      Assert.AreEqual('ProbeBase.dfm', ExtractFileName(Chain.Files[0]));
    finally
      Chain.Free;
    end;
  finally
    Index.Free;
  end;
end;

procedure TLoadedClassesTests.AnAncestorThatIsNeitherLoadedNorBesideAUnitIsRefused;
var
  Index: TDfmClassIndex;
  Chain: TAncestorChain;
  ChildFile: string;
begin
  ChildFile := WriteDfm(FDocumentDir, 'StrangerChild.dfm', StrangerChildDfm);
  WriteDfm(FAncestorDir, 'StrangerBase.dfm', StrangerBaseDfm);
  Index := TDfmClassIndex.Create;
  try
    Index.SearchIn(FDocumentDir, [FAncestorDir]);
    Chain := TAncestorChain.Create(nil, Index);
    try
      // Neither stranger class is compiled in and no .pas file is written,
      // so the message must name the file and both failed sources: a loaded
      // package and a unit StrangerChild.pas, beside it or on the path.
      Assert.WillRaiseWithMessage(
        procedure
        begin
          Chain.Resolve(ChildFile, 'TProbeStrangerChild');
        end,
        EAncestorChainError,
        '"TProbeStrangerChild" in ' + ChildFile + ' is built on another ' +
        'form, and neither a loaded package nor a unit StrangerChild.pas ' +
        'beside it or on the search path says which one. The designer ' +
        'needs it to read the form.');
    finally
      Chain.Free;
    end;
  finally
    Index.Free;
  end;
end;

procedure TLoadedClassesTests.TheUnitOfALoadedAncestorPicksItsFile;
var
  Index: TDfmClassIndex;
  Chain: TAncestorChain;
  ChildFile, Named: string;
begin
  // The decoy is in the document's directory, which is searched first, so
  // only the unit can make the chain pass it over.
  ChildFile := WriteDfm(FDocumentDir, 'ProbeChild.dfm', ChildDfm);
  WriteDfm(FDocumentDir, 'Decoy.dfm', DecoyBaseDfm);
  Named := WriteDfm(FAncestorDir, ThisUnit + '.dfm', BaseDfm);
  Index := TDfmClassIndex.Create;
  try
    Index.SearchIn(FDocumentDir, [FAncestorDir]);
    Chain := TAncestorChain.Create(nil, Index);
    try
      Chain.Resolve(ChildFile, 'TProbeLoadedChild');
      Assert.AreEqual(1, Length(Chain.Files),
        'the ancestor form file was not taken into the chain');
      Assert.AreEqual(Named, Chain.Files[0],
        'the file named after the unit of the loaded class was passed over');
      Assert.AreEqual('TForm', Chain.BaseClass);
    finally
      Chain.Free;
    end;
  finally
    Index.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TLoadedClassesTests);

end.
