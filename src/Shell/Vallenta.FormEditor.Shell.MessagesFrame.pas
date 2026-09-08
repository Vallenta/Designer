// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Shell.MessagesFrame;

// Messages pane over two TDesignLog instances in one owner-drawn list box: a
// rebuild lists the session log before the document log, later entries from
// either append in arrival order. Row text is colored by severity, session
// info rows dimmed. Attach registers listeners on both logs, so neither may
// be freed while attached; Attach(nil, nil) removes them.
//
// Main thread only: TDesignLog does not lock and notifies its listeners on
// the calling thread.

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.Menus,
  System.Types,
  Vallenta.FormEditor.Core.Log;

type
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
    procedure SessionEntryAdded(Sender: TObject; const Entry: TDesignLogEntry);
    procedure DocumentEntryAdded(Sender: TObject; const Entry: TDesignLogEntry);
    procedure LogTrimmed(Sender: TObject);
    procedure Append(const Entry: TDesignLogEntry; AFromSession: Boolean);
    procedure Rebuild;
    procedure LetGo;
  public
    // Removes the listeners from both attached logs.
    destructor Destroy; override;
    // Rebuilds the list from both logs and listens for further entries; either
    // may be nil. Detaches from logs attached earlier, so Attach(nil, nil)
    // releases both.
    procedure Attach(ASession, ADocument: TDesignLog);
  end;

implementation

{$R *.dfm}

uses
  Winapi.Windows,
  Vcl.Graphics,
  Vcl.Clipbrd;

const
  // Row text colors by severity, and the item-data flag marking a session row.
  SeverityColor: array [TLogSeverity] of TColor = (clWindowText, clOlive, clRed);
  // The severity occupies the low two bits of the item data, so TLogSeverity
  // must stay at four values or fewer.
  SessionMark = 4;

destructor TMessagesFrame.Destroy;
begin
  LetGo;
  inherited Destroy;
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

procedure TMessagesFrame.Rebuild;
var
  I: Integer;
begin
  LogList.Items.BeginUpdate;
  try
    LogList.Items.Clear;
    if FSession <> nil then
      for I := 0 to FSession.Count - 1 do
        Append(FSession[I], True);
    if FDocument <> nil then
      for I := 0 to FDocument.Count - 1 do
        Append(FDocument[I], False);
  finally
    LogList.Items.EndUpdate;
  end;
  LogList.ItemIndex := LogList.Items.Count - 1;
end;

procedure TMessagesFrame.Append(const Entry: TDesignLogEntry;
  AFromSession: Boolean);
var
  Marked: NativeInt;
begin
  Marked := Ord(Entry.Severity);
  if AFromSession then
    Marked := Marked or SessionMark;
  LogList.Items.AddObject(Entry.Text, TObject(Marked));
  LogList.ItemIndex := LogList.Items.Count - 1;
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
  Marked: NativeInt;
  Severity: TLogSeverity;
begin
  Marked := NativeInt(LogList.Items.Objects[Index]);
  Severity := TLogSeverity(Marked and not SessionMark);
  LogList.Canvas.FillRect(Rect);
  if odSelected in State then
    LogList.Canvas.Font.Color := clHighlightText
  else if (Marked and SessionMark <> 0) and (Severity = lsInfo) then
    LogList.Canvas.Font.Color := clGrayText
  else
    LogList.Canvas.Font.Color := SeverityColor[Severity];
  LogList.Canvas.TextOut(Rect.Left + 4, Rect.Top + 1, LogList.Items[Index]);
end;

procedure TMessagesFrame.CopyItemClick(Sender: TObject);
begin
  Clipboard.AsText := LogList.Items.Text;
end;

procedure TMessagesFrame.ClearItemClick(Sender: TObject);
begin
  // The session log is shared by every window, and Clear notifies no
  // listener: clearing it would drop entries the other panes still show.
  if FDocument <> nil then
    FDocument.Clear;
  Rebuild;
end;

end.
