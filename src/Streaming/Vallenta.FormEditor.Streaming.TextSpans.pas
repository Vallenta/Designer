// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Streaming.TextSpans;

// Scanner over the text form of a form file: it records the character range
// of every block and property line without interpreting values, so content
// the designer cannot load is still located and spliced back. The text is
// what DfmStreamToText returns, the one form both the load and the save side
// scan, so a span cut from it fits back in unchanged.
//
// Spans are 1-based and half-open. A TDfmDocument or TDfmFragment frees the
// block tree it parsed. The unit holds no state outside those objects.

interface

uses
  System.Classes,
  System.SysUtils,
  System.Generics.Collections;

type
  // Raised for text or a stream form this unit cannot read, and for a
  // component an entry or an insertion names that the text does not hold.
  EDfmScanError = class(Exception);

  // Half-open character range, 1-based like string indexing.
  TDfmSpan = record
    Start: Integer;
    Stop: Integer;
    // The substring of ADocument the range covers.
    function TextIn(const ADocument: string): string;
  end;

  // One property assignment of a block, name and value.
  TDfmPropertySpan = record
    // Property name, dotted for a sub-property such as Font.Style.
    Name: string;
    // The whole assignment, from its indentation through the line break
    // ending the value; a collection or a "+"-joined string covers several
    // lines.
    Span: TDfmSpan;
  end;

  // One "object"/"inherited"/"inline" block with its property lines and the
  // blocks nested in it.
  TDfmBlock = class
  private
    FKeyword: string;
    FName: string;
    FDeclaredClass: string;
    FSpan: TDfmSpan;
    FClassSpan: TDfmSpan;
    FContentEnd: Integer;
    FParent: TDfmBlock;
    FChildren: TObjectList<TDfmBlock>;
    FProperties: TArray<TDfmPropertySpan>;
    function GetPropertyCount: Integer;
    function GetProperty(AIndex: Integer): TDfmPropertySpan;
  public
    // Adds the new block to AParent's children, which then own it; AParent is
    // nil for a root block.
    constructor Create(AParent: TDfmBlock);
    destructor Destroy; override;
    // Text offset where the child block at AIndex begins; for an index
    // outside the child range, the offset of the block's "end" line.
    function ChildOffset(AIndex: Integer): Integer;
    // Text offset where the property at AIndex begins; for an index outside
    // the property range, the offset of the first nested block, or of the
    // block's "end" line when there is none.
    function PropertyOffset(AIndex: Integer): Integer;
    // Index of the first property at or after AFrom whose full dotted name
    // matches AName, or else the first whose last segment does. Matching is
    // case-insensitive; -1 when neither matches.
    function IndexOfProperty(const AName: string; AFrom: Integer = 0): Integer;
    // Position among the parent's children; -1 for the root.
    function IndexInParent: Integer;
    // "object", "inherited" or "inline".
    property Keyword: string read FKeyword;
    // Component name; empty for a block that names none.
    property Name: string read FName;
    // Class name from the block header.
    property DeclaredClass: string read FDeclaredClass;
    // The whole block, header through "end" line.
    property Span: TDfmSpan read FSpan;
    // Range of the class name alone within the header line, the range
    // RestoreDeclaredClasses overwrites.
    property ClassSpan: TDfmSpan read FClassSpan;
    // Enclosing block; nil for the root.
    property Parent: TDfmBlock read FParent;
    // Nested blocks in file order; owned by this block.
    property Children: TObjectList<TDfmBlock> read FChildren;
    // Number of property lines.
    property PropertyCount: Integer read GetPropertyCount;
    // Property line at AIndex.
    property Properties[AIndex: Integer]: TDfmPropertySpan read GetProperty;
  end;

  // Parsed span tree over one form file text.
  TDfmDocument = class
  private
    FText: string;
    FRoot: TDfmBlock;
  public
    // Parses AText as one root block; anything after that block is ignored.
    // Raises EDfmScanError on text the scanner cannot follow.
    constructor Create(const AText: string);
    destructor Destroy; override;
    // Depth-first search by component name, case-insensitive; nil for an
    // empty AName or when no block carries the name.
    function FindBlock(const AName: string): TDfmBlock;
    // The text the spans index.
    property Text: string read FText;
    // The outermost block.
    property Root: TDfmBlock read FRoot;
  end;

  // Parsed span tree over text holding a sequence of top-level blocks rather
  // than one root object, the form a copied selection takes on the clipboard.
  TDfmFragment = class
  private
    FText: string;
    FBlocks: TObjectList<TDfmBlock>;
    function GetCount: Integer;
    function GetBlock(AIndex: Integer): TDfmBlock;
  public
    // Parses AText as a sequence of top-level blocks. Raises EDfmScanError on
    // text the scanner cannot follow; blank text yields an empty fragment.
    constructor Create(const AText: string);
    destructor Destroy; override;
    // The text the spans index.
    property Text: string read FText;
    // Number of top-level blocks.
    property Count: Integer read GetCount;
    // Top-level block at a 0-based index in text order; owned by the fragment.
    property Blocks[AIndex: Integer]: TDfmBlock read GetBlock; default;
  end;

  // Which of a block's two lists an insertion index counts within.
  TDfmInsertionKind = (dikBlock, dikProperty);

  // A piece of original text to splice back into a written form.
  TDfmInsertion = record
    // Whether Index counts child blocks or property lines.
    Kind: TDfmInsertionKind;
    // Name of the block the text is inserted into.
    Owner: string;
    // Position in the original block, counting the pieces cut out of it.
    Index: Integer;
    // The text, carrying its own indentation and trailing line break.
    Text: string;
  end;

  // The class a component was declared under, for a block written under a
  // stub class name: every frame instance is a TFrame and streams as one.
  TDfmDeclaredClass = record
    ComponentName: string;
    // Class name to write over the stub's.
    DeclaredClass: string;
  end;

// Reads AStream from its start and returns its text form; a binary form is
// converted with ObjectBinaryToText and a UTF-8 BOM is dropped. Raises
// EDfmScanError for a stream that is neither text nor a TPF0 binary form.
function DfmStreamToText(AStream: TStream): string;

// True when the first non-blank word of AText is "object", "inherited" or
// "inline", case-insensitive. Nothing beyond that word is parsed.
function StartsWithBlockKeyword(const AText: string): Boolean;

// Returns AText with the class name in each named block's header replaced by
// the entry's declared class. Raises EDfmScanError when AText holds no
// component of an entry's name.
function RestoreDeclaredClasses(const AText: string;
  const AEntries: TArray<TDfmDeclaredClass>): string;

// Returns AText with every insertion put back at the position its Owner and
// Index name. Raises EDfmScanError when AText holds no component named by an
// insertion's Owner.
function SpliceDfmText(const AText: string; const AInsertions: TArray<TDfmInsertion>): string;

implementation

uses
  System.Generics.Defaults;

const
  BlockKeywords: array [0 .. 2] of string = ('object', 'inherited', 'inline');
  ItemKeyword = 'item';
  EndKeyword = 'end';

function IsBlockKeyword(const AWord: string): Boolean;
var
  Keyword: string;
begin
  for Keyword in BlockKeywords do
    if SameText(AWord, Keyword) then
      Exit(True);
  Result := False;
end;

{ TDfmSpan }

function TDfmSpan.TextIn(const ADocument: string): string;
begin
  Result := Copy(ADocument, Start, Stop - Start);
end;

{ TDfmBlock }

constructor TDfmBlock.Create(AParent: TDfmBlock);
begin
  inherited Create;
  FParent := AParent;
  FChildren := TObjectList<TDfmBlock>.Create(True);
  if FParent <> nil then
    FParent.FChildren.Add(Self);
end;

destructor TDfmBlock.Destroy;
begin
  FChildren.Free;
  inherited Destroy;
end;

function TDfmBlock.GetPropertyCount: Integer;
begin
  Result := Length(FProperties);
end;

function TDfmBlock.GetProperty(AIndex: Integer): TDfmPropertySpan;
begin
  Result := FProperties[AIndex];
end;

function TDfmBlock.ChildOffset(AIndex: Integer): Integer;
begin
  if (AIndex >= 0) and (AIndex < FChildren.Count) then
    Result := FChildren[AIndex].Span.Start
  else
    Result := FContentEnd;
end;

function TDfmBlock.PropertyOffset(AIndex: Integer): Integer;
begin
  if (AIndex >= 0) and (AIndex < Length(FProperties)) then
    Result := FProperties[AIndex].Span.Start
  else if FChildren.Count > 0 then
    Result := FChildren[0].Span.Start
  else
    Result := FContentEnd;
end;

function LastSegment(const AName: string): string;
var
  Dot: Integer;
begin
  Dot := AName.LastDelimiter('.');
  if Dot < 0 then
    Result := AName
  else
    Result := AName.Substring(Dot + 1);
end;

function TDfmBlock.IndexOfProperty(const AName: string; AFrom: Integer): Integer;
var
  I: Integer;
begin
  for I := AFrom to High(FProperties) do
    if SameText(FProperties[I].Name, AName) then
      Exit(I);
  for I := AFrom to High(FProperties) do
    if SameText(LastSegment(FProperties[I].Name), AName) then
      Exit(I);
  Result := -1;
end;

function TDfmBlock.IndexInParent: Integer;
begin
  if FParent = nil then
    Result := -1
  else
    Result := FParent.FChildren.IndexOf(Self);
end;

{ scanning }

type
  // Parses the text form of a .dfm into TDfmBlock trees, one block at a
  // time from the current position.
  TDfmScanner = class
  private
    FText: string;
    FPos: Integer;
    function Current: Char;
    function LineStartAt(APos: Integer): Integer;
    function LineEndAfter(APos: Integer): Integer;
    procedure SkipBlanks;
    procedure SkipSpaces;
    function ReadWord: string;
    procedure SkipStringLiteral;
    procedure SkipBinary;
    procedure SkipBracketed(ACloser: Char);
    procedure SkipCollection;
    procedure SkipValue;
    function ReadQualifiedName(const AFirst: string): string;
    procedure Fail(const AMessage: string);
  public
    constructor Create(const AText: string);
    function AtEnd: Boolean;
    function PeekWord: string;
    function ParseBlock(AParent: TDfmBlock): TDfmBlock;
    procedure SkipToFirstBlock;
    property Position: Integer read FPos;
  end;

constructor TDfmScanner.Create(const AText: string);
begin
  inherited Create;
  FText := AText;
  FPos := 1;
end;

procedure TDfmScanner.Fail(const AMessage: string);
var
  Line, I, Last: Integer;
begin
  Line := 1;
  Last := FPos;
  if Last > Length(FText) then
    Last := Length(FText);
  for I := 1 to Last do
    if FText[I] = #10 then
      Inc(Line);
  raise EDfmScanError.CreateFmt('%s (line %d)', [AMessage, Line]);
end;

function TDfmScanner.AtEnd: Boolean;
begin
  Result := FPos > Length(FText);
end;

function TDfmScanner.Current: Char;
begin
  if AtEnd then
    Result := #0
  else
    Result := FText[FPos];
end;

function TDfmScanner.LineStartAt(APos: Integer): Integer;
begin
  Result := APos;
  while (Result > 1) and (FText[Result - 1] <> #10) do
    Dec(Result);
end;

function TDfmScanner.LineEndAfter(APos: Integer): Integer;
begin
  Result := APos;
  while (Result <= Length(FText)) and (FText[Result] <> #10) do
    Inc(Result);
  if Result <= Length(FText) then
    Inc(Result);
end;

procedure TDfmScanner.SkipBlanks;
begin
  while not AtEnd and CharInSet(FText[FPos], [' ', #9, #13, #10]) do
    Inc(FPos);
end;

procedure TDfmScanner.SkipSpaces;
begin
  while not AtEnd and CharInSet(FText[FPos], [' ', #9]) do
    Inc(FPos);
end;

function TDfmScanner.PeekWord: string;
var
  Saved: Integer;
begin
  Saved := FPos;
  Result := ReadWord;
  FPos := Saved;
end;

function TDfmScanner.ReadWord: string;
var
  Start: Integer;
begin
  SkipBlanks;
  Start := FPos;
  while not AtEnd and
    CharInSet(FText[FPos], ['A' .. 'Z', 'a' .. 'z', '0' .. '9', '_']) do
    Inc(FPos);
  Result := Copy(FText, Start, FPos - Start);
end;

procedure TDfmScanner.SkipStringLiteral;
begin
  Inc(FPos);
  while not AtEnd do
  begin
    if FText[FPos] = '''' then
      if (FPos < Length(FText)) and (FText[FPos + 1] = '''') then
        Inc(FPos, 2)
      else
      begin
        Inc(FPos);
        Exit;
      end
    else
      Inc(FPos);
  end;
  Fail('a string is not closed');
end;

procedure TDfmScanner.SkipBinary;
begin
  while not AtEnd and (FText[FPos] <> '}') do
    Inc(FPos);
  if AtEnd then
    Fail('a binary value is not closed');
  Inc(FPos);
end;

procedure TDfmScanner.SkipBracketed(ACloser: Char);
begin
  Inc(FPos);
  while not AtEnd and (FText[FPos] <> ACloser) do
    if FText[FPos] = '''' then
      SkipStringLiteral
    else
      Inc(FPos);
  if AtEnd then
    Fail(Format('a value is missing its "%s"', [ACloser]));
  Inc(FPos);
end;

procedure TDfmScanner.SkipCollection;
var
  Word: string;
begin
  // Collections nested in item properties are consumed by the recursion
  // through SkipValue, so only this collection's own ">" is seen here.
  Inc(FPos);
  repeat
    SkipBlanks;
    if AtEnd then
      Fail('a collection is not closed');
    if Current = '>' then
    begin
      Inc(FPos);
      Exit;
    end;
    Word := ReadWord;
    if Word = '' then
      Fail('a collection item holds something the scanner cannot follow')
    else if SameText(Word, ItemKeyword) or SameText(Word, EndKeyword) then
      Continue
    else
    begin
      ReadQualifiedName(Word);
      SkipBlanks;
      if Current <> '=' then
        Fail(Format('"%s" in a collection item is not an assignment', [Word]));
      Inc(FPos);
      SkipValue;
    end;
  until False;
end;

function TDfmScanner.ReadQualifiedName(const AFirst: string): string;
begin
  Result := AFirst;
  while not AtEnd and (Current = '.') do
  begin
    Inc(FPos);
    Result := Result + '.' + ReadWord;
  end;
end;

procedure TDfmScanner.SkipValue;
begin
  SkipBlanks;
  if AtEnd then
    Fail('a property has no value');
  case Current of
    '''', '#':
      // The "+" continuation check must not cross a line break, or the
      // property span runs into the next line and takes an "end" with it.
      repeat
        while not AtEnd and CharInSet(Current, ['''', '#']) do
          if Current = '''' then
            SkipStringLiteral
          else
          begin
            Inc(FPos);
            while not AtEnd and CharInSet(FText[FPos],
              ['0' .. '9', '$', 'A' .. 'F', 'a' .. 'f']) do
              Inc(FPos);
          end;
        SkipSpaces;
        if Current <> '+' then
          Break;
        Inc(FPos);
        SkipBlanks;
      until AtEnd;
    '{':
      SkipBinary;
    '<':
      SkipCollection;
    '[':
      SkipBracketed(']');
    '(':
      SkipBracketed(')');
  else
    while not AtEnd and not CharInSet(FText[FPos], [#13, #10]) do
      Inc(FPos);
  end;
end;

procedure TDfmScanner.SkipToFirstBlock;
begin
  SkipBlanks;
end;

function TDfmScanner.ParseBlock(AParent: TDfmBlock): TDfmBlock;
var
  Block: TDfmBlock;
  Word, First: string;
  HeaderStart, ClassStart, PropertyStart: Integer;
  Entry: TDfmPropertySpan;
begin
  SkipBlanks;
  HeaderStart := LineStartAt(FPos);
  Word := ReadWord;
  if not IsBlockKeyword(Word) then
    Fail(Format('expected an object block, found "%s"', [Word]));
  Block := TDfmBlock.Create(AParent);
  Block.FKeyword := Word;
  Block.FSpan.Start := HeaderStart;
  SkipBlanks;
  ClassStart := FPos;
  First := ReadWord;
  SkipBlanks;
  if Current = ':' then
  begin
    Inc(FPos);
    Block.FName := First;
    SkipBlanks;
    ClassStart := FPos;
    Block.FDeclaredClass := ReadWord;
  end
  else
    Block.FDeclaredClass := First;
  Block.FClassSpan.Start := ClassStart;
  Block.FClassSpan.Stop := ClassStart + Length(Block.FDeclaredClass);
  SkipBlanks;
  // An "inherited" or "inline" header may carry a "[index]" suffix giving the
  // component's position among its siblings.
  if Current = '[' then
    SkipBracketed(']');

  repeat
    SkipBlanks;
    if AtEnd then
      Fail(Format('"%s" is not closed', [Block.FName + ': ' + Block.FDeclaredClass]));
    Word := PeekWord;
    if SameText(Word, EndKeyword) then
    begin
      Block.FContentEnd := LineStartAt(FPos);
      ReadWord;
      Block.FSpan.Stop := LineEndAfter(FPos);
      Break;
    end;
    if IsBlockKeyword(Word) then
    begin
      ParseBlock(Block);
      Continue;
    end;
    if Word = '' then
      Fail('expected a property or a nested object');
    PropertyStart := LineStartAt(FPos);
    Entry.Name := ReadQualifiedName(ReadWord);
    SkipBlanks;
    if Current <> '=' then
      Fail(Format('"%s" is not an assignment', [Entry.Name]));
    Inc(FPos);
    SkipValue;
    Entry.Span.Start := PropertyStart;
    Entry.Span.Stop := LineEndAfter(FPos);
    Block.FProperties := Block.FProperties + [Entry];
    FPos := Entry.Span.Stop;
  until False;
  Result := Block;
end;

{ TDfmDocument }

constructor TDfmDocument.Create(const AText: string);
var
  Scanner: TDfmScanner;
begin
  inherited Create;
  FText := AText;
  Scanner := TDfmScanner.Create(AText);
  try
    Scanner.SkipToFirstBlock;
    FRoot := Scanner.ParseBlock(nil);
  finally
    Scanner.Free;
  end;
end;

destructor TDfmDocument.Destroy;
begin
  FRoot.Free;
  inherited Destroy;
end;

function FindBlockIn(ABlock: TDfmBlock; const AName: string): TDfmBlock;
var
  Child, Found: TDfmBlock;
begin
  if SameText(ABlock.Name, AName) then
    Exit(ABlock);
  for Child in ABlock.Children do
  begin
    Found := FindBlockIn(Child, AName);
    if Found <> nil then
      Exit(Found);
  end;
  Result := nil;
end;

function TDfmDocument.FindBlock(const AName: string): TDfmBlock;
begin
  if (FRoot = nil) or (AName = '') then
    Exit(nil);
  Result := FindBlockIn(FRoot, AName);
end;

{ TDfmFragment }

constructor TDfmFragment.Create(const AText: string);
var
  Scanner: TDfmScanner;
begin
  inherited Create;
  FText := AText;
  FBlocks := TObjectList<TDfmBlock>.Create(True);
  Scanner := TDfmScanner.Create(AText);
  try
    Scanner.SkipToFirstBlock;
    while not Scanner.AtEnd do
    begin
      FBlocks.Add(Scanner.ParseBlock(nil));
      Scanner.SkipToFirstBlock;
    end;
  finally
    Scanner.Free;
  end;
end;

destructor TDfmFragment.Destroy;
begin
  FBlocks.Free;
  inherited Destroy;
end;

function TDfmFragment.GetCount: Integer;
begin
  Result := FBlocks.Count;
end;

function TDfmFragment.GetBlock(AIndex: Integer): TDfmBlock;
begin
  Result := FBlocks[AIndex];
end;

function StartsWithBlockKeyword(const AText: string): Boolean;
var
  Scanner: TDfmScanner;
begin
  Scanner := TDfmScanner.Create(AText);
  try
    Scanner.SkipToFirstBlock;
    Result := IsBlockKeyword(Scanner.PeekWord);
  finally
    Scanner.Free;
  end;
end;

{ splicing }

function PreambleLength(const ABytes: TBytes): Integer;
var
  Preamble: TBytes;
  I: Integer;
begin
  Preamble := TEncoding.UTF8.GetPreamble;
  if Length(ABytes) < Length(Preamble) then
    Exit(0);
  for I := 0 to High(Preamble) do
    if ABytes[I] <> Preamble[I] then
      Exit(0);
  Result := Length(Preamble);
end;

function DfmStreamToText(AStream: TStream): string;
var
  Text: TMemoryStream;
  Bytes: TBytes;
  Start: Integer;
begin
  AStream.Position := 0;
  case TestStreamFormat(AStream) of
    sofText, sofUTF8Text:
      begin
        SetLength(Bytes, AStream.Size);
        AStream.Position := 0;
        if Length(Bytes) > 0 then
          AStream.ReadBuffer(Bytes[0], Length(Bytes));
        // GetString keeps a UTF-8 BOM, which no skip rule consumes: the first
        // word then reads empty and the block header fails to parse.
        Start := PreambleLength(Bytes);
        Exit(TEncoding.UTF8.GetString(Bytes, Start, Length(Bytes) - Start));
      end;
    sofBinary:
      begin
        Text := TMemoryStream.Create;
        try
          AStream.Position := 0;
          ObjectBinaryToText(AStream, Text);
          SetLength(Bytes, Text.Size);
          if Length(Bytes) > 0 then
            Move(Text.Memory^, Bytes[0], Length(Bytes));
          Result := TEncoding.UTF8.GetString(Bytes);
        finally
          Text.Free;
        end;
      end;
  else
    raise EDfmScanError.Create('The stream is neither text nor a TPF0 binary form file.');
  end;
end;

type
  TResolvedClass = record
    Span: TDfmSpan;
    DeclaredClass: string;
  end;

function RestoreDeclaredClasses(const AText: string;
  const AEntries: TArray<TDfmDeclaredClass>): string;
var
  Document: TDfmDocument;
  Resolved: TArray<TResolvedClass>;
  Entry: TResolvedClass;
  Block: TDfmBlock;
  I, Count: Integer;
begin
  Result := AText;
  if Length(AEntries) = 0 then
    Exit;
  Document := TDfmDocument.Create(AText);
  try
    SetLength(Resolved, Length(AEntries));
    Count := 0;
    for I := 0 to High(AEntries) do
    begin
      Block := Document.FindBlock(AEntries[I].ComponentName);
      if Block = nil then
        raise EDfmScanError.CreateFmt(
          'The written form holds no component named "%s", so the class it was ' +
          'declared under has nowhere to go back to.', [AEntries[I].ComponentName]);
      if SameStr(Block.DeclaredClass, AEntries[I].DeclaredClass) then
        Continue;
      Resolved[Count].Span := Block.ClassSpan;
      Resolved[Count].DeclaredClass := AEntries[I].DeclaredClass;
      Inc(Count);
    end;
    SetLength(Resolved, Count);
  finally
    Document.Free;
  end;

  // Replacing from the back keeps every earlier offset valid.
  TArray.Sort<TResolvedClass>(Resolved, TComparer<TResolvedClass>.Construct(
    function(const A, B: TResolvedClass): Integer
    begin
      Result := B.Span.Start - A.Span.Start;
    end));
  for Entry in Resolved do
  begin
    Delete(Result, Entry.Span.Start, Entry.Span.Stop - Entry.Span.Start);
    Insert(Entry.DeclaredClass, Result, Entry.Span.Start);
  end;
end;

type
  TResolvedInsertion = record
    Offset: Integer;
    Kind: TDfmInsertionKind;
    Index: Integer;
    Text: string;
  end;

function PrecedingInsertions(const AInsertions: TArray<TDfmInsertion>;
  AAt: Integer): Integer;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to High(AInsertions) do
    if (I <> AAt) and (AInsertions[I].Kind = AInsertions[AAt].Kind) and
      SameText(AInsertions[I].Owner, AInsertions[AAt].Owner) and
      (AInsertions[I].Index < AInsertions[AAt].Index) then
      Inc(Result);
end;

function SpliceDfmText(const AText: string; const AInsertions: TArray<TDfmInsertion>): string;
var
  Document: TDfmDocument;
  Resolved: TArray<TResolvedInsertion>;
  Insertion: TDfmInsertion;
  Entry: TResolvedInsertion;
  Block: TDfmBlock;
  I, Position: Integer;
begin
  Result := AText;
  if Length(AInsertions) = 0 then
    Exit;
  Document := TDfmDocument.Create(AText);
  try
    SetLength(Resolved, Length(AInsertions));
    for I := 0 to High(AInsertions) do
    begin
      Insertion := AInsertions[I];
      Block := Document.FindBlock(Insertion.Owner);
      if Block = nil then
        raise EDfmScanError.CreateFmt(
          'The preserved text of "%s" has nowhere to go: the written form holds ' +
          'no component of that name.', [Insertion.Owner]);
      // The written text holds none of the insertions, so an original index
      // must be reduced by those of the same kind and owner that precede it.
      Position := Insertion.Index - PrecedingInsertions(AInsertions, I);
      if Insertion.Kind = dikBlock then
        Resolved[I].Offset := Block.ChildOffset(Position)
      else
        Resolved[I].Offset := Block.PropertyOffset(Position);
      Resolved[I].Kind := Insertion.Kind;
      Resolved[I].Index := Insertion.Index;
      Resolved[I].Text := Insertion.Text;
    end;
  finally
    Document.Free;
  end;

  // Inserting back to front keeps earlier offsets valid; at a shared offset
  // the last insertion ends up first, so blocks are inserted ahead of
  // properties and a higher index ahead of a lower one.
  TArray.Sort<TResolvedInsertion>(Resolved, TComparer<TResolvedInsertion>.Construct(
    function(const A, B: TResolvedInsertion): Integer
    begin
      Result := B.Offset - A.Offset;
      if Result = 0 then
        Result := Ord(A.Kind) - Ord(B.Kind);
      if Result = 0 then
        Result := B.Index - A.Index;
    end));
  for Entry in Resolved do
    Insert(Entry.Text, Result, Entry.Offset);
end;

end.
