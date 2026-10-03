// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Streaming.RootClassifier;

// Reads the root declaration of a form file (keyword, class and object name)
// from a binary TPF0 stream or the first line of the text form, and classifies
// the root as form, frame or data module by the ancestor in the companion .pas
// unit, else by the root's property names. Also reads class declarations out
// of Pascal units, and indexes .dfm files by root class and object name.
//
// TDfmClassIndex lists its directories inside the first lookup and holds no
// lock; FileFor and FileForInstance are therefore not safe to call
// concurrently. Headers read by any index are kept in one process-wide cache
// guarded by a lock.

interface

uses
  System.Classes,
  System.SysUtils,
  System.Generics.Collections;

type
  // Kind of design root: form, frame, or data module.
  TDesignRootClass = (drForm, drFrame, drDataModule);

  // Keyword a root block is declared with: "object" for a plain root,
  // "inherited" for a descendant of another form or frame, "inline" for an
  // embedded frame instance.
  TDfmRootKind = (rkObject, rkInherited, rkInline);

  // Root block declaration as read from a form file.
  TDfmRootHeader = record
    Kind: TDfmRootKind;
    // Empty when no root declaration could be read.
    ClassName: string;
    // Empty for a root declared without an instance name.
    ObjectName: string;
  end;

  // Classification stage that decided the kind; rksAssumed means no evidence
  // was found and the kind defaults to drForm.
  TRootKindSource = (rksCompanionUnit, rksPropertySniff, rksAssumed);

  // Result of ClassifyDesignRoot; DescribeRootKind renders it as one line.
  TRootKind = record
    Kind: TDesignRootClass;
    Source: TRootKindSource;
    // Companion unit file name for rksCompanionUnit, otherwise a phrase
    // naming the evidence or its absence.
    Detail: string;
  end;

  // Raised when a stream lacks the TPF0 signature.
  ERootHeaderError = class(Exception);

  // Indexed form file and the keyword of its root block.
  TDfmClassFile = record
    FileName: string;
    Kind: TDfmRootKind;
  end;

  // Reports a lookup that found AName in more than one form file with no
  // unit in scope to choose by. AFiles lists them in walk order; the first is
  // the file taken. AByInstance is True when AName is a root object name,
  // False when it is a root class name.
  TDfmClassClashEvent = procedure(const AName: string; AByInstance: Boolean;
    const AFiles: TArray<string>) of object;

  // A form file as reported by a directory listing. Size and WriteTime decide
  // whether a header read from it earlier is still valid.
  TDfmListedFile = record
    FileName: string;
    Size: Int64;
    WriteTime: TDateTime;
  end;

  // Declaration of one class as read from a Pascal unit.
  TUnitDeclaration = record
    FileName: string;
    // Ancestor class named in the declaration, without a unit qualifier.
    AncestorClass: string;
    // Units in scope for the declaration in compiler resolution order, the
    // unit listed last first. A class declared in the interface section has
    // only the interface uses clause in scope.
    UsedUnits: TArray<string>;
  end;

  // Maps root class names and root object names to the .dfm files in the
  // directory set by SearchIn and in the extra directories given with it.
  // Every file declaring a name is kept, in directory walk order; a search
  // path often holds two unrelated forms of one class name, or a copy of a
  // form file made for linking.
  //
  // The first lookup lists the directories. Headers are read only as a
  // lookup needs them: the files named after a unit in scope first, and every
  // file only when those do not decide. A header once read is kept for the
  // process and read again only when the listing reports a different size or
  // write time for its file.
  TDfmClassIndex = class
  private
    FDirectory: string;
    FExtra: TArray<string>;
    // Every form file in walk order, and the positions in it of the files
    // sharing one base name, which is the name of their unit.
    FListing: TList<TDfmListedFile>;
    FByUnit: TDictionary<string, TArray<Integer>>;
    FListed: Boolean;
    // Filled by Scan from every header: the files declaring each root class,
    // and the files whose root carries each object name, in walk order.
    FScanned: Boolean;
    FFiles: TDictionary<string, TArray<TDfmClassFile>>;
    FInstances: TDictionary<string, TArray<string>>;
    FReported: TDictionary<string, Boolean>;
    FOnClash: TDfmClassClashEvent;
    procedure List;
    procedure Scan;
    function HeaderAt(APosition: Integer): TDfmRootHeader;
    procedure ReportClash(const AName: string; AByInstance: Boolean;
      const AFiles: TArray<string>);
  public
    constructor Create;
    destructor Destroy; override;
    // Sets the directory to index and discards an index already built.
    procedure SearchIn(const ADirectory: string); overload;
    // Sets the directory to index plus extra directories walked after it, so
    // a class declared in both is taken from ADirectory unless a unit in
    // scope selects the other file. A directory that does not exist is
    // skipped, and one listed more than once, or equal to ADirectory, is kept
    // once, where it first appears.
    procedure SearchIn(const ADirectory: string;
      const AExtraDirectories: TArray<string>); overload;
    // Indexed file whose root declares AClassName with a keyword in AKinds;
    // FileName is empty when there is none. Among several, the file named
    // after the earliest unit in AUnitNames is taken, else the first in walk
    // order, which OnClash reports.
    function FileFor(const AClassName: string;
      const AKinds: array of TDfmRootKind;
      const AUnitNames: array of string): TDfmClassFile;
    // Path of the indexed file whose root object name is AInstanceName, or an
    // empty string, chosen among several as FileFor chooses. Roots declared
    // "inline" are not indexed by object name.
    function FileForInstance(const AInstanceName: string;
      const AUnitNames: array of string): string;
    // Every file AUnitName.pas in Directory and the extra directories, in
    // walk order. Needs no index.
    function UnitFiles(const AUnitName: string): TArray<string>;
    // Directory set by SearchIn.
    property Directory: string read FDirectory;
    // Extra directories set by SearchIn, walked after Directory.
    property ExtraDirectories: TArray<string> read FExtra;
    // Called by a lookup that took the first of several files because no
    // unit in scope named one of them; once per name until the next SearchIn.
    property OnClash: TDfmClassClashEvent read FOnClash write FOnClash;
  end;

// Reads the root declaration at the current position of ABinaryDfm, which
// must be on the TPF0 signature (see SeekDfmSignature); raises
// ERootHeaderError when it is not. The position is restored when the header
// is read; a raise leaves it past the bytes already consumed.
function ReadDfmRootHeader(ABinaryDfm: TStream): TDfmRootHeader;

// Leaves ABinaryDfm positioned on its TPF0 signature: unchanged for a bare
// binary form, past the resource header for a wrapped .dfm. Raises
// EInvalidImage when the stream is neither.
procedure SeekDfmSignature(ABinaryDfm: TStream);

// Root declaration of the form file AFileName, binary or text. ClassName is
// empty when the file is missing, unreadable, or not a form file. Reads at
// most the first 1024 bytes of the file.
function DfmFileRootHeader(const AFileName: string): TDfmRootHeader;

// Ancestor class named in the declaration of ARootClassName in the .pas file
// beside ADfmFileName; empty when that file is missing or declares no such
// class. A unit-qualified ancestor is reduced to the class name.
function CompanionAncestorClass(const ADfmFileName, ARootClassName: string): string;

// Reads the declaration of AClassName out of the Pascal unit AUnitFile,
// passing over comments, compiler directives and string literals. False when
// the file is missing or unreadable or declares no such class, with
// ADeclaration left empty.
function ReadUnitDeclaration(const AUnitFile, AClassName: string;
  out ADeclaration: TUnitDeclaration): Boolean;

// Every unit listed in the uses clauses of the Pascal unit AUnitFile,
// interface and implementation, the one listed last first; empty when the
// file is missing or unreadable.
function ReadUsedUnits(const AUnitFile: string): TArray<string>;

// True when AClassName is one of the base classes that fix a root kind
// (TForm, TCustomForm, TFrame, TCustomFrame, TDataModule), matched
// case-insensitively. AKind is that kind, drForm when the result is False.
function BaseClassKind(const AClassName: string; out AKind: TDesignRootClass): Boolean;

// Lower-case name of AKind: 'form', 'frame' or 'datamodule'. The spelling is
// a protocol value: it is sent in the opened event and written to the
// recovery note, which TryRootKind reads back.
function RootKindName(AKind: TDesignRootClass): string;

// Parses a name written by RootKindName, case-insensitively. False for an
// unknown name, with AKind set to drForm.
function TryRootKind(const AName: string; out AKind: TDesignRootClass): Boolean;

// Classifies the root of ADfmFileName; ARootClassName is the class looked up
// in the companion .pas unit. ABinaryDfm must hold the whole binary form
// starting at position 0; its position is restored before returning.
function ClassifyDesignRoot(const ADfmFileName, ARootClassName: string;
  ABinaryDfm: TStream): TRootKind;

// ClassifyDesignRoot over the form file ADfmFileName itself, text or binary.
// A file that cannot be read as a form is an assumed form.
function ClassifyDesignRootFile(const ADfmFileName, ARootClassName: string): TRootKind;

// One line naming the kind and the evidence for it, e.g. "frame (declared in
// frame_basic.pas)".
function DescribeRootKind(const ARootKind: TRootKind): string;

implementation

uses
  System.Math,
  System.StrUtils,
  System.IOUtils,
  System.Generics.Defaults,
  System.RegularExpressions;

type
  // A base class and the root kind fixed by it.
  TAncestorEntry = record
    Name: string;
    Kind: TDesignRootClass;
  end;

const
  // Kind names, base classes and marker properties read by the classification.
  RootKindNames: array [TDesignRootClass] of string = (
    'form', 'frame', 'datamodule');

  // An ancestor outside this list is a user class, which leaves the kind to
  // the marker properties below.
  KnownAncestors: array [0 .. 4] of TAncestorEntry = (
    (Name: 'TForm'; Kind: drForm),
    (Name: 'TCustomForm'; Kind: drForm),
    (Name: 'TFrame'; Kind: drFrame),
    (Name: 'TCustomFrame'; Kind: drFrame),
    (Name: 'TDataModule'; Kind: drDataModule));

  FrameMarker = 'TabOrder';
  FormMarkers: array [0 .. 2] of string = ('ClientWidth', 'ClientHeight', 'Caption');
  // Not exclusive to a data module; they identify one only when neither
  // FrameMarker nor a FormMarker is present.
  DataModuleMarkers: array [0 .. 1] of string = ('Width', 'Height');

const
  // Filer stream layout.
  FilerSignature: array [0 .. 3] of AnsiChar = 'TPF0';
  // First byte of the resource header wrapping a binary .dfm.
  ResourceMarker = $FF;
  // A byte in $F0..$FF before the root class name is a filer flags prefix;
  // any lower value is already the class-name length.
  FlagsPrefix = $F0;
  InheritedFlag = 1;
  ChildPosFlag = 2;
  InlineFlag = 4;

  // Bytes read from the head of a file; a binary root declaration is at most
  // 517 bytes.
  HeaderProbeSize = 1024;

function RootKindName(AKind: TDesignRootClass): string;
begin
  Result := RootKindNames[AKind];
end;

function TryRootKind(const AName: string; out AKind: TDesignRootClass): Boolean;
var
  Kind: TDesignRootClass;
begin
  AKind := drForm;
  for Kind := Low(TDesignRootClass) to High(TDesignRootClass) do
    if SameText(AName, RootKindNames[Kind]) then
    begin
      AKind := Kind;
      Exit(True);
    end;
  Result := False;
end;

function ReadDfmRootHeader(ABinaryDfm: TStream): TDfmRootHeader;

  function ReadShortStr: string;
  var
    Len: Byte;
    Buf: TBytes;
  begin
    ABinaryDfm.ReadBuffer(Len, SizeOf(Len));
    SetLength(Buf, Len);
    if Len > 0 then
      ABinaryDfm.ReadBuffer(Buf[0], Len);
    Result := TEncoding.UTF8.GetString(Buf);
  end;

var
  Signature: array [0 .. 3] of AnsiChar;
  Prefix: Byte;
  Saved: Int64;
begin
  Result.Kind := rkObject;
  Result.ClassName := '';
  Result.ObjectName := '';
  Saved := ABinaryDfm.Position;
  ABinaryDfm.ReadBuffer(Signature, SizeOf(Signature));
  if not CompareMem(@Signature, @FilerSignature, SizeOf(Signature)) then
    raise ERootHeaderError.Create('The stream is missing the TPF0 signature.');
  ABinaryDfm.ReadBuffer(Prefix, SizeOf(Prefix));
  if (Prefix and FlagsPrefix) = FlagsPrefix then
  begin
    if (Prefix and InheritedFlag) <> 0 then
      Result.Kind := rkInherited
    else if (Prefix and InlineFlag) <> 0 then
      Result.Kind := rkInline;
    if (Prefix and ChildPosFlag) <> 0 then
    begin
      // A typed sibling-position value follows before the names; roots do not
      // carry one, so the names are left unread rather than decoded here.
      ABinaryDfm.Position := Saved;
      Exit;
    end;
  end
  else
    ABinaryDfm.Position := ABinaryDfm.Position - 1;
  Result.ClassName := ReadShortStr;
  Result.ObjectName := ReadShortStr;
  ABinaryDfm.Position := Saved;
end;

procedure SeekDfmSignature(ABinaryDfm: TStream);
var
  Saved: Int64;
  Signature: array [0 .. 3] of AnsiChar;
  Count: Integer;
begin
  Saved := ABinaryDfm.Position;
  Count := ABinaryDfm.Read(Signature, SizeOf(Signature));
  ABinaryDfm.Position := Saved;
  if (Count = SizeOf(Signature)) and
     CompareMem(@Signature, @FilerSignature, SizeOf(Signature)) then
    Exit;
  ABinaryDfm.ReadResHeader;
end;

function TextRootHeader(const AProbe: string): TDfmRootHeader;
var
  Line, Keyword, Rest: string;
  Split, Stop: Integer;
begin
  Result.Kind := rkObject;
  Result.ClassName := '';
  Result.ObjectName := '';
  Line := Trim(Copy(AProbe, 1, Pos(#10, AProbe + #10) - 1));
  Split := Pos(' ', Line);
  if Split = 0 then
    Exit;
  Keyword := Copy(Line, 1, Split - 1);
  if SameText(Keyword, 'inherited') then
    Result.Kind := rkInherited
  else if SameText(Keyword, 'inline') then
    Result.Kind := rkInline;
  Rest := Trim(Copy(Line, Split + 1, Length(Line)));
  Split := Pos(':', Rest);
  if Split > 0 then
  begin
    Result.ObjectName := Trim(Copy(Rest, 1, Split - 1));
    Rest := Trim(Copy(Rest, Split + 1, Length(Rest)));
  end;
  Stop := 1;
  while (Stop <= Length(Rest)) and
    CharInSet(Rest[Stop], ['A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '.']) do
    Inc(Stop);
  Result.ClassName := Copy(Rest, 1, Stop - 1);
end;

function ProbeText(const ABytes: TBytes): string;
var
  Start: Integer;
begin
  Start := 0;
  // A UTF-8 BOM would otherwise be read as part of the first keyword.
  if (Length(ABytes) >= 3) and (ABytes[0] = $EF) and (ABytes[1] = $BB) and
     (ABytes[2] = $BF) then
    Start := 3;
  // Only ASCII names are scanned from the result, and a single-byte decode
  // never fails on arbitrary bytes.
  Result := TEncoding.ANSI.GetString(ABytes, Start, Length(ABytes) - Start);
end;

function DfmFileRootHeader(const AFileName: string): TDfmRootHeader;
var
  Input: TFileStream;
  Probe: TMemoryStream;
  Bytes: TBytes;
begin
  Result.Kind := rkObject;
  Result.ClassName := '';
  Result.ObjectName := '';
  // A missing file is not checked for first: the open fails the same way,
  // and a full scan reads thousands of these.
  try
    Input := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
    try
      Probe := TMemoryStream.Create;
      try
        Probe.CopyFrom(Input, Min(Input.Size, HeaderProbeSize));
        Probe.Position := 0;
        if Probe.Size >= SizeOf(FilerSignature) then
        begin
          SetLength(Bytes, Probe.Size);
          Move(Probe.Memory^, Bytes[0], Probe.Size);
          if (Bytes[0] = ResourceMarker) or
             CompareMem(@Bytes[0], @FilerSignature, SizeOf(FilerSignature)) then
          begin
            SeekDfmSignature(Probe);
            Exit(ReadDfmRootHeader(Probe));
          end;
          Result := TextRootHeader(ProbeText(Bytes));
        end;
      finally
        Probe.Free;
      end;
    finally
      Input.Free;
    end;
  except
    Result.ClassName := '';
  end;
end;

function DescribeRootKind(const ARootKind: TRootKind): string;
begin
  case ARootKind.Source of
    rksCompanionUnit:
      Result := Format('%s (declared in %s)',
        [RootKindName(ARootKind.Kind), ARootKind.Detail]);
    rksPropertySniff:
      Result := Format('%s (%s)',
        [RootKindName(ARootKind.Kind), ARootKind.Detail]);
  else
    Result := Format('%s (assumed - %s)',
      [RootKindName(ARootKind.Kind), ARootKind.Detail]);
  end;
end;

function RootPropertyNames(ABinaryDfm: TStream): TStringList;
const
  NestedStarters: array [0 .. 2] of string = ('object', 'inline', 'inherited');
var
  Saved: Int64;
  Text: TMemoryStream;
  Lines: TStringList;
  I, J, Split: Integer;
  Line, Name: string;
  Nested: Boolean;
begin
  Result := TStringList.Create;
  try
    Result.CaseSensitive := False;
    Saved := ABinaryDfm.Position;
    Text := TMemoryStream.Create;
    try
      ABinaryDfm.Position := 0;
      ObjectBinaryToText(ABinaryDfm, Text);
      ABinaryDfm.Position := Saved;
      Text.Position := 0;
      Lines := TStringList.Create;
      try
        // Property names are ASCII; a single-byte decode of arbitrary value
        // bytes never fails or substitutes characters.
        Lines.LoadFromStream(Text, TEncoding.ANSI);
        for I := 1 to Lines.Count - 1 do
        begin
          Line := Trim(Lines[I]);
          if SameText(Line, 'end') then
            Break;
          Nested := False;
          for J := Low(NestedStarters) to High(NestedStarters) do
            if StartsText(NestedStarters[J] + ' ', Line) then
              Nested := True;
          if Nested then
            Break;
          Split := Pos('=', Line);
          if Split <= 1 then
            Continue;
          Name := Trim(Copy(Line, 1, Split - 1));
          // Continuation lines of a long string can carry their own "=", so
          // only a plain identifier is accepted as a name.
          if IsValidIdent(Name, True) then
            Result.Add(Name);
        end;
      finally
        Lines.Free;
      end;
    finally
      Text.Free;
    end;
  except
    Result.Free;
    raise;
  end;
end;

// ASource with every comment, compiler directive and string literal replaced
// by spaces and the line breaks kept, so every pattern match in the result is
// code.
function CodeOnly(const ASource: string): string;
var
  Code: string;
  Len: Integer;

  procedure Blank(AFrom, ATo: Integer);
  var
    J: Integer;
  begin
    for J := AFrom to ATo do
      if not CharInSet(Code[J], [#10, #13]) then
        Code[J] := ' ';
  end;

var
  I, Stop: Integer;
begin
  Code := ASource;
  Len := Length(Code);
  I := 1;
  while I <= Len do
  begin
    Stop := 0;
    if Code[I] = '{' then
    begin
      Stop := PosEx('}', Code, I + 1);
      if Stop = 0 then
        Stop := Len;
    end
    else if (Code[I] = '(') and (I < Len) and (Code[I + 1] = '*') then
    begin
      Stop := PosEx('*)', Code, I + 2);
      if Stop = 0 then
        Stop := Len
      else
        Inc(Stop);
    end
    else if (Code[I] = '/') and (I < Len) and (Code[I + 1] = '/') then
    begin
      Stop := I + 1;
      while (Stop < Len) and not CharInSet(Code[Stop + 1], [#10, #13]) do
        Inc(Stop);
    end
    else if Code[I] = '''' then
    begin
      // A doubled quote inside a literal is a quote character, and a literal
      // ends at the line break, so an unmatched quote cannot blank the rest of
      // the unit.
      Stop := I + 1;
      while (Stop <= Len) and not CharInSet(Code[Stop], [#10, #13]) do
        if Code[Stop] <> '''' then
          Inc(Stop)
        else if (Stop < Len) and (Code[Stop + 1] = '''') then
          Inc(Stop, 2)
        else
          Break;
      if Stop > Len then
        Stop := Len;
    end;
    if Stop > 0 then
    begin
      Blank(I, Stop);
      I := Stop + 1;
    end
    else
      Inc(I);
  end;
  Result := Code;
end;

// Unit names listed in one uses clause, without any "in" path.
function UnitNamesIn(const AClause: string): TArray<string>;
var
  Item: string;
  Name: TMatch;
begin
  Result := nil;
  for Item in AClause.Split([',']) do
  begin
    Name := TRegEx.Match(Item, '^\s*([\w.]+)');
    if Name.Success then
      Result := Result + [Name.Groups[1].Value];
  end;
end;

function Reversed(const AItems: TArray<string>): TArray<string>;
var
  I: Integer;
begin
  SetLength(Result, Length(AItems));
  for I := 0 to High(AItems) do
    Result[High(AItems) - I] := AItems[I];
end;

// Code of the Pascal unit AUnitFile as returned by CodeOnly; False when the
// file is missing or unreadable.
function ReadCode(const AUnitFile: string; out ACode: string): Boolean;
begin
  ACode := '';
  if not FileExists(AUnitFile) then
    Exit(False);
  try
    ACode := CodeOnly(TFile.ReadAllText(AUnitFile));
  except
    Exit(False);
  end;
  Result := True;
end;

// Units listed in the uses clauses of ACode, in source order, split at the
// implementation keyword; AImplementationAt receives its position, MaxInt
// when there is none. ACode must be a result of CodeOnly.
procedure ReadUsesClauses(const ACode: string; out AImplementationAt: Integer;
  out AInterfaceUnits, AImplementationUnits: TArray<string>);
var
  Section, Clause: TMatch;
begin
  Section := TRegEx.Match(ACode, '\bimplementation\b', [roIgnoreCase]);
  if Section.Success then
    AImplementationAt := Section.Index
  else
    AImplementationAt := MaxInt;
  AInterfaceUnits := nil;
  AImplementationUnits := nil;
  for Clause in TRegEx.Matches(ACode, '\buses\b([^;]*);', [roIgnoreCase]) do
    if Clause.Index < AImplementationAt then
      AInterfaceUnits := AInterfaceUnits + UnitNamesIn(Clause.Groups[1].Value)
    else
      AImplementationUnits := AImplementationUnits +
        UnitNamesIn(Clause.Groups[1].Value);
end;

function ReadUsedUnits(const AUnitFile: string): TArray<string>;
var
  Code: string;
  ImplementationAt: Integer;
  InterfaceUnits, ImplementationUnits: TArray<string>;
begin
  Result := nil;
  if not ReadCode(AUnitFile, Code) then
    Exit;
  ReadUsesClauses(Code, ImplementationAt, InterfaceUnits, ImplementationUnits);
  Result := Reversed(InterfaceUnits + ImplementationUnits);
end;

function ReadUnitDeclaration(const AUnitFile, AClassName: string;
  out ADeclaration: TUnitDeclaration): Boolean;
var
  Code: string;
  Declaration: TMatch;
  ImplementationAt: Integer;
  InterfaceUnits, ImplementationUnits: TArray<string>;
begin
  ADeclaration.FileName := '';
  ADeclaration.AncestorClass := '';
  ADeclaration.UsedUnits := nil;
  Result := False;
  if (AClassName = '') or not ReadCode(AUnitFile, Code) then
    Exit;
  Declaration := TRegEx.Match(Code,
    '\b' + TRegEx.Escape(AClassName) + '\s*=\s*class\s*\(\s*(?:\w+\s*\.\s*)*(\w+)',
    [roIgnoreCase]);
  if not Declaration.Success then
    Exit;
  ReadUsesClauses(Code, ImplementationAt, InterfaceUnits, ImplementationUnits);
  ADeclaration.FileName := AUnitFile;
  ADeclaration.AncestorClass := Declaration.Groups[1].Value;
  if Declaration.Index < ImplementationAt then
    ADeclaration.UsedUnits := Reversed(InterfaceUnits)
  else
    ADeclaration.UsedUnits := Reversed(InterfaceUnits + ImplementationUnits);
  Result := True;
end;

function CompanionAncestorClass(const ADfmFileName, ARootClassName: string): string;
var
  Declaration: TUnitDeclaration;
begin
  if ReadUnitDeclaration(ChangeFileExt(ADfmFileName, '.pas'), ARootClassName,
    Declaration) then
    Result := Declaration.AncestorClass
  else
    Result := '';
end;

function BaseClassKind(const AClassName: string; out AKind: TDesignRootClass): Boolean;
var
  I: Integer;
begin
  AKind := drForm;
  for I := Low(KnownAncestors) to High(KnownAncestors) do
    if SameText(AClassName, KnownAncestors[I].Name) then
    begin
      AKind := KnownAncestors[I].Kind;
      Exit(True);
    end;
  Result := False;
end;

function CompanionUnitKind(const ADfmFileName, ARootClassName: string;
  out AKind: TDesignRootClass; out ADetail: string): Boolean;
begin
  ADetail := '';
  Result := BaseClassKind(
    CompanionAncestorClass(ADfmFileName, ARootClassName), AKind);
  if Result then
    ADetail := ExtractFileName(ChangeFileExt(ADfmFileName, '.pas'));
end;

function SniffedKind(Names: TStringList; out AKind: TDesignRootClass;
  out ADetail: string): Boolean;

  function Has(const AName: string): Boolean;
  begin
    Result := Names.IndexOf(AName) >= 0;
  end;

  function HasAll(const ANames: array of string): Boolean;
  var
    I: Integer;
  begin
    Result := True;
    for I := Low(ANames) to High(ANames) do
      if not Has(ANames[I]) then
        Exit(False);
  end;

  function HasAny(const ANames: array of string): Boolean;
  var
    I: Integer;
  begin
    Result := False;
    for I := Low(ANames) to High(ANames) do
      if Has(ANames[I]) then
        Exit(True);
  end;

begin
  AKind := drForm;
  ADetail := '';
  if Has(FrameMarker) then
  begin
    AKind := drFrame;
    ADetail := FrameMarker + ' in the root properties';
    Exit(True);
  end;
  if not HasAny(FormMarkers) and HasAll(DataModuleMarkers) then
  begin
    AKind := drDataModule;
    ADetail := 'a sized root without a client area';
    Exit(True);
  end;
  if HasAny(FormMarkers) then
  begin
    ADetail := 'a client area in the root properties';
    Exit(True);
  end;
  Result := False;
end;

{ TDfmClassIndex }

type
  // A header read earlier, with the file size and write time at that read.
  TCachedHeader = record
    Size: Int64;
    WriteTime: TDateTime;
    Header: TDfmRootHeader;
  end;

var
  // Every header read by any index in this process, keyed by full path and
  // guarded by HeaderLock.
  HeaderLock: TObject;
  CachedHeaders: TDictionary<string, TCachedHeader>;

// Root declaration of AFile; read from disk only when no header is cached for
// the size and write time reported by the listing.
function CachedRootHeader(const AFile: TDfmListedFile): TDfmRootHeader;
var
  Cached: TCachedHeader;
begin
  TMonitor.Enter(HeaderLock);
  try
    if CachedHeaders.TryGetValue(AFile.FileName, Cached) and
       (Cached.Size = AFile.Size) and (Cached.WriteTime = AFile.WriteTime) then
      Exit(Cached.Header);
  finally
    TMonitor.Exit(HeaderLock);
  end;
  Result := DfmFileRootHeader(AFile.FileName);
  Cached.Size := AFile.Size;
  Cached.WriteTime := AFile.WriteTime;
  Cached.Header := Result;
  TMonitor.Enter(HeaderLock);
  try
    CachedHeaders.AddOrSetValue(AFile.FileName, Cached);
  finally
    TMonitor.Exit(HeaderLock);
  end;
end;

function KindIn(AKind: TDfmRootKind; const AKinds: array of TDfmRootKind): Boolean;
var
  Kind: TDfmRootKind;
begin
  for Kind in AKinds do
    if Kind = AKind then
      Exit(True);
  Result := False;
end;

// Duplicate-detection key of a directory: expanded and without a trailing
// delimiter. Callers compare keys case-insensitively.
function DirectoryKey(const ADirectory: string): string;
begin
  Result := ExcludeTrailingPathDelimiter(ExpandFileName(ADirectory));
end;

constructor TDfmClassIndex.Create;
begin
  inherited Create;
  FListing := TList<TDfmListedFile>.Create;
  FByUnit := TDictionary<string, TArray<Integer>>.Create(TIStringComparer.Ordinal);
  FFiles := TDictionary<string, TArray<TDfmClassFile>>.Create(
    TIStringComparer.Ordinal);
  FInstances := TDictionary<string, TArray<string>>.Create(
    TIStringComparer.Ordinal);
  FReported := TDictionary<string, Boolean>.Create(TIStringComparer.Ordinal);
end;

destructor TDfmClassIndex.Destroy;
begin
  FReported.Free;
  FInstances.Free;
  FFiles.Free;
  FByUnit.Free;
  FListing.Free;
  inherited Destroy;
end;

procedure TDfmClassIndex.SearchIn(const ADirectory: string);
begin
  SearchIn(ADirectory, nil);
end;

procedure TDfmClassIndex.SearchIn(const ADirectory: string;
  const AExtraDirectories: TArray<string>);
var
  Seen: TDictionary<string, Boolean>;
  Directory, Key: string;
begin
  FDirectory := ADirectory;
  FExtra := nil;
  Seen := TDictionary<string, Boolean>.Create(TIStringComparer.Ordinal);
  try
    if ADirectory <> '' then
      Seen.Add(DirectoryKey(ADirectory), True);
    for Directory in AExtraDirectories do
    begin
      if Directory = '' then
        Continue;
      Key := DirectoryKey(Directory);
      if Seen.ContainsKey(Key) then
        Continue;
      Seen.Add(Key, True);
      FExtra := FExtra + [Directory];
    end;
  finally
    Seen.Free;
  end;
  FListed := False;
  FScanned := False;
  FListing.Clear;
  FByUnit.Clear;
  FFiles.Clear;
  FInstances.Clear;
  FReported.Clear;
end;

procedure TDfmClassIndex.List;
var
  Directories: TArray<string>;
  Directory, Folder, BaseName: string;
  Found: TSearchRec;
  Listed: TDfmListedFile;
  Positions: TArray<Integer>;
begin
  FListed := True;
  Directories := [FDirectory] + FExtra;
  for Directory in Directories do
  begin
    if Directory = '' then
      Continue;
    Folder := IncludeTrailingPathDelimiter(Directory);
    if FindFirst(Folder + '*.dfm', faAnyFile, Found) <> 0 then
      Continue;
    try
      repeat
        // The pattern also matches a longer extension through a file's short
        // name, such as a backup named .dfm52.
        if (Found.Attr and faDirectory <> 0) or
           not SameText(ExtractFileExt(Found.Name), '.dfm') then
          Continue;
        Listed.FileName := Folder + Found.Name;
        Listed.Size := Found.Size;
        Listed.WriteTime := Found.TimeStamp;
        BaseName := ChangeFileExt(Found.Name, '');
        if not FByUnit.TryGetValue(BaseName, Positions) then
          Positions := nil;
        FByUnit.AddOrSetValue(BaseName, Positions + [FListing.Count]);
        FListing.Add(Listed);
      until FindNext(Found) <> 0;
    finally
      FindClose(Found);
    end;
  end;
end;

function TDfmClassIndex.HeaderAt(APosition: Integer): TDfmRootHeader;
begin
  Result := CachedRootHeader(FListing[APosition]);
end;

procedure TDfmClassIndex.Scan;
var
  Position: Integer;
  Header: TDfmRootHeader;
  Entry: TDfmClassFile;
  Entries: TArray<TDfmClassFile>;
  Holders: TArray<string>;
begin
  if not FListed then
    List;
  FScanned := True;
  for Position := 0 to FListing.Count - 1 do
  begin
    Header := HeaderAt(Position);
    if Header.ClassName = '' then
      Continue;
    if (Header.ObjectName <> '') and (Header.Kind <> rkInline) then
    begin
      if not FInstances.TryGetValue(Header.ObjectName, Holders) then
        Holders := nil;
      FInstances.AddOrSetValue(Header.ObjectName,
        Holders + [FListing[Position].FileName]);
    end;
    if not FFiles.TryGetValue(Header.ClassName, Entries) then
      Entries := nil;
    Entry.FileName := FListing[Position].FileName;
    Entry.Kind := Header.Kind;
    FFiles.AddOrSetValue(Header.ClassName, Entries + [Entry]);
  end;
end;

procedure TDfmClassIndex.ReportClash(const AName: string; AByInstance: Boolean;
  const AFiles: TArray<string>);
var
  Key: string;
begin
  if not Assigned(FOnClash) then
    Exit;
  Key := IfThen(AByInstance, 'root ', 'class ') + AName;
  if FReported.ContainsKey(Key) then
    Exit;
  FReported.Add(Key, True);
  FOnClash(AName, AByInstance, AFiles);
end;

function TDfmClassIndex.FileFor(const AClassName: string;
  const AKinds: array of TDfmRootKind;
  const AUnitNames: array of string): TDfmClassFile;
var
  UnitHint: string;
  Positions: TArray<Integer>;
  Position: Integer;
  Header: TDfmRootHeader;
  Entries: TArray<TDfmClassFile>;
  Entry: TDfmClassFile;
  Candidates: TArray<string>;
begin
  Result.FileName := '';
  Result.Kind := rkObject;
  if AClassName = '' then
    Exit;
  if not FListed then
    List;
  // A form file carries the name of its unit, so the files named after a
  // unit in scope are read first, and they usually decide without the rest.
  for UnitHint in AUnitNames do
    if FByUnit.TryGetValue(UnitHint, Positions) then
      for Position in Positions do
      begin
        Header := HeaderAt(Position);
        if SameText(Header.ClassName, AClassName) and
           KindIn(Header.Kind, AKinds) then
        begin
          Result.FileName := FListing[Position].FileName;
          Result.Kind := Header.Kind;
          Exit;
        end;
      end;
  if not FScanned then
    Scan;
  if not FFiles.TryGetValue(AClassName, Entries) then
    Exit;
  Candidates := nil;
  for Entry in Entries do
    if KindIn(Entry.Kind, AKinds) then
    begin
      if Length(Candidates) = 0 then
        Result := Entry;
      Candidates := Candidates + [Entry.FileName];
    end;
  if Length(Candidates) > 1 then
    ReportClash(AClassName, False, Candidates);
end;

function TDfmClassIndex.FileForInstance(const AInstanceName: string;
  const AUnitNames: array of string): string;
var
  UnitHint: string;
  Positions: TArray<Integer>;
  Position: Integer;
  Header: TDfmRootHeader;
  Holders: TArray<string>;
begin
  Result := '';
  if AInstanceName = '' then
    Exit;
  if not FListed then
    List;
  for UnitHint in AUnitNames do
    if FByUnit.TryGetValue(UnitHint, Positions) then
      for Position in Positions do
      begin
        Header := HeaderAt(Position);
        if (Header.Kind <> rkInline) and
           SameText(Header.ObjectName, AInstanceName) then
          Exit(FListing[Position].FileName);
      end;
  if not FScanned then
    Scan;
  if not FInstances.TryGetValue(AInstanceName, Holders) then
    Exit;
  Result := Holders[0];
  if Length(Holders) > 1 then
    ReportClash(AInstanceName, True, Holders);
end;

function TDfmClassIndex.UnitFiles(const AUnitName: string): TArray<string>;
var
  Directories: TArray<string>;
  Directory, Candidate: string;
begin
  Result := nil;
  if AUnitName = '' then
    Exit;
  Directories := [FDirectory] + FExtra;
  for Directory in Directories do
  begin
    if Directory = '' then
      Continue;
    Candidate := IncludeTrailingPathDelimiter(Directory) + AUnitName + '.pas';
    if FileExists(Candidate) then
      Result := Result + [Candidate];
  end;
end;

function ClassifyDesignRoot(const ADfmFileName, ARootClassName: string;
  ABinaryDfm: TStream): TRootKind;
var
  Names: TStringList;
begin
  if CompanionUnitKind(ADfmFileName, ARootClassName, Result.Kind, Result.Detail) then
  begin
    Result.Source := rksCompanionUnit;
    Exit;
  end;
  Names := RootPropertyNames(ABinaryDfm);
  try
    if SniffedKind(Names, Result.Kind, Result.Detail) then
      Result.Source := rksPropertySniff
    else
    begin
      Result.Kind := drForm;
      Result.Source := rksAssumed;
      Result.Detail := 'the root properties do not identify a kind';
    end;
  finally
    Names.Free;
  end;
end;

function ClassifyDesignRootFile(const ADfmFileName, ARootClassName: string): TRootKind;
var
  Input, Binary: TMemoryStream;
begin
  Input := TMemoryStream.Create;
  Binary := TMemoryStream.Create;
  try
    try
      Input.LoadFromFile(ADfmFileName);
      Input.Position := 0;
      case TestStreamFormat(Input) of
        sofText, sofUTF8Text:
          begin
            Input.Position := 0;
            ObjectTextToBinary(Input, Binary);
          end;
        sofBinary:
          begin
            Input.Position := 0;
            SeekDfmSignature(Input);
            Binary.CopyFrom(Input, Input.Size - Input.Position);
          end;
      end;
    except
      // Classifying is a best guess taken before the load; a file that
      // cannot be read fails the load itself with the reason.
      on Exception do
        Binary.Clear;
    end;
    if Binary.Size = 0 then
    begin
      Result.Kind := drForm;
      Result.Source := rksAssumed;
      Result.Detail := 'the file cannot be read as a form';
      Exit;
    end;
    Binary.Position := 0;
    Result := ClassifyDesignRoot(ADfmFileName, ARootClassName, Binary);
  finally
    Binary.Free;
    Input.Free;
  end;
end;

initialization
  HeaderLock := TObject.Create;
  CachedHeaders := TDictionary<string, TCachedHeader>.Create(
    TIStringComparer.Ordinal);

finalization
  CachedHeaders.Free;
  HeaderLock.Free;

end.
