// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

program VallentaDesigner;

// Process entry point. Two starts: --serve starts the resident core without
// a document and waits for connections on that pipe; a file name, or the
// file dialog when none was given, opens that form file, or hands it to the
// process already holding the single-instance claim and exits.
//
// ExitCode 2 means no form file was chosen or the --config-file file could
// not be read; ExitCode 1 means the running core refused the file, the
// document failed to open, or an exception ended the start.
uses
  Winapi.Windows,
  System.SysUtils,
  System.IOUtils,
  System.UITypes,
  System.JSON,
  Vcl.Forms,
  Vcl.Dialogs,
  Vallenta.FormEditor.Core.Console in 'src\Core\Vallenta.FormEditor.Core.Console.pas',
  Vallenta.FormEditor.Core.Log in 'src\Core\Vallenta.FormEditor.Core.Log.pas',
  Vallenta.FormEditor.Core.SingleInstance in 'src\Core\Vallenta.FormEditor.Core.SingleInstance.pas',
  Vallenta.FormEditor.Core.Settings in 'src\Core\Vallenta.FormEditor.Core.Settings.pas',
  Vallenta.FormEditor.Core.ArgumentFile in 'src\Core\Vallenta.FormEditor.Core.ArgumentFile.pas',
  Vallenta.FormEditor.Core.SearchPath in 'src\Core\Vallenta.FormEditor.Core.SearchPath.pas',
  Vallenta.FormEditor.Core.LoadedClasses in 'src\Core\Vallenta.FormEditor.Core.LoadedClasses.pas',
  Vallenta.FormEditor.Core.Sessions in 'src\Core\Vallenta.FormEditor.Core.Sessions.pas',
  Vallenta.FormEditor.Core.FieldLedger in 'src\Core\Vallenta.FormEditor.Core.FieldLedger.pas',
  Vallenta.FormEditor.Core.Coupling in 'src\Core\Vallenta.FormEditor.Core.Coupling.pas',
  Vallenta.FormEditor.Core.Recovery in 'src\Core\Vallenta.FormEditor.Core.Recovery.pas',
  Vallenta.FormEditor.Streaming.EventNames in 'src\Streaming\Vallenta.FormEditor.Streaming.EventNames.pas',
  Vallenta.FormEditor.Surface.Handles in 'src\Surface\Vallenta.FormEditor.Surface.Handles.pas',
  Vallenta.FormEditor.Core.ComponentRegistry in 'src\Core\Vallenta.FormEditor.Core.ComponentRegistry.pas',
  Vallenta.FormEditor.Packages.PeImage in 'src\Packages\Vallenta.FormEditor.Packages.PeImage.pas',
  Vallenta.FormEditor.Packages.Stacks in 'src\Packages\Vallenta.FormEditor.Packages.Stacks.pas',
  Vallenta.FormEditor.Packages.Discovery in 'src\Packages\Vallenta.FormEditor.Packages.Discovery.pas',
  Vallenta.FormEditor.Packages.Preflight in 'src\Packages\Vallenta.FormEditor.Packages.Preflight.pas',
  Vallenta.FormEditor.Packages.Dependencies in 'src\Packages\Vallenta.FormEditor.Packages.Dependencies.pas',
  Vallenta.FormEditor.Palette.Model in 'src\Palette\Vallenta.FormEditor.Palette.Model.pas',
  Vallenta.FormEditor.Palette.Favourites in 'src\Palette\Vallenta.FormEditor.Palette.Favourites.pas',
  Vallenta.FormEditor.Palette.Buttons in 'src\Palette\Vallenta.FormEditor.Palette.Buttons.pas',
  Vallenta.FormEditor.Packages.Icons in 'src\Packages\Vallenta.FormEditor.Packages.Icons.pas',
  Vallenta.FormEditor.DesignTime.IdeServices in 'src\DesignTime\Vallenta.FormEditor.DesignTime.IdeServices.pas',
  Vallenta.FormEditor.DesignTime.Environment in 'src\DesignTime\Vallenta.FormEditor.DesignTime.Environment.pas',
  Vallenta.FormEditor.Packages.Host in 'src\Packages\Vallenta.FormEditor.Packages.Host.pas',
  Vallenta.FormEditor.DesignTime.Designer in 'src\DesignTime\Vallenta.FormEditor.DesignTime.Designer.pas',
  Vallenta.FormEditor.Packages.ManagerDialog in 'src\Packages\Vallenta.FormEditor.Packages.ManagerDialog.pas',
  Vallenta.FormEditor.Surface.Tiles in 'src\Surface\Vallenta.FormEditor.Surface.Tiles.pas',
  Vallenta.FormEditor.Surface.TileLayer in 'src\Surface\Vallenta.FormEditor.Surface.TileLayer.pas',
  Vallenta.FormEditor.Streaming.RootClassifier in 'src\Streaming\Vallenta.FormEditor.Streaming.RootClassifier.pas',
  Vallenta.FormEditor.Streaming.TextSpans in 'src\Streaming\Vallenta.FormEditor.Streaming.TextSpans.pas',
  Vallenta.FormEditor.Streaming.Preserved in 'src\Streaming\Vallenta.FormEditor.Streaming.Preserved.pas',
  Vallenta.FormEditor.Streaming.Frames in 'src\Streaming\Vallenta.FormEditor.Streaming.Frames.pas',
  Vallenta.FormEditor.Streaming.Ancestors in 'src\Streaming\Vallenta.FormEditor.Streaming.Ancestors.pas',
  Vallenta.FormEditor.Streaming.Loader in 'src\Streaming\Vallenta.FormEditor.Streaming.Loader.pas',
  Vallenta.FormEditor.Streaming.Saver in 'src\Streaming\Vallenta.FormEditor.Streaming.Saver.pas',
  Vallenta.FormEditor.Streaming.Clipboard in 'src\Streaming\Vallenta.FormEditor.Streaming.Clipboard.pas',
  Vallenta.FormEditor.Surface.Undo in 'src\Surface\Vallenta.FormEditor.Surface.Undo.pas',
  Vallenta.FormEditor.Surface.FormDesigner in 'src\Surface\Vallenta.FormEditor.Surface.FormDesigner.pas',
  Vallenta.FormEditor.Shell.AlignDialogs in 'src\Shell\Vallenta.FormEditor.Shell.AlignDialogs.pas',
  Vallenta.FormEditor.Shell.Layout in 'src\Shell\Vallenta.FormEditor.Shell.Layout.pas',
  Vallenta.FormEditor.Surface.IconCanvas in 'src\Surface\Vallenta.FormEditor.Surface.IconCanvas.pas',
  Vallenta.FormEditor.Inspector.PropertyModel in 'src\Inspector\Vallenta.FormEditor.Inspector.PropertyModel.pas',
  Vallenta.FormEditor.Inspector.Grid in 'src\Inspector\Vallenta.FormEditor.Inspector.Grid.pas',
  Vallenta.FormEditor.Palette.Frame in 'src\Palette\Vallenta.FormEditor.Palette.Frame.pas' {PaletteFrame: TFrame},
  Vallenta.FormEditor.Shell.MessagesFrame in 'src\Shell\Vallenta.FormEditor.Shell.MessagesFrame.pas' {MessagesFrame: TFrame},
  Vallenta.FormEditor.Inspector.Frame in 'src\Inspector\Vallenta.FormEditor.Inspector.Frame.pas' {InspectorFrame: TFrame},
  Vallenta.FormEditor.Shell.MainWindow in 'src\Shell\Vallenta.FormEditor.Shell.MainWindow.pas' {MainDesignerForm},
  Vallenta.FormEditor.Shell.RecoveryDialog in 'src\Shell\Vallenta.FormEditor.Shell.RecoveryDialog.pas',
  Vallenta.FormEditor.Shell.SplashWindow in 'src\Shell\Vallenta.FormEditor.Shell.SplashWindow.pas' {SplashForm},
  Vallenta.FormEditor.Shell.Core in 'src\Shell\Vallenta.FormEditor.Shell.Core.pas',
  Vcl.Themes,
  Vcl.Styles;

{$R *.res}

procedure RunServe;
var
  Listener: TCoreListener;
begin
  if not ClaimCore then
    Exit;
  TStyleManager.TrySetStyle(DesignerStyle);
  Application.Initialize;
  Application.MainFormOnTaskbar := True;

  Listener := TCoreListener.Create(CorePipeName);
  try
    try
      InstallStandardEditors;
      LoadConfiguredPackages;
      Application.ShowMainForm := False;
      Application.CreateForm(TDesignerCore, DesignerCore);

      DesignerCore.ServeStarted := True;
      DesignerCore.TakeHandovers(Listener);
      Application.Run;
    except
      on E: Exception do
        ExitCode := 1;
    end;
  finally
    if DesignerCore <> nil then
      DesignerCore.Shutdown
    else
    begin
      if Listener.Stop then
        Listener.Free;
      UnloadAll;
      ReleaseCore;
    end;
  end;
end;

function PromptForDfm: string;
var
  Dialog: TOpenDialog;
begin
  Result := '';
  Dialog := TOpenDialog.Create(nil);
  try
    Dialog.Title := 'Vallenta Designer - select a form file';
    Dialog.Filter := 'Form files (*.dfm)|*.dfm|All files (*.*)|*.*';
    Dialog.Options := Dialog.Options + [ofFileMustExist];
    if Dialog.Execute then
      Result := Dialog.FileName;
  finally
    Dialog.Free;
  end;
end;

var
  Arguments: TArray<string>;
  ArgumentsRead: Boolean;
  ArgumentError: string;
  SearchPathList: string;
  DfmFile: string;
  Refusal: string;
  IsCore: Boolean;
  Routed: TRouteOutcome;
  Listener: TCoreListener;
  Splash: TSplashForm;

function FirstArgumentIs(const AOption: string): Boolean;
begin
  Result := (Length(Arguments) > 0) and SameText(Arguments[0], AOption);
end;

begin
  Arguments := CommandLineArguments;
  // Must run before any option is read: --serve, --search-path and the file
  // name may arrive from the --config-file file rather than the command line.
  ArgumentsRead := ExpandConfigFileArgument(Arguments, ArgumentError);
  // Must run before Arguments[0] is read as the file name; --search-path may
  // stand ahead of it.
  SearchPathList := TakeSearchPathArgument(Arguments);
  if SearchPathList <> '' then
    SetDefaultSearchPath(SplitSearchPath(SearchPathList));
  if not ArgumentsRead then
  begin
    // MessageBox rather than a VCL dialog: this runs before
    // Application.Initialize.
    ArgumentError := 'The form designer did not start: ' + ArgumentError + '.';
    if TryAttachParentConsole then
      ConsoleWriteLn(ArgumentError)
    else
      MessageBox(0, PChar(ArgumentError), 'Vallenta Designer',
        MB_OK or MB_ICONERROR);
    ExitCode := 2;
  end
  else if FirstArgumentIs('--serve') then
    RunServe
  else
    try
      TStyleManager.TrySetStyle(DesignerStyle);
      Application.Initialize;
      Application.MainFormOnTaskbar := True;
      if Length(Arguments) > 0 then
        DfmFile := Arguments[0]
      else
        DfmFile := PromptForDfm;
      if DfmFile = '' then
        ExitCode := 2
      else
      begin
        DfmFile := ExpandFileName(DfmFile);
        IsCore := ClaimCore;
        Listener := nil;
        Routed := roUnreachable;
        if IsCore then
          Listener := TCoreListener.Create(CorePipeName)
        else
          Routed := RouteToCore(DfmFile, Refusal, SearchPathList);
        case Routed of
          roOpened, roFocused:
            ;
          roRefused:
            begin
              Refusal := Format('The running form designer did not open %s: %s',
                [DfmFile, Refusal]);
              if TryAttachParentConsole then
                ConsoleWriteLn(Refusal)
              else
                MessageDlg(Refusal, mtInformation, [mbOK], 0);
              ExitCode := 1;
            end;
          roUnreachable:
            try
              Splash := TSplashForm.Create(nil);
              Splash.ShowSplash;
              Splash.SetStatus('Preparing the design-time layer', 2);
              InstallStandardEditors;

              Splash.BeginStage('Loading package %s', 2, 88);
              ReportProgressTo(Splash.StepStage);
              try
                LoadConfiguredPackages;
              finally
                ReportProgressTo(nil);
              end;
              Splash.SetStatus('Starting the designer core', 92);
              Application.ShowMainForm := False;
              Application.CreateForm(TDesignerCore, DesignerCore);
              if Listener <> nil then
                DesignerCore.TakeHandovers(Listener)
              else
                DesignerCore.SessionLog.AddFmt(lsWarn, 'another designer ' +
                  'holds the single-instance claim but did not answer (%s) - ' +
                  'this instance runs alongside it and later starts will not ' +
                  'reach it', [Refusal]);
              Splash.SetStatus(Format('Opening %s',
                [ExtractFileName(DfmFile)]), 96);

              if DesignerCore.OpenDocument(DfmFile) = nil then
                ExitCode := 1
              else
              begin
                FreeAndNil(Splash);
                Application.Run;
              end;
            finally
              Splash.Free;
              if DesignerCore <> nil then
                DesignerCore.Shutdown
              else
              begin
                if (Listener <> nil) and Listener.Stop then
                  Listener.Free;
                UnloadAll;
                ReleaseCore;
              end;
            end;
        end;
      end;
    except
      on E: Exception do
      begin
        MessageDlg(Format('%s: %s', [E.ClassName, E.Message]), mtError, [mbOK], 0);
        ExitCode := 1;
      end;
    end;
end.

