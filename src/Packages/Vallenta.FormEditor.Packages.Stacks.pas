// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Packages.Stacks;

// Names code addresses for a package failure diagnosed from a log rather than
// a debugger: installs the RTL stack-info hooks and reports each address as
// its module, the offset into it, and the exported symbol below it. Frames
// come from a scan of stack slots for return addresses, as the 32-bit RTL and
// VCL are built without frame pointers.
//
// Not thread-safe: the module and symbol caches are unit variables reached
// without a lock. Win32 only - the stack is read with inline x86 assembly and
// candidates are recognized by x86 call opcodes. A scan reports calls that
// have already returned, so a listed frame is not necessarily on the current
// call path.

interface

uses
  Winapi.Windows,
  System.SysUtils;

// Installs the RTL stack-info hooks; does nothing when a provider is already
// installed. The installed hook records a stack only while capture is on.
procedure InstallStackCapture;

// Switches frame capture on or off; off until the first call with True, so
// nothing is recorded before it. Switching on clears the module and symbol
// caches: a module unloaded since the last capture would leave stale entries.
procedure SetStackCapture(AOn: Boolean);

// AException.StackTrace split into lines; empty when AException is nil or no
// stack was captured. The text comes from whichever provider holds the RTL
// hooks; from this one, an optional 'raised at' line, then a header and one
// line per frame when the scan found any.
function StackFrames(AException: Exception): TArray<string>;

// Scans the calling thread's stack and names each frame as DescribeAddress
// does, regardless of the RTL hooks and of the capture switch. Entries are
// indented by two spaces; the innermost ones are frames inside this unit.
function CurrentStack: TArray<string>;

// AAddress as 'module + $offset (symbol + $offset)'. The symbol part is
// omitted when no export lies within $1000 bytes below the address; when no
// module can be named for the address, the result is '$' and the raw address
// in hexadecimal.
function DescribeAddress(AAddress: Pointer): string;

implementation

uses
  System.Classes,
  System.Generics.Collections,
  Vallenta.FormEditor.Packages.PeImage;

const
  // Scan limits: frames reported per scan, and stack bytes read for them.
  MaxFrames = 16;
  ScanBytes = 8192;
  // Bytes; an export further below an address does not name it.
  MaxSymbolOffset = $1000;
  // 64 KB module mapping granularity; no block spans two modules.
  BlockMask = NativeUInt($FFFF0000);
  // GetModuleHandleEx flags.
  ModuleFromAddress = $00000004;
  ModuleUnchangedRefCount = $00000002;

var
  Capturing: Boolean = False;
  Symbols: TDictionary<HMODULE, TArray<TExportedSymbol>> = nil;
  Blocks: TDictionary<NativeUInt, HMODULE> = nil;

function GetModuleHandleEx(AFlags: DWORD; AModuleName: PChar;
  out AModule: HMODULE): BOOL; stdcall;
  external kernel32 name 'GetModuleHandleExW';

function StackPointer: Pointer;
asm
  mov eax, esp
end;

// The thread's stack base, from the TEB this thread's FS selector points at.
function StackTop: Pointer;
asm
  mov eax, fs:[4]
end;

function ModuleAt(AAddress: Pointer): HMODULE;
var
  Block: NativeUInt;
begin
  Block := NativeUInt(AAddress) and BlockMask;
  if Blocks.TryGetValue(Block, Result) then
    Exit;
  if not GetModuleHandleEx(ModuleFromAddress or ModuleUnchangedRefCount,
    PChar(AAddress), Result) then
    Result := 0;
  Blocks.Add(Block, Result);
end;

function ModuleFileName(AModule: HMODULE): string;
var
  Buffer: array [0 .. MAX_PATH] of Char;
begin
  if GetModuleFileName(AModule, @Buffer[0], Length(Buffer)) = 0 then
    Exit('');
  Result := ExtractFileName(string(PChar(@Buffer[0])));
end;

function SymbolsOf(AModule: HMODULE): TArray<TExportedSymbol>;
begin
  if Symbols.TryGetValue(AModule, Result) then
    Exit;
  Result := ExportedSymbols(AModule);
  Symbols.Add(AModule, Result);
end;

function SymbolBelow(const ASymbols: TArray<TExportedSymbol>; AAddress: Pointer;
  out AOffset: NativeUInt): string;
var
  Lower, Upper, Middle, Found: Integer;
begin
  Result := '';
  Found := -1;
  Lower := 0;
  Upper := High(ASymbols);
  while Lower <= Upper do
  begin
    Middle := Lower + (Upper - Lower) div 2;
    if NativeUInt(ASymbols[Middle].Address) <= NativeUInt(AAddress) then
    begin
      Found := Middle;
      Lower := Middle + 1;
    end
    else
      Upper := Middle - 1;
  end;
  if Found < 0 then
    Exit;
  AOffset := NativeUInt(AAddress) - NativeUInt(ASymbols[Found].Address);
  if AOffset > MaxSymbolOffset then
    Exit;
  Result := ASymbols[Found].Name;
end;

function DescribeAddress(AAddress: Pointer): string;
var
  Module: HMODULE;
  Name, Symbol: string;
  Offset: NativeUInt;
begin
  Result := Format('$%p', [AAddress]);
  Module := ModuleAt(AAddress);
  if Module = 0 then
    Exit;
  Name := ModuleFileName(Module);
  if Name = '' then
    Exit;
  Result := Format('%s + $%.8x', [Name, NativeUInt(AAddress) - Module]);
  Symbol := SymbolBelow(SymbolsOf(Module), AAddress, Offset);
  if Symbol <> '' then
    Result := Format('%s (%s + $%x)', [Result, Symbol, Offset]);
end;

// True when the bytes before AAddress are a call instruction, which is what
// separates a return address on the stack from a value that only looks like
// one. Covers call rel32, call r/m32 in its addressing forms, and the far
// call; any other encoding reads as not a call.
function FollowsACall(AAddress: Pointer): Boolean;
var
  Code: PByte;
  Back: Integer;
begin
  Result := False;
  Code := AAddress;
  if (Code - 5)^ = $E8 then
    Exit(True);
  if (Code - 7)^ = $9A then
    Exit(True);
  for Back := 2 to 7 do
    if ((Code - Back)^ = $FF) and ((((Code - Back + 1)^ shr 3) and 7) = 2) then
      Exit(True);
end;

function IsReturnAddress(AAddress: Pointer): Boolean;
var
  Module: HMODULE;
begin
  Result := False;
  Module := ModuleAt(AAddress);
  if Module = 0 then
    Exit;
  // FollowsACall reads up to 7 bytes below AAddress; this keeps that read
  // inside the module.
  if NativeUInt(AAddress) < Module + 16 then
    Exit;
  Result := FollowsACall(AAddress);
end;

procedure CollectFrames(AFrames: TStrings);
var
  Slot, Last: PByte;
  Candidate, Previous: Pointer;
begin
  Slot := StackPointer;
  Previous := nil;
  Last := PByte(StackTop) - SizeOf(Pointer);
  if Last > Slot + ScanBytes then
    Last := Slot + ScanBytes;
  while (Slot <= Last) and (AFrames.Count < MaxFrames) do
  begin
    Candidate := PPointer(Slot)^;
    if (Candidate <> Previous) and IsReturnAddress(Candidate) then
    begin
      AFrames.Add('  ' + DescribeAddress(Candidate));
      Previous := Candidate;
    end;
    Inc(Slot, SizeOf(Pointer));
  end;
end;

function CaptureStack(P: System.PExceptionRecord): Pointer;
var
  Frames, Found: TStringList;
begin
  Result := nil;
  if not Capturing then
    Exit;
  Frames := TStringList.Create;
  try
    if (P <> nil) and (P.ExceptionAddress <> nil) then
      Frames.Add('raised at ' + DescribeAddress(P.ExceptionAddress));
    Found := TStringList.Create;
    try
      CollectFrames(Found);
      if Found.Count > 0 then
      begin
        Frames.Add('found on the stack, innermost first - a scan, so some of ' +
          'these calls have already returned:');
        Frames.AddStrings(Found);
      end;
    finally
      Found.Free;
    end;
  except
    // This hook runs inside the RTL's raise path; an exception escaping here
    // would replace the one being reported.
    FreeAndNil(Frames);
  end;
  Result := Frames;
end;

function DescribeStack(AInfo: Pointer): string;
begin
  Result := '';
  if AInfo <> nil then
    Result := TStringList(AInfo).Text;
end;

procedure ReleaseStack(AInfo: Pointer);
begin
  TStringList(AInfo).Free;
end;

procedure InstallStackCapture;
begin
  // The three hooks must come from one provider: a stack recorded here is a
  // TStringList that only ReleaseStack may free.
  if Assigned(Exception.GetExceptionStackInfoProc) then
    Exit;
  Exception.GetExceptionStackInfoProc := CaptureStack;
  Exception.GetStackInfoStringProc := DescribeStack;
  Exception.CleanUpStackInfoProc := ReleaseStack;
end;

procedure SetStackCapture(AOn: Boolean);
begin
  Capturing := AOn;
  if not AOn then
    Exit;
  Symbols.Clear;
  Blocks.Clear;
end;

function StackFrames(AException: Exception): TArray<string>;
var
  Trace: string;
begin
  Result := [];
  if AException = nil then
    Exit;
  Trace := AException.StackTrace;
  if Trace = '' then
    Exit;
  Result := Trace.Split([sLineBreak, #10], TStringSplitOptions.ExcludeEmpty);
end;

function CurrentStack: TArray<string>;
var
  Found: TStringList;
  I: Integer;
begin
  Result := [];
  Found := TStringList.Create;
  try
    CollectFrames(Found);
    SetLength(Result, Found.Count);
    for I := 0 to Found.Count - 1 do
      Result[I] := Found[I];
  finally
    Found.Free;
  end;
end;

initialization
  Symbols := TDictionary<HMODULE, TArray<TExportedSymbol>>.Create;
  Blocks := TDictionary<NativeUInt, HMODULE>.Create;

finalization
  // The hooks stay installed: an already captured stack could not be released
  // once they are cleared. Capture is switched off so the exception hook
  // stops before the caches are freed.
  Capturing := False;
  FreeAndNil(Blocks);
  FreeAndNil(Symbols);

end.
