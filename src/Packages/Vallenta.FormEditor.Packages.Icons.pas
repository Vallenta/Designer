// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Packages.Icons;

// Reads component bitmaps from package files into a process-wide table keyed
// by class name in upper case, and exposes them as an IPaletteIconProvider
// layered over a fallback provider. Each file is mapped with
// LOAD_LIBRARY_AS_DATAFILE, so no package code runs, and every bitmap is
// copied before that mapping is released. Nothing here is synchronized.

interface

uses
  Vallenta.FormEditor.Palette.Model;

// Reads component bitmaps from the package file at APath into the table under
// their class names in upper case; a trailing run of digits is stripped, so
// 'TCHART16' keys as 'TCHART'. Per class the lowest-numbered suffix is kept,
// and an unsuffixed name is preferred over every sized one. Returns the
// number of classes newly added, 0 when the file cannot be opened.
function HarvestIcons(const APath: string): Integer;

// Frees every harvested bitmap and empties the table. Providers created
// before the call stay valid and delegate every class to their fallback.
procedure ReleaseIcons;

// Wraps AFallback in a provider that draws the harvested bitmap of a class,
// stretched to the bounds the caller passes, and delegates every other class
// to AFallback. Returns AFallback itself while the table is empty, so icons
// must be harvested before this call.
function IconProviderOver(
  const AFallback: IPaletteIconProvider): IPaletteIconProvider;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Classes,
  System.Types,
  System.Generics.Collections,
  Vcl.Graphics;

const
  // BITMAPFILEHEADER.bfType, 'BM' in little-endian byte order.
  BitmapSignature = $4D42;
  // Rank of a resource name without a size suffix; a suffixed name ranks by
  // its number. The entry with the lowest rank is kept; an equal rank keeps
  // the one already held.
  PreferredRank = 0;

type
  TIconEntry = record
    Bitmap: TBitmap;
    Rank: Integer;
  end;

  TPackageIconProvider = class(TInterfacedObject, IPaletteIconProvider)
  private
    FFallback: IPaletteIconProvider;
  public
    constructor Create(const AFallback: IPaletteIconProvider);
    function GlyphSize: Integer;
    procedure DrawGlyph(AItem: TPaletteItem; ACanvas: TCanvas;
      const ABounds: TRect);
    procedure DrawClassGlyph(AComponentClass: TComponentClass; ACanvas: TCanvas;
      const ABounds: TRect);
  end;

var
  Icons: TDictionary<string, TIconEntry>;

function EnumBitmapName(AModule: HMODULE; AType, AName: PChar;
  AParam: NativeInt): BOOL; stdcall;
begin
  // AName is an integer resource id, not a string pointer, when its upper half
  // is zero (IS_INTRESOURCE); such an id names no class.
  if (NativeUInt(AName) shr 16) <> 0 then
    TStringList(AParam).Add(AName);
  Result := True;
end;

procedure SplitIconName(const AName: string; out AClassName: string;
  out ARank: Integer);
var
  Stop: Integer;
begin
  Stop := Length(AName);
  while (Stop > 0) and CharInSet(AName[Stop], ['0' .. '9']) do
    Dec(Stop);
  AClassName := UpperCase(Copy(AName, 1, Stop));
  if Stop = Length(AName) then
    ARank := PreferredRank
  else
    ARank := StrToIntDef(Copy(AName, Stop + 1, MaxInt), MaxInt);
end;

function BitmapFromResource(AModule: HMODULE; const AName: string): TBitmap;
var
  Found: HRSRC;
  Resource: HGLOBAL;
  Source: PByte;
  Size, Colors: Cardinal;
  Info: PBitmapInfoHeader;
  FileHeader: TBitmapFileHeader;
  Stream: TMemoryStream;
begin
  Result := nil;
  Found := FindResource(AModule, PChar(AName), RT_BITMAP);
  if Found = 0 then
    Exit;
  Size := SizeofResource(AModule, Found);
  if Size <= SizeOf(TBitmapInfoHeader) then
    Exit;
  Resource := LoadResource(AModule, Found);
  if Resource = 0 then
    Exit;
  Source := LockResource(Resource);
  if Source = nil then
    Exit;

  // An RT_BITMAP resource has no BITMAPFILEHEADER; bfOffBits must span the
  // info header, the BI_BITFIELDS masks and the color table that follow.
  Info := PBitmapInfoHeader(Source);
  Colors := Info.biClrUsed;
  if (Colors = 0) and (Info.biBitCount <= 8) then
    Colors := Cardinal(1) shl Info.biBitCount;
  FileHeader.bfType := BitmapSignature;
  FileHeader.bfSize := SizeOf(FileHeader) + Size;
  FileHeader.bfReserved1 := 0;
  FileHeader.bfReserved2 := 0;
  FileHeader.bfOffBits := SizeOf(FileHeader) + Info.biSize +
    Colors * SizeOf(TRGBQuad);
  if Info.biCompression = BI_BITFIELDS then
    Inc(FileHeader.bfOffBits, 3 * SizeOf(DWORD));

  Stream := TMemoryStream.Create;
  try
    Stream.WriteBuffer(FileHeader, SizeOf(FileHeader));
    Stream.WriteBuffer(Source^, Size);
    Stream.Position := 0;
    Result := TBitmap.Create;
    try
      Result.LoadFromStream(Stream);
      // Component bitmaps mark transparency with the bottom-left pixel, the
      // color TBitmap reads as TransparentColor in its default tmAuto mode.
      Result.Transparent := True;
    except
      FreeAndNil(Result);
    end;
  finally
    Stream.Free;
  end;
end;

function HarvestIcons(const APath: string): Integer;
var
  Module: HMODULE;
  Names: TStringList;
  Name, ClassName: string;
  Rank: Integer;
  Entry, Present: TIconEntry;
  Known: Boolean;
begin
  Result := 0;
  Module := LoadLibraryEx(PChar(APath), 0, LOAD_LIBRARY_AS_DATAFILE);
  if Module = 0 then
    Exit;
  try
    Names := TStringList.Create;
    try
      EnumResourceNames(Module, RT_BITMAP, @EnumBitmapName,
        NativeInt(Pointer(Names)));
      for Name in Names do
      begin
        SplitIconName(Name, ClassName, Rank);
        if ClassName = '' then
          Continue;
        Known := Icons.TryGetValue(ClassName, Present);
        if Known and (Present.Rank <= Rank) then
          Continue;
        Entry.Bitmap := BitmapFromResource(Module, Name);
        if Entry.Bitmap = nil then
          Continue;
        Entry.Rank := Rank;
        if Known then
          Present.Bitmap.Free
        else
          Inc(Result);
        Icons.AddOrSetValue(ClassName, Entry);
      end;
    finally
      Names.Free;
    end;
  finally
    FreeLibrary(Module);
  end;
end;

procedure ReleaseIcons;
var
  Entry: TIconEntry;
begin
  for Entry in Icons.Values do
    Entry.Bitmap.Free;
  Icons.Clear;
end;

function IconProviderOver(
  const AFallback: IPaletteIconProvider): IPaletteIconProvider;
begin
  if Icons.Count = 0 then
    Result := AFallback
  else
    Result := TPackageIconProvider.Create(AFallback);
end;

{ TPackageIconProvider }

constructor TPackageIconProvider.Create(const AFallback: IPaletteIconProvider);
begin
  inherited Create;
  FFallback := AFallback;
end;

function TPackageIconProvider.GlyphSize: Integer;
begin
  Result := FFallback.GlyphSize;
end;

procedure TPackageIconProvider.DrawGlyph(AItem: TPaletteItem; ACanvas: TCanvas;
  const ABounds: TRect);
begin
  DrawClassGlyph(AItem.ComponentClass, ACanvas, ABounds);
end;

procedure TPackageIconProvider.DrawClassGlyph(AComponentClass: TComponentClass;
  ACanvas: TCanvas; const ABounds: TRect);
var
  Entry: TIconEntry;
begin
  if Icons.TryGetValue(UpperCase(AComponentClass.ClassName), Entry) then
    ACanvas.StretchDraw(ABounds, Entry.Bitmap)
  else
    FFallback.DrawClassGlyph(AComponentClass, ACanvas, ABounds);
end;

initialization
  Icons := TDictionary<string, TIconEntry>.Create;

finalization
  ReleaseIcons;
  FreeAndNil(Icons);

end.
