// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Packages.PeImage;

// Reads the PE image format: machine type and imported module names from a
// file on disk, and the export table of a module already mapped in this
// process. No shared state is held, so any function may be called from any
// thread.
//
// The mapped-module functions read the data directory at its PE32 offset and
// are correct only in a 32-bit process. Returned addresses point into the
// mapped image and are valid only while AModule stays loaded.

interface

uses
  Winapi.Windows,
  System.SysUtils;

type
  // Raised when a file cannot be opened or is not a readable PE image.
  EPeImageError = class(Exception);

  // One named export of a module mapped in this process.
  TExportedSymbol = record
    // Export name as stored in the module's export name table.
    Name: string;
    // Address in this process, not a relative virtual address.
    Address: Pointer;
  end;

// Machine type of the image at APath (IMAGE_FILE_MACHINE_*). Raises
// EPeImageError when the file is not a readable PE image.
function ImageMachineType(const APath: string): Word;

// Module names from the import table of the image at APath, with the letter
// case the file stores. Raises EPeImageError when the file is not a readable
// PE image.
function ImportedModuleNames(const APath: string): TArray<string>;

// Export names of a module mapped in this process, in export-table order and
// including forwarded exports. Empty when AModule is 0 or the module exports
// nothing by name.
function ExportedNames(AModule: HMODULE): TArray<string>;

// Exported symbols of a module mapped in this process, in ascending address
// order for lookup by address. Forwarded exports are omitted: their address
// points into the export directory rather than at code in this module.
function ExportedSymbols(AModule: HMODULE): TArray<TExportedSymbol>;

implementation

uses
  System.Classes,
  System.Generics.Collections,
  System.Generics.Defaults;

const
  // Optional header layout, and bounds that end a scan of a corrupt import
  // table with no final descriptor or name.
  OptionalHeaderMagic32 = $10B;
  OptionalHeaderMagic64 = $20B;
  // The data directory array is the last field of both optional header
  // layouts.
  DirectoryOffset32 = SizeOf(TImageOptionalHeader32) -
    IMAGE_NUMBEROF_DIRECTORY_ENTRIES * SizeOf(TImageDataDirectory);
  DirectoryOffset64 = SizeOf(TImageOptionalHeader64) -
    IMAGE_NUMBEROF_DIRECTORY_ENTRIES * SizeOf(TImageDataDirectory);
  MaxImportedModules = 1024;
  MaxNameLength = 512;

type
  // Reads the headers, sections and data directories of a PE file on disk.
  TPeFile = class
  private
    FStream: TFileStream;
    FMachine: Word;
    FSections: TArray<TImageSectionHeader>;
    FDirectories: TArray<TImageDataDirectory>;
    procedure ReadAt(AOffset: Int64; var ABuffer; ASize: Integer);
    function ReadNameAt(AOffset: Int64): string;
    procedure ReadHeaders;
    function FileOffsetOf(AAddress: Cardinal): Int64;
  public
    constructor Create(const APath: string);
    destructor Destroy; override;
    function ImportedModules: TArray<string>;
    property Machine: Word read FMachine;
  end;

constructor TPeFile.Create(const APath: string);
begin
  inherited Create;
  try
    FStream := TFileStream.Create(APath, fmOpenRead or fmShareDenyNone);
  except
    on E: EStreamError do
      raise EPeImageError.Create(E.Message);
  end;
  ReadHeaders;
end;

destructor TPeFile.Destroy;
begin
  FStream.Free;
  inherited Destroy;
end;

procedure TPeFile.ReadAt(AOffset: Int64; var ABuffer; ASize: Integer);
begin
  if (AOffset < 0) or (AOffset + ASize > FStream.Size) then
    raise EPeImageError.Create('it ends before its headers do');
  FStream.Position := AOffset;
  FStream.ReadBuffer(ABuffer, ASize);
end;

function TPeFile.ReadNameAt(AOffset: Int64): string;
var
  Character: AnsiChar;
  Name: AnsiString;
begin
  Name := '';
  while Length(Name) < MaxNameLength do
  begin
    ReadAt(AOffset + Length(Name), Character, SizeOf(Character));
    if Character = #0 then
      Break;
    Name := Name + Character;
  end;
  Result := string(Name);
end;

procedure TPeFile.ReadHeaders;
var
  DosHeader: TImageDosHeader;
  FileHeader: TImageFileHeader;
  Signature: Cardinal;
  Magic: Word;
  OptionalHeader, DirectoryStart: Int64;
  DirectoryCount: Cardinal;
  I: Integer;
begin
  ReadAt(0, DosHeader, SizeOf(DosHeader));
  if DosHeader.e_magic <> IMAGE_DOS_SIGNATURE then
    raise EPeImageError.Create('it does not begin like an executable');
  ReadAt(DosHeader._lfanew, Signature, SizeOf(Signature));
  if Signature <> IMAGE_NT_SIGNATURE then
    raise EPeImageError.Create('it carries no portable executable header');
  ReadAt(DosHeader._lfanew + SizeOf(Signature), FileHeader, SizeOf(FileHeader));
  FMachine := FileHeader.Machine;

  OptionalHeader := DosHeader._lfanew + SizeOf(Signature) + SizeOf(FileHeader);
  SetLength(FSections, FileHeader.NumberOfSections);
  for I := 0 to High(FSections) do
    ReadAt(OptionalHeader + FileHeader.SizeOfOptionalHeader +
      I * SizeOf(TImageSectionHeader), FSections[I], SizeOf(TImageSectionHeader));

  if FileHeader.SizeOfOptionalHeader = 0 then
    Exit;
  ReadAt(OptionalHeader, Magic, SizeOf(Magic));
  case Magic of
    OptionalHeaderMagic32:
      DirectoryStart := OptionalHeader + DirectoryOffset32;
    OptionalHeaderMagic64:
      DirectoryStart := OptionalHeader + DirectoryOffset64;
  else
    raise EPeImageError.Create('its header is of a kind this does not read');
  end;
  // NumberOfRvaAndSizes is the last field before the directory array.
  ReadAt(DirectoryStart - SizeOf(DirectoryCount), DirectoryCount,
    SizeOf(DirectoryCount));
  if DirectoryCount > IMAGE_NUMBEROF_DIRECTORY_ENTRIES then
    DirectoryCount := IMAGE_NUMBEROF_DIRECTORY_ENTRIES;
  SetLength(FDirectories, DirectoryCount);
  for I := 0 to High(FDirectories) do
    ReadAt(DirectoryStart + I * SizeOf(TImageDataDirectory), FDirectories[I],
      SizeOf(TImageDataDirectory));
end;

function TPeFile.FileOffsetOf(AAddress: Cardinal): Int64;
var
  Section: TImageSectionHeader;
  Extent: Cardinal;
begin
  for Section in FSections do
  begin
    Extent := Section.Misc.VirtualSize;
    if Extent = 0 then
      Extent := Section.SizeOfRawData;
    if (AAddress >= Section.VirtualAddress) and
      (AAddress < Section.VirtualAddress + Extent) then
      Exit(Int64(Section.PointerToRawData) +
        Int64(AAddress) - Int64(Section.VirtualAddress));
  end;
  Result := -1;
end;

function TPeFile.ImportedModules: TArray<string>;
var
  Directory: TImageDataDirectory;
  Descriptor: TImageImportDescriptor;
  Offset, NameOffset: Int64;
  Count: Integer;
begin
  Result := [];
  if Length(FDirectories) <= IMAGE_DIRECTORY_ENTRY_IMPORT then
    Exit;
  Directory := FDirectories[IMAGE_DIRECTORY_ENTRY_IMPORT];
  if Directory.VirtualAddress = 0 then
    Exit;
  Offset := FileOffsetOf(Directory.VirtualAddress);
  if Offset < 0 then
    Exit;
  for Count := 1 to MaxImportedModules do
  begin
    ReadAt(Offset, Descriptor, SizeOf(Descriptor));
    if Descriptor.Name = 0 then
      Break;
    NameOffset := FileOffsetOf(Descriptor.Name);
    if NameOffset >= 0 then
      Result := Result + [ReadNameAt(NameOffset)];
    Inc(Offset, SizeOf(Descriptor));
  end;
end;

function ImageMachineType(const APath: string): Word;
var
  Image: TPeFile;
begin
  Image := TPeFile.Create(APath);
  try
    Result := Image.Machine;
  finally
    Image.Free;
  end;
end;

function ImportedModuleNames(const APath: string): TArray<string>;
var
  Image: TPeFile;
begin
  Image := TPeFile.Create(APath);
  try
    Result := Image.ImportedModules;
  finally
    Image.Free;
  end;
end;

function ExportedNames(AModule: HMODULE): TArray<string>;
var
  Header: PImageDosHeader;
  Headers: PImageNtHeaders32;
  Address: Cardinal;
  Table: PImageExportDirectory;
  NameAddresses: PCardinal;
  I: Cardinal;
begin
  Result := [];
  if AModule = 0 then
    Exit;
  Header := PImageDosHeader(AModule);
  Headers := PImageNtHeaders32(PByte(AModule) + Header._lfanew);
  Address := Headers.OptionalHeader.DataDirectory[
    IMAGE_DIRECTORY_ENTRY_EXPORT].VirtualAddress;
  if Address = 0 then
    Exit;
  Table := PImageExportDirectory(PByte(AModule) + Address);
  // A module exporting by ordinal only has NumberOfNames = 0, which
  // underflows the Cardinal loop bound.
  if Table.NumberOfNames = 0 then
    Exit;
  NameAddresses := PCardinal(PByte(AModule) + Cardinal(Table.AddressOfNames));
  for I := 0 to Table.NumberOfNames - 1 do
    Result := Result + [string(AnsiString(PAnsiChar(PByte(AModule) +
      PCardinal(PByte(NameAddresses) + I * SizeOf(Cardinal))^)))];
end;

function ExportedSymbols(AModule: HMODULE): TArray<TExportedSymbol>;
var
  Header: PImageDosHeader;
  Headers: PImageNtHeaders32;
  Directory: TImageDataDirectory;
  Table: PImageExportDirectory;
  Names, Functions: PCardinal;
  Ordinals: PWord;
  I, Index, Address: Cardinal;
  Kept: Integer;
begin
  Result := [];
  if AModule = 0 then
    Exit;
  Header := PImageDosHeader(AModule);
  Headers := PImageNtHeaders32(PByte(AModule) + Header._lfanew);
  Directory := Headers.OptionalHeader.DataDirectory[
    IMAGE_DIRECTORY_ENTRY_EXPORT];
  if Directory.VirtualAddress = 0 then
    Exit;
  Table := PImageExportDirectory(PByte(AModule) + Directory.VirtualAddress);
  if Table.NumberOfNames = 0 then
    Exit;
  Names := PCardinal(PByte(AModule) + Cardinal(Table.AddressOfNames));
  Functions := PCardinal(PByte(AModule) + Cardinal(Table.AddressOfFunctions));
  Ordinals := PWord(PByte(AModule) + Cardinal(Table.AddressOfNameOrdinals));
  SetLength(Result, Table.NumberOfNames);
  Kept := 0;
  for I := 0 to Table.NumberOfNames - 1 do
  begin
    Index := PWord(PByte(Ordinals) + I * SizeOf(Word))^;
    if Index >= Table.NumberOfFunctions then
      Continue;
    Address := PCardinal(PByte(Functions) + Index * SizeOf(Cardinal))^;
    if (Address >= Directory.VirtualAddress) and
      (Address < Directory.VirtualAddress + Directory.Size) then
      Continue;
    Result[Kept].Name := string(AnsiString(PAnsiChar(PByte(AModule) +
      PCardinal(PByte(Names) + I * SizeOf(Cardinal))^)));
    Result[Kept].Address := PByte(AModule) + Address;
    Inc(Kept);
  end;
  SetLength(Result, Kept);
  TArray.Sort<TExportedSymbol>(Result,
    TComparer<TExportedSymbol>.Construct(
      function(const A, B: TExportedSymbol): Integer
      begin
        if NativeUInt(A.Address) < NativeUInt(B.Address) then
          Result := -1
        else if NativeUInt(A.Address) > NativeUInt(B.Address) then
          Result := 1
        else
          Result := 0;
      end));
end;

end.
