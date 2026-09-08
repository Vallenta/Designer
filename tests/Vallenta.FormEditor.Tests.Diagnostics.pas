// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.Diagnostics;

// Covers the stack capture and address naming in
// Vallenta.FormEditor.Packages.Stacks and the export table read by
// Vallenta.FormEditor.Packages.PeImage. The suite has to be built for Win32
// with runtime packages: the frame scan is 32-bit assembler, and the symbol
// tests read the export table of rtl<suffix>.bpl, which must be mapped.

interface

uses
  DUnitX.TestFramework;

type
  // Stack scanning, export-table order, the naming of an address, and the
  // trace attached at a raise.
  [TestFixture]
  TStackCaptureTests = class
  public
    // Installs the RTL stack-info hooks unless another provider already holds
    // them; once installed they stay for the lifetime of the process. Turns
    // capture on.
    [Setup]
    procedure InstallTheProvider;
    [TearDown]
    procedure StopCapturing;
    [Test]
    procedure ARuntimePackageOffersItsExportsInAddressOrder;
    [Test]
    procedure AnAddressInThisProgramNamesTheModuleAndTheOffset;
    [Test]
    procedure AnAddressInARuntimePackageNamesASymbol;
    [Test]
    procedure TheScanReachesTheCallerBehindTheRtl;
    // Asserts only that a trace is attached: a provider another tool already
    // installed is not replaced, so the frame text is not fixed.
    [Test]
    procedure ARaisedExceptionCarriesWhereItCameFrom;
    [Test]
    procedure AnAddressInNoModuleStaysAnAddress;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.StrUtils,
  Vallenta.FormEditor.Core.Settings,
  Vallenta.FormEditor.Packages.PeImage,
  Vallenta.FormEditor.Packages.Stacks;

function RuntimeLibrary: HMODULE;
begin
  Result := GetModuleHandle(PChar('rtl' + PackageSuffix + '.bpl'));
  Assert.IsTrue(Result <> 0,
    'the suite is built with runtime packages, so rtl' + PackageSuffix +
    '.bpl is mapped');
end;

procedure TStackCaptureTests.InstallTheProvider;
begin
  InstallStackCapture;
  SetStackCapture(True);
end;

procedure TStackCaptureTests.StopCapturing;
begin
  SetStackCapture(False);
end;

procedure TStackCaptureTests.ARuntimePackageOffersItsExportsInAddressOrder;
var
  Symbols: TArray<TExportedSymbol>;
  I: Integer;
begin
  Symbols := ExportedSymbols(RuntimeLibrary);
  Assert.IsTrue(Length(Symbols) > 100,
    Format('the runtime package exported %d symbol(s)', [Length(Symbols)]));
  for I := 1 to High(Symbols) do
    if NativeUInt(Symbols[I].Address) < NativeUInt(Symbols[I - 1].Address) then
      Assert.Fail(Format('symbol %d (%s) sorts before its predecessor (%s)',
        [I, Symbols[I].Name, Symbols[I - 1].Name]));
end;

procedure TStackCaptureTests.AnAddressInThisProgramNamesTheModuleAndTheOffset;
var
  Described: string;
begin
  Described := DescribeAddress(@RuntimeLibrary);
  Assert.IsTrue(ContainsText(Described, ExtractFileName(ParamStr(0))),
    'an address in this program has to name it: ' + Described);
  Assert.IsTrue(ContainsText(Described, '+ $'),
    'an address has to carry its offset into the module: ' + Described);
end;

procedure TStackCaptureTests.AnAddressInARuntimePackageNamesASymbol;
var
  Symbols: TArray<TExportedSymbol>;
  Described: string;
begin
  Symbols := ExportedSymbols(RuntimeLibrary);
  Assert.IsTrue(Length(Symbols) > 0, 'the runtime package exports nothing');
  Described := DescribeAddress(PByte(Symbols[0].Address) + 4);
  Assert.IsTrue(ContainsText(Described, Symbols[0].Name),
    Format('%s should have been named for the address just past it, got %s',
      [Symbols[0].Name, Described]));
end;

procedure TStackCaptureTests.TheScanReachesTheCallerBehindTheRtl;
var
  Frames: TArray<string>;
  Line: string;
begin
  Frames := CurrentStack;
  Assert.IsTrue(Length(Frames) > 0, 'the scan found no frame at all');
  for Line in Frames do
    if ContainsText(Line, ExtractFileName(ParamStr(0))) then
      Exit;
  Assert.Fail('no frame reached the caller in ' + ExtractFileName(ParamStr(0)) +
    ': ' + string.Join(' | ', Frames));
end;

procedure TStackCaptureTests.ARaisedExceptionCarriesWhereItCameFrom;
var
  Frames: TArray<string>;
begin
  Frames := [];
  try
    raise EIntfCastError.Create('a cast that did not work out');
  except
    on E: Exception do
      Frames := StackFrames(E);
  end;
  Assert.IsTrue(Length(Frames) > 0, 'nothing was captured at the raise');
end;

procedure TStackCaptureTests.AnAddressInNoModuleStaysAnAddress;
var
  Described: string;
begin
  Described := DescribeAddress(Pointer($10));
  Assert.AreEqual('$00000010', Described,
    'an address in no loaded module has nothing to name it after');
end;

end.
