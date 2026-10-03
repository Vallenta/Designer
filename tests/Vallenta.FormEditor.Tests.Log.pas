// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.Log;

// Suite for TDesignLog: the entry limit, the trim notification, and the log
// state seen by an entry listener. The limit cases add lsInfo entries, the
// only severity dropped by Trim. Also covers the messages pane: after a burst
// of entries it selects the last row once, when the burst ends. That case
// shows a form on the desktop and frees it again.

interface

uses
  DUnitX.TestFramework,
  Vallenta.FormEditor.Core.Log;

type
  // Covers TDesignLog entry retention, its two listener kinds, and the
  // messages pane following a log.
  [TestFixture]
  TLogTests = class
  private
    FTrims: Integer;
    FSeenCount: Integer;
    FSeenLast: string;
    FWatched: TObject;
    procedure CountTrim(Sender: TObject);
    procedure ReadTheLog(Sender: TObject; const Entry: TDesignLogEntry);
  public
    [Test]
    procedure ALogWithNoLimitKeepsEverything;
    [Test]
    procedure ALimitKeepsTheNewestAndDropsTheOldest;
    // A log filled to exactly Limit raises no trim notification; each append
    // beyond it drops one entry and raises one notification.
    [Test]
    procedure LettingGoOfTheOldestIsAnnouncedOnce;
    // Assigning a lower Limit trims immediately, and the whole trim raises one
    // notification rather than one per dropped entry.
    [Test]
    procedure LoweringTheLimitTakesEffectAtOnce;
    // Add applies the drop before notifying entry listeners.
    [Test]
    procedure WhatAListenerReadsIsWhatTheLogHolds;
    // Selecting the row of every entry repaints a shown list once per entry;
    // a burst of a few thousand entries then takes seconds.
    [Test]
    procedure AShownPaneSelectsTheLastRowOnceABurstIsOver;
  end;

implementation

uses
  System.SysUtils,
  Vcl.Controls,
  Vcl.Forms,
  Vallenta.FormEditor.Shell.MessagesFrame;

const
  // Entry limit set by the limit cases.
  Limit = 10;

procedure TLogTests.CountTrim(Sender: TObject);
begin
  Inc(FTrims);
end;

procedure TLogTests.ReadTheLog(Sender: TObject; const Entry: TDesignLogEntry);
var
  Log: TDesignLog;
begin
  Log := TDesignLog(FWatched);
  FSeenCount := Log.Count;
  FSeenLast := Log[Log.Count - 1].Text;
end;

procedure Fill(ALog: TDesignLog; ACount: Integer);
var
  I: Integer;
begin
  for I := 1 to ACount do
    ALog.AddFmt(lsInfo, 'entry %d', [I]);
end;

procedure TLogTests.ALogWithNoLimitKeepsEverything;
var
  Log: TDesignLog;
begin
  Log := TDesignLog.Create;
  try
    Fill(Log, 500);
    Assert.AreEqual(500, Log.Count,
      'a log nobody capped let go of something anyway');
  finally
    Log.Free;
  end;
end;

procedure TLogTests.ALimitKeepsTheNewestAndDropsTheOldest;
var
  Log: TDesignLog;
begin
  Log := TDesignLog.Create;
  try
    Log.Limit := Limit;
    Fill(Log, Limit * 3);
    Assert.AreEqual(Limit, Log.Count, 'the log grew past its limit');
    Assert.AreEqual('entry 21', Log[0].Text,
      'the log kept the oldest entries rather than the newest');
    Assert.AreEqual('entry 30', Log[Log.Count - 1].Text,
      'the newest entry is not the last one');
  finally
    Log.Free;
  end;
end;

procedure TLogTests.LettingGoOfTheOldestIsAnnouncedOnce;
var
  Log: TDesignLog;
begin
  Log := TDesignLog.Create;
  try
    Log.Limit := Limit;
    Log.AddTrimListener(CountTrim);
    FTrims := 0;
    Fill(Log, Limit);
    Assert.AreEqual(0, FTrims,
      'a log that is exactly full said it had let go of something');
    Fill(Log, 5);
    Assert.AreEqual(5, FTrims, 'five entries over the limit were not five drops');
  finally
    Log.Free;
  end;
end;

procedure TLogTests.LoweringTheLimitTakesEffectAtOnce;
var
  Log: TDesignLog;
begin
  Log := TDesignLog.Create;
  try
    Fill(Log, 100);
    Log.AddTrimListener(CountTrim);
    FTrims := 0;
    Log.Limit := Limit;
    Assert.AreEqual(Limit, Log.Count, 'lowering the limit dropped nothing');
    Assert.AreEqual(1, FTrims,
      'dropping ninety entries in one go was not announced once');
  finally
    Log.Free;
  end;
end;

procedure TLogTests.WhatAListenerReadsIsWhatTheLogHolds;
var
  Log: TDesignLog;
begin
  Log := TDesignLog.Create;
  try
    FWatched := Log;
    Log.Limit := Limit;
    Log.AddListener(ReadTheLog);
    FSeenCount := 0;
    FSeenLast := '';
    Fill(Log, Limit * 2);
    Assert.AreEqual(Limit, FSeenCount,
      'a listener found a log longer than the log is allowed to be');
    Assert.AreEqual('entry 20', FSeenLast,
      'a listener did not find the entry it had just been told about last');
  finally
    Log.Free;
  end;
end;

procedure TLogTests.AShownPaneSelectsTheLastRowOnceABurstIsOver;
const
  Burst = 200;
var
  Host: TForm;
  Pane: TMessagesFrame;
  Log: TDesignLog;
  I: Integer;
begin
  Host := TForm.Create(nil);
  Log := TDesignLog.Create;
  Pane := nil;
  try
    Pane := TMessagesFrame.Create(Host);
    Pane.Parent := Host;
    Pane.Align := alClient;
    Host.Show;
    Pane.Attach(nil, Log);
    for I := 1 to Burst do
      Log.AddFmt(lsWarn, 'entry %d', [I]);
    Assert.AreEqual(Burst, Pane.RowCount);
    Assert.AreEqual(Burst, Pane.LogList.Count,
      'the list box does not show every row');
    Assert.AreEqual('entry ' + IntToStr(Burst), Pane.RowText(Burst - 1));
    Assert.AreNotEqual(Burst - 1, Pane.LogList.ItemIndex,
      'the last row was selected while the burst was still running');
    Application.ProcessMessages;
    Assert.AreEqual(Burst - 1, Pane.LogList.ItemIndex,
      'the last row was not selected once the burst was over');
  finally
    // The pane is a listener of the log and is detached before the log is
    // freed.
    if Pane <> nil then
      Pane.Attach(nil, nil);
    Log.Free;
    Host.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TLogTests);

end.
