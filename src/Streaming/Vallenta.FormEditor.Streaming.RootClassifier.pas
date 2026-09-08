// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Streaming.RootClassifier;

// Reads the root declaration of a form file - the block keyword, the class
// name and the object name - from a binary TPF0 stream or from the text
// form's first line, and classifies the root as form, frame or data module by
// the ancestor in the companion .pas unit, else by the root's property names.
// Also indexes a directory set's .dfm files by root class and object name.
//
// TDfmClassIndex builds its index inside the first lookup and holds no lock;
// FileFor and FileForInstance are therefore not safe to call concurrently.

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

  // Indexed form file and the keyword its root carries.
  TDfmClassFile = record
    FileName: string;
    Kind: TDfmRootKind;
  end;

  // Reports a root class name that two indexed files declare. AKept is the
  // file the index keeps, ADropped the one ignored.
  TDfmClassClashEvent = procedure(const AClassName, AKept, ADropped: string) of object;

  // Maps root class names and root object names to the .dfm files in the
  // directory set by SearchIn and in the extra directories given with it.
  // The index is built inside the first lookup.
  TDfmClassIndex = class
  private
    FDirectory: string;
    FExtra: TArray<string>;
    FBuilt: Boolean;
    FFiles: TDictionary<string, TDfmClassFile>;
    FInstances: TDictionary<string, string>;
    FOnClash: TDfmClassClashEvent;
    procedure Build;
  public
    constructor Create;
    destructor Destroy; override;
    // Sets the directory to index and discards an index already built.
    procedure SearchIn(const ADirectory: string); overload;
    // Sets the directory to index plus extra directories walked after it, so
    // a class declared in both is taken from ADirectory. A directory that
    // does not exist is skipped.
    procedure SearchIn(const ADirectory: string;
      const AExtraDirectories: TArray<string>); overload;
    // Path of the indexed file whose root declares AClassName, or an empty
    // string when no file declares it or its root keyword is not in AKinds.
    function FileFor(const AClassName: string;
      const AKinds: array of TDfmRootKind): string;
    // Path of the indexed file whose root object name is AInstanceName, or an
    // empty string. Roots declared "inline" are not indexed by object name.
    function FileForInstance(const AInstanceName: string): string;
    // Directory set by SearchIn.
    property Directory: string read FDirectory;
    // Extra directories set by SearchIn, walked after Directory.
    property ExtraDirectories: TArray<string> read FExtra;
    // Called during the build when two files declare the same root class.
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
  TAncestorEntry = record
    Name: string;
    Kind: TDesignRootClass;
  end;

const
  // Kind names, base classes and marker properties the classification reads.
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
  if not FileExists(AFileName) then
    Exit;
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

function CompanionAncestorClass(const ADfmFileName, ARootClassName: string): string;
var
  UnitFile, Source: string;
  Match: TMatch;
begin
  Result := '';
  if ARootClassName = '' then
    Exit;
  UnitFile := ChangeFileExt(ADfmFileName, '.pas');
  if not FileExists(UnitFile) then
    Exit;
  try
    Source := TFile.ReadAllText(UnitFile);
  except
    Exit;
  end;
  Match := TRegEx.Match(Source,
    '\b' + TRegEx.Escape(ARootClassName) + '\s*=\s*class\s*\(\s*(?:\w+\s*\.\s*)*(\w+)',
    [roIgnoreCase]);
  if Match.Success then
    Result := Match.Groups[1].Value;
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

function SameDirectory(const A, B: string): Boolean;
begin
  Result := SameText(
    ExcludeTrailingPathDelimiter(ExpandFileName(A)),
    ExcludeTrailingPathDelimiter(ExpandFileName(B)));
end;

constructor TDfmClassIndex.Create;
begin
  inherited Create;
  FFiles := TDictionary<string, TDfmClassFile>.Create(TIStringComparer.Ordinal);
  FInstances := TDictionary<string, string>.Create(TIStringComparer.Ordinal);
end;

destructor TDfmClassIndex.Destroy;
begin
  FInstances.Free;
  FFiles.Free;
  inherited Destroy;
end;

procedure TDfmClassIndex.SearchIn(const ADirectory: string);
begin
  SearchIn(ADirectory, nil);
end;

procedure TDfmClassIndex.SearchIn(const ADirectory: string;
  const AExtraDirectories: TArray<string>);
begin
  FDirectory := ADirectory;
  FExtra := Copy(AExtraDirectories);
  FBuilt := False;
  FFiles.Clear;
  FInstances.Clear;
end;

procedure TDfmClassIndex.Build;
var
  Directories: TArray<string>;
  Directory, Done, FileName: string;
  Walked: TArray<string>;
  Header: TDfmRootHeader;
  Entry: TDfmClassFile;
  Skip: Boolean;
begin
  FBuilt := True;
  Directories := [FDirectory] + FExtra;
  Walked := nil;
  for Directory in Directories do
  begin
    if (Directory = '') or not TDirectory.Exists(Directory) then
      Continue;
    Skip := False;
    for Done in Walked do
      if SameDirectory(Done, Directory) then
      begin
        Skip := True;
        Break;
      end;
    if Skip then
      Continue;
    Walked := Walked + [Directory];
    for FileName in TDirectory.GetFiles(Directory, '*.dfm') do
    begin
      Header := DfmFileRootHeader(FileName);
      if Header.ClassName = '' then
        Continue;
      if (Header.ObjectName <> '') and (Header.Kind <> rkInline) and
         not FInstances.ContainsKey(Header.ObjectName) then
        FInstances.Add(Header.ObjectName, FileName);
      if FFiles.TryGetValue(Header.ClassName, Entry) then
      begin
        if Assigned(FOnClash) then
          FOnClash(Header.ClassName, Entry.FileName, FileName);
        Continue;
      end;
      Entry.FileName := FileName;
      Entry.Kind := Header.Kind;
      FFiles.Add(Header.ClassName, Entry);
    end;
  end;
end;

function TDfmClassIndex.FileFor(const AClassName: string;
  const AKinds: array of TDfmRootKind): string;
var
  Entry: TDfmClassFile;
  Kind: TDfmRootKind;
begin
  Result := '';
  if AClassName = '' then
    Exit;
  if not FBuilt then
    Build;
  if not FFiles.TryGetValue(AClassName, Entry) then
    Exit;
  for Kind in AKinds do
    if Entry.Kind = Kind then
      Exit(Entry.FileName);
end;

function TDfmClassIndex.FileForInstance(const AInstanceName: string): string;
begin
  Result := '';
  if AInstanceName = '' then
    Exit;
  if not FBuilt then
    Build;
  if not FInstances.TryGetValue(AInstanceName, Result) then
    Result := '';
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

end.
