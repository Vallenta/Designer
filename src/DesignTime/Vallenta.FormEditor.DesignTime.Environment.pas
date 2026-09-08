// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.DesignTime.Environment;

// IDesignEnvironment implementation for the design-time layer: the vcldesigner
// package's initializer requires one, and nothing outside the IDE supplies it.
// Most methods return a fixed value; GetMainWindowSize reports the bounds the
// provider set by UseWindowBounds supplies, and the executable and app data
// paths are real. Nothing here is synchronized.
//
// The interface ships only inside designide.dcp; the 32 signatures here were
// recovered by trial compilation against 37.0. An instance handed to the
// package must stay alive for the process lifetime: the package calls back
// into it long after initialization.

interface

uses
  System.Types,
  System.Classes,
  System.IniFiles,
  DesignIntf,
  ComponentDesigner,
  Events;

type
  // Receives the name of a stub method at that method's first call.
  TEnvironmentCall = procedure(const AMethod: string);

  // IDesignEnvironment implementation. Unless a member below carries its own
  // line, it does nothing, leaves its parameters untouched and returns the
  // zero value of its result type. OnCall reporting is deduplicated by
  // method name over the lifetime of the instance.
  TDesignEnvironmentStub = class(TInterfacedObject, IDesignEnvironment)
  private
    FOnCall: TEnvironmentCall;
    FSeen: TStringList;
    procedure Note(const AMethod: string);
  public
    constructor Create;
    destructor Destroy; override;
    { IDesignEnvironment }
    procedure ActiveRootModified;
    procedure RootActivated;
    procedure RootDeactivated;
    procedure ResetCompClass;
    procedure SelectionChanged;
    // Full path of the running executable.
    function GetPathAndBaseExeName: string;
    // Directory of the running executable.
    function GetPrivateDirectory: string;
    // The roaming application data directory. ALocal is ignored; the '= False'
    // default is required, the declaration does not compile without it.
    function GetAppDataDirectory(ALocal: Boolean = False): string;
    function GetTemplateDirectory: string;
    // No IDE registry key is read or written here.
    function GetBaseRegKey: string;
    function GetIDEOptions: TCustomIniFile;
    function GetToolSelected: Boolean;
    function GetCurCompClass: IInternalPaletteItem;
    function GetCurTime: Integer;
    // Rect design-time dialogs position themselves in: the bounds from the
    // provider set by UseWindowBounds, or the desktop work area when no
    // provider is set or the provider returns False.
    function GetMainWindowSize: TRect;
    function GetWorkspaceOrigin: TPoint;
    function GetPackagesEvInstalled: TEvent;
    function GetPackagesEvUninstalling: TEvent;
    function CreateBackupFile: Boolean;
    procedure ComponentRenamed(const AOldName, ANewName: string);
    function FindComponent(const AName: string): TComponent;
    procedure ExecDesignDialog(ADialog: TDesignDialog);
    function GetPaletteItem(AClass: TComponentClass): IInternalPaletteItem;
    procedure GetDesignerOptions(var AOptions: TDesignerOptions);
    function GetComponentClass(const AName: string): TComponentClass;
    procedure LoadCustomModuleClass(const AName: string;
      const ADesigner: IComponentDesigner);
    procedure ModalEdit(AKey: Char; const AActivatable: IActivatable);
    procedure OpenRoot(const AName: string; AFocus: Boolean);
    procedure SelectItemName(const AName: string);
    // AFileName with '.~bak' appended.
    function MakeBackupFileName(const AFileName: string): string;
    procedure RequestTemplate(const AName, ADescription: string;
      AStream: TStream; AStrings: TStrings);
    procedure ItemDeleted(const ADesigner: IDesigner; AItem: TPersistent);
    // Fires once per method name, at that method's first call.
    property OnCall: TEnvironmentCall read FOnCall write FOnCall;
  end;

  // Supplies the bounds design-time dialogs are placed over. Returns False
  // when no bounds are available, leaving ABounds untouched.
  TWindowBoundsProvider = function(out ABounds: TRect): Boolean of object;

// Sets the provider GetMainWindowSize reads. The provider is held module-wide
// beyond the lifetime of the object supplying it, so that object must call
// UseWindowBounds(nil) before it is destroyed.
procedure UseWindowBounds(const AProvider: TWindowBoundsProvider);

implementation

uses
  System.SysUtils,
  System.IOUtils,
  Vcl.Forms;

var
  WindowBounds: TWindowBoundsProvider = nil;

procedure UseWindowBounds(const AProvider: TWindowBoundsProvider);
begin
  WindowBounds := AProvider;
end;

constructor TDesignEnvironmentStub.Create;
begin
  inherited Create;
  FSeen := TStringList.Create;
  FSeen.Sorted := True;
  FSeen.Duplicates := dupIgnore;
end;

destructor TDesignEnvironmentStub.Destroy;
begin
  FSeen.Free;
  inherited Destroy;
end;

procedure TDesignEnvironmentStub.Note(const AMethod: string);
var
  Index: Integer;
begin
  if FSeen.Find(AMethod, Index) then
    Exit;
  FSeen.Add(AMethod);
  if Assigned(FOnCall) then
    FOnCall(AMethod);
end;

procedure TDesignEnvironmentStub.ActiveRootModified;
begin
  Note('ActiveRootModified');
end;

procedure TDesignEnvironmentStub.RootActivated;
begin
  Note('RootActivated');
end;

procedure TDesignEnvironmentStub.RootDeactivated;
begin
  Note('RootDeactivated');
end;

procedure TDesignEnvironmentStub.ResetCompClass;
begin
  Note('ResetCompClass');
end;

procedure TDesignEnvironmentStub.SelectionChanged;
begin
  Note('SelectionChanged');
end;

function TDesignEnvironmentStub.GetPathAndBaseExeName: string;
begin
  Note('GetPathAndBaseExeName');
  Result := ParamStr(0);
end;

function TDesignEnvironmentStub.GetPrivateDirectory: string;
begin
  Note('GetPrivateDirectory');
  Result := ExtractFilePath(ParamStr(0));
end;

function TDesignEnvironmentStub.GetAppDataDirectory(ALocal: Boolean): string;
begin
  Note('GetAppDataDirectory');
  Result := TPath.GetHomePath;
end;

function TDesignEnvironmentStub.GetTemplateDirectory: string;
begin
  Note('GetTemplateDirectory');
  Result := '';
end;

function TDesignEnvironmentStub.GetBaseRegKey: string;
begin
  Note('GetBaseRegKey');
  Result := '';
end;

function TDesignEnvironmentStub.GetIDEOptions: TCustomIniFile;
begin
  Note('GetIDEOptions');
  Result := nil;
end;

function TDesignEnvironmentStub.GetToolSelected: Boolean;
begin
  Note('GetToolSelected');
  Result := False;
end;

function TDesignEnvironmentStub.GetCurCompClass: IInternalPaletteItem;
begin
  Note('GetCurCompClass');
  Result := nil;
end;

function TDesignEnvironmentStub.GetCurTime: Integer;
begin
  Note('GetCurTime');
  Result := 0;
end;

function TDesignEnvironmentStub.GetMainWindowSize: TRect;
begin
  Note('GetMainWindowSize');
  if not (Assigned(WindowBounds) and WindowBounds(Result)) then
    Result := Screen.WorkAreaRect;
end;

function TDesignEnvironmentStub.GetWorkspaceOrigin: TPoint;
begin
  Note('GetWorkspaceOrigin');
  Result := TPoint.Create(0, 0);
end;

function TDesignEnvironmentStub.GetPackagesEvInstalled: TEvent;
begin
  Note('GetPackagesEvInstalled');
  Result := nil;
end;

function TDesignEnvironmentStub.GetPackagesEvUninstalling: TEvent;
begin
  Note('GetPackagesEvUninstalling');
  Result := nil;
end;

function TDesignEnvironmentStub.CreateBackupFile: Boolean;
begin
  Note('CreateBackupFile');
  Result := False;
end;

procedure TDesignEnvironmentStub.ComponentRenamed(const AOldName,
  ANewName: string);
begin
  Note('ComponentRenamed');
end;

function TDesignEnvironmentStub.FindComponent(const AName: string): TComponent;
begin
  Note('FindComponent');
  Result := nil;
end;

procedure TDesignEnvironmentStub.ExecDesignDialog(ADialog: TDesignDialog);
begin
  Note('ExecDesignDialog');
end;

function TDesignEnvironmentStub.GetPaletteItem(
  AClass: TComponentClass): IInternalPaletteItem;
begin
  Note('GetPaletteItem');
  Result := nil;
end;

procedure TDesignEnvironmentStub.GetDesignerOptions(
  var AOptions: TDesignerOptions);
begin
  Note('GetDesignerOptions');
end;

function TDesignEnvironmentStub.GetComponentClass(
  const AName: string): TComponentClass;
begin
  Note('GetComponentClass');
  Result := nil;
end;

procedure TDesignEnvironmentStub.LoadCustomModuleClass(const AName: string;
  const ADesigner: IComponentDesigner);
begin
  Note('LoadCustomModuleClass');
end;

procedure TDesignEnvironmentStub.ModalEdit(AKey: Char;
  const AActivatable: IActivatable);
begin
  Note('ModalEdit');
end;

procedure TDesignEnvironmentStub.OpenRoot(const AName: string;
  AFocus: Boolean);
begin
  Note('OpenRoot');
end;

procedure TDesignEnvironmentStub.SelectItemName(const AName: string);
begin
  Note('SelectItemName');
end;

function TDesignEnvironmentStub.MakeBackupFileName(
  const AFileName: string): string;
begin
  Note('MakeBackupFileName');
  Result := AFileName + '.~bak';
end;

procedure TDesignEnvironmentStub.RequestTemplate(const AName,
  ADescription: string; AStream: TStream; AStrings: TStrings);
begin
  Note('RequestTemplate');
end;

procedure TDesignEnvironmentStub.ItemDeleted(const ADesigner: IDesigner;
  AItem: TPersistent);
begin
  Note('ItemDeleted');
end;

end.
