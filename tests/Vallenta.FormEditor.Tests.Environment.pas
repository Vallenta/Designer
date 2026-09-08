// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.Environment;

// Process-wide setup for a test run - the VCL application, the standard
// property editors and the design packages - the location of the fixture
// form files, and a byte-for-byte comparison of two files.

interface

// Directory holding the fixture form files, located by walking up from the
// test executable and cached after the first successful call. Raises when no
// such directory is found.
function FixtureDirectory: string;

// Full path of the named file in FixtureDirectory.
function FixtureFile(const AFileName: string): string;

// Starts the designer session for this process: VCL application, standard
// property editors, design packages. Calls after the first do nothing.
procedure BeginDesignerSession;

// Unloads the design packages. Call after everything holding a class a
// package registered has been released.
procedure EndDesignerSession;

// True when both files hold identical bytes. AWhere names the differing
// lengths or the offset of the first differing byte, and is empty on a match.
function SameBytes(const AFileA, AFileB: string; out AWhere: string): Boolean;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  Vcl.Forms,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.DesignTime.Designer,
  Vallenta.FormEditor.Packages.Host;

const
  // Fixture file whose presence identifies the fixtures directory.
  MarkerFixture = 'basic_form.dfm';
  // Levels above the executable directory that are searched. The test
  // executable sits in tests\bin\<platform>\<config>\<release>, five levels
  // below the directory holding fixtures.
  SearchDepth = 6;

var
  FoundDirectory: string = '';
  SessionStarted: Boolean = False;

function FixtureDirectory: string;
var
  Directory, Candidate: string;
  Level: Integer;
begin
  if FoundDirectory <> '' then
    Exit(FoundDirectory);
  Directory := TPath.GetDirectoryName(ParamStr(0));
  for Level := 0 to SearchDepth do
  begin
    Candidate := TPath.Combine(Directory, 'fixtures');
    if TFile.Exists(TPath.Combine(Candidate, MarkerFixture)) then
    begin
      FoundDirectory := Candidate;
      Exit(FoundDirectory);
    end;
    Directory := TPath.GetDirectoryName(Directory);
    if Directory = '' then
      Break;
  end;
  raise Exception.CreateFmt('No fixtures directory holding %s at or above %s.',
    [MarkerFixture, TPath.GetDirectoryName(ParamStr(0))]);
end;

function FixtureFile(const AFileName: string): string;
begin
  Result := TPath.Combine(FixtureDirectory, AFileName);
end;

function SameBytes(const AFileA, AFileB: string; out AWhere: string): Boolean;
var
  A, B: TBytes;
  I: Integer;
begin
  A := TFile.ReadAllBytes(AFileA);
  B := TFile.ReadAllBytes(AFileB);
  if Length(A) <> Length(B) then
  begin
    AWhere := Format('%d byte(s) against %d', [Length(A), Length(B)]);
    Exit(False);
  end;
  for I := 0 to High(A) do
    if A[I] <> B[I] then
    begin
      AWhere := Format('they differ at byte %d', [I]);
      Exit(False);
    end;
  AWhere := '';
  Result := True;
end;

procedure ReportPackageLog;
var
  Log: TDesignLog;
  Quiet, I: Integer;
begin
  Log := TDesignLog.Create;
  try
    ReportInto(Log);
    Quiet := 0;
    for I := 0 to Log.Count - 1 do
      if Log[I].Severity = lsInfo then
        Inc(Quiet)
      else
        Writeln(FormatLogLine(Log[I]));
    Writeln(Format('packages: %d line(s), %d of them plain information',
      [Log.Count, Quiet]));
  finally
    // ReportInto(nil) must run before Log.Free: the package host keeps the
    // reader and writes into it after the load.
    ReportInto(nil);
    Log.Free;
  end;
end;

procedure BeginDesignerSession;
begin
  if SessionStarted then
    Exit;
  SessionStarted := True;
  Application.Initialize;
  // InstallStandardEditors must run before the packages load: a package's
  // editor for the same type then takes precedence over the standard one.
  InstallStandardEditors;
  LoadPackagesFrom(PackageSettingsKey);
  ReportPackageLog;
end;

procedure EndDesignerSession;
begin
  if not SessionStarted then
    Exit;
  SessionStarted := False;
  UnloadAll;
end;

end.
