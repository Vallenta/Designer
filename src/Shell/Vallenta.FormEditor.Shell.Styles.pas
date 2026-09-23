// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Shell.Styles;

// VCL style of the designer's own windows: the styles the installed release
// ships, the choice kept in the settings of this release, and the switch
// between them. The style is process-wide; a control in design mode is drawn
// in the system style under every style, so a designed document keeps its
// look. Main thread only.
//
// A switch while windows exist recreates every window handle, the designed
// documents' included. A window re-applies state it holds in a handle when
// CM_STYLECHANGED reaches it, which happens after its recreation.

interface

uses
  Vallenta.FormEditor.Core.Log;

type
  // One style offered for selection, known to TStyleManager by Name.
  TDesignerStyle = record
    Name: string;
    // Full path of the style file; empty for the system style.
    FileName: string;
  end;

  // Reads and writes the chosen style as one registry value below
  // HKEY_CURRENT_USER, under the key path it is constructed with. Loading
  // creates no key and no method raises; a failure sets LastError.
  TStyleChoiceStore = class
  private
    FKey: string;
    FLastError: string;
  public
    // AKey is the key path below HKEY_CURRENT_USER, given without a root key.
    constructor Create(const AKey: string);
    // True when a choice is stored. AFileName receives the style file name
    // without a directory, empty for the system style.
    function Load(out AFileName: string): Boolean;
    // Stores AFileName, a style file name without a directory or empty for
    // the system style, creating the key if needed.
    procedure Save(const AFileName: string);
    // Message from the last Load or Save, empty when it succeeded.
    property LastError: string read FLastError;
  end;

const
  // Key below the settings root that holds the chosen style.
  StyleSettingsKey = 'Appearance';

// Styles folder of the release's shared documents directory; empty when that
// directory is unknown.
function StylesDirectory: string;

// The system style first, then one entry per .vsf file in ADirectory holding a
// valid style, ordered by name. A file declaring a name an entry already
// carries is left out. A missing directory yields the system style alone.
function ListStyles(const ADirectory: string): TArray<TDesignerStyle>;

// ListStyles over StylesDirectory, read on the first call and kept for the
// lifetime of the process.
function InstalledStyles: TArray<TDesignerStyle>;

// Name of the style the windows are drawn in.
function ActiveStyleName: string;

// Draws every window in AStyle from now on, loading its file on first use.
// Existing windows are recreated by a posted message after this returns.
// Raises when the style file cannot be loaded; the active style is then
// unchanged.
procedure ApplyStyle(const AStyle: TDesignerStyle);

// ApplyStyle, then keeps AStyle as the choice of this release. Raises as
// ApplyStyle does, before anything is kept. AKeepError receives why the choice
// could not be kept; empty when it was.
procedure ChooseStyle(const AStyle: TDesignerStyle; out AKeepError: string);

// Applies the style kept for this release; with none kept, or the kept file
// missing, Windows Modern where the release ships it, else the system style.
// Must run before the first window is created. Its warnings are held until
// ReportStartupStyle.
procedure ApplyStartupStyle;

// Writes the warnings ApplyStartupStyle held and the name of the style in use
// into ALog, and forgets the warnings.
procedure ReportStartupStyle(ALog: TDesignLog);

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.IOUtils,
  System.Win.Registry,
  System.Generics.Collections,
  System.Generics.Defaults,
  Vcl.Themes,
  Vcl.Styles,
  Vallenta.FormEditor.Core.Settings,
  Vallenta.FormEditor.Packages.Discovery;

const
  // Registry value, style file extension, and the style applied when no
  // choice is kept and the release ships it.
  StyleValue = 'Style';
  StyleExtension = '.vsf';
  DefaultStyleFile = 'WindowsModern.vsf';

var
  // The list InstalledStyles returns, and whether it has been read.
  Installed: TArray<TDesignerStyle>;
  InstalledRead: Boolean;
  // Warnings ApplyStartupStyle recorded for ReportStartupStyle.
  StartupNotes: TArray<TDesignLogEntry>;

procedure Note(const AText: string);
var
  Entry: TDesignLogEntry;
begin
  Entry.Severity := lsWarn;
  Entry.Text := AText;
  StartupNotes := StartupNotes + [Entry];
end;

{ TStyleChoiceStore }

constructor TStyleChoiceStore.Create(const AKey: string);
begin
  inherited Create;
  FKey := AKey;
end;

function TStyleChoiceStore.Load(out AFileName: string): Boolean;
var
  Registry: TRegistry;
begin
  FLastError := '';
  AFileName := '';
  Result := False;
  try
    Registry := TRegistry.Create(KEY_READ);
    try
      Registry.RootKey := HKEY_CURRENT_USER;
      if not Registry.OpenKeyReadOnly(FKey) or
         not Registry.ValueExists(StyleValue) then
        Exit;
      AFileName := Registry.ReadString(StyleValue);
      Result := True;
    finally
      Registry.Free;
    end;
  except
    on E: Exception do
    begin
      FLastError := E.Message;
      AFileName := '';
      Result := False;
    end;
  end;
end;

procedure TStyleChoiceStore.Save(const AFileName: string);
var
  Registry: TRegistry;
begin
  FLastError := '';
  try
    Registry := TRegistry.Create(KEY_READ or KEY_WRITE);
    try
      Registry.RootKey := HKEY_CURRENT_USER;
      if Registry.OpenKey(FKey, True) then
        Registry.WriteString(StyleValue, AFileName)
      else
        FLastError := Format('cannot open HKEY_CURRENT_USER\%s', [FKey]);
    finally
      Registry.Free;
    end;
  except
    on E: Exception do
      FLastError := E.Message;
  end;
end;

function StylesDirectory: string;
begin
  Result := IdeCommonDirectory;
  if Result <> '' then
    Result := TPath.Combine(Result, 'Styles');
end;

function ListStyles(const ADirectory: string): TArray<TDesignerStyle>;
var
  Found: TList<TDesignerStyle>;
  FileName: string;
  Info: TStyleInfo;
  Style: TDesignerStyle;

  function Listed(const AName: string): Boolean;
  var
    Entry: TDesignerStyle;
  begin
    Result := SameText(AName, TStyleManager.SystemStyleName);
    for Entry in Found do
      if SameText(Entry.Name, AName) then
        Exit(True);
  end;

begin
  Found := TList<TDesignerStyle>.Create;
  try
    if (ADirectory <> '') and TDirectory.Exists(ADirectory) then
      for FileName in TDirectory.GetFiles(ADirectory, '*' + StyleExtension) do
        // The mask also matches a longer extension through the 8.3 file name.
        if SameText(TPath.GetExtension(FileName), StyleExtension) and
           TStyleManager.IsValidStyle(FileName, Info) and (Info.Name <> '') and
           not Listed(Info.Name) then
        begin
          Style.Name := Info.Name;
          Style.FileName := FileName;
          Found.Add(Style);
        end;
    Found.Sort(TComparer<TDesignerStyle>.Construct(
      function(const ALeft, ARight: TDesignerStyle): Integer
      begin
        Result := CompareText(ALeft.Name, ARight.Name);
      end));
    Style.Name := TStyleManager.SystemStyleName;
    Style.FileName := '';
    Found.Insert(0, Style);
    Result := Found.ToArray;
  finally
    Found.Free;
  end;
end;

function InstalledStyles: TArray<TDesignerStyle>;
begin
  if not InstalledRead then
  begin
    Installed := ListStyles(StylesDirectory);
    InstalledRead := True;
  end;
  Result := Installed;
end;

function ActiveStyleName: string;
begin
  Result := TStyleManager.ActiveStyle.Name;
end;

procedure ApplyStyle(const AStyle: TDesignerStyle);
var
  Loaded: TCustomStyleServices;
begin
  if AStyle.FileName = '' then
  begin
    TStyleManager.SetStyle(TStyleManager.SystemStyle);
    Exit;
  end;
  // A file is loaded once: loading a second file that declares a name already
  // known raises.
  Loaded := TStyleManager.Style[AStyle.Name];
  if Loaded = nil then
    TStyleManager.SetStyle(TStyleManager.LoadFromFile(AStyle.FileName))
  else
    TStyleManager.SetStyle(Loaded);
end;

procedure ChooseStyle(const AStyle: TDesignerStyle; out AKeepError: string);
var
  Store: TStyleChoiceStore;
begin
  ApplyStyle(AStyle);
  Store := TStyleChoiceStore.Create(SettingsKey(StyleSettingsKey));
  try
    Store.Save(TPath.GetFileName(AStyle.FileName));
    AKeepError := Store.LastError;
  finally
    Store.Free;
  end;
end;

procedure ApplyStartupStyle;
var
  Store: TStyleChoiceStore;
  Directory, Kept: string;
  IsKept: Boolean;

  // False when AFileName is not a valid style file in Directory or fails to
  // load; a load failure is noted.
  function TryApply(const AFileName: string): Boolean;
  var
    Path: string;
    Info: TStyleInfo;
  begin
    Result := False;
    if (Directory = '') or (AFileName = '') then
      Exit;
    Path := TPath.Combine(Directory, AFileName);
    if not TFile.Exists(Path) or not TStyleManager.IsValidStyle(Path, Info) then
      Exit;
    try
      TStyleManager.SetStyle(TStyleManager.LoadFromFile(Path));
      Result := True;
    except
      on E: Exception do
        Note(Format('the style file %s could not be loaded: %s',
          [Path, E.Message]));
    end;
  end;

begin
  StartupNotes := nil;
  Directory := StylesDirectory;
  Store := TStyleChoiceStore.Create(SettingsKey(StyleSettingsKey));
  try
    IsKept := Store.Load(Kept);
    if Store.LastError <> '' then
      Note(Format('the kept window style could not be read: %s',
        [Store.LastError]));
  finally
    Store.Free;
  end;
  if IsKept and (Kept = '') then
    Exit;
  // A directory in the value is dropped: only the release's own folder is read.
  if IsKept and TryApply(TPath.GetFileName(Kept)) then
    Exit;
  if IsKept then
    Note(Format('the kept window style %s is not installed with this Delphi ' +
      'release - the windows use the default style', [Kept]));
  TryApply(DefaultStyleFile);
end;

procedure ReportStartupStyle(ALog: TDesignLog);
var
  Entry: TDesignLogEntry;
begin
  for Entry in StartupNotes do
    ALog.Add(Entry.Severity, Entry.Text);
  StartupNotes := nil;
  ALog.AddFmt(lsInfo, 'the designer windows are drawn in the %s style',
    [ActiveStyleName]);
end;

end.
