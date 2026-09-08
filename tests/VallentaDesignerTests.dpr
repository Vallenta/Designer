// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

program VallentaDesignerTests;

// Console runner for the designer's test suite. The exit code is the number
// of failed plus errored tests, zero when all pass, and 1 when an exception
// escapes the run.
//
// The design packages are loaded on first use by a fixture and unloaded
// after the run, so every fixture in a process runs against one set of
// packages.

{$APPTYPE CONSOLE}
// DUnitX finds fixtures through RTTI at run time; without this directive the
// linker strips types no code references and those fixtures never run.
{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  DUnitX.Loggers.Console,
  DUnitX.TestFramework,
  Vallenta.FormEditor.Tests.Environment in 'Vallenta.FormEditor.Tests.Environment.pas',
  Vallenta.FormEditor.Tests.RoundTrip in 'Vallenta.FormEditor.Tests.RoundTrip.pas',
  Vallenta.FormEditor.Tests.SingleInstance in 'Vallenta.FormEditor.Tests.SingleInstance.pas',
  Vallenta.FormEditor.Tests.Protocol in 'Vallenta.FormEditor.Tests.Protocol.pas',
  Vallenta.FormEditor.Tests.FieldDiff in 'Vallenta.FormEditor.Tests.FieldDiff.pas',
  Vallenta.FormEditor.Tests.Coupling in 'Vallenta.FormEditor.Tests.Coupling.pas',
  Vallenta.FormEditor.Tests.Rename in 'Vallenta.FormEditor.Tests.Rename.pas',
  Vallenta.FormEditor.Tests.Orphan in 'Vallenta.FormEditor.Tests.Orphan.pas',
  Vallenta.FormEditor.Tests.Recovery in 'Vallenta.FormEditor.Tests.Recovery.pas',
  Vallenta.FormEditor.Tests.SettledImage in 'Vallenta.FormEditor.Tests.SettledImage.pas',
  Vallenta.FormEditor.Tests.SourceFiles in 'Vallenta.FormEditor.Tests.SourceFiles.pas',
  Vallenta.FormEditor.Tests.ArgumentFile in 'Vallenta.FormEditor.Tests.ArgumentFile.pas',
  Vallenta.FormEditor.Tests.LoadedClasses in 'Vallenta.FormEditor.Tests.LoadedClasses.pas',
  Vallenta.FormEditor.Tests.SearchPath in 'Vallenta.FormEditor.Tests.SearchPath.pas',
  Vallenta.FormEditor.Tests.LinkedModules in 'Vallenta.FormEditor.Tests.LinkedModules.pas',
  Vallenta.FormEditor.Tests.Log in 'Vallenta.FormEditor.Tests.Log.pas',
  Vallenta.FormEditor.Tests.Palette in 'Vallenta.FormEditor.Tests.Palette.pas',
  Vallenta.FormEditor.Tests.Layout in 'Vallenta.FormEditor.Tests.Layout.pas',
  Vallenta.FormEditor.Tests.Tiles in 'Vallenta.FormEditor.Tests.Tiles.pas',
  Vallenta.FormEditor.Tests.DesignerDiscovery in 'Vallenta.FormEditor.Tests.DesignerDiscovery.pas',
  Vallenta.FormEditor.Tests.DesignHitTest in 'Vallenta.FormEditor.Tests.DesignHitTest.pas',
  Vallenta.FormEditor.Tests.IdeServices in 'Vallenta.FormEditor.Tests.IdeServices.pas',
  Vallenta.FormEditor.Tests.Diagnostics in 'Vallenta.FormEditor.Tests.Diagnostics.pas',
  Vallenta.FormEditor.Tests.ZOrder in 'Vallenta.FormEditor.Tests.ZOrder.pas',
  Vallenta.FormEditor.Tests.InspectorRows in 'Vallenta.FormEditor.Tests.InspectorRows.pas',
  Vallenta.FormEditor.Tests.Clipboard in 'Vallenta.FormEditor.Tests.Clipboard.pas';

var
  Runner: ITestRunner;
  Results: IRunResults;
begin
  try
    TDUnitX.CheckCommandLine;
    Runner := TDUnitX.CreateRunner;
    Runner.UseRTTI := True;
    Runner.AddLogger(TDUnitXConsoleLogger.Create(False));
    Results := Runner.Execute;
    EndDesignerSession;
    if not Results.AllPassed then
      ExitCode := Results.FailureCount + Results.ErrorCount;
  except
    on E: Exception do
    begin
      Writeln(Format('%s: %s', [E.ClassName, E.Message]));
      ExitCode := 1;
    end;
  end;
end.
