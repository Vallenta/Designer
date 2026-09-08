// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.RoundTrip;

// Byte round trip over the fixture form files: each fixture is loaded through
// the full designer path with nothing shown, written again through the save
// pipeline and compared byte by byte. Identical bytes mean the loader and the
// writer together changed nothing: no event handler unwired, no preserved
// subtree dropped, no value rendered differently.
//
// Both tests call BeginDesignerSession, which starts the VCL application and
// loads the design packages once per process. A class that neither a loaded
// package registers nor a file beside the fixture declares is preserved
// verbatim and written back unchanged, so the fixtures naming third-party
// classes do not require those packages to be installed.

interface

uses
  DUnitX.TestFramework;

type
  // Byte identity of a load-then-save for each fixture, and the refusal of a
  // form whose ancestor cannot be resolved.
  [TestFixture]
  TRoundTripTests = class
  public
    [Test]
    [TestCase('basic_form', 'basic_form.dfm')]
    [TestCase('nested_panels', 'nested_panels.dfm')]
    [TestCase('event_handlers', 'event_handlers.dfm')]
    [TestCase('string_continuation', 'string_continuation.dfm')]
    [TestCase('roundtrip_events', 'roundtrip_events.dfm')]
    [TestCase('roundtrip_types', 'roundtrip_types.dfm')]
    [TestCase('roundtrip_image', 'roundtrip_image.dfm')]
    [TestCase('frame_basic', 'frame_basic.dfm')]
    [TestCase('frame_sniffed', 'frame_sniffed.dfm')]
    [TestCase('frame_child', 'frame_child.dfm')]
    [TestCase('frame_host', 'frame_host.dfm')]
    [TestCase('frame_missing', 'frame_missing.dfm')]
    [TestCase('frame_outer', 'frame_outer.dfm')]
    [TestCase('frame_nesting', 'frame_nesting.dfm')]
    [TestCase('nonvisual_on_form', 'nonvisual_on_form.dfm')]
    [TestCase('datamodule_basic', 'datamodule_basic.dfm')]
    [TestCase('unknown_property', 'unknown_property.dfm')]
    [TestCase('unknown_class', 'unknown_class.dfm')]
    [TestCase('preserved_unknown', 'preserved_unknown.dfm')]
    [TestCase('vfi_base', 'vfi_base.dfm')]
    [TestCase('vfi_child', 'vfi_child.dfm')]
    [TestCase('vfi_grand', 'vfi_grand.dfm')]
    [TestCase('pica_components', 'pica_components.dfm')]
    [TestCase('teechart_form', 'teechart_form.dfm')]
    procedure RoundTripsByteIdentically(const AFixture: string);

    [Test]
    procedure AFormBuiltOnAnotherFormRefusesToLoad;
  end;

implementation

uses
  System.SysUtils,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Streaming.Saver,
  Vallenta.FormEditor.Tests.Environment;

const
  // Fixture built on a form class no loaded package and no companion unit
  // declares, and the text its refusal must contain.
  RefusedFixture = 'inherited_form.dfm';
  RefusedBecause = 'built on another form';

function Reported(const AVerdict: string; ALog: TDesignLog): string;
var
  I: Integer;
begin
  Result := AVerdict;
  for I := 0 to ALog.Count - 1 do
    Result := Result + sLineBreak + '      ' + FormatLogLine(ALog[I]);
end;

procedure TRoundTripTests.RoundTripsByteIdentically(const AFixture: string);
var
  Log: TDesignLog;
  Verdict: string;
  Identical: Boolean;
begin
  BeginDesignerSession;
  Log := TDesignLog.Create;
  try
    // RoundTripDfm fills Verdict and Log, so it runs in its own statement:
    // nested in the Assert call, argument evaluation order is unspecified.
    Identical := RoundTripDfm(FixtureFile(AFixture), Log, Verdict);
    Assert.IsTrue(Identical, Reported(Verdict, Log));
  finally
    Log.Free;
  end;
end;

procedure TRoundTripTests.AFormBuiltOnAnotherFormRefusesToLoad;
var
  Log: TDesignLog;
  Verdict, Refusal: string;
begin
  BeginDesignerSession;
  Log := TDesignLog.Create;
  try
    Refusal := '';
    try
      RoundTripDfm(FixtureFile(RefusedFixture), Log, Verdict);
    except
      on E: Exception do
        Refusal := E.Message;
    end;
    Assert.Contains(Refusal, RefusedBecause,
      Reported('the load was expected to refuse the file and say why', Log));
  finally
    Log.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TRoundTripTests);

end.
