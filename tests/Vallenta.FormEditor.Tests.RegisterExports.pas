// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.RegisterExports;

// Covers UnitRegisterExports in Vallenta.FormEditor.Packages.Host: which of
// a package's exports are called as Register procedures. The names follow
// the mangling the compiler produces; no package is loaded.

interface

uses
  DUnitX.TestFramework;

type
  // A unit's Register procedure against the other exports that end the same
  // way: methods, generic instances, and units of other packages.
  [TestFixture]
  TRegisterExportTests = class
  public
    [Test]
    procedure AUnitProcedureIsFoundUnderTheFoldedSpelling;
    [Test]
    procedure ADottedUnitNameMatchesSegmentBySegment;
    [Test]
    procedure AMethodNamedRegisterIsNotCalled;
    [Test]
    procedure AGenericMethodNamedRegisterIsNotCalled;
    [Test]
    procedure AUnitTheInformationDoesNotListIsNotMatched;
    [Test]
    procedure TheExportOrderIsKept;
  end;

implementation

uses
  System.SysUtils,
  Vallenta.FormEditor.Packages.Host;

procedure TRegisterExportTests.AUnitProcedureIsFoundUnderTheFoldedSpelling;
var
  Found: TArray<string>;
begin
  Found := UnitRegisterExports(
    ['@Vendorexpresspkg_design_reg@Finalize$qqrv',
     '@Vendorexpresspkg_design_reg@Register$qqrv'],
    ['VendorExpressPkg_Design', 'VendorExpressPkg_Design_Reg', 'SysInit']);
  Assert.AreEqual('@Vendorexpresspkg_design_reg@Register$qqrv',
    string.Join(',', Found));
end;

procedure TRegisterExportTests.ADottedUnitNameMatchesSegmentBySegment;
var
  Found: TArray<string>;
begin
  Found := UnitRegisterExports(
    ['@Vendor@Ide@Reg@Register$qqrv'],
    ['Vendor', 'Vendor.Ide.Reg', 'SysInit']);
  Assert.AreEqual('@Vendor@Ide@Reg@Register$qqrv', string.Join(',', Found));
end;

procedure TRegisterExportTests.AMethodNamedRegisterIsNotCalled;
var
  Found: TArray<string>;
begin
  Found := UnitRegisterExports(
    ['@Vendor@Ide@Menus@TdmVendorMenus@Register$qqrv',
     '@Vendor@Server@TVendorBaseCLI@Register$qqrv'],
    ['Vendor.Ide.Menus', 'Vendor.Server']);
  Assert.AreEqual(0, Length(Found), string.Join(',', Found));
end;

procedure TRegisterExportTests.AGenericMethodNamedRegisterIsNotCalled;
var
  Found: TArray<string>;
begin
  Found := UnitRegisterExports(
    ['@Vendor@Ide@Tools@%TVendorTool__1$p42Vendor@Ide@Tools@Ide@' +
     'TVendorOpenFileParams%@Register$qqrv'],
    ['Vendor.Ide.Tools', 'Vendor.Ide.Tools.Ide']);
  Assert.AreEqual(0, Length(Found), string.Join(',', Found));
end;

procedure TRegisterExportTests.AUnitTheInformationDoesNotListIsNotMatched;
var
  Found: TArray<string>;
begin
  Found := UnitRegisterExports(
    ['@Vcgridreg@Register$qqrv'],
    ['vcGridEMFReg', 'SysInit']);
  Assert.AreEqual(0, Length(Found), string.Join(',', Found));
end;

procedure TRegisterExportTests.TheExportOrderIsKept;
var
  Found: TArray<string>;
begin
  Found := UnitRegisterExports(
    ['@Unitb@Register$qqrv', '@Unita@Register$qqrv'],
    ['UnitA', 'UnitB']);
  Assert.AreEqual('@Unitb@Register$qqrv,@Unita@Register$qqrv',
    string.Join(',', Found));
end;

end.
