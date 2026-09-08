// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Shell.SplashWindow;

// Start-up splash window created by the .dpr before the design-time packages
// load and before the designer core form exists; it depends on RTL and VCL
// units only. Main thread only. Every public routine ends in an Update,
// directly or through SetProgress, so the window repaints synchronously
// during a start-up that runs no message loop.

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.ExtCtrls,
  Vcl.Forms,
  Vcl.StdCtrls, Vcl.Imaging.pngimage;

type
  // Splash form. The backdrop and the logo are PNG images stored in the .dfm;
  // the labels and the progress bar are controls placed over them.
  TSplashForm = class(TForm)
    // Controls and event handlers bound by the .dfm.
    ImageBackground: TImage;
    ImageLogo: TImage;
    LabelBrand: TLabel;
    LabelTitle: TLabel;
    LabelSubtitle: TLabel;
    LabelStatus: TLabel;
    LabelPercent: TLabel;
    ProgressArea: TPaintBox;
    LabelFormMode: TLabel;
    procedure FormCreate(Sender: TObject);
    procedure ProgressAreaPaint(Sender: TObject);
  private
    FProgress: Integer;
    FStageCaption: string;
    FStageFrom: Integer;
    FStageTo: Integer;
    procedure SetProgress(AValue: Integer);
  protected
    // Adds WS_EX_TOOLWINDOW: no taskbar button and no alt-tab entry.
    procedure CreateParams(var Params: TCreateParams); override;
  public
    // Shows the window and repaints it before returning. Position is
    // poDesigned, so the window appears at the Left/Top set in the .dfm.
    procedure ShowSplash;
    // Sets the subtitle line above the status line; StepStage writes the
    // status line and leaves the subtitle unchanged.
    procedure SetPhase(const AText: string);
    // Sets the status line. The bar and the percentage keep their value.
    procedure SetStatus(const AText: string); overload;
    // Sets the status line and the bar; APercent is clamped to 0..100.
    procedure SetStatus(const AText: string; APercent: Integer); overload;
    // Starts a stage that spans the bar band AFrom..ATo in percent and moves
    // the bar to AFrom. ACaption is a format string taking one step name, as
    // in 'Loading package %s'.
    procedure BeginStage(const ACaption: string; AFrom, ATo: Integer);
    // Advances within the current stage: the bar lands at ADone of ACount
    // across the band and AWhat fills the stage caption. Signature matches
    // TPackageProgress; ACount <= 0 has no effect.
    procedure StepStage(ADone, ACount: Integer; const AWhat: string);
    // Bar position in percent; assignment clamps to 0..100.
    property Progress: Integer read FProgress write SetProgress;
  end;

implementation

{$R *.dfm}

uses
  Winapi.Windows,
  System.SysUtils,
  System.Math,
  System.Types,
  Vcl.Graphics,
  Vcl.GraphUtil;

const
  // Progress bar colours.
  ProgressTrack    = TColor($002B211C);
  ProgressFillFrom = TColor($00F5742E);
  ProgressFillTo   = TColor($00FF8941);

procedure TSplashForm.FormCreate(Sender: TObject);
begin
  SetStatus('', 0);
end;

procedure TSplashForm.CreateParams(var Params: TCreateParams);
begin
  inherited CreateParams(Params);
  Params.ExStyle := Params.ExStyle or WS_EX_TOOLWINDOW;
end;

procedure TSplashForm.ShowSplash;
begin
  Show;
  Update;
end;

procedure TSplashForm.SetPhase(const AText: string);
begin
  LabelSubtitle.Caption := AText;
  Update;
end;

procedure TSplashForm.SetStatus(const AText: string);
begin
  LabelStatus.Caption := AText;
  Update;
end;

procedure TSplashForm.SetStatus(const AText: string; APercent: Integer);
begin
  LabelStatus.Caption := AText;
  SetProgress(APercent);
end;

procedure TSplashForm.SetProgress(AValue: Integer);
begin
  FProgress := EnsureRange(AValue, 0, 100);
  LabelPercent.Caption := Format('%d%%', [FProgress]);
  ProgressArea.Invalidate;
  Update;
end;

procedure TSplashForm.BeginStage(const ACaption: string; AFrom, ATo: Integer);
begin
  FStageCaption := ACaption;
  FStageFrom := AFrom;
  FStageTo := ATo;
  SetProgress(AFrom);
end;

procedure TSplashForm.StepStage(ADone, ACount: Integer; const AWhat: string);
begin
  if ACount <= 0 then
    Exit;
  SetStatus(Format(FStageCaption, [AWhat]),
    FStageFrom + MulDiv(FStageTo - FStageFrom, ADone, ACount));
end;

procedure TSplashForm.ProgressAreaPaint(Sender: TObject);
var
  Bar: TRect;
  Radius, FillWidth: Integer;
  Groove: TBitmap;
  Pill: HRGN;
begin
  Bar := ProgressArea.ClientRect;
  Radius := Bar.Height;
  FillWidth := Round(Bar.Width * FProgress / 100);

  // SelectClipRgn takes device coordinates, and a graphic control's canvas is
  // the form's DC with a shifted origin, so the bar is composed on a bitmap.
  Groove := TBitmap.Create;
  try
    Groove.SetSize(Bar.Width, Bar.Height);
    // RoundRect leaves the corner pixels of the new bitmap undefined, so the
    // backdrop is copied in before the track is drawn over it.
    Groove.Canvas.CopyRect(Bar, ProgressArea.Canvas, Bar);
    Groove.Canvas.Brush.Color := ProgressTrack;
    Groove.Canvas.Pen.Color := ProgressTrack;
    Groove.Canvas.RoundRect(Bar.Left, Bar.Top, Bar.Right, Bar.Bottom,
      Radius, Radius);

    if FillWidth > 0 then
    begin
      // The gradient covers the whole bar rather than the filled part, so the
      // colour at a given position stays the same as the fill grows.
      Pill := CreateRoundRectRgn(Bar.Left, Bar.Top, Bar.Right + 1,
        Bar.Bottom + 1, Radius, Radius);
      try
        SelectClipRgn(Groove.Canvas.Handle, Pill);
        IntersectClipRect(Groove.Canvas.Handle, Bar.Left, Bar.Top,
          Bar.Left + FillWidth, Bar.Bottom);
        GradientFillCanvas(Groove.Canvas, ProgressFillFrom, ProgressFillTo, Bar,
          gdHorizontal);
        SelectClipRgn(Groove.Canvas.Handle, 0);
      finally
        DeleteObject(Pill);
      end;
    end;

    ProgressArea.Canvas.Draw(Bar.Left, Bar.Top, Groove);
  finally
    Groove.Free;
  end;
end;

end.
