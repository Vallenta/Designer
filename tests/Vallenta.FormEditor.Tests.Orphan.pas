// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.Orphan;

// Covers EvaluateOrphan from Vallenta.FormEditor.Core.Sessions: the clause
// that selects the grace period for an idle core, the length each clause
// carries, and its arming, disarming and expiry. Time is supplied through
// TOrphanInputs.Now, so cases advance the clock instead of waiting. The
// caller that drives the rule, Vallenta.FormEditor.Shell.Core, is not linked.

interface

uses
  DUnitX.TestFramework,
  Vallenta.FormEditor.Core.Sessions;

type
  // Inputs for EvaluateOrphan and the watch its last verdict returned; the
  // watch is stored between calls as the shell stores it.
  TCoreUnderTest = record
    State: TOrphanInputs;
    Watch: TOrphanWatch;
    // Evaluates the rule once, stores the returned watch and returns the
    // action name: stand, arm, disarm or end.
    function Beat: string;
    // Moves the simulated clock forward by ASeconds, then evaluates once.
    function After(ASeconds: Cardinal): string;
    // Seconds from the simulated clock to the deadline of the armed watch.
    function GraceLeft: Integer;
    procedure EditorAttaches;
    procedure EditorGoes;
    procedure FormOpens;
    procedure FormCloses;
  end;

  // Clause selection, grace lengths, arming and disarming, and the end
  // verdict that repeats.
  [TestFixture]
  TOrphanRuleTests = class
  public
    [Test]
    procedure AStandaloneCoreIsNeverTouchedHoweverLongItSits;
    [Test]
    procedure AStandaloneCoreThatOpenedAndClosedFormsIsStillNeverTouched;
    [Test]
    procedure ACoreTheEditorLetGoOfArmsTheShortGrace;
    [Test]
    procedure TheShortGracePassingEndsTheCore;
    [Test]
    procedure TheArmingIsAnsweredOnceRatherThanEveryBeat;
    [Test]
    procedure AnEditorComingBackDisarmsTheGrace;
    [Test]
    procedure AFormOpeningDisarmsTheGrace;
    [Test]
    procedure AGraceThatWasDisarmedStartsOverRatherThanResuming;
    [Test]
    procedure ADirtyDocumentIsAWindowSoTheRuleCannotReachIt;
    [Test]
    procedure AServeCoreNobodyEverAttachedToEndsAfterTheLongGrace;
    [Test]
    procedure AServeCoreIsLeftAloneWhileSomethingIsOpenInIt;
    [Test]
    procedure AServeCoreThatWasAttachedToOnceFallsUnderTheShortGrace;
    [Test]
    procedure AnEndNothingCarriedOutIsStillOwedAtTheNextBeat;
  end;

implementation

const
  ActionNames: array [TOrphanAction] of string =
    ('stand', 'arm', 'disarm', 'end');
  // AnHour is in seconds and is far beyond either grace period.
  AnHour = 3600;
  ShortGrace = AbandonedGrace div 1000;
  LongGrace = UnusedServeGrace div 1000;

function StandaloneCore: TCoreUnderTest;
begin
  Result := Default(TCoreUnderTest);
  Result.State.Now := 100000;
end;

function ServeStartedCore: TCoreUnderTest;
begin
  Result := StandaloneCore;
  Result.State.ServeStart := True;
end;

{ TCoreUnderTest }

function TCoreUnderTest.Beat: string;
var
  Verdict: TOrphanVerdict;
begin
  Verdict := EvaluateOrphan(State, Watch);
  Watch := Verdict.Watch;
  Result := ActionNames[Verdict.Action];
end;

function TCoreUnderTest.After(ASeconds: Cardinal): string;
begin
  State.Now := State.Now + ASeconds * 1000;
  Result := Beat;
end;

function TCoreUnderTest.GraceLeft: Integer;
begin
  Result := Integer((Watch.Deadline - State.Now) div 1000);
end;

procedure TCoreUnderTest.EditorAttaches;
begin
  State.HadSession := True;
  Inc(State.Sessions);
end;

procedure TCoreUnderTest.EditorGoes;
begin
  Dec(State.Sessions);
end;

procedure TCoreUnderTest.FormOpens;
begin
  Inc(State.Windows);
end;

procedure TCoreUnderTest.FormCloses;
begin
  Dec(State.Windows);
end;

{ TOrphanRuleTests }

procedure TOrphanRuleTests.AStandaloneCoreIsNeverTouchedHoweverLongItSits;
var
  Core: TCoreUnderTest;
begin
  Core := StandaloneCore;
  Assert.AreEqual('stand', Core.Beat,
    'a core no editor ever attached to was taken up by the rule');
  Assert.AreEqual('stand', Core.After(AnHour),
    'sitting there for an hour was read as being abandoned');
end;

procedure TOrphanRuleTests.AStandaloneCoreThatOpenedAndClosedFormsIsStillNeverTouched;
var
  Core: TCoreUnderTest;
begin
  Core := StandaloneCore;
  Core.FormOpens;
  Assert.AreEqual('stand', Core.After(10), 'a document open is not the rule''s business');
  Core.FormCloses;
  Assert.AreEqual('stand', Core.Beat,
    'closing the last form ended a core the user started themselves');
  Assert.AreEqual('stand', Core.After(AnHour),
    'a core with no windows and no editor behind it was ended anyway');
end;

procedure TOrphanRuleTests.ACoreTheEditorLetGoOfArmsTheShortGrace;
var
  Core: TCoreUnderTest;
begin
  Core := StandaloneCore;
  Core.EditorAttaches;
  Core.FormOpens;
  Assert.AreEqual('stand', Core.Beat, 'a coupled document was counted against');
  Core.FormCloses;
  Assert.AreEqual('stand', Core.Beat, 'a session still attached was counted against');
  Core.EditorGoes;
  Assert.AreEqual('arm', Core.Beat, 'the editor going left nothing armed');
  Assert.AreEqual(ShortGrace, Core.GraceLeft, 'the grace armed was not the short one');
end;

procedure TOrphanRuleTests.TheShortGracePassingEndsTheCore;
var
  Core: TCoreUnderTest;
begin
  Core := StandaloneCore;
  Core.EditorAttaches;
  Core.EditorGoes;
  Assert.AreEqual('arm', Core.Beat, 'nothing was armed');
  Assert.AreEqual('stand', Core.After(ShortGrace - 1),
    'the core ended a second before its own deadline');
  Assert.AreEqual('end', Core.After(1), 'the deadline passed and nothing came of it');
end;

procedure TOrphanRuleTests.TheArmingIsAnsweredOnceRatherThanEveryBeat;
var
  Core: TCoreUnderTest;
begin
  Core := StandaloneCore;
  Core.EditorAttaches;
  Core.EditorGoes;
  Assert.AreEqual('arm', Core.Beat, 'nothing was armed');
  Assert.AreEqual('stand', Core.After(10), 'the second beat armed it all over again');
  Assert.AreEqual('stand', Core.After(10), 'the third beat armed it all over again');
  Assert.AreEqual(ShortGrace - 20, Core.GraceLeft,
    'the deadline moved with the beats instead of standing still');
end;

procedure TOrphanRuleTests.AnEditorComingBackDisarmsTheGrace;
var
  Core: TCoreUnderTest;
begin
  Core := StandaloneCore;
  Core.EditorAttaches;
  Core.EditorGoes;
  Assert.AreEqual('arm', Core.Beat, 'nothing was armed');
  Core.EditorAttaches;
  Assert.AreEqual('disarm', Core.After(10), 'the editor returning left the grace running');
  Assert.AreEqual('stand', Core.After(AnHour),
    'a core with a session attached was ended by a deadline that should be gone');
end;

procedure TOrphanRuleTests.AFormOpeningDisarmsTheGrace;
var
  Core: TCoreUnderTest;
begin
  Core := StandaloneCore;
  Core.EditorAttaches;
  Core.EditorGoes;
  Assert.AreEqual('arm', Core.Beat, 'nothing was armed');
  Core.FormOpens;
  Assert.AreEqual('disarm', Core.After(10), 'a document opening left the grace running');
  Assert.AreEqual('stand', Core.After(AnHour),
    'a core with a document open in it was ended');
end;

procedure TOrphanRuleTests.AGraceThatWasDisarmedStartsOverRatherThanResuming;
var
  Core: TCoreUnderTest;
begin
  Core := StandaloneCore;
  Core.EditorAttaches;
  Core.EditorGoes;
  Assert.AreEqual('arm', Core.Beat, 'nothing was armed');
  Core.After(ShortGrace - 10);
  Core.EditorAttaches;
  Assert.AreEqual('disarm', Core.Beat, 'the editor returning left the grace running');
  Core.EditorGoes;
  Assert.AreEqual('arm', Core.Beat, 'the second departure armed nothing');
  Assert.AreEqual(ShortGrace, Core.GraceLeft,
    'the second grace carried on where the first left off');
  Assert.AreEqual('stand', Core.After(ShortGrace - 1),
    'the core ended on the deadline of a grace that was disarmed');
end;

// EvaluateOrphan has no unsaved-changes input: a document with unsaved
// changes is one of the open windows counted in TOrphanInputs.Windows.
procedure TOrphanRuleTests.ADirtyDocumentIsAWindowSoTheRuleCannotReachIt;
var
  Core: TCoreUnderTest;
begin
  Core := StandaloneCore;
  Core.EditorAttaches;
  Core.FormOpens;
  Core.EditorGoes;
  Assert.AreEqual('stand', Core.Beat,
    'the editor going armed a grace over a document that is still open');
  Assert.AreEqual('stand', Core.After(AnHour),
    'a designer holding unsaved work ended itself');
end;

procedure TOrphanRuleTests.AServeCoreNobodyEverAttachedToEndsAfterTheLongGrace;
var
  Core: TCoreUnderTest;
begin
  Core := ServeStartedCore;
  Assert.AreEqual('arm', Core.Beat, 'a core started to be attached to armed nothing');
  Assert.AreEqual(LongGrace, Core.GraceLeft, 'the grace armed was not the long one');
  Assert.AreEqual('stand', Core.After(LongGrace - 1),
    'the core ended a second before its own deadline');
  Assert.AreEqual('end', Core.After(1), 'the leak guard never fired');
end;

procedure TOrphanRuleTests.AServeCoreIsLeftAloneWhileSomethingIsOpenInIt;
var
  Core: TCoreUnderTest;
begin
  Core := ServeStartedCore;
  Core.FormOpens;
  Assert.AreEqual('stand', Core.Beat, 'a document routed into it was counted against');
  Assert.AreEqual('stand', Core.After(AnHour), 'a core with a document open was ended');
  Core.FormCloses;
  Assert.AreEqual('arm', Core.Beat, 'the last document closing armed nothing');
  Assert.AreEqual(LongGrace, Core.GraceLeft,
    'a core no editor ever attached to got the short grace');
end;

// The clause checks are ordered, not exclusive: HadSession is tested before
// ServeStart, so a --serve start that had a session waits AbandonedGrace.
procedure TOrphanRuleTests.AServeCoreThatWasAttachedToOnceFallsUnderTheShortGrace;
var
  Core: TCoreUnderTest;
begin
  Core := ServeStartedCore;
  Assert.AreEqual('arm', Core.Beat, 'the leak guard was never armed');
  Core.EditorAttaches;
  Assert.AreEqual('disarm', Core.Beat, 'the attach left the leak guard counting');
  Core.EditorGoes;
  Assert.AreEqual('arm', Core.Beat, 'the editor going armed nothing');
  Assert.AreEqual(ShortGrace, Core.GraceLeft,
    'a core that has had a session waited the leak guard''s five minutes');
end;

// The shell skips the end while a modal dialog is open, so the end verdict
// repeats at every later beat instead of being reported once.
procedure TOrphanRuleTests.AnEndNothingCarriedOutIsStillOwedAtTheNextBeat;
var
  Core: TCoreUnderTest;
begin
  Core := StandaloneCore;
  Core.EditorAttaches;
  Core.EditorGoes;
  Core.Beat;
  Assert.AreEqual('end', Core.After(ShortGrace), 'the deadline passed and nothing came of it');
  Assert.AreEqual('end', Core.After(10), 'the ending was forgotten by the next beat');
  Assert.AreEqual('end', Core.After(AnHour), 'the ending was forgotten by the next beat');
end;

initialization
  TDUnitX.RegisterTestFixture(TOrphanRuleTests);

end.
