// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Packages.Preflight;

// Decides whether a package file can be loaded, from its PE headers and from
// the state of this process, without loading it. Each check yields a verdict
// and a reason text; InspectPackage converts EPeImageError to pvUnreadable
// and lets any other exception through. The host release is cached in unit
// variables with no lock, so no entry point may be called concurrently.

interface

type
  // Outcome of inspecting a package file without loading it.
  TPreflightVerdict = (
    pvLoadable,     // no check rejected the file
    pvMissing,      // no file at the path
    pvArchitecture, // not a 32-bit x86 image
    pvRelease,      // imports an rtl or vcl package of another release
    pvIdeWindow,    // derives a window from the IDE's dockable form
    pvDuplicate,    // listed in AChosen, or that file name is loaded already
    pvUnreadable);  // not a readable PE image

  // Result of inspecting one package file.
  TPreflight = record
    // The check that rejected the file, or pvLoadable when none did.
    Verdict: TPreflightVerdict;
    // Reason text for the log and the package manager list, a fragment such
    // as 'the file does not exist'; empty for pvLoadable.
    Detail: string;
  end;

// Inspects the package file at APath without loading it; an image that
// cannot be read yields pvUnreadable rather than an exception. AChosen holds
// the paths already accepted, each compared with APath as a whole string,
// case-insensitively and without normalization.
function InspectPackage(const APath: string;
  const AChosen: TArray<string>): TPreflight;

// Release digits of the first rtl or vcl package this executable requires,
// '290' for rtl290.bpl. Read once and cached; empty when none is required or
// the package information cannot be read, which skips the release check.
function HostRuntimeRelease: string;

// True when AImports, names imported from the IDE's design package, include
// a member of Dockform.TDockableForm. A window derived from that class
// subscribes at creation to a desktop event that only the IDE creates, so
// no other host can construct it.
function DerivesIdeWindow(const AImports: TArray<string>): Boolean;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.IOUtils,
  System.StrUtils,
  Vallenta.FormEditor.Packages.PeImage;

const
  // Machine types the designer cannot load, and the package extension.
  MachineAmd64 = $8664;
  MachineArm64 = $AA64;
  PackageExtension = '.bpl';
  // The IDE's design package without release digits and extension, and the
  // mangled prefix of the dockable form's members it exports.
  DesignPackagePrefix = 'designide';
  DockableFormPrefix = '@Dockform@TDockableForm@';

var
  // The host's own package release, read from HInstance once on first use.
  HostRelease: string;
  HostReleaseRead: Boolean = False;

// The digits following APrefix in the file name of AName, without the
// extension: '370' for designide370.bpl against 'designide'. Empty unless the
// name is APrefix followed by digits only.
function ReleaseDigits(const AName, APrefix: string): string;
var
  Base: string;
  Character: Char;
begin
  Result := '';
  Base := LowerCase(ChangeFileExt(ExtractFileName(AName), ''));
  if not StartsStr(APrefix, Base) then
    Exit;
  Result := Copy(Base, Length(APrefix) + 1, MaxInt);
  for Character in Result do
    if not CharInSet(Character, ['0' .. '9']) then
      Exit('');
end;

function RuntimeRelease(const AName: string): string;
begin
  Result := ReleaseDigits(AName, 'rtl');
  if Result = '' then
    Result := ReleaseDigits(AName, 'vcl');
end;

function IsDesignPackage(const AName: string): Boolean;
begin
  Result := SameText(ExtractFileExt(AName), PackageExtension) and
    (ReleaseDigits(AName, DesignPackagePrefix) <> '');
end;

function DerivesIdeWindow(const AImports: TArray<string>): Boolean;
var
  Import: string;
begin
  for Import in AImports do
    if StartsText(DockableFormPrefix, Import) then
      Exit(True);
  Result := False;
end;

procedure ReadHostRequirement(const Name: string; NameType: TNameType;
  Flags: Byte; Param: Pointer);
begin
  if (NameType = ntRequiresPackage) and (HostRelease = '') then
    HostRelease := RuntimeRelease(Name);
end;

function HostRuntimeRelease: string;
var
  Flags: Integer;
begin
  if not HostReleaseRead then
  begin
    HostReleaseRead := True;
    try
      GetPackageInfo(HInstance, nil, Flags, ReadHostRequirement);
    except
      HostRelease := '';
    end;
  end;
  Result := HostRelease;
end;

function MachineName(AMachine: Word): string;
begin
  case AMachine of
    MachineAmd64:
      Result := '64-bit';
    MachineArm64:
      Result := '64-bit ARM';
  else
    Result := Format('machine type %x', [AMachine]);
  end;
end;

function IsAlreadyChosen(const APath: string;
  const AChosen: TArray<string>): Boolean;
var
  Chosen: string;
begin
  for Chosen in AChosen do
    if SameText(Chosen, APath) then
      Exit(True);
  Result := False;
end;

function ReleaseVerdict(const APath: string): TPreflight;
var
  Imported, Release: string;
begin
  Result.Verdict := pvLoadable;
  Result.Detail := '';
  if HostRuntimeRelease = '' then
    Exit;
  for Imported in ImportedModuleNames(APath) do
  begin
    if not SameText(ExtractFileExt(Imported), PackageExtension) then
      Continue;
    Release := RuntimeRelease(Imported);
    if (Release <> '') and (Release <> HostRuntimeRelease) then
    begin
      Result.Verdict := pvRelease;
      Result.Detail := Format('it was built against %s and this designer ' +
        'against release %s', [Imported, HostRuntimeRelease]);
      Exit;
    end;
  end;
end;

function IdeWindowVerdict(const APath: string): TPreflight;
var
  Imported: string;
begin
  Result.Verdict := pvLoadable;
  Result.Detail := '';
  for Imported in ImportedModuleNames(APath) do
    if IsDesignPackage(Imported) and
      DerivesIdeWindow(ImportedNames(APath, Imported)) then
    begin
      Result.Verdict := pvIdeWindow;
      Result.Detail := 'it derives a window from the IDE''s dockable form, ' +
        'which only the IDE sets up';
      Exit;
    end;
end;

function InspectPackage(const APath: string;
  const AChosen: TArray<string>): TPreflight;
var
  Machine: Word;
begin
  Result.Verdict := pvLoadable;
  Result.Detail := '';
  if not TFile.Exists(APath) then
  begin
    Result.Verdict := pvMissing;
    Result.Detail := 'the file does not exist';
    Exit;
  end;
  try
    Machine := ImageMachineType(APath);
    if Machine <> IMAGE_FILE_MACHINE_I386 then
    begin
      Result.Verdict := pvArchitecture;
      Result.Detail := Format('it is %s and this designer is 32-bit',
        [MachineName(Machine)]);
      Exit;
    end;
    if IsAlreadyChosen(APath, AChosen) then
    begin
      Result.Verdict := pvDuplicate;
      Result.Detail := 'the package is listed more than once';
      Exit;
    end;
    if GetModuleHandle(PChar(ExtractFileName(APath))) <> 0 then
    begin
      Result.Verdict := pvDuplicate;
      Result.Detail := 'a package of this name is already in the process';
      Exit;
    end;
    Result := ReleaseVerdict(APath);
    if Result.Verdict = pvLoadable then
      Result := IdeWindowVerdict(APath);
  except
    on E: EPeImageError do
    begin
      Result.Verdict := pvUnreadable;
      Result.Detail := E.Message;
    end;
  end;
end;

end.
