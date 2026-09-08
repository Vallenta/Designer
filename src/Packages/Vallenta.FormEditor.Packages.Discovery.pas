// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Packages.Discovery;

// Reads installed design packages from the Known Packages and Disabled
// Packages subkeys of HKEY_CURRENT_USER\Software\Embarcadero\BDS\<IdeVersion>,
// read-only: a value name is a package path, its data the description.
// Expands the IDE path variables those paths carry, and supplies the
// default allow and exclusion lists and the matching that applies them.
//
// IdeRootDirectory caches the installation root in unit variables without
// synchronization: the read flag is set before the root is assigned, so a
// concurrent first call can read an empty root.

interface

type
  // Source of a package candidate. The allow and exclusion lists are applied
  // to poRegistry candidates only.
  TPackageOrigin = (poRegistry, poExplicit);

  // One discovered or configured package file.
  TDiscoveredPackage = record
    // Package file path; IDE path variables are expanded on poRegistry
    // entries.
    Path: string;
    // Description the registry holds for the package; empty when there is
    // none.
    Description: string;
    // Whether the path came from registry discovery or from configuration.
    Origin: TPackageOrigin;
  end;

const
  // Package discovery constants.
  OriginCaptions: array [TPackageOrigin] of string = ('IDE', 'configured');

  // Matched exactly against an allow-list entry, never as a mask.
  AllowEverything = '*';

// IDE installation root: the BDS environment variable, or the RootDir value
// under the IDE registry key when that is unset; empty when neither is set.
// No trailing path separator. Read once and kept for the process lifetime.
function IdeRootDirectory: string;
// IdeRootDirectory with '\bin' appended; empty when the root is empty.
function IdeBinDirectory: string;

// Expands $(BDS), $(BDSBIN), $(BDSLIB) and $(BDSCOMMONDIR), then %VAR% and
// any remaining $(VAR) from the environment. A variable with no value is
// left in place rather than replaced by an empty string.
function ExpandPackagePath(const APath: string): string;

// Packages listed under Known Packages, minus the paths also listed under
// Disabled Packages. Paths are expanded and Origin is poRegistry on every
// entry; entry order follows the registry enumeration, which is undefined.
function InstalledPackages: TArray<TDiscoveredPackage>;

// Allow list applied when the registry configures none: AllowEverything,
// which admits every discovered package.
function DefaultAllowList: TArray<string>;

// Exclusion list applied when the registry holds no exclusion value:
// 'madExcept*'. The mask must span the family: madExceptVcl_ loads
// madExcept_, whose initialization hook turns an exception during a load
// into a modal dialog.
function DefaultExclusions: TArray<string>;

// True when an exclusion entry matches the file name of APath. Entries are
// file-name masks, matched case-insensitively; an empty list excludes
// nothing.
function IsExcluded(const APath: string; const AExclusions: TArray<string>): Boolean;

// Splits a configured allow or exclusion list on commas and semicolons,
// trimming each entry and dropping the empty ones.
function ParseNameList(const AText: string): TArray<string>;

// True when the allow list names neither AllowEverything nor the file name
// of APath. Entries are compared to the file name case-insensitively and are
// not masks; an empty list admits everything.
function IsHeldBack(const APath: string; const AAllowList: TArray<string>): Boolean;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.StrUtils,
  System.Masks,
  System.Win.Registry,
  Vallenta.FormEditor.Core.Settings;

const
  IdeRegistryRoot = 'Software\Embarcadero\BDS\' + IdeVersion;
  KnownPackagesKey = IdeRegistryRoot + '\Known Packages';
  DisabledPackagesKey = IdeRegistryRoot + '\Disabled Packages';
  RootDirectoryValue = 'RootDir';

var
  IdeRoot: string;
  IdeRootRead: Boolean = False;

function ReadEnvironment(const AName: string): string;
begin
  Result := GetEnvironmentVariable(AName);
end;

function IdeRootDirectory: string;
var
  Registry: TRegistry;
begin
  if not IdeRootRead then
  begin
    IdeRootRead := True;
    IdeRoot := ReadEnvironment('BDS');
    if IdeRoot = '' then
    begin
      Registry := TRegistry.Create(KEY_READ);
      try
        Registry.RootKey := HKEY_CURRENT_USER;
        if Registry.OpenKeyReadOnly(IdeRegistryRoot) and
          Registry.ValueExists(RootDirectoryValue) then
          IdeRoot := Registry.ReadString(RootDirectoryValue);
      finally
        Registry.Free;
      end;
    end;
    IdeRoot := ExcludeTrailingPathDelimiter(IdeRoot);
  end;
  Result := IdeRoot;
end;

function IdeBinDirectory: string;
begin
  Result := IdeRootDirectory;
  if Result <> '' then
    Result := Result + '\bin';
end;

function IdeCommonDirectory: string;
begin
  Result := ReadEnvironment('BDSCOMMONDIR');
  if Result <> '' then
    Exit;
  Result := ReadEnvironment('PUBLIC');
  if Result <> '' then
    Result := Format('%s\Documents\Embarcadero\Studio\%s', [Result, IdeVersion]);
end;

function ExpandFromEnvironment(const APath: string): string;
var
  Required, Written: Cardinal;
begin
  Required := ExpandEnvironmentStrings(PChar(APath), nil, 0);
  if Required = 0 then
    Exit(APath);
  SetLength(Result, Integer(Required));
  Written := ExpandEnvironmentStrings(PChar(APath), PChar(Result), Required);
  if Written = 0 then
    Exit(APath);
  // ExpandEnvironmentStrings counts include the null terminator.
  SetLength(Result, Integer(Written) - 1);
end;

function ExpandRemainingVariables(const APath: string): string;
var
  Start, Stop: Integer;
  Name, Value: string;
begin
  Result := APath;
  Start := Pos('$(', Result);
  while Start > 0 do
  begin
    Stop := PosEx(')', Result, Start);
    if Stop = 0 then
      Break;
    Name := Copy(Result, Start + 2, Stop - Start - 2);
    Value := ReadEnvironment(Name);
    if Value = '' then
      Start := PosEx('$(', Result, Stop)
    else
    begin
      Result := Copy(Result, 1, Start - 1) + Value +
        Copy(Result, Stop + 1, MaxInt);
      Start := PosEx('$(', Result, Start + Length(Value));
    end;
  end;
end;

procedure ReplaceKnown(var APath: string; const AVariable, AValue: string);
begin
  if AValue <> '' then
    APath := StringReplace(APath, AVariable, AValue, [rfReplaceAll, rfIgnoreCase]);
end;

function ExpandPackagePath(const APath: string): string;
var
  Root: string;
begin
  Result := APath;
  Root := IdeRootDirectory;
  // $(BDS) is a prefix of the other names and must be replaced last.
  ReplaceKnown(Result, '$(BDSCOMMONDIR)', IdeCommonDirectory);
  ReplaceKnown(Result, '$(BDSBIN)', IdeBinDirectory);
  if Root <> '' then
    ReplaceKnown(Result, '$(BDSLIB)', Root + '\lib');
  ReplaceKnown(Result, '$(BDS)', Root);
  Result := ExpandFromEnvironment(Result);
  Result := ExpandRemainingVariables(Result);
end;

function ReadPackageKey(const AKey: string): TStringList;
var
  Registry: TRegistry;
  Names: TStringList;
  Name: string;
begin
  Result := TStringList.Create;
  Result.CaseSensitive := False;
  Registry := TRegistry.Create(KEY_READ);
  try
    Registry.RootKey := HKEY_CURRENT_USER;
    if not Registry.OpenKeyReadOnly(AKey) then
      Exit;
    Names := TStringList.Create;
    try
      Registry.GetValueNames(Names);
      for Name in Names do
        if Registry.GetDataType(Name) in [rdString, rdExpandString] then
          Result.AddPair(ExpandPackagePath(Name), Registry.ReadString(Name))
        else
          Result.AddPair(ExpandPackagePath(Name), '');
    finally
      Names.Free;
    end;
  finally
    Registry.Free;
  end;
end;

function InstalledPackages: TArray<TDiscoveredPackage>;
var
  Known, Disabled: TStringList;
  Entry: TDiscoveredPackage;
  I: Integer;
begin
  Result := [];
  Known := ReadPackageKey(KnownPackagesKey);
  try
    Disabled := ReadPackageKey(DisabledPackagesKey);
    try
      Entry.Origin := poRegistry;
      for I := 0 to Known.Count - 1 do
      begin
        Entry.Path := Known.Names[I];
        if Disabled.IndexOfName(Entry.Path) >= 0 then
          Continue;
        Entry.Description := Known.ValueFromIndex[I];
        Result := Result + [Entry];
      end;
    finally
      Disabled.Free;
    end;
  finally
    Known.Free;
  end;
end;

function DefaultAllowList: TArray<string>;
begin
  Result := [AllowEverything];
end;

function DefaultExclusions: TArray<string>;
begin
  Result := ['madExcept*'];
end;

function IsExcluded(const APath: string; const AExclusions: TArray<string>): Boolean;
var
  Excluded, Name: string;
begin
  Name := ExtractFileName(APath);
  for Excluded in AExclusions do
    if MatchesMask(Name, Excluded) then
      Exit(True);
  Result := False;
end;

function ParseNameList(const AText: string): TArray<string>;
var
  Part: string;
begin
  Result := [];
  for Part in SplitString(AText, ',;') do
    if Trim(Part) <> '' then
      Result := Result + [Trim(Part)];
end;

function IsHeldBack(const APath: string; const AAllowList: TArray<string>): Boolean;
var
  Allowed: string;
begin
  if Length(AAllowList) = 0 then
    Exit(False);
  for Allowed in AAllowList do
    if (Allowed = AllowEverything) or
      SameText(Allowed, ExtractFileName(APath)) then
      Exit(False);
  Result := True;
end;

end.
