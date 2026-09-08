// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.LinkedModules;

// References from a document into another module, written
// "XModData.PopupMenuShared": the load resolves the reference through the DFM
// class index over the document's own directory and the search path, the save
// writes it back qualified, and a reference into a module no form file
// declares is written back unchanged.
//
// Both cases create and delete two temp directories; only the resolving case
// writes the module files into the second one. Both call
// BeginDesignerSession, which loads the design packages once per process, and
// the resolving case sets the process-wide per-document search path override
// that makes the module directory visible to the load and clears it again.

interface

uses
  DUnitX.TestFramework;

type
  // A reference into another module: resolved and saved qualified, or kept as
  // written when no form file declares the module.
  [TestFixture]
  TLinkedModuleTests = class
  public
    [Test]
    procedure AReferenceIntoAnotherModuleResolvesAndSavesQualified;
    // The load also logs a warning naming the module it did not find.
    [Test]
    procedure AReferenceIntoAMissingModuleIsKeptAsWritten;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.StrUtils,
  Vcl.StdCtrls,
  Vcl.Menus,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Core.SearchPath,
  Vallenta.FormEditor.Streaming.EventNames,
  Vallenta.FormEditor.Streaming.Frames,
  Vallenta.FormEditor.Streaming.Preserved,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Streaming.Saver,
  Vallenta.FormEditor.Tests.Environment;

const
  ReferenceLine = 'PopupMenu = XModData.PopupMenuShared';

  HostDfm =
    'object XModHost: TXModHost'#13#10 +
    '  Left = 0'#13#10 +
    '  Top = 0'#13#10 +
    '  Caption = ''Host'''#13#10 +
    '  ClientHeight = 200'#13#10 +
    '  ClientWidth = 300'#13#10 +
    '  object SharedButton: TButton'#13#10 +
    '    Left = 10'#13#10 +
    '    Top = 10'#13#10 +
    '    Width = 75'#13#10 +
    '    Height = 25'#13#10 +
    '    Caption = ''Shared'''#13#10 +
    '    ' + ReferenceLine + #13#10 +
    '    TabOrder = 0'#13#10 +
    '  end'#13#10 +
    'end'#13#10;

  HostUnit =
    'unit xmod_host;'#13#10 +
    'interface'#13#10 +
    'uses Vcl.Forms, Vcl.StdCtrls;'#13#10 +
    'type'#13#10 +
    '  TXModHost = class(TForm)'#13#10 +
    '    SharedButton: TButton;'#13#10 +
    '  end;'#13#10 +
    'implementation'#13#10 +
    'end.'#13#10;

  ModuleDfm =
    'object XModData: TXModData'#13#10 +
    '  Height = 150'#13#10 +
    '  Width = 215'#13#10 +
    '  object PopupMenuShared: TPopupMenu'#13#10 +
    '    Left = 40'#13#10 +
    '    Top = 32'#13#10 +
    '  end'#13#10 +
    'end'#13#10;

  ModuleUnit =
    'unit xmod_data;'#13#10 +
    'interface'#13#10 +
    'uses System.Classes;'#13#10 +
    'type'#13#10 +
    '  TXModData = class(TDataModule)'#13#10 +
    '  end;'#13#10 +
    'implementation'#13#10 +
    'end.'#13#10;

procedure BuildWorld(AWithModule: Boolean;
  out ADocDir, AModuleDir, ADocFile: string);
begin
  ADocDir := TPath.Combine(TPath.GetTempPath, 'vsfe_linked_doc');
  AModuleDir := TPath.Combine(TPath.GetTempPath, 'vsfe_linked_mod');
  TDirectory.CreateDirectory(ADocDir);
  TDirectory.CreateDirectory(AModuleDir);
  ADocFile := TPath.Combine(ADocDir, 'xmod_host.dfm');
  TFile.WriteAllText(ADocFile, HostDfm);
  TFile.WriteAllText(TPath.Combine(ADocDir, 'xmod_host.pas'), HostUnit);
  if AWithModule then
  begin
    TFile.WriteAllText(TPath.Combine(AModuleDir, 'xmod_data.dfm'), ModuleDfm);
    TFile.WriteAllText(TPath.Combine(AModuleDir, 'xmod_data.pas'), ModuleUnit);
  end;
end;

procedure DropWorld(const ADocDir, AModuleDir: string);
begin
  TDirectory.Delete(ADocDir, True);
  TDirectory.Delete(AModuleDir, True);
end;

function Occurrences(const AText, APiece: string): Integer;
var
  At: Integer;
begin
  Result := 0;
  At := PosEx(APiece, AText);
  while At > 0 do
  begin
    Inc(Result);
    At := PosEx(APiece, AText, At + 1);
  end;
end;

// The loader must outlive SaveDesignedForm: the saved reference points into
// a linked module component that TFormLoader frees in its destructor.
function LoadAndSave(const ADocFile: string; ALog: TDesignLog;
  out AResolvedTo: string): string;
var
  Loader: TFormLoader;
  Document: TDesignDocument;
  Button: TButton;
  EventMap: TEventNameMap;
  Preserved: TPreservedModel;
  Frames: TFrameInstances;
  Ancestor: TDesignDocument;
  OutFile: string;
begin
  AResolvedTo := '';
  Loader := TFormLoader.Create(ALog);
  try
    Loader.Prepare(ADocFile);
    Document := CreateDesignDocument(Loader.RootKind);
    try
      Loader.StreamInto(Document.Root);
      Button := Document.Root.FindComponent('SharedButton') as TButton;
      if Button.PopupMenu <> nil then
        AResolvedTo := Button.PopupMenu.Owner.Name + '.' + Button.PopupMenu.Name;
      EventMap := Loader.ExtractEventMap;
      Preserved := Loader.ExtractPreserved;
      Frames := Loader.ExtractFrames;
      Ancestor := Loader.ExtractAncestor;
      try
        OutFile := ChangeFileExt(ADocFile, '.saved.dfm');
        SaveDesignedForm(Document.Root, EventMap, Loader.LoadedState, Frames,
          Preserved, Ancestor.Root, OutFile);
        Result := TFile.ReadAllText(OutFile);
      finally
        FreeDesignDocument(Ancestor);
        Frames.Free;
        Preserved.Free;
        EventMap.Free;
      end;
    finally
      FreeDesignDocument(Document);
    end;
  finally
    Loader.Free;
  end;
end;

{ TLinkedModuleTests }

procedure TLinkedModuleTests.AReferenceIntoAnotherModuleResolvesAndSavesQualified;
var
  DocDir, ModuleDir, DocFile, ResolvedTo, Saved: string;
  Log: TDesignLog;
begin
  BeginDesignerSession;
  BuildWorld(True, DocDir, ModuleDir, DocFile);
  try
    NoteSearchPathFor(DocFile, [ModuleDir]);
    try
      Log := TDesignLog.Create;
      try
        Saved := LoadAndSave(DocFile, Log, ResolvedTo);
      finally
        Log.Free;
      end;
      Assert.AreEqual('XModData.PopupMenuShared', ResolvedTo,
        'the reference into the module did not resolve to its component');
      Assert.AreEqual(1, Occurrences(Saved, ReferenceLine),
        'the qualified reference was not written back exactly once');
    finally
      NoteSearchPathFor(DocFile, nil);
    end;
  finally
    DropWorld(DocDir, ModuleDir);
  end;
end;

procedure TLinkedModuleTests.AReferenceIntoAMissingModuleIsKeptAsWritten;
var
  DocDir, ModuleDir, DocFile, ResolvedTo, Saved: string;
  Log: TDesignLog;
  I: Integer;
  Warned: Boolean;
begin
  BeginDesignerSession;
  BuildWorld(False, DocDir, ModuleDir, DocFile);
  try
    Log := TDesignLog.Create;
    try
      Saved := LoadAndSave(DocFile, Log, ResolvedTo);
      Warned := False;
      for I := 0 to Log.Count - 1 do
        if (Log[I].Severity = lsWarn) and ContainsText(Log[I].Text, 'XModData') then
          Warned := True;
    finally
      Log.Free;
    end;
    Assert.AreEqual('', ResolvedTo,
      'there is no module, so nothing may have resolved');
    Assert.AreEqual(1, Occurrences(Saved, ReferenceLine),
      'the reference line was not preserved exactly once');
    Assert.IsTrue(Warned, 'the missing module was not named in a warning');
  finally
    DropWorld(DocDir, ModuleDir);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TLinkedModuleTests);

end.
