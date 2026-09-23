// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.Styles;

// Covers Shell.Styles: the styles ListStyles offers for a directory, the
// choice TStyleChoiceStore keeps, and a style change under an open document,
// which recreates every window handle and must leave the document unmodified,
// in the system style and saving the bytes it was opened from.
//
// The live cases show a window that never takes the activation and put the
// system style back before they end. The store cases write below a Tests
// subkey of the settings root, never the key the product reads.

interface

uses
  DUnitX.TestFramework;

type
  // The styles a directory offers, the kept choice, and a style change under
  // an open document.
  [TestFixture]
  TStyleTests = class
  public
    [Test]
    procedure TheSystemStyleComesFirst;
    [Test]
    procedure TheInstalledStylesFollowInNameOrder;
    [Test]
    procedure AFileHoldingNoStyleIsLeftOut;
    [Test]
    procedure ASecondFileDeclaringTheSameStyleIsLeftOut;
    [Test]
    procedure AMissingDirectoryOffersTheSystemStyleAlone;
    [Test]
    procedure NothingIsKeptBeforeTheFirstChoice;
    [Test]
    procedure AChosenStyleFileIsReadBack;
    [Test]
    procedure TheSystemStyleIsKeptAsAnEmptyName;
    // AFromStyle is the style file the window is created under; empty for the
    // system style, which attaches no style hook to the window.
    [Test]
    [TestCase('Standard controls from the system style', 'roundtrip_types.dfm,')]
    [TestCase('Standard controls from another style', 'roundtrip_types.dfm,Windows10.vsf')]
    [TestCase('Third-party chart from another style', 'teechart_form.dfm,Windows10.vsf')]
    [TestCase('Non-visual components from another style', 'nonvisual_on_form.dfm,Windows10.vsf')]
    procedure AStyleChangeLeavesAnOpenDocumentAsLoaded(const AFixture,
      AFromStyle: string);
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.Win.Registry,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.Themes,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Core.Settings,
  Vallenta.FormEditor.Streaming.RootClassifier,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Surface.FormDesigner,
  Vallenta.FormEditor.Surface.Undo,
  Vallenta.FormEditor.Shell.Styles,
  Vallenta.FormEditor.Tests.Environment;

const
  // Key below the settings root the store cases write to, and a style file
  // every supported release installs.
  TestStyleKey = 'Tests\StyleChoice';
  DarkStyleFile = 'Windows10Dark.vsf';
  // Rounds of message and synchronize pumping after a style change. A round
  // empties the message queue, and a handled message may post another.
  SettleRounds = 8;

type
  // Top-level window standing in for the document window. It never takes the
  // activation, so a run does not pull the keyboard focus off the desktop.
  THostWindow = class(TForm)
  protected
    procedure CreateParams(var Params: TCreateParams); override;
  end;

  // One fixture form loaded into a designer and embedded in a shown window as
  // the document window embeds it, so that every designed control has a
  // window handle for a style change to recreate.
  TShownDocument = class
  private
    FLog: TDesignLog;
    FUndo: TUndoStack;
    FHost: THostWindow;
    FDocument: TDesignDocument;
    FDesigner: TFormDesigner;
    FWritten: string;
  public
    constructor Create(const AFileName: string);
    destructor Destroy; override;
    // Writes the document through the save pipeline to a temp file of this
    // session and returns its path; the file is deleted with the session.
    function WrittenFile: string;
    property Document: TDesignDocument read FDocument;
    property Designer: TFormDesigner read FDesigner;
    property Undo: TUndoStack read FUndo;
  end;

procedure THostWindow.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.ExStyle := Params.ExStyle or WS_EX_NOACTIVATE;
end;

procedure Settle;
var
  Round: Integer;
begin
  for Round := 1 to SettleRounds do
  begin
    Application.ProcessMessages;
    CheckSynchronize;
  end;
end;

// The installed style whose file is named AFileName; fails the case when the
// release installs no such file.
function InstalledStyle(const AFileName: string): TDesignerStyle;
var
  Style: TDesignerStyle;
begin
  Result := Default(TDesignerStyle);
  for Style in InstalledStyles do
    if SameText(TPath.GetFileName(Style.FileName), AFileName) then
      Exit(Style);
  Assert.Fail(Format('%s is not installed in %s', [AFileName, StylesDirectory]));
end;

procedure DeleteTestKey;
var
  Registry: TRegistry;
begin
  Registry := TRegistry.Create(KEY_READ or KEY_WRITE);
  try
    Registry.RootKey := HKEY_CURRENT_USER;
    Registry.DeleteKey(SettingsKey(TestStyleKey));
  finally
    Registry.Free;
  end;
end;

{ TShownDocument }

constructor TShownDocument.Create(const AFileName: string);
var
  Loader: TFormLoader;
  Surface: TScrollBox;
begin
  inherited Create;
  FWritten := TPath.Combine(TPath.GetTempPath, 'vsfe_styles_' +
    TPath.GetFileName(AFileName));
  FLog := TDesignLog.Create;
  FUndo := TUndoStack.Create;
  FHost := THostWindow.CreateNew(nil);
  FHost.SetBounds(0, 0, 900, 700);
  Surface := TScrollBox.Create(FHost);
  Surface.Parent := FHost;
  Surface.Align := alClient;
  Loader := TFormLoader.Create(FLog);
  try
    Loader.Prepare(AFileName);
    if Loader.RootKind <> drForm then
      raise Exception.CreateFmt('%s holds no form', [AFileName]);
    FDocument := CreateDesignDocument(Loader.RootKind);
    FDesigner := TFormDesigner.Create(FDocument.HostForm, FDocument.Root, FLog);
    FDesigner.UndoStack := FUndo;
    Loader.StreamInto(FDocument.Root);
    FDesigner.AttachLoaded(AFileName, Loader.ExtractEventMap,
      Loader.ExtractPreserved, Loader.ExtractFrames, Loader.ExtractAncestor,
      Loader.LoadedState);
    EmbedDesignedForm(FDocument.HostForm, Surface, Loader.LoadedState);
  finally
    Loader.Free;
  end;
  FDesigner.ShowPlaceholders;
  FDesigner.BeginEditing;
  FHost.Visible := True;
  SetWindowPos(FHost.Handle, HWND_BOTTOM, 0, 0, 0, 0,
    SWP_NOMOVE or SWP_NOSIZE or SWP_NOACTIVATE);
  Settle;
end;

destructor TShownDocument.Destroy;
begin
  // The designer is freed first: it holds the preserved model whose
  // placeholders the document also parents and would otherwise free twice.
  FreeAndNil(FDesigner);
  FreeDesignDocument(FDocument);
  FHost.Free;
  Settle;
  FUndo.Free;
  FLog.Free;
  DeleteFile(FWritten);
  inherited Destroy;
end;

function TShownDocument.WrittenFile: string;
begin
  FDesigner.WriteTo(FWritten);
  Result := FWritten;
end;

{ TStyleTests }

procedure TStyleTests.TheSystemStyleComesFirst;
var
  Styles: TArray<TDesignerStyle>;
begin
  Styles := ListStyles(StylesDirectory);
  Assert.IsTrue(Length(Styles) > 0, 'no style is offered at all');
  Assert.AreEqual(TStyleManager.SystemStyleName, Styles[0].Name,
    'the first style offered is not the system style');
  Assert.AreEqual('', Styles[0].FileName,
    'the system style is offered with a file');
end;

procedure TStyleTests.TheInstalledStylesFollowInNameOrder;
var
  Styles: TArray<TDesignerStyle>;
  I: Integer;
begin
  Styles := ListStyles(StylesDirectory);
  Assert.IsTrue(Length(Styles) > 1,
    Format('%s offers no style file', [StylesDirectory]));
  for I := 1 to High(Styles) do
  begin
    Assert.IsTrue(TFile.Exists(Styles[I].FileName),
      Format('%s is offered from %s, which does not exist',
      [Styles[I].Name, Styles[I].FileName]));
    Assert.IsTrue(SameText(TPath.GetExtension(Styles[I].FileName), '.vsf'),
      Format('%s is offered from %s, which is no .vsf file',
      [Styles[I].Name, Styles[I].FileName]));
    // Strictly ascending, so a name offered twice fails here as well.
    if I > 1 then
      Assert.IsTrue(CompareText(Styles[I - 1].Name, Styles[I].Name) < 0,
        Format('%s is offered before %s', [Styles[I - 1].Name, Styles[I].Name]));
  end;
end;

procedure TStyleTests.AFileHoldingNoStyleIsLeftOut;
var
  Dark: TDesignerStyle;
  Directory, Copied: string;
  Styles: TArray<TDesignerStyle>;
begin
  Dark := InstalledStyle(DarkStyleFile);
  Directory := TPath.Combine(TPath.GetTempPath,
    Format('vsfe_styles_%d', [GetCurrentProcessId]));
  TDirectory.CreateDirectory(Directory);
  try
    Copied := TPath.Combine(Directory, DarkStyleFile);
    TFile.Copy(Dark.FileName, Copied);
    TFile.WriteAllText(TPath.Combine(Directory, 'NotAStyle.vsf'),
      'object Form1: TForm1' + sLineBreak + 'end' + sLineBreak);
    // A longer extension the *.vsf mask can reach through an 8.3 file name.
    TFile.Copy(Dark.FileName, TPath.Combine(Directory, 'Longer.vsfx'));
    Styles := ListStyles(Directory);
    Assert.AreEqual(2, Integer(Length(Styles)),
      'the directory offers more or fewer styles than the one style file');
    Assert.AreEqual(Dark.Name, Styles[1].Name,
      'the style file is offered under another name');
    Assert.IsTrue(SameText(Copied, Styles[1].FileName),
      Format('the style is offered from %s', [Styles[1].FileName]));
  finally
    TDirectory.Delete(Directory, True);
  end;
end;

procedure TStyleTests.ASecondFileDeclaringTheSameStyleIsLeftOut;
var
  Dark: TDesignerStyle;
  Directory: string;
  Styles: TArray<TDesignerStyle>;
begin
  Dark := InstalledStyle(DarkStyleFile);
  Directory := TPath.Combine(TPath.GetTempPath,
    Format('vsfe_styles_%d', [GetCurrentProcessId]));
  TDirectory.CreateDirectory(Directory);
  try
    TFile.Copy(Dark.FileName, TPath.Combine(Directory, DarkStyleFile));
    TFile.Copy(Dark.FileName, TPath.Combine(Directory, 'Again.vsf'));
    Styles := ListStyles(Directory);
    Assert.AreEqual(2, Integer(Length(Styles)),
      Format('%s is offered once per file that declares it', [Dark.Name]));
    Assert.AreEqual(Dark.Name, Styles[1].Name);
  finally
    TDirectory.Delete(Directory, True);
  end;
end;

procedure TStyleTests.AMissingDirectoryOffersTheSystemStyleAlone;
var
  Styles: TArray<TDesignerStyle>;
begin
  Styles := ListStyles(TPath.Combine(TPath.GetTempPath,
    'vsfe_no_such_styles_directory'));
  Assert.AreEqual(1, Integer(Length(Styles)),
    'a missing directory offers a style besides the system style');
  Assert.AreEqual(TStyleManager.SystemStyleName, Styles[0].Name);
  Styles := ListStyles('');
  Assert.AreEqual(1, Integer(Length(Styles)),
    'an unknown directory offers a style besides the system style');
end;

procedure TStyleTests.NothingIsKeptBeforeTheFirstChoice;
var
  Store: TStyleChoiceStore;
  Kept: string;
begin
  DeleteTestKey;
  Store := TStyleChoiceStore.Create(SettingsKey(TestStyleKey));
  try
    Assert.IsFalse(Store.Load(Kept), 'a choice was read from a missing key');
    Assert.AreEqual('', Store.LastError);
  finally
    Store.Free;
  end;
end;

procedure TStyleTests.AChosenStyleFileIsReadBack;
const
  Chosen = 'WindowsModernDark.vsf';
var
  Store: TStyleChoiceStore;
  Kept: string;
begin
  DeleteTestKey;
  Store := TStyleChoiceStore.Create(SettingsKey(TestStyleKey));
  try
    Store.Save(Chosen);
    Assert.AreEqual('', Store.LastError, 'the choice could not be written');
    Assert.IsTrue(Store.Load(Kept), 'the written choice is not read back');
    Assert.AreEqual(Chosen, Kept);
  finally
    Store.Free;
    DeleteTestKey;
  end;
end;

procedure TStyleTests.TheSystemStyleIsKeptAsAnEmptyName;
var
  Store: TStyleChoiceStore;
  Kept: string;
begin
  DeleteTestKey;
  Store := TStyleChoiceStore.Create(SettingsKey(TestStyleKey));
  try
    Store.Save('');
    Assert.IsTrue(Store.Load(Kept),
      'the system style is not read back as a kept choice');
    Assert.AreEqual('', Kept);
  finally
    Store.Free;
    DeleteTestKey;
  end;
end;

procedure TStyleTests.AStyleChangeLeavesAnOpenDocumentAsLoaded(
  const AFixture, AFromStyle: string);
var
  Dark: TDesignerStyle;
  Session: TShownDocument;
  Source, Where: string;
  Before: HWND;
  Root: TControl;
  I: Integer;
begin
  BeginDesignerSession;
  Dark := InstalledStyle(DarkStyleFile);
  Source := FixtureFile(AFixture);
  if AFromStyle <> '' then
    ApplyStyle(InstalledStyle(AFromStyle));
  Session := nil;
  try
    Session := TShownDocument.Create(Source);
    Before := Session.Document.HostForm.Handle;
    ApplyStyle(Dark);
    Settle;
    Assert.IsTrue(Session.Document.HostForm.Handle <> Before,
      'the style change did not recreate the designed form''s window');
    Root := Session.Document.Root as TControl;
    Assert.IsFalse(Root.IsCustomStyleActive,
      Format('the designed form is drawn in the %s style', [Dark.Name]));
    for I := 0 to Root.ComponentCount - 1 do
      if Root.Components[I] is TControl then
        Assert.IsFalse(TControl(Root.Components[I]).IsCustomStyleActive,
          Format('%s is drawn in the %s style',
          [Root.Components[I].Name, Dark.Name]));
    Assert.IsFalse(Session.Designer.Dirty,
      'the style change marked the document modified');
    Assert.IsFalse(Session.Undo.CanUndo,
      'the style change left a step in the history');
    Assert.IsTrue(SameBytes(Source, Session.WrittenFile, Where),
      'after the style change the document no longer writes what it was ' +
      'opened from: ' + Where);
  finally
    Session.Free;
    ApplyStyle(InstalledStyles[0]);
    Settle;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TStyleTests);

end.
