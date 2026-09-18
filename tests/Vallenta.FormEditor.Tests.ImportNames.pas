// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.ImportNames;

// Covers ImportedNames in Vallenta.FormEditor.Packages.PeImage, read from
// the test executable's own import table - SysInit imports GetProcAddress
// from kernel32.dll in every Win32 executable - and DerivesIdeWindow in
// Vallenta.FormEditor.Packages.Preflight, given name literals in the
// mangling the compiler produces. No package is loaded.

interface

uses
  DUnitX.TestFramework;

type
  // The names an image imports from one module, and the check that finds
  // the IDE's dockable form among them.
  [TestFixture]
  TImportNameTests = class
  public
    [Test]
    procedure TheExecutableImportsGetProcAddressFromKernel32;
    [Test]
    procedure TheModuleNameIsMatchedCaseInsensitively;
    [Test]
    procedure AModuleNotImportedYieldsNoNames;
    [Test]
    procedure ADockableFormMemberMarksAnIdeWindow;
    [Test]
    procedure OtherDesignPackageMembersDoNot;
    [Test]
    procedure NoImportsMarkNothing;
  end;

implementation

uses
  System.SysUtils,
  System.StrUtils,
  Vallenta.FormEditor.Packages.PeImage,
  Vallenta.FormEditor.Packages.Preflight;

procedure TImportNameTests.TheExecutableImportsGetProcAddressFromKernel32;
var
  Names: TArray<string>;
begin
  Names := ImportedNames(ParamStr(0), 'kernel32.dll');
  Assert.IsTrue(MatchText('GetProcAddress', Names),
    'kernel32.dll imports: ' + string.Join(',', Names));
end;

procedure TImportNameTests.TheModuleNameIsMatchedCaseInsensitively;
begin
  Assert.AreEqual(
    string.Join(',', ImportedNames(ParamStr(0), 'kernel32.dll')),
    string.Join(',', ImportedNames(ParamStr(0), 'KERNEL32.DLL')));
end;

procedure TImportNameTests.AModuleNotImportedYieldsNoNames;
begin
  Assert.AreEqual(0, Length(ImportedNames(ParamStr(0), 'nosuchmodule.dll')));
end;

procedure TImportNameTests.ADockableFormMemberMarksAnIdeWindow;
begin
  Assert.IsTrue(DerivesIdeWindow(
    ['@Deskform@TDesktopForm@Loaded$qqrv',
     '@Dockform@TDockableForm@$bctr$qqrp25System@Classes@TComponent']));
end;

procedure TImportNameTests.OtherDesignPackageMembersDoNot;
begin
  Assert.IsFalse(DerivesIdeWindow(
    ['@Deskform@TDesktopForm@Loaded$qqrv',
     '@Toolsapi@BorlandIDEServices',
     '@Toolsapi@RegisterPackageWizard$qqrx46System@%DelphiInterface$19' +
     'Toolsapi@IOTAWizard%',
     '@Designintf@RegisterDesignNotification$qqrx52System@%DelphiInterface' +
     '$29Designintf@IDesignNotification%']));
end;

procedure TImportNameTests.NoImportsMarkNothing;
begin
  Assert.IsFalse(DerivesIdeWindow([]));
end;

end.
