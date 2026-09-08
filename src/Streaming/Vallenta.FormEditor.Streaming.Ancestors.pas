// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Streaming.Ancestors;

// Determines which ancestor form files a document built on another form
// needs and in which order, base-most first. An ancestor class name comes
// from the class of that name present in this process, those in loaded
// design packages included, and from the companion .pas unit otherwise;
// the file is located through TDfmClassIndex. The loader streams the files.
//
// The index passed to the constructor must have been pointed at the
// document's directory with SearchIn before Resolve is called. One instance
// resolves one document at a time; concurrent calls are not supported.

interface

uses
  System.SysUtils,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Streaming.RootClassifier;

type
  // Raised when an ancestor chain cannot be resolved: an ancestor class
  // neither a loaded class nor the companion .pas unit declares, a missing
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
    function AncestorOf(const AFileName, AClassName: string): string;
  public
    // ALog may be nil. AIndex is only referenced: the caller frees it and
    // must keep it alive for the lifetime of this instance.
    constructor Create(ALog: TDesignLog; AIndex: TDfmClassIndex);
    // Walks from ARootClass ancestor by ancestor until a base class known to
    // BaseClassKind, filling Files, BaseClass and BaseKind. ADocumentFile is
    // the document's own form file; its name supplies the companion .pas
    // unit and the unit hint for the first lookup. Raises
    // EAncestorChainError instead of returning an incomplete chain.
    procedure Resolve(const ADocumentFile, ARootClass: string);
    // The ancestor form files in streaming order, base-most first; the
    // document's own file is not included. Empty when ARootClass descends
    // directly from a base class.
    property Files: TArray<string> read FFiles;
    // Name of the base class the chain ends at, e.g. TForm; empty until
    // Resolve succeeds.
    property BaseClass: string read FBaseClass;
    // Root kind fixed by the base class; valid only after Resolve returns.
    property BaseKind: TDesignRootClass read FBaseKind;
  end;

const
  // Maximum number of ancestor form files in one chain.
  AncestorDepthLimit = 8;

implementation

uses
  System.StrUtils,
  Vallenta.FormEditor.Core.LoadedClasses;

constructor TAncestorChain.Create(ALog: TDesignLog; AIndex: TDfmClassIndex);
begin
  inherited Create;
  FLog := ALog;
  FIndex := AIndex;
  FBaseKind := drForm;
end;

function TAncestorChain.AncestorOf(const AFileName, AClassName: string): string;
begin
  Result := LoadedAncestorClass(AClassName,
    ChangeFileExt(ExtractFileName(AFileName), ''));
  if Result = '' then
    Result := CompanionAncestorClass(AFileName, AClassName);
  if Result = '' then
    raise EAncestorChainError.CreateFmt(
      '"%s" is built on another form, and neither a loaded package nor the ' +
      'unit beside %s says which one. The designer needs it to read the form.',
      [AClassName, ExtractFileName(ChangeFileExt(AFileName, '.pas'))]);
end;

procedure TAncestorChain.Resolve(const ADocumentFile, ARootClass: string);
var
  CurrentFile, CurrentClass, Ancestor, AncestorFile: string;
  Seen: TArray<string>;
  Step: string;
begin
  FFiles := nil;
  FBaseClass := '';
  CurrentFile := ADocumentFile;
  CurrentClass := ARootClass;
  Seen := [ARootClass];
  repeat
    Ancestor := AncestorOf(CurrentFile, CurrentClass);
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
    AncestorFile := FIndex.FileFor(Ancestor, [rkObject, rkInherited]);
    if AncestorFile = '' then
      if Length(FIndex.ExtraDirectories) > 0 then
        raise EAncestorChainError.CreateFmt(
          '"%s" is built on "%s", and no form file beside %s or on the ' +
          'search path declares it. The designer cannot read the form ' +
          'without the one it is built on.',
          [CurrentClass, Ancestor, ExtractFileName(ADocumentFile)])
      else
        raise EAncestorChainError.CreateFmt(
          '"%s" is built on "%s", and no form file beside %s declares it. ' +
          'The designer cannot read the form without the one it is built ' +
          'on; a search path (--search-path) names other directories to ' +
          'look in.',
          [CurrentClass, Ancestor, ExtractFileName(ADocumentFile)]);
    FFiles := [AncestorFile] + FFiles;
    Seen := Seen + [Ancestor];
    if Length(FFiles) > AncestorDepthLimit then
      raise EAncestorChainError.CreateFmt(
        '"%s" is built on more than %d forms, which the designer takes for a ' +
        'mistake rather than a hierarchy.', [ARootClass, AncestorDepthLimit]);
    CurrentFile := AncestorFile;
    CurrentClass := Ancestor;
  until False;

  if FLog <> nil then
    for Step in FFiles do
      FLog.AddFmt(lsInfo, 'built on %s', [ExtractFileName(Step)]);
end;

end.
