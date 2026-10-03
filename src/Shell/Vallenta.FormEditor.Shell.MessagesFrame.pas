// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Shell.MessagesFrame;

// Messages pane over two TDesignLog instances in one owner-drawn list box: a
// rebuild lists the session log before the document log, and later entries
// from either are appended in arrival order. Row text is colored by severity,
// with session info rows dimmed. Main thread only: TDesignLog does not lock
// and notifies its listeners on the calling thread.
//
// Attach registers listeners on both logs, so neither may be freed while
// attached; Attach(nil, nil) removes them. The rows are held here and the list
// box is virtual, because every new window lists a session log of thousands of
// entries. The last row is selected once per burst of entries, because
// selecting a row scrolls and repaints a shown list immediately.

interface

uses
  Winapi.Messages,
  System.Classes,
  System.Generics.Collections,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.Menus,
  System.Types,
  Vallenta.FormEditor.Core.Log;

const
  // Posted to the frame by the first entry of a burst; handled once the
  // burst is over, it selects the last row.
  WM_FOLLOWLAST = WM_APP + 1;

type
  // One row of the list: the entry's text and severity, and whether it came
  // from the session log.
  TMessageRow = record
    Text: string;
    Severity: TLogSeverity;
    FromSession: Boolean;
  end;

  // Messages frame. The list stays empty until Attach binds logs; both logs
  // are referenced only and are never freed here.
  TMessagesFrame = class(TFrame)
    HeaderPanel: TPanel;
    LogList: TListBox;
    LogMenu: TPopupMenu;
    CopyItem: TMenuItem;
    ClearItem: TMenuItem;
    procedure LogListDrawItem(Control: TWinControl; Index: Integer; Rect: TRect;
      State: TOwnerDrawState);
    procedure CopyItemClick(Sender: TObject);
    procedure ClearItemClick(Sender: TObject);
  private
    FSession: TDesignLog;
    FDocument: TDesignLog;
    FRows: TList<TMessageRow>;
    FFollowPending: Boolean;
    procedure SessionEntryAdded(Sender: TObject; const Entry: TDesignLogEntry);
    procedure DocumentEntryAdded(Sender: TObject; const Entry: TDesignLogEntry);
    procedure LogTrimmed(Sender: TObject);
    procedure Append(const Entry: TDesignLogEntry; AFromSession: Boolean);
    procedure ShowRowCount;
    procedure FollowLast;
    procedure WMFollowLast(var Message: TMessage); message WM_FOLLOWLAST;
    procedure Rebuild;
    procedure LetGo;
  protected
    procedure DestroyWnd; override;
  public
    constructor Create(AOwner: TComponent); override;
    // Removes the listeners from both attached logs.
    destructor Destroy; override;
    // Rebuilds the list from both logs and listens for further entries; either
    // may be nil. Detaches from logs attached earlier, so Attach(nil, nil)
    // releases both.
    procedure Attach(ASession, ADocument: TDesignLog);
    // Number of rows in the list.
    function RowCount: Integer;
    // Text of the row at AIndex, 0-based.
    function RowText(AIndex: Integer): string;
  end;

implementation

{$R *.dfm}

uses
  Winapi.Windows,
  System.SysUtils,
  Vcl.Graphics,
  Vcl.Themes,
  Vcl.Clipbrd,
  Vallenta.FormEditor.Shell.Styles;

const
  // Row text colors by severity, indexed first by whether the list background
  // is dark. System colors among them are mapped through the active style.
  SeverityColor: array [Boolean, TLogSeverity] of TColor = (
    (clWindowText, clOlive, clRed),
    (clWindowText, TColor($003CC0E8), TColor($006B6BFF)));

// True when AColor is nearer black than white in perceived brightness.
function IsDark(AColor: TColor): Boolean;
var
  Value: TColorRef;
begin
  Value := TColorRef(ColorToRGB(AColor));
  Result := GetRValue(Value) * 299 + GetGValue(Value) * 587 +
    GetBValue(Value) * 114 < 128000;
end;

constructor TMessagesFrame.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FRows := TList<TMessageRow>.Create;
  KeepEraseOffScreen(HeaderPanel);
  KeepEraseOffScreen(LogList);
end;

destructor TMessagesFrame.Destroy;
begin
  LetGo;
  FRows.Free;
  inherited Destroy;
end;

function TMessagesFrame.RowCount: Integer;
begin
  Result := FRows.Count;
end;

function TMessagesFrame.RowText(AIndex: Integer): string;
begin
  Result := FRows[AIndex].Text;
end;

procedure TMessagesFrame.LetGo;
begin
  if FSession <> nil then
  begin
    FSession.RemoveListener(SessionEntryAdded);
    FSession.RemoveTrimListener(LogTrimmed);
  end;
  if FDocument <> nil then
    FDocument.RemoveListener(DocumentEntryAdded);
end;

procedure TMessagesFrame.Attach(ASession, ADocument: TDesignLog);
begin
  LetGo;
  FSession := ASession;
  FDocument := ADocument;
  Rebuild;
  if FSession <> nil then
  begin
    FSession.AddListener(SessionEntryAdded);
    // A drop under Limit is reported to trim listeners only, so a capped log
    // needs a rebuild; the session log is capped, the document log is not.
    FSession.AddTrimListener(LogTrimmed);
  end;
  if FDocument <> nil then
    FDocument.AddListener(DocumentEntryAdded);
end;

procedure TMessagesFrame.LogTrimmed(Sender: TObject);
begin
  Rebuild;
end;

function RowOf(const Entry: TDesignLogEntry; AFromSession: Boolean): TMessageRow;
begin
  Result.Text := Entry.Text;
  Result.Severity := Entry.Severity;
  Result.FromSession := AFromSession;
end;

procedure TMessagesFrame.ShowRowCount;
begin
  // The list box is switched to virtual here rather than in the form file: the
  // switch clears the list through its window handle, which cannot exist
  // before the frame has a parent; an attached pane has one by the first row.
  if LogList.Style <> lbVirtualOwnerDraw then
  begin
    if FRows.Count = 0 then
      Exit;
    LogList.Style := lbVirtualOwnerDraw;
  end;
  LogList.Count := FRows.Count;
end;

procedure TMessagesFrame.Rebuild;
var
  I: Integer;
begin
  FRows.Clear;
  if FSession <> nil then
    for I := 0 to FSession.Count - 1 do
      FRows.Add(RowOf(FSession[I], True));
  if FDocument <> nil then
    for I := 0 to FDocument.Count - 1 do
      FRows.Add(RowOf(FDocument[I], False));
  ShowRowCount;
  LogList.ItemIndex := FRows.Count - 1;
end;

procedure TMessagesFrame.Append(const Entry: TDesignLogEntry;
  AFromSession: Boolean);
begin
  FRows.Add(RowOf(Entry, AFromSession));
  ShowRowCount;
  FollowLast;
end;

procedure TMessagesFrame.FollowLast;
begin
  if not HandleAllocated then
  begin
    LogList.ItemIndex := FRows.Count - 1;
    Exit;
  end;
  if FFollowPending then
    Exit;
  FFollowPending := True;
  PostMessage(Handle, WM_FOLLOWLAST, 0, 0);
end;

procedure TMessagesFrame.WMFollowLast(var Message: TMessage);
begin
  FFollowPending := False;
  LogList.ItemIndex := FRows.Count - 1;
end;

procedure TMessagesFrame.DestroyWnd;
begin
  // A message posted to the window being destroyed is lost with it; the
  // next entry posts to the new one.
  FFollowPending := False;
  inherited DestroyWnd;
end;

procedure TMessagesFrame.SessionEntryAdded(Sender: TObject;
  const Entry: TDesignLogEntry);
begin
  Append(Entry, True);
end;

procedure TMessagesFrame.DocumentEntryAdded(Sender: TObject;
  const Entry: TDesignLogEntry);
begin
  Append(Entry, False);
end;

procedure TMessagesFrame.LogListDrawItem(Control: TWinControl; Index: Integer;
  Rect: TRect; State: TOwnerDrawState);
var
  Row: TMessageRow;
  Style: TCustomStyleServices;
begin
  Style := StyleServices(LogList);
  LogList.Canvas.FillRect(Rect);
  // The list box may request a row past FRows between a rebuild and the
  // update of its count.
  if (Index < 0) or (Index >= FRows.Count) then
    Exit;
  Row := FRows[Index];
  if odSelected in State then
    LogList.Canvas.Font.Color := Style.GetSystemColor(clHighlightText)
  else if Row.FromSession and (Row.Severity = lsInfo) then
    LogList.Canvas.Font.Color := Style.GetSystemColor(clGrayText)
  else
    LogList.Canvas.Font.Color := Style.GetSystemColor(
      SeverityColor[IsDark(Style.GetSystemColor(clWindow)), Row.Severity]);
  LogList.Canvas.TextOut(Rect.Left + 4, Rect.Top + 1, Row.Text);
end;

procedure TMessagesFrame.CopyItemClick(Sender: TObject);
var
  Text: TStringBuilder;
  Row: TMessageRow;
begin
  Text := TStringBuilder.Create;
  try
    for Row in FRows do
      Text.AppendLine(Row.Text);
    Clipboard.AsText := Text.ToString;
  finally
    Text.Free;
  end;
end;

procedure TMessagesFrame.ClearItemClick(Sender: TObject);
begin
  // The session log is shared by every window, and Clear notifies no
  // listener: clearing it would drop entries still shown by the other panes.
  if FDocument <> nil then
    FDocument.Clear;
  Rebuild;
end;

end.
