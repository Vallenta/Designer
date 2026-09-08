// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Streaming.Loader;

// Streams a .dfm (text or TPF0 binary) into a stub root without the declared
// class being compiled in, and records what the load captures for the caller
// and the save side: the declared root class name, the root kind, the streamed
// design position and the interned event handler names. Prepare classifies the
// root, CreateDesignDocument builds the stub, StreamInto fills it.
//
// Not thread-safe: nothing here locks, and a load builds VCL forms and
// frames, which the VCL requires on the main thread.

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Vcl.Controls,
  Vcl.Forms,
  Vallenta.FormEditor.Streaming.Ancestors,
  Vallenta.FormEditor.Streaming.EventNames,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Streaming.TextSpans,
  Vallenta.FormEditor.Streaming.Frames,
  Vallenta.FormEditor.Streaming.Preserved,
  Vallenta.FormEditor.Streaming.RootClassifier;

type
  // Raised when a form file cannot be loaded.
  EFormLoadError = class(Exception);

  // Root state captured during the load: the declared class name, the root
  // kind, the design position as streamed, and the name of the root's
  // ActiveControl at the end of the load.
  TLoadedFormState = record
    RootClassName: string;
    RootKind: TDesignRootClass;
    Left: Integer;
    Top: Integer;
    ActiveControlName: string;
  end;

  // The stub a document is designed in. Root is the designed component; a
  // form is its own HostForm, a frame is parented into a chrome-only host
  // form, and a data module has no window, so HostForm stays nil.
  TDesignDocument = record
    Root: TComponent;
    HostForm: TCustomForm;
  end;

  // Another module loaded so that the document's dotted references resolve,
  // e.g. "DataModuleEZI.DataSourceOPKreditoren". Loaded for its components
  // only: never shown, never saved. EventMap interns the handler names those
  // components hold markers for and must outlive them.
  TLinkedModule = record
    ModuleName: string;
    FileName: string;
    Document: TDesignDocument;
    EventMap: TEventNameMap;
  end;

  // Why a form file was read besides the document.
  TSourceKind = (skAncestor, skFrame);

  // One form file read besides the document; FileName is a full path.
  TSourceFile = record
    FileName: string;
    Kind: TSourceKind;
  end;

  // A property line to be kept verbatim, identified by the component that
  // carries it; component names are unique within a form file.
  TUnreadProperty = record
    ComponentName: string;
    PropertyName: string;
  end;

  // Loads one form file. A Prepare call classifies the root; StreamInto then
  // fills the stub the caller created for that kind.
  TFormLoader = class
  private
    FLog: TDesignLog;
    FEventMap: TEventNameMap;
    FLoadedState: TLoadedFormState;
    FPendingUnknownClass: string;
    FUnknownClasses: TStringList;
    FUnreadProperties: TList<TUnreadProperty>;
    FCurrentComponent: string;
    FPreserved: TPreservedModel;
    FClassIndex: TDfmClassIndex;
    FFrames: TFrameInstances;
    FChain: TAncestorChain;
    FAncestor: TDesignDocument;
    FPendingFrameClass: string;
    // >0 while a file other than the document is read (an ancestor or a
    // frame file), FOutsideFile naming it. Nothing from such a file is
    // preserved verbatim, and its warnings name the file, not the document.
    FOutsideDocument: Integer;
    FOutsideFile: string;
    FOtherFiles: TArray<TSourceFile>;
    // Modules loaded for cross-module references, held by the outermost
    // loader; a nested loader delegates through FLinkedParent so that one
    // load shares one set.
    FLinkedModules: TArray<TLinkedModule>;
    FLinkedParent: TFormLoader;
    FLinkedFailed: TStringList;
    FLinkedLoading: TStringList;
    // Search-path directories passed down by the load that started this one.
    FInheritedSearchPath: TArray<string>;
    FUnresolvedReferences: TArray<string>;
    FSourceText: string;
    FBinary: TMemoryStream;
    FFileName: string;
    FRootObjectName: string;
    FQuiet: Boolean;
    procedure NoteOtherFile(const AFileName: string; AKind: TSourceKind);
    function ToBinaryDfm(AInput: TStream; const AWhat: string): TMemoryStream;
    function ReadFileToBinaryDfm(const FileName: string): TMemoryStream;
    function InlineClassesIn(const AText: string): TArray<string>;
    procedure PlanFrames(const AText: string);
    procedure RefuseFramesInDescendant(const AText: string);
    function LoadFrameFile(const AFileName, ADeclaredClass: string;
      AOwner: TComponent): TComponent;
    procedure StreamFrom(ABinary: TStream; ARoot: TComponent);
    procedure StreamOtherFile(ABinary: TStream; ARoot: TComponent;
      const AFileName: string; AKind: TSourceKind);
    procedure StreamAncestorInto(const AFileName: string; ARoot: TComponent);
    procedure StreamAncestors(ARoot: TComponent);
    procedure BuildPristineAncestor;
    procedure HandleFindComponentClass(Reader: TReader; const AClassName: string;
      var ComponentClass: TComponentClass);
    procedure HandleCreateComponent(Reader: TReader;
      ComponentClass: TComponentClass; var Component: TComponent);
    procedure HandleReaderError(Reader: TReader; const AMessage: string;
      var Handled: Boolean);
    procedure HandleSetName(Reader: TReader; Component: TComponent;
      var Name: string);
    procedure HandleClassClash(const AClassName, AKept, ADropped: string);
    procedure HandleFindComponentInstance(Reader: TReader; const Name: string;
      var Instance: Pointer);
    function LinkedModuleRoot(const AModuleName: string): TComponent;
    procedure DropLinkedModules;
    procedure CollectUnresolvedReferences(ARoot: TComponent);
    procedure PreserveModuleReferences(ADocument: TDfmDocument);
    procedure BuildPreserved;
    procedure PreserveBlocksIn(ABlock: TDfmBlock);
    procedure PreserveUnreadProperties(ADocument: TDfmDocument);
    procedure PrepareImage(AImage: TStream; const AWhat: string;
      const AState: TLoadedFormState; const ADocumentFile: string);
  public
    constructor Create(ALog: TDesignLog);
    destructor Destroy; override;
    // Reads the file and determines the root kind. Builds no components; the
    // caller creates the document that kind requires.
    procedure Prepare(const FileName: string);
    // Prepares a reload from an undo snapshot of the live document. The image
    // holds no root kind and carries the stub's class name, so both come from
    // AState; ancestors and frame files are re-read from disk, resolved
    // against ADocumentFile's directory. Logs less than a regular open.
    procedure PrepareFromSnapshot(ASnapshot: TStream;
      const AState: TLoadedFormState; const ADocumentFile: string);
    // Prepares a load from the recovery journal's copy, a complete form file
    // including the preserved blocks. Root kind and declared class come from
    // AState: the kind is derived from the document's directory, which the
    // copy does not sit in, and the class is not read back out of the image.
    // Logs like a regular open.
    procedure PrepareRecovered(const ARecoveryFile: string;
      const AState: TLoadedFormState; const ADocumentFile: string);
    // Prepares a module that is loaded only for its components. Like Prepare,
    // but the lines "Active = True", "Connected = True" and "Visible = True"
    // are dropped from the text first, so that no component goes live during
    // the load, and less is logged.
    procedure PrepareLinked(const FileName: string);
    // Adds the directories of the load that started this one to those
    // searched for ancestors, frame files and linked modules. Must be called
    // before Prepare; ADirectories is copied.
    procedure InheritSearchPath(const ADirectories: TArray<string>);
    // Streams the prepared file into ARoot, the stub built for RootKind, and
    // captures the state the save side needs. Raises EFormLoadError when no
    // Prepare call ran.
    procedure StreamInto(ARoot: TComponent);
    // Transfers ownership of the interned event handler names. The map must
    // outlive the document: saving resolves handler markers through it.
    function ExtractEventMap: TEventNameMap;
    // Transfers ownership of the verbatim-kept pieces. They must outlive the
    // document: saving splices them back into the output.
    function ExtractPreserved: TPreservedModel;
    // Transfers ownership of the frame instances. Saving diffs each instance
    // against the untouched instance held there and takes the declared class
    // names from it.
    function ExtractFrames: TFrameInstances;
    // Transfers ownership of the ancestor-only document a descendant is
    // diffed against when saving. Root is nil when the document has no
    // ancestor.
    function ExtractAncestor: TDesignDocument;
    // Transfers ownership of the linked modules. They must outlive the
    // document and the ancestor, whose components hold references into them.
    function ExtractLinkedModules: TArray<TLinkedModule>;
    // References ("Module.Component") the load could not resolve; the shell
    // guards the document read-only while any remain. Filled by StreamInto.
    property UnresolvedReferences: TArray<string> read FUnresolvedReferences;
    // Interned event handler names; nil after ExtractEventMap.
    property EventMap: TEventNameMap read FEventMap;
    // Pieces of the file kept verbatim; nil after ExtractPreserved.
    property Preserved: TPreservedModel read FPreserved;
    // Frame instances of the document; nil after ExtractFrames.
    property Frames: TFrameInstances read FFrames;
    // Ancestor-only document; cleared after ExtractAncestor.
    property Ancestor: TDesignDocument read FAncestor;
    // State captured for the save side; complete after StreamInto.
    property LoadedState: TLoadedFormState read FLoadedState;
    // Root kind, set by whichever Prepare call ran.
    property RootKind: TDesignRootClass read FLoadedState.RootKind;
    // Form files this document draws on besides its own: ancestors and frame
    // files, each an absolute path listed once.
    property SourceFiles: TArray<TSourceFile> read FOtherFiles;
  end;

const
  // Design-surface layout, in pixels. FrameHostMargin is the gap between a
  // frame and its host form's edge, wide enough for the selection handles of
  // a selected frame root.
  FrameHostMargin = 6;
  SurfaceMargin = 8;

// Puts AComponent and its children into design mode. Must run before
// streaming, so that components stay inert while their properties are read.
procedure EnterDesignMode(AComponent: TComponent);

// Builds the stub root for AKind and, for a frame, the host form it is
// parented into. Released with FreeDesignDocument.
function CreateDesignDocument(AKind: TDesignRootClass): TDesignDocument;

// Frees the root and the host form and clears the record. A form, which is
// its own host, is freed once.
procedure FreeDesignDocument(var ADocument: TDesignDocument);

// Parents the designed form into the design surface and restores State.Left
// and State.Top as the stored design position. Nothing is written to make the
// form appear: a design-mode control is shown by its parent regardless of its
// own Visible value.
procedure EmbedDesignedForm(Form: TCustomForm; Surface: TWinControl;
  const State: TLoadedFormState);

// Parents a frame into its host form. Required even when nothing is shown: an
// unparented frame reads TabOrder as -1, which the saver would drop as a
// default.
procedure AttachFrameToHost(const ADocument: TDesignDocument);

// Parents the host form into the surface and attaches the frame to it.
procedure EmbedDesignedFrame(const ADocument: TDesignDocument; Surface: TWinControl);

// Sizes the host form's client area around the frame; the frame's own Left
// and Top are left as streamed.
procedure SizeFrameHost(AHost: TCustomForm; AFrame: TControl);

// Runs Action and restores the form's Position afterwards. Assigning Left or
// Top to an embedded design-mode root forces Position to a designed value,
// silently changing a stored property; every writer of Left or Top must go
// through here.
procedure PreservingPosition(Form: TCustomForm; const Action: TProc);

implementation

uses
  Winapi.Windows,
  Vallenta.FormEditor.Core.ComponentRegistry,
  Vallenta.FormEditor.Core.SearchPath;

type
  TComponentAccess = class(TComponent);
  TFormAccess = class(TCustomForm);

procedure EnterDesignMode(AComponent: TComponent);
begin
  TComponentAccess(AComponent).SetDesigning(True);
end;

procedure PreservingPosition(Form: TCustomForm; const Action: TProc);
var
  SavedPosition: TPosition;
begin
  SavedPosition := TFormAccess(Form).Position;
  try
    Action;
  finally
    TFormAccess(Form).Position := SavedPosition;
  end;
end;

function CreateDesignDocument(AKind: TDesignRootClass): TDesignDocument;
begin
  Result.Root := nil;
  Result.HostForm := nil;
  case AKind of
    drForm:
      begin
        Result.HostForm := TForm.Create(nil);
        Result.Root := Result.HostForm;
      end;
    drFrame:
      begin
        Result.HostForm := TForm.CreateNew(nil);
        Result.HostForm.BorderStyle := bsNone;
        EnterDesignMode(Result.HostForm);
        Result.Root := TFrame.Create(nil);
      end;
    drDataModule:
      begin
        Result.Root := TDataModule.CreateNew(nil);
        // A code-created data module has PixelsPerInch 0, which the filer
        // would store; the default screen DPI keeps the property unwritten
        // unless the file sets one.
        TDataModule(Result.Root).PixelsPerInch := USER_DEFAULT_SCREEN_DPI;
      end;
  end;
end;

procedure FreeDesignDocument(var ADocument: TDesignDocument);
var
  Host: TCustomForm;
begin
  Host := ADocument.HostForm;
  if TComponent(Host) = ADocument.Root then
    Host := nil;
  ADocument.HostForm := nil;
  FreeAndNil(ADocument.Root);
  Host.Free;
end;

procedure SizeFrameHost(AHost: TCustomForm; AFrame: TControl);
begin
  AHost.ClientWidth := AFrame.Left + AFrame.Width + FrameHostMargin;
  AHost.ClientHeight := AFrame.Top + AFrame.Height + FrameHostMargin;
end;

procedure AttachFrameToHost(const ADocument: TDesignDocument);
var
  Frame: TControl;
begin
  Frame := ADocument.Root as TControl;
  Frame.Parent := ADocument.HostForm;
  SizeFrameHost(ADocument.HostForm, Frame);
end;

procedure EmbedDesignedFrame(const ADocument: TDesignDocument; Surface: TWinControl);
begin
  ADocument.HostForm.Parent := Surface;
  AttachFrameToHost(ADocument);
  ADocument.HostForm.SetBounds(SurfaceMargin, SurfaceMargin,
    ADocument.HostForm.Width, ADocument.HostForm.Height);
  ADocument.HostForm.UpdateControlState;
end;

procedure EmbedDesignedForm(Form: TCustomForm; Surface: TWinControl;
  const State: TLoadedFormState);
begin
  Form.Parent := Surface;
  PreservingPosition(Form,
    procedure
    begin
      Form.Left := State.Left;
      Form.Top := State.Top;
    end);
  Form.SetBounds(SurfaceMargin, SurfaceMargin, Form.Width, Form.Height);
  Form.UpdateControlState;
end;

{ TFormLoader }

constructor TFormLoader.Create(ALog: TDesignLog);
begin
  inherited Create;
  FLog := ALog;
  FEventMap := TEventNameMap.Create;
  FPreserved := TPreservedModel.Create;
  FClassIndex := TDfmClassIndex.Create;
  FClassIndex.OnClash := HandleClassClash;
  FChain := TAncestorChain.Create(ALog, FClassIndex);
  FFrames := TFrameInstances.Create(ALog, FClassIndex);
  FFrames.OnLoadFrame := LoadFrameFile;
  FUnknownClasses := TStringList.Create;
  FUnknownClasses.CaseSensitive := False;
  FUnknownClasses.Duplicates := dupIgnore;
  FUnknownClasses.Sorted := True;
  FUnreadProperties := TList<TUnreadProperty>.Create;
  FLinkedFailed := TStringList.Create;
  FLinkedFailed.CaseSensitive := False;
  FLinkedFailed.Duplicates := dupIgnore;
  FLinkedFailed.Sorted := True;
  FLinkedLoading := TStringList.Create;
  FLinkedLoading.CaseSensitive := False;
end;

destructor TFormLoader.Destroy;
begin
  FUnreadProperties.Free;
  FUnknownClasses.Free;
  FBinary.Free;
  FreeDesignDocument(FAncestor);
  // After the ancestor: its components may hold references into the linked
  // modules.
  DropLinkedModules;
  FLinkedLoading.Free;
  FLinkedFailed.Free;
  FFrames.Free;
  FChain.Free;
  FClassIndex.Free;
  FPreserved.Free;
  FEventMap.Free;
  inherited Destroy;
end;

function TFormLoader.ExtractEventMap: TEventNameMap;
begin
  Result := FEventMap;
  FEventMap := nil;
end;

function TFormLoader.ExtractPreserved: TPreservedModel;
begin
  Result := FPreserved;
  FPreserved := nil;
end;

function TFormLoader.ExtractLinkedModules: TArray<TLinkedModule>;
begin
  Result := FLinkedModules;
  FLinkedModules := nil;
end;

procedure TFormLoader.InheritSearchPath(const ADirectories: TArray<string>);
begin
  FInheritedSearchPath := Copy(ADirectories);
end;

procedure TFormLoader.DropLinkedModules;
var
  I: Integer;
begin
  for I := 0 to High(FLinkedModules) do
  begin
    FreeDesignDocument(FLinkedModules[I].Document);
    FLinkedModules[I].EventMap.Free;
  end;
  FLinkedModules := nil;
end;

function TFormLoader.ExtractFrames: TFrameInstances;
begin
  Result := FFrames;
  FFrames := nil;
end;

function TFormLoader.ExtractAncestor: TDesignDocument;
begin
  Result := FAncestor;
  FAncestor.Root := nil;
  FAncestor.HostForm := nil;
end;

function TFormLoader.ToBinaryDfm(AInput: TStream; const AWhat: string): TMemoryStream;
begin
  AInput.Position := 0;
  Result := TMemoryStream.Create;
  try
    case TestStreamFormat(AInput) of
      sofText, sofUTF8Text:
        begin
          AInput.Position := 0;
          ObjectTextToBinary(AInput, Result);
          if not FQuiet then
            FLog.Add(lsInfo, 'input format: text (converted to TPF0 in memory)');
        end;
      sofBinary:
        begin
          AInput.Position := 0;
          SeekDfmSignature(AInput);
          if not FQuiet then
          begin
            if AInput.Position > 0 then
              FLog.Add(lsInfo,
                'input format: binary (TPF0 in a resource wrapper)')
            else
              FLog.Add(lsInfo, 'input format: binary (TPF0)');
          end;
          Result.CopyFrom(AInput, AInput.Size - AInput.Position);
        end;
    else
      raise EFormLoadError.CreateFmt(
        '%s is not recognized as a DFM (neither text nor TPF0 binary).', [AWhat]);
    end;
    Result.Position := 0;
  except
    Result.Free;
    raise;
  end;
end;

function TFormLoader.ReadFileToBinaryDfm(const FileName: string): TMemoryStream;
var
  Input: TMemoryStream;
begin
  Input := TMemoryStream.Create;
  try
    Input.LoadFromFile(FileName);
    Result := ToBinaryDfm(Input, FileName);
  finally
    Input.Free;
  end;
end;

function TFormLoader.InlineClassesIn(const AText: string): TArray<string>;
var
  Document: TDfmDocument;
  Classes: TArray<string>;

  procedure Collect(ABlock: TDfmBlock);
  var
    Child: TDfmBlock;
  begin
    for Child in ABlock.Children do
    begin
      if SameText(Child.Keyword, 'inline') and (Child.DeclaredClass <> '') then
        Classes := Classes + [Child.DeclaredClass];
      Collect(Child);
    end;
  end;

begin
  Document := TDfmDocument.Create(AText);
  try
    Collect(Document.Root);
  finally
    Document.Free;
  end;
  Result := Classes;
end;

procedure TFormLoader.PlanFrames(const AText: string);
begin
  FFrames.RegisterInlineClasses(InlineClassesIn(AText));
end;

procedure TFormLoader.RefuseFramesInDescendant(const AText: string);
begin
  if Length(InlineClassesIn(AText)) = 0 then
    Exit;
  raise EFormLoadError.CreateFmt(
    '%s is built on another form and uses a frame. The designer does not yet ' +
    'read a form that does both.', [ExtractFileName(FFileName)]);
end;

procedure TFormLoader.HandleFindComponentClass(Reader: TReader;
  const AClassName: string; var ComponentClass: TComponentClass);
begin
  // OnFindComponentClass fires for every class, so only a nil ComponentClass
  // on entry means unresolved; the reader raises right after this handler.
  FPendingFrameClass := '';
  if ComponentClass <> nil then
    Exit;
  if (FOutsideDocument = 0) and FFrames.IsFrameClass(AClassName) then
  begin
    ComponentClass := TFrame;
    FPendingFrameClass := AClassName;
    Exit;
  end;
  FPendingUnknownClass := AClassName;
  if FOutsideDocument = 0 then
    FUnknownClasses.Add(AClassName);
end;

procedure TFormLoader.HandleCreateComponent(Reader: TReader;
  ComponentClass: TComponentClass; var Component: TComponent);
var
  DeclaredClass: string;
begin
  // Fires directly after OnFindComponentClass, which set FPendingFrameClass.
  DeclaredClass := FPendingFrameClass;
  FPendingFrameClass := '';
  if DeclaredClass = '' then
    Exit;
  try
    Component := FFrames.CreateInstance(DeclaredClass, Reader.Owner);
  except
    on E: Exception do
    begin
      FFrames.Withdraw(DeclaredClass);
      FPendingUnknownClass := DeclaredClass;
      if FOutsideDocument = 0 then
        FUnknownClasses.Add(DeclaredClass);
      FLog.AddFmt(lsWarn, 'the frame "%s" could not be built: %s',
        [DeclaredClass, E.Message]);
      raise;
    end;
  end;
  // The reader sets the inline flag only on instances it creates itself, and
  // the writer emits a frame instance rather than a plain block only for a
  // flagged one.
  TComponentAccess(Component).SetInline(True);
end;

procedure TFormLoader.HandleSetName(Reader: TReader; Component: TComponent;
  var Name: string);
begin
  // Properties precede nested components in every block, so the component
  // named last is the one whose properties are being read.
  FCurrentComponent := Name;
end;

procedure TFormLoader.HandleClassClash(const AClassName, AKept, ADropped: string);
begin
  FLog.AddFmt(lsWarn, 'both %s and %s declare "%s"; %s is the one used',
    [ExtractFileName(AKept), ExtractFileName(ADropped), AClassName,
     ExtractFileName(AKept)]);
end;

procedure TFormLoader.HandleFindComponentInstance(Reader: TReader;
  const Name: string; var Instance: Pointer);
var
  Dot: Integer;
  Module: TComponent;
begin
  Dot := Pos('.', Name);
  if Dot <= 1 then
    Exit;
  Module := LinkedModuleRoot(Copy(Name, 1, Dot - 1));
  if Module <> nil then
    Instance := FindNestedComponent(Module, Copy(Name, Dot + 1, MaxInt));
end;

function TFormLoader.LinkedModuleRoot(const AModuleName: string): TComponent;
var
  I: Integer;
  FileName: string;
  Nested: TFormLoader;
  Module: TLinkedModule;
begin
  Result := nil;
  if FLinkedParent <> nil then
    Exit(FLinkedParent.LinkedModuleRoot(AModuleName));
  for I := 0 to High(FLinkedModules) do
    if SameText(FLinkedModules[I].ModuleName, AModuleName) then
      Exit(FLinkedModules[I].Document.Root);
  if FLinkedFailed.IndexOf(AModuleName) >= 0 then
    Exit;
  if FLinkedLoading.IndexOf(AModuleName) >= 0 then
  begin
    FLinkedFailed.Add(AModuleName);
    FLog.AddFmt(lsWarn, '"%s" is asked for again while it is still loading - ' +
      'module references run in a circle, and these are kept as written',
      [AModuleName]);
    Exit;
  end;
  if FLinkedLoading.Count >= AncestorDepthLimit then
  begin
    FLinkedFailed.Add(AModuleName);
    FLog.AddFmt(lsWarn, 'module references run deeper than %d files at "%s", ' +
      'which the designer takes for a mistake - these are kept as written',
      [AncestorDepthLimit, AModuleName]);
    Exit;
  end;
  FileName := FClassIndex.FileForInstance(AModuleName);
  if FileName = '' then
  begin
    FLinkedFailed.Add(AModuleName);
    if not FQuiet then
      FLog.AddFmt(lsWarn, 'the document refers into "%s", and no form file ' +
        'beside it or on the search path declares that root - the references ' +
        'are kept as written', [AModuleName]);
    Exit;
  end;
  FLinkedLoading.Add(AModuleName);
  try
    try
      Nested := TFormLoader.Create(FLog);
      try
        Nested.FLinkedParent := Self;
        Nested.InheritSearchPath(FClassIndex.ExtraDirectories);
        Nested.PrepareLinked(FileName);
        Module.Document := CreateDesignDocument(Nested.RootKind);
        try
          Nested.StreamInto(Module.Document.Root);
        except
          FreeDesignDocument(Module.Document);
          raise;
        end;
        Module.ModuleName := AModuleName;
        Module.FileName := ExpandFileName(FileName);
        Module.EventMap := Nested.ExtractEventMap;
        FLinkedModules := FLinkedModules + [Module];
        if not FQuiet then
          FLog.AddFmt(lsInfo, 'linked module "%s" is read from %s',
            [AModuleName, ExtractFileName(FileName)]);
        Result := Module.Document.Root;
      finally
        Nested.Free;
      end;
    except
      on E: Exception do
      begin
        FLinkedFailed.Add(AModuleName);
        FLog.AddFmt(lsWarn, 'the module "%s" could not be loaded from %s - ' +
          'its references are kept as written: %s',
          [AModuleName, ExtractFileName(FileName), E.Message]);
      end;
    end;
  finally
    I := FLinkedLoading.IndexOf(AModuleName);
    if I >= 0 then
      FLinkedLoading.Delete(I);
  end;
end;

procedure TFormLoader.StreamFrom(ABinary: TStream; ARoot: TComponent);
var
  Reader: TDesignReader;
begin
  ABinary.Position := 0;
  Reader := TDesignReader.Create(ABinary, 4096);
  try
    Reader.EventMap := FEventMap;
    if not FQuiet and (FOutsideDocument = 0) then
      Reader.Log := FLog;
    Reader.OnFindComponentClass := HandleFindComponentClass;
    Reader.OnCreateComponent := HandleCreateComponent;
    Reader.OnSetName := HandleSetName;
    Reader.OnFindComponentInstance := HandleFindComponentInstance;
    Reader.OnError := HandleReaderError;
    Reader.ReadRootComponent(ARoot);
  finally
    Reader.Free;
  end;
end;

procedure TFormLoader.NoteOtherFile(const AFileName: string;
  AKind: TSourceKind);
var
  Full: string;
  Present: TSourceFile;
  Noted: TSourceFile;
begin
  Full := ExpandFileName(AFileName);
  for Present in FOtherFiles do
    if SameText(Present.FileName, Full) then
      Exit;
  Noted.FileName := Full;
  Noted.Kind := AKind;
  FOtherFiles := FOtherFiles + [Noted];
end;

procedure TFormLoader.StreamOtherFile(ABinary: TStream; ARoot: TComponent;
  const AFileName: string; AKind: TSourceKind);
var
  Previous: string;
begin
  NoteOtherFile(AFileName, AKind);
  Previous := FOutsideFile;
  FOutsideFile := AFileName;
  Inc(FOutsideDocument);
  try
    StreamFrom(ABinary, ARoot);
  finally
    Dec(FOutsideDocument);
    FOutsideFile := Previous;
  end;
end;

procedure TFormLoader.StreamAncestorInto(const AFileName: string;
  ARoot: TComponent);
var
  Binary: TMemoryStream;
begin
  Binary := ReadFileToBinaryDfm(AFileName);
  try
    if Length(InlineClassesIn(DfmStreamToText(Binary))) > 0 then
      raise EFormLoadError.CreateFmt(
        '%s is built on %s, which uses a frame. The designer does not yet read ' +
        'a form that is both built on another and uses frames.',
        [ExtractFileName(FFileName), ExtractFileName(AFileName)]);
    StreamOtherFile(Binary, ARoot, AFileName, skAncestor);
  finally
    Binary.Free;
  end;
end;

procedure TFormLoader.StreamAncestors(ARoot: TComponent);
var
  FileName: string;
begin
  for FileName in FChain.Files do
    StreamAncestorInto(FileName, ARoot);
end;

procedure TFormLoader.BuildPristineAncestor;
begin
  if Length(FChain.Files) = 0 then
    Exit;
  FAncestor := CreateDesignDocument(FLoadedState.RootKind);
  EnterDesignMode(FAncestor.Root);
  StreamAncestors(FAncestor.Root);
end;

function TFormLoader.LoadFrameFile(const AFileName, ADeclaredClass: string;
  AOwner: TComponent): TComponent;
var
  Frame: TFrame;
  Binary: TMemoryStream;
  Nested: TArray<string>;
begin
  Frame := TFrame.Create(AOwner);
  try
    EnterDesignMode(Frame);
    Binary := ReadFileToBinaryDfm(AFileName);
    try
      Nested := InlineClassesIn(DfmStreamToText(Binary));
      if Length(Nested) > 0 then
        raise EFrameInstanceError.CreateFmt(
          'the frame uses a frame of its own ("%s"), which this designer does ' +
          'not take apart', [Nested[0]]);
      StreamOtherFile(Binary, Frame, AFileName, skFrame);
    finally
      Binary.Free;
    end;
  except
    // AOwner keeps a half-streamed stub alive, and it would be saved as an
    // empty frame.
    Frame.Free;
    raise;
  end;
  Result := Frame;
end;

procedure TFormLoader.HandleReaderError(Reader: TReader; const AMessage: string;
  var Handled: Boolean);
var
  Unread: TUnreadProperty;
begin
  Handled := True;
  if FPendingUnknownClass <> '' then
  begin
    if FOutsideDocument > 0 then
      FLog.AddFmt(lsWarn, 'class "%s" is not registered by any loaded ' +
        'package and is declared in %s, which this save does not write - ' +
        'the component is dropped',
        [FPendingUnknownClass, ExtractFileName(FOutsideFile)])
    else
      FLog.AddFmt(lsWarn, 'class "%s" is not registered by any loaded ' +
        'package - its text is preserved and a placeholder is shown',
        [FPendingUnknownClass]);
    FPendingUnknownClass := '';
    Exit;
  end;
  Unread.ComponentName := FCurrentComponent;
  Unread.PropertyName := TDesignReader(Reader).PropName;
  if Unread.PropertyName = '' then
  begin
    FLog.Add(lsWarn, 'the failing text is not preserved - the error names ' +
      'no property: ' + AMessage);
    Exit;
  end;
  if FOutsideDocument > 0 then
  begin
    FLog.AddFmt(lsWarn, 'skipped in %s, which this save does not write: %s',
      [ExtractFileName(FOutsideFile), AMessage]);
    Exit;
  end;
  FUnreadProperties.Add(Unread);
  FLog.Add(lsWarn, 'preserved unread: ' + AMessage);
end;

procedure TFormLoader.Prepare(const FileName: string);
var
  Header: TDfmRootHeader;
  Classification: TRootKind;
begin
  FPendingUnknownClass := '';
  if not FileExists(FileName) then
    raise EFormLoadError.CreateFmt('File not found: %s', [FileName]);

  FFileName := FileName;
  FreeAndNil(FBinary);
  FBinary := ReadFileToBinaryDfm(FileName);
  Header := ReadDfmRootHeader(FBinary);
  FLoadedState.RootClassName := Header.ClassName;
  FRootObjectName := Header.ObjectName;
  if Header.Kind = rkInline then
    raise EFormLoadError.CreateFmt(
      '"%s: %s" is an embedded frame ("inline" root). The designer loads a ' +
      'frame from the file the frame itself is in.',
      [FRootObjectName, FLoadedState.RootClassName]);

  FSourceText := DfmStreamToText(FBinary);
  FClassIndex.SearchIn(ExtractFilePath(FileName),
    SearchPathFor(FileName) + FInheritedSearchPath);
  if Length(FClassIndex.ExtraDirectories) > 0 then
    FLog.AddFmt(lsInfo, 'search path: %d location(s) besides the ' +
      'document''s directory', [Length(FClassIndex.ExtraDirectories)]);

  if Header.Kind = rkInherited then
  begin
    // A descendant's own file holds only overrides and need not indicate a
    // kind at all, so the kind comes from the chain's base class.
    FChain.Resolve(FileName, FLoadedState.RootClassName);
    FLoadedState.RootKind := FChain.BaseKind;
    FLog.AddFmt(lsInfo, 'root kind: %s (built on %s)',
      [RootKindName(FChain.BaseKind), FChain.BaseClass]);
    RefuseFramesInDescendant(FSourceText);
    Exit;
  end;

  PlanFrames(FSourceText);
  Classification := ClassifyDesignRoot(FileName, FLoadedState.RootClassName, FBinary);
  FLoadedState.RootKind := Classification.Kind;
  FLog.AddFmt(lsInfo, 'root kind: %s', [DescribeRootKind(Classification)]);
  if Classification.Source = rksAssumed then
    FLog.AddFmt(lsWarn, 'root kind assumed: form - %s', [Classification.Detail]);
end;

procedure TFormLoader.PrepareLinked(const FileName: string);
var
  Lines: TStringList;
  I: Integer;
  Line: string;
  Text: TStringStream;
begin
  FQuiet := True;
  Prepare(FileName);
  Lines := TStringList.Create;
  try
    Lines.Text := FSourceText;
    for I := Lines.Count - 1 downto 0 do
    begin
      Line := Trim(Lines[I]);
      if SameText(Line, 'Active = True') or
         SameText(Line, 'Connected = True') or
         SameText(Line, 'Visible = True') then
        Lines.Delete(I);
    end;
    FSourceText := Lines.Text;
  finally
    Lines.Free;
  end;
  Text := TStringStream.Create(FSourceText, TEncoding.UTF8);
  try
    FreeAndNil(FBinary);
    FBinary := ToBinaryDfm(Text, FileName);
  finally
    Text.Free;
  end;
end;

function BlockIntProperty(ABlock: TDfmBlock; const AText, AName: string;
  out AValue: Integer): Boolean;
var
  Index, Assign: Integer;
  Line: string;
begin
  Result := False;
  AValue := 0;
  Index := ABlock.IndexOfProperty(AName);
  if Index < 0 then
    Exit;
  Line := ABlock.Properties[Index].Span.TextIn(AText);
  Assign := Pos('=', Line);
  if Assign = 0 then
    Exit;
  Result := TryStrToInt(Trim(Copy(Line, Assign + 1, Length(Line))), AValue);
end;

procedure ReadPlaceholderBounds(ABlock: TDfmBlock; const AText: string;
  APiece: TPreservedPiece);
var
  Left, Top, Width, Height: Integer;
  HasWidth, HasHeight: Boolean;
begin
  BlockIntProperty(ABlock, AText, 'Left', Left);
  BlockIntProperty(ABlock, AText, 'Top', Top);
  HasWidth := BlockIntProperty(ABlock, AText, 'Width', Width);
  HasHeight := BlockIntProperty(ABlock, AText, 'Height', Height);
  APiece.HasSize := HasWidth and HasHeight;
  APiece.HasTabOrder := BlockIntProperty(ABlock, AText, 'TabOrder',
    APiece.TabOrder);
  if APiece.HasSize then
    APiece.Bounds := TRect.Create(Left, Top, Left + Width, Top + Height)
  else
    APiece.Bounds := TRect.Create(Left, Top, Left, Top);
end;

procedure ReserveNamesIn(AModel: TPreservedModel; ABlock: TDfmBlock);
var
  Child: TDfmBlock;
begin
  AModel.ReserveName(ABlock.Name);
  for Child in ABlock.Children do
    ReserveNamesIn(AModel, Child);
end;

procedure TFormLoader.PreserveBlocksIn(ABlock: TDfmBlock);
var
  Child: TDfmBlock;
  Piece: TPreservedPiece;
begin
  for Child in ABlock.Children do
  begin
    if FUnknownClasses.IndexOf(Child.DeclaredClass) < 0 then
    begin
      PreserveBlocksIn(Child);
      Continue;
    end;
    if ABlock.Name = '' then
      raise EFormLoadError.CreateFmt(
        'The block holding "%s" carries no name, so its text could not be put ' +
        'back where it belongs.', [Child.DeclaredClass]);
    Piece := TPreservedPiece.Create;
    Piece.Kind := pkBlock;
    Piece.OwnerName := ABlock.Name;
    Piece.Index := Child.IndexInParent;
    Piece.Text := Child.Span.TextIn(FSourceText);
    Piece.ComponentName := Child.Name;
    Piece.DeclaredClass := Child.DeclaredClass;
    ReadPlaceholderBounds(Child, FSourceText, Piece);
    FPreserved.Add(Piece);
    ReserveNamesIn(FPreserved, Child);
  end;
end;

procedure TFormLoader.PreserveUnreadProperties(ADocument: TDfmDocument);
var
  Unread: TUnreadProperty;
  Block: TDfmBlock;
  Index, Searched: Integer;
  LastOwner: string;
  Piece: TPreservedPiece;
begin
  Searched := 0;
  for Unread in FUnreadProperties do
  begin
    // Unread properties arrive in file order per component; the search
    // resumes after the previous match to keep repeated names apart.
    if not SameText(Unread.ComponentName, LastOwner) then
    begin
      LastOwner := Unread.ComponentName;
      Searched := 0;
    end;
    Block := ADocument.FindBlock(Unread.ComponentName);
    if Block <> nil then
      Index := Block.IndexOfProperty(Unread.PropertyName, Searched)
    else
      Index := -1;
    if Index < 0 then
    begin
      FLog.AddFmt(lsWarn, 'the unread property "%s" of "%s" is not kept: its ' +
        'line could not be identified', [Unread.PropertyName, Unread.ComponentName]);
      Continue;
    end;
    Piece := TPreservedPiece.Create;
    Piece.Kind := pkProperty;
    Piece.OwnerName := Unread.ComponentName;
    Piece.Index := Index;
    Piece.Text := Block.Properties[Index].Span.TextIn(FSourceText);
    Piece.PropertyName := Unread.PropertyName;
    FPreserved.Add(Piece);
    Searched := Index + 1;
  end;
end;

procedure TFormLoader.CollectUnresolvedReferences(ARoot: TComponent);
var
  Roots, Instances: TStringList;
  RootName, InstanceName: string;
begin
  FUnresolvedReferences := nil;
  Roots := TStringList.Create;
  Instances := TStringList.Create;
  try
    GetFixupReferenceNames(ARoot, Roots);
    for RootName in Roots do
    begin
      Instances.Clear;
      GetFixupInstanceNames(ARoot, RootName, Instances);
      for InstanceName in Instances do
        FUnresolvedReferences := FUnresolvedReferences +
          [RootName + '.' + InstanceName];
    end;
  finally
    Instances.Free;
    Roots.Free;
  end;
end;

procedure TFormLoader.PreserveModuleReferences(ADocument: TDfmDocument);

  function Unresolved(const AValue: string): Boolean;
  var
    Reference: string;
  begin
    for Reference in FUnresolvedReferences do
      if SameText(Reference, AValue) then
        Exit(True);
    Result := False;
  end;

  procedure Walk(ABlock: TDfmBlock);
  var
    I, Assign: Integer;
    Line: string;
    Unread: TUnreadProperty;
    Child: TDfmBlock;
  begin
    for I := 0 to ABlock.PropertyCount - 1 do
    begin
      Line := ABlock.Properties[I].Span.TextIn(FSourceText);
      Assign := Pos('=', Line);
      if (Assign = 0) or
         not Unresolved(Trim(Copy(Line, Assign + 1, MaxInt))) then
        Continue;
      if ABlock.Name = '' then
      begin
        FLog.AddFmt(lsWarn, 'the reference "%s" sits in a block without a ' +
          'name, so its line is not kept', [Trim(Line)]);
        Continue;
      end;
      Unread.ComponentName := ABlock.Name;
      Unread.PropertyName := ABlock.Properties[I].Name;
      FUnreadProperties.Add(Unread);
      if not FQuiet then
        FLog.AddFmt(lsWarn, '%s refers into a module that is not here - ' +
          'the line is kept as written', [Trim(Line)]);
    end;
    for Child in ABlock.Children do
      Walk(Child);
  end;

begin
  if Length(FUnresolvedReferences) = 0 then
    Exit;
  Walk(ADocument.Root);
end;

procedure TFormLoader.BuildPreserved;
var
  Document: TDfmDocument;
begin
  if (FUnknownClasses.Count = 0) and (FUnreadProperties.Count = 0) and
     (Length(FUnresolvedReferences) = 0) then
    Exit;
  Document := TDfmDocument.Create(FSourceText);
  try
    PreserveBlocksIn(Document.Root);
    // Before the unread pass: module references are queued as unread
    // properties, which that pass then splices.
    PreserveModuleReferences(Document);
    PreserveUnreadProperties(Document);
  finally
    Document.Free;
  end;
  FLog.AddFmt(lsInfo, 'preserved %d piece(s) of the file verbatim',
    [FPreserved.Count]);
end;

procedure TFormLoader.PrepareImage(AImage: TStream; const AWhat: string;
  const AState: TLoadedFormState; const ADocumentFile: string);
var
  Header: TDfmRootHeader;
begin
  FPendingUnknownClass := '';
  FFileName := ADocumentFile;
  FreeAndNil(FBinary);
  FBinary := ToBinaryDfm(AImage, AWhat);
  Header := ReadDfmRootHeader(FBinary);
  if Header.Kind = rkInline then
    raise EFormLoadError.CreateFmt(
      '%s is an embedded frame and cannot be read back.', [AWhat]);
  FRootObjectName := Header.ObjectName;
  FLoadedState.RootClassName := AState.RootClassName;
  FLoadedState.RootKind := AState.RootKind;
  FSourceText := DfmStreamToText(FBinary);
  FClassIndex.SearchIn(ExtractFilePath(ADocumentFile),
    SearchPathFor(ADocumentFile) + FInheritedSearchPath);
  if Header.Kind = rkInherited then
  begin
    FChain.Resolve(ADocumentFile, AState.RootClassName);
    RefuseFramesInDescendant(FSourceText);
  end
  else
    PlanFrames(FSourceText);
end;

procedure TFormLoader.PrepareFromSnapshot(ASnapshot: TStream;
  const AState: TLoadedFormState; const ADocumentFile: string);
begin
  FQuiet := True;
  PrepareImage(ASnapshot, 'the document image', AState, ADocumentFile);
end;

procedure TFormLoader.PrepareRecovered(const ARecoveryFile: string;
  const AState: TLoadedFormState; const ADocumentFile: string);
var
  Image: TFileStream;
begin
  if not FileExists(ARecoveryFile) then
    raise EFormLoadError.CreateFmt('Recovered copy not found: %s',
      [ARecoveryFile]);
  Image := TFileStream.Create(ARecoveryFile, fmOpenRead or fmShareDenyWrite);
  try
    PrepareImage(Image, 'the recovered copy', AState, ADocumentFile);
  finally
    Image.Free;
  end;
end;

procedure TFormLoader.StreamInto(ARoot: TComponent);
begin
  if FBinary = nil then
    raise EFormLoadError.Create('The form file has to be prepared before it streams.');

  if not FQuiet then
    FLog.AddFmt(lsInfo, 'root "%s: %s" streams into a stub %s',
      [FRootObjectName, FLoadedState.RootClassName, ARoot.ClassName]);

  EnterDesignMode(ARoot);
  // A root already in design mode keeps its own name while streaming, so the
  // stub is named here or the saved file loses the name.
  if FRootObjectName <> '' then
    ARoot.Name := FRootObjectName;

  FCurrentComponent := FRootObjectName;
  // One bracket spans the document and every frame file it draws on, so that
  // Loaded fires only after all of them streamed; a frame instance is built
  // before the host block's own property lines are read.
  BeginGlobalLoading;
  try
    // Ancestors stream first into the same stub, base-most first, so that the
    // document's own pass finds their components already there to modify.
    StreamAncestors(ARoot);
    StreamFrom(FBinary, ARoot);
    BuildPristineAncestor;
    NotifyGlobalLoading;
  finally
    EndGlobalLoading;
  end;
  CollectUnresolvedReferences(ARoot);
  if (FFrames.Count > 0) and not FQuiet then
    FLog.AddFmt(lsInfo, 'the document holds %d frame instance(s)', [FFrames.Count]);
  BuildPreserved;

  // Captured before the root is embedded in the design surface, which
  // overwrites Left and Top with the surface position.
  if ARoot is TControl then
  begin
    FLoadedState.Left := TControl(ARoot).Left;
    FLoadedState.Top := TControl(ARoot).Top;
  end;
  if (ARoot is TCustomForm) and (TCustomForm(ARoot).ActiveControl <> nil) then
    FLoadedState.ActiveControlName := TCustomForm(ARoot).ActiveControl.Name;

  if not FQuiet then
    FLog.AddFmt(lsInfo, 'loaded %d component(s) from %s',
      [ARoot.ComponentCount, FFileName]);
end;

initialization
  RegisterDesignerClasses;

end.
