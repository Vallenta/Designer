// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Streaming.Ancestors;

// Determines the ancestor form files of a document built on another form,
// base-most first; the loader streams them. An ancestor class name is taken
// from the loaded class of that name, design packages included, else from the
// class's unit beside the form file or on the search path. A form file with a
// plain "object" root holds the complete state of its class and ends the chain.
//
// The TDfmClassIndex passed to the constructor must have been prepared with
// SearchIn for the document's directory before Resolve is called. One
// instance resolves one document at a time; concurrent calls are not
// supported.

interface

uses
  System.SysUtils,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Streaming.RootClassifier;

type
  // Raised when an ancestor chain cannot be resolved: an "inherited" root
  // with an ancestor named by neither a loaded class nor a unit, a missing
  // form file, a cycle, or a chain longer than AncestorDepthLimit.
  EAncestorChainError = class(Exception);

  // Resolves the chain of ancestor form files for one document. Reusable:
  // each Resolve replaces the previous result.
  TAncestorChain = class
  private
    FLog: TDesignLog;
    FIndex: TDfmClassIndex;
    FFiles: TArray<string>;
    FBaseClass: string;
    FBaseKind: TDesignRootClass;
    function FindUnitDeclaration(const AFileName, AClassName: string;
      out ADeclaration: TUnitDeclaration): Boolean;
    function AncestorOf(const AFileName, AClassName: string;
      out AUnitNames: TArray<string>): string;
    procedure SettleBase(const AFileName, AClassName: string);
  public
    // ALog may be nil. AIndex is only referenced: the caller frees it and
    // must keep it alive for the lifetime of this instance.
    constructor Create(ALog: TDesignLog; AIndex: TDfmClassIndex);
    // Walks the ancestors of ARootClass up to a base class known to
    // BaseClassKind or a form file with a plain "object" root, and fills
    // Files, BaseClass and BaseKind. ADocumentFile is the document's own
    // "inherited" form file; its name is the unit name of the first lookup.
    // Where several form files declare an ancestor class, the file named after
    // a unit in scope of the declaration naming it is taken. Raises
    // EAncestorChainError rather than leave an incomplete chain.
    procedure Resolve(const ADocumentFile, ARootClass: string);
    // The ancestor form files in streaming order, base-most first; the
    // document's own file is not included. Empty when ARootClass descends
    // directly from a base class.
    property Files: TArray<string> read FFiles;
    // Base class at the end of the chain, e.g. TForm; the stub class of the
    // root kind when the root file's properties decided the kind. Empty until
    // Resolve succeeds.
    property BaseClass: string read FBaseClass;
    // Root kind fixed by the base class, or by the properties of a plain root
    // whose base no loaded class or unit names; valid only after Resolve.
    property BaseKind: TDesignRootClass read FBaseKind;
  end;

const
  // Maximum number of ancestor form files in one chain.
  AncestorDepthLimit = 8;

implementation

uses
  System.StrUtils,
  Vallenta.FormEditor.Core.LoadedClasses;

const
  // Stub class streamed into for each root kind.
  StubClasses: array [TDesignRootClass] of string = (
    'TForm', 'TFrame', 'TDataModule');

// Name of the unit paired with a form file; the two share a base name.
function UnitNameOf(const AFileName: string): string;
begin
  Result := ChangeFileExt(ExtractFileName(AFileName), '');
end;

constructor TAncestorChain.Create(ALog: TDesignLog; AIndex: TDfmClassIndex);
begin
  inherited Create;
  FLog := ALog;
  FIndex := AIndex;
  FBaseKind := drForm;
end;

// Reads the declaration of AClassName from the unit beside AFileName, else
// from a unit of that name on the search path: a directory of form files
// copied for linking holds no units.
function TAncestorChain.FindUnitDeclaration(const AFileName, AClassName: string;
  out ADeclaration: TUnitDeclaration): Boolean;
var
  Beside, Candidate: string;
begin
  Beside := ChangeFileExt(AFileName, '.pas');
  if ReadUnitDeclaration(Beside, AClassName, ADeclaration) then
    Exit(True);
  for Candidate in FIndex.UnitFiles(UnitNameOf(AFileName)) do
    if not SameFileName(ExpandFileName(Candidate), ExpandFileName(Beside)) and
       ReadUnitDeclaration(Candidate, AClassName, ADeclaration) then
    begin
      if FLog <> nil then
        FLog.AddFmt(lsInfo, 'no unit beside %s declares "%s" - what it is ' +
          'built on is read from %s', [AFileName, AClassName, Candidate]);
      Exit(True);
    end;
  Result := False;
end;

function TAncestorChain.AncestorOf(const AFileName, AClassName: string;
  out AUnitNames: TArray<string>): string;
var
  Loaded: TClass;
  Declaration: TUnitDeclaration;
begin
  AUnitNames := nil;
  Loaded := LoadedClass(AClassName, UnitNameOf(AFileName));
  if (Loaded <> nil) and (Loaded.ClassParent <> nil) then
  begin
    AUnitNames := [Loaded.ClassParent.UnitName];
    Exit(Loaded.ClassParent.ClassName);
  end;
  if not FindUnitDeclaration(AFileName, AClassName, Declaration) then
    Exit('');
  Result := Declaration.AncestorClass;
  AUnitNames := Declaration.UsedUnits;
  // The unit of a loaded class of that name ranks after the uses clause, which
  // states where the project itself declares the class.
  Loaded := LoadedClass(Result);
  if Loaded <> nil then
    AUnitNames := AUnitNames + [Loaded.UnitName];
end;

// Sets BaseClass and BaseKind for a plain "object" root, whose classes up to
// the stub's base class contribute nothing to stream: from the nearest base of
// a loaded class, else from the unit's declaration, else from the file's own
// properties.
procedure TAncestorChain.SettleBase(const AFileName, AClassName: string);
var
  Loaded: TClass;
  Declaration: TUnitDeclaration;
  Sniffed: TRootKind;
begin
  Loaded := LoadedClass(AClassName, UnitNameOf(AFileName));
  while Loaded <> nil do
  begin
    if BaseClassKind(Loaded.ClassName, FBaseKind) then
    begin
      FBaseClass := Loaded.ClassName;
      Exit;
    end;
    Loaded := Loaded.ClassParent;
  end;
  if FindUnitDeclaration(AFileName, AClassName, Declaration) and
     BaseClassKind(Declaration.AncestorClass, FBaseKind) then
  begin
    FBaseClass := Declaration.AncestorClass;
    Exit;
  end;
  Sniffed := ClassifyDesignRootFile(AFileName, AClassName);
  FBaseKind := Sniffed.Kind;
  FBaseClass := StubClasses[Sniffed.Kind];
  if FLog = nil then
    Exit;
  if Sniffed.Source = rksAssumed then
    FLog.AddFmt(lsWarn, 'neither a loaded package nor a unit names what ' +
      '"%s" in %s descends from, so its kind is taken from the file: %s',
      [AClassName, AFileName, DescribeRootKind(Sniffed)])
  else
    FLog.AddFmt(lsInfo, 'neither a loaded package nor a unit names what ' +
      '"%s" in %s descends from, so its kind is taken from the file: %s',
      [AClassName, AFileName, DescribeRootKind(Sniffed)]);
end;

procedure TAncestorChain.Resolve(const ADocumentFile, ARootClass: string);
var
  CurrentFile, CurrentClass, Ancestor, SearchPathClause: string;
  UnitNames: TArray<string>;
  Found: TDfmClassFile;
  Seen: TArray<string>;
  Step: string;
begin
  FFiles := nil;
  FBaseClass := '';
  FBaseKind := drForm;
  SearchPathClause := IfThen(Length(FIndex.ExtraDirectories) > 0,
    ' or on the search path', '');
  CurrentFile := ADocumentFile;
  CurrentClass := ARootClass;
  Seen := [ARootClass];
  repeat
    // CurrentFile is "inherited" here - the document, or an ancestor with
    // such a root - so it has an ancestor that must be found.
    Ancestor := AncestorOf(CurrentFile, CurrentClass, UnitNames);
    if Ancestor = '' then
      raise EAncestorChainError.CreateFmt(
        '"%s" in %s is built on another form, and neither a loaded package ' +
        'nor a unit %s beside it%s says which one. The designer needs it to ' +
        'read the form.',
        [CurrentClass, CurrentFile, UnitNameOf(CurrentFile) + '.pas',
         SearchPathClause]);
    if BaseClassKind(Ancestor, FBaseKind) then
    begin
      FBaseClass := Ancestor;
      Break;
    end;
    for Step in Seen do
      if SameText(Step, Ancestor) then
        raise EAncestorChainError.CreateFmt(
          '"%s" is built on itself: %s.',
          [ARootClass, string.Join(' is built on ', Seen + [Ancestor])]);
    Found := FIndex.FileFor(Ancestor, [rkObject, rkInherited], UnitNames);
    if Found.FileName = '' then
      if Length(FIndex.ExtraDirectories) > 0 then
        raise EAncestorChainError.CreateFmt(
          '"%s" is built on "%s", and no form file in %s or on the search ' +
          'path declares it. The designer cannot read the form without the ' +
          'one it is built on.',
          [CurrentClass, Ancestor, ExtractFileDir(ADocumentFile)])
      else
        raise EAncestorChainError.CreateFmt(
          '"%s" is built on "%s", and no form file in %s declares it. The ' +
          'designer cannot read the form without the one it is built on; a ' +
          'search path (--search-path) names other directories to look in.',
          [CurrentClass, Ancestor, ExtractFileDir(ADocumentFile)]);
    FFiles := [Found.FileName] + FFiles;
    Seen := Seen + [Ancestor];
    if Length(FFiles) > AncestorDepthLimit then
      raise EAncestorChainError.CreateFmt(
        '"%s" is built on more than %d forms, which the designer takes for a ' +
        'mistake rather than a hierarchy.', [ARootClass, AncestorDepthLimit]);
    if Found.Kind = rkObject then
    begin
      SettleBase(Found.FileName, Ancestor);
      Break;
    end;
    CurrentFile := Found.FileName;
    CurrentClass := Ancestor;
  until False;

  if FLog <> nil then
    for Step in FFiles do
      FLog.AddFmt(lsInfo, 'built on %s', [Step]);
end;

end.
