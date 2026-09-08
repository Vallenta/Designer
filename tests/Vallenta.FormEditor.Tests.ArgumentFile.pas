// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.ArgumentFile;

// Covers ExpandConfigFileArgument from Vallenta.FormEditor.Core.ArgumentFile:
// one argument per non-empty line, the file arguments appended after those
// already present, removal of the option and of any nested --config-file,
// and the failure reported for a file that cannot be read.
//
// Argument files are written as start.args in a temp directory that Setup
// creates and TearDown deletes recursively.

interface

uses
  DUnitX.TestFramework;

type
  // Expansion of a --config-file argument into the argument array.
  [TestFixture]
  TArgumentFileTests = class
  private
    FDirectory: string;
    function WriteArgumentFile(const AContent: string;
      const AWithByteOrderMark: Boolean = False): string;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;
    [Test]
    procedure EveryNonEmptyLineBecomesOneArgument;
    [Test]
    procedure TheOptionAndItsFileAreTakenOffTheArguments;
    [Test]
    procedure TheFileArgumentsFollowTheOnesAlreadyThere;
    [Test]
    procedure ArgumentsWithoutTheOptionAreLeftAlone;
    [Test]
    procedure AFileThatIsNotThereFailsAndNamesItself;
    [Test]
    procedure ASearchPathFromTheFileReadsLikeOneFromTheCommandLine;
    [Test]
    procedure ANestedConfigFileIsRemovedAndNotFollowed;
    [Test]
    procedure AByteOrderMarkIsNotPartOfTheFirstArgument;
    [Test]
    procedure Utf8WithoutAMarkIsReadAsUtf8;
    [Test]
    procedure ATrailingOptionWithoutAValueTakesNoArgumentBeforeIt;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  System.Classes,
  Vallenta.FormEditor.Core.ArgumentFile,
  Vallenta.FormEditor.Core.SearchPath;

procedure TArgumentFileTests.Setup;
begin
  FDirectory := TPath.Combine(TPath.GetTempPath, 'vsfe_argumentfile');
  TDirectory.CreateDirectory(FDirectory);
end;

procedure TArgumentFileTests.TearDown;
begin
  if TDirectory.Exists(FDirectory) then
    TDirectory.Delete(FDirectory, True);
end;

// No byte order mark by default: the extension writes the argument file as
// UTF-8 without a preamble.
function TArgumentFileTests.WriteArgumentFile(const AContent: string;
  const AWithByteOrderMark: Boolean): string;
var
  Bytes: TBytes;
begin
  Result := TPath.Combine(FDirectory, 'start.args');
  if AWithByteOrderMark then
    Bytes := TEncoding.UTF8.GetPreamble + TEncoding.UTF8.GetBytes(AContent)
  else
    Bytes := TEncoding.UTF8.GetBytes(AContent);
  TFile.WriteAllBytes(Result, Bytes);
end;

procedure TArgumentFileTests.EveryNonEmptyLineBecomesOneArgument;
var
  Arguments: TArray<string>;
  Error: string;
begin
  Arguments := ['--config-file',
    WriteArgumentFile('--search-path'#10'C:\A;C:\B'#10#10'  --serve  '#10)];

  Assert.IsTrue(ExpandConfigFileArgument(Arguments, Error), Error);
  Assert.AreEqual(3, Length(Arguments));
  Assert.AreEqual('--search-path', Arguments[0]);
  Assert.AreEqual('C:\A;C:\B', Arguments[1], 'a value is one line, spaces and all');
  Assert.AreEqual('--serve', Arguments[2], 'surrounding space is not part of an argument');
end;

procedure TArgumentFileTests.TheOptionAndItsFileAreTakenOffTheArguments;
var
  Arguments: TArray<string>;
  Error: string;
begin
  Arguments := ['C:\Work\Unit1.dfm', '--config-file',
    WriteArgumentFile('--search-path'#10'C:\A'#10)];

  Assert.IsTrue(ExpandConfigFileArgument(Arguments, Error), Error);
  Assert.AreEqual(3, Length(Arguments));
  Assert.AreEqual('C:\Work\Unit1.dfm', Arguments[0]);
end;

// VallentaDesigner.dpr reads the .dfm file from Arguments[0], so the
// appended file arguments must not displace it.
procedure TArgumentFileTests.TheFileArgumentsFollowTheOnesAlreadyThere;
var
  Arguments: TArray<string>;
  Error: string;
begin
  Arguments := ['C:\Work\Unit1.dfm', '--config-file',
    WriteArgumentFile('--search-path'#10'C:\A'#10)];

  Assert.IsTrue(ExpandConfigFileArgument(Arguments, Error), Error);
  Assert.AreEqual('C:\Work\Unit1.dfm', Arguments[0]);
  Assert.AreEqual('--search-path', Arguments[1]);
  Assert.AreEqual('C:\A', Arguments[2]);
end;

procedure TArgumentFileTests.ArgumentsWithoutTheOptionAreLeftAlone;
var
  Arguments: TArray<string>;
  Error: string;
begin
  Arguments := ['--search-path', 'C:\A', 'C:\Work\Unit1.dfm'];

  Assert.IsTrue(ExpandConfigFileArgument(Arguments, Error), Error);
  Assert.AreEqual(3, Length(Arguments));
  Assert.AreEqual('C:\Work\Unit1.dfm', Arguments[2]);
end;

procedure TArgumentFileTests.AFileThatIsNotThereFailsAndNamesItself;
var
  Arguments: TArray<string>;
  Error: string;
  Missing: string;
begin
  Missing := TPath.Combine(FDirectory, 'gone.args');
  Arguments := ['C:\Work\Unit1.dfm', '--config-file', Missing];

  Assert.IsFalse(ExpandConfigFileArgument(Arguments, Error));
  Assert.Contains(Error, Missing, 'the failure does not name the file');
end;

// The second path contains a space, which a command line would require
// quotes for; from a file line it stays one entry after SplitSearchPath.
procedure TArgumentFileTests.ASearchPathFromTheFileReadsLikeOneFromTheCommandLine;
var
  Arguments: TArray<string>;
  Error: string;
  Paths: TArray<string>;
begin
  Arguments := ['C:\Work\Unit1.dfm', '--config-file',
    WriteArgumentFile('--search-path'#10'C:\Base\Forms;D:\Shared Forms\User'#10)];

  Assert.IsTrue(ExpandConfigFileArgument(Arguments, Error), Error);
  Paths := SplitSearchPath(TakeSearchPathArgument(Arguments));
  Assert.AreEqual(2, Length(Paths));
  Assert.AreEqual('C:\Base\Forms', Paths[0]);
  Assert.AreEqual('D:\Shared Forms\User', Paths[1]);
  Assert.AreEqual(1, Length(Arguments), 'option and value were not removed');
  Assert.AreEqual('C:\Work\Unit1.dfm', Arguments[0]);
end;

// The nested file name points at a path that does not exist, so the call
// succeeds only when that option is removed rather than followed.
procedure TArgumentFileTests.ANestedConfigFileIsRemovedAndNotFollowed;
var
  Arguments: TArray<string>;
  Error: string;
begin
  Arguments := ['C:\Work\Unit1.dfm', '--config-file',
    WriteArgumentFile('--config-file'#10'C:\Elsewhere\other.args'#10'--search-path'#10'C:\A'#10)];

  Assert.IsTrue(ExpandConfigFileArgument(Arguments, Error), Error);
  Assert.AreEqual(3, Length(Arguments));
  Assert.AreEqual('C:\Work\Unit1.dfm', Arguments[0]);
  Assert.AreEqual('--search-path', Arguments[1]);
  Assert.AreEqual('C:\A', Arguments[2]);
end;

procedure TArgumentFileTests.AByteOrderMarkIsNotPartOfTheFirstArgument;
var
  Arguments: TArray<string>;
  Error: string;
begin
  Arguments := ['--config-file',
    WriteArgumentFile('--search-path'#10'D:\Küchen\Formulare'#10, True)];

  Assert.IsTrue(ExpandConfigFileArgument(Arguments, Error), Error);
  Assert.AreEqual('--search-path', Arguments[0]);
  Assert.AreEqual('D:\Küchen\Formulare', Arguments[1]);
end;

procedure TArgumentFileTests.Utf8WithoutAMarkIsReadAsUtf8;
var
  Arguments: TArray<string>;
  Error: string;
begin
  Arguments := ['--config-file',
    WriteArgumentFile('--search-path'#10'D:\Küchen\Formulare'#10)];

  Assert.IsTrue(ExpandConfigFileArgument(Arguments, Error), Error);
  Assert.AreEqual('D:\Küchen\Formulare', Arguments[1]);
end;

procedure TArgumentFileTests.ATrailingOptionWithoutAValueTakesNoArgumentBeforeIt;
var
  Arguments: TArray<string>;
  Error: string;
begin
  Arguments := ['C:\Work\Unit1.dfm', '--config-file'];

  Assert.IsTrue(ExpandConfigFileArgument(Arguments, Error), Error);
  Assert.AreEqual(1, Length(Arguments));
  Assert.AreEqual('C:\Work\Unit1.dfm', Arguments[0]);
end;

initialization
  TDUnitX.RegisterTestFixture(TArgumentFileTests);

end.
