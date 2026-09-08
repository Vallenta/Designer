// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Streaming.Saver;

// Writes a designed document back to a text .dfm: TWriter streams the root
// into a TPF0 buffer, ObjectBinaryToText converts it, the verbatim-preserved
// spans are spliced back in, and the file is replaced in one MoveFileEx step.
// The unit holds no state of its own and takes no locks.
//
// Byte-identical output depends on state only the load carries: the event
// name map (required), the declared root class name, the ancestor and frame
// diff bases, and the preserved spans.

interface

uses
  System.Classes,
  System.SysUtils,
  Vcl.Forms,
  Vallenta.FormEditor.Streaming.EventNames,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Streaming.Frames,
  Vallenta.FormEditor.Streaming.Preserved;

type
  // Raised when the designed document cannot be written. A failure of the
  // file replacement itself surfaces as EOSError.
  EFormSaveError = class(Exception);

// Writes the designed root to FileName as text DFM, replacing the file in one
// step. State supplies the declared root class name, which the stub cannot,
// and the load-time ActiveControl the write is checked against; Frames and
// Ancestor are the diff bases, Preserved the verbatim spans spliced back in.
// EventMap is required; Frames, Preserved and Ancestor may be nil.
procedure SaveDesignedForm(Root: TComponent; EventMap: TEventNameMap;
  const State: TLoadedFormState; Frames: TFrameInstances;
  Preserved: TPreservedModel; Ancestor: TComponent; const FileName: string);

// The document as text DFM in a stream the caller frees, without touching a
// file. Neither the declared root class name nor the preserved spans are put
// back, so the text carries the stub's class name and a reload needs the
// load state alongside it.
function StreamDesignedForm(Root: TComponent; EventMap: TEventNameMap;
  Frames: TFrameInstances; Ancestor: TComponent): TMemoryStream;

// Writes AText to AFileName as UTF-8 without a BOM, through a temporary file
// beside it that replaces the target in one MoveFileEx step. The temporary
// file is AFileName + '.tmp' and is left behind when the replacement fails.
procedure WriteTextAtomically(const AText, AFileName: string);

// Loads InputFile through the full designer path with nothing shown, saves it
// to the temp directory and compares both files byte by byte; the written
// copy is left behind. Verdict is 'PASS' or 'FAIL <offset>', the differing
// bytes and lines go to Log. True when the files are identical; a failure of
// the load, the save or the compare propagates as an exception.
function RoundTripDfm(const InputFile: string; Log: TDesignLog;
  out Verdict: string): Boolean;

implementation

uses
  Winapi.Windows,
  System.Math,
  System.IOUtils,
  Vallenta.FormEditor.Surface.FormDesigner,
  Vallenta.FormEditor.Streaming.TextSpans,
  Vallenta.FormEditor.Streaming.RootClassifier;

{ save pipeline }

function PatchRootClassName(Binary: TMemoryStream; const NewClassName: string): TMemoryStream;
const
  FilerSignature: array [0 .. 3] of AnsiChar = 'TPF0';
  FlagsPrefix = $F0;
  ChildPosFlag = 2;
var
  Signature: array [0 .. 3] of AnsiChar;
  Flags, OldLength, NewLength: Byte;
  HasFlags: Boolean;
  NameBytes: TBytes;
begin
  Binary.Position := 0;
  Binary.ReadBuffer(Signature, SizeOf(Signature));
  if not CompareMem(@Signature, @FilerSignature, SizeOf(Signature)) then
    raise EFormSaveError.Create('The written stream is missing the TPF0 signature.');
  Binary.ReadBuffer(OldLength, SizeOf(OldLength));
  HasFlags := (OldLength and FlagsPrefix) = FlagsPrefix;
  Flags := OldLength;
  if HasFlags then
  begin
    if (Flags and ChildPosFlag) <> 0 then
      raise EFormSaveError.Create(
        'The written root carries a position among siblings, which no root has.');
    Binary.ReadBuffer(OldLength, SizeOf(OldLength));
  end;
  Binary.Position := Binary.Position + OldLength;

  NameBytes := TEncoding.UTF8.GetBytes(NewClassName);
  if Length(NameBytes) > 255 then
    raise EFormSaveError.CreateFmt('Root class name "%s" is too long for a DFM.', [NewClassName]);
  NewLength := Length(NameBytes);

  Result := TMemoryStream.Create;
  try
    Result.WriteBuffer(FilerSignature, SizeOf(FilerSignature));
    if HasFlags then
      Result.WriteBuffer(Flags, SizeOf(Flags));
    Result.WriteBuffer(NewLength, SizeOf(NewLength));
    if NewLength > 0 then
      Result.WriteBuffer(NameBytes[0], NewLength);
    Result.CopyFrom(Binary, Binary.Size - Binary.Position);
    Result.Position := 0;
  except
    Result.Free;
    raise;
  end;
end;

procedure WriteFileAtomically(Data: TMemoryStream; const FileName: string);
var
  TempName: string;
begin
  TempName := FileName + '.tmp';
  Data.Position := 0;
  Data.SaveToFile(TempName);
  if not MoveFileEx(PChar(TempName), PChar(FileName),
    MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    RaiseLastOSError;
end;

procedure CheckLoadedState(Root: TComponent; const State: TLoadedFormState);
var
  Form: TCustomForm;
  LiveName: string;
begin
  if (State.ActiveControlName = '') or not (Root is TCustomForm) then
    Exit;
  Form := TCustomForm(Root);
  if Form.FindComponent(State.ActiveControlName) = nil then
    Exit;
  if Form.ActiveControl <> nil then
    LiveName := Form.ActiveControl.Name;
  if not SameText(LiveName, State.ActiveControlName) then
    raise EFormSaveError.CreateFmt(
      'ActiveControl changed from "%s" to "%s" while designing - the designer ' +
      'must not let input reach the form.',
      [State.ActiveControlName, LiveName]);
end;

function WriteDesignedForm(Root: TComponent; EventMap: TEventNameMap;
  Frames: TFrameInstances; Ancestor: TComponent): TMemoryStream;
var
  Writer: TWriter;
begin
  if EventMap = nil then
    raise EFormSaveError.Create('Writing the document needs the event name map of the load.');
  Result := TMemoryStream.Create;
  try
    Writer := TWriter.Create(Result, 4096);
    try
      Writer.OnFindMethodName := EventMap.FindMethodName;
      if Frames <> nil then
        Writer.OnFindAncestor := Frames.FindAncestor;
      if Ancestor <> nil then
        Writer.WriteDescendent(Root, Ancestor)
      else
        Writer.WriteRootComponent(Root);
      Writer.FlushBuffer;
    finally
      Writer.Free;
    end;
    Result.Position := 0;
  except
    Result.Free;
    raise;
  end;
end;

function DesignedFormText(Binary: TMemoryStream; Frames: TFrameInstances): string;
var
  Text: TMemoryStream;
begin
  Text := TMemoryStream.Create;
  try
    Binary.Position := 0;
    ObjectBinaryToText(Binary, Text);
    Result := DfmStreamToText(Text);
  finally
    Text.Free;
  end;
  if Frames <> nil then
    Result := RestoreDeclaredClasses(Result, Frames.Declarations);
end;

function StreamDesignedForm(Root: TComponent; EventMap: TEventNameMap;
  Frames: TFrameInstances; Ancestor: TComponent): TMemoryStream;
var
  Binary: TMemoryStream;
  Bytes: TBytes;
begin
  Binary := WriteDesignedForm(Root, EventMap, Frames, Ancestor);
  try
    Bytes := TEncoding.UTF8.GetBytes(DesignedFormText(Binary, Frames));
  finally
    Binary.Free;
  end;
  Result := TMemoryStream.Create;
  try
    if Length(Bytes) > 0 then
      Result.WriteBuffer(Bytes[0], Length(Bytes));
    Result.Position := 0;
  except
    Result.Free;
    raise;
  end;
end;

procedure WriteTextAtomically(const AText, AFileName: string);
var
  Data: TMemoryStream;
  Bytes: TBytes;
begin
  Bytes := TEncoding.UTF8.GetBytes(AText);
  Data := TMemoryStream.Create;
  try
    if Length(Bytes) > 0 then
      Data.WriteBuffer(Bytes[0], Length(Bytes));
    WriteFileAtomically(Data, AFileName);
  finally
    Data.Free;
  end;
end;

procedure SaveDesignedForm(Root: TComponent; EventMap: TEventNameMap;
  const State: TLoadedFormState; Frames: TFrameInstances;
  Preserved: TPreservedModel; Ancestor: TComponent; const FileName: string);
var
  Binary, Patched, Text: TMemoryStream;
  Insertions: TArray<TDfmInsertion>;
begin
  CheckLoadedState(Root, State);

  Binary := WriteDesignedForm(Root, EventMap, Frames, Ancestor);
  try
    Patched := PatchRootClassName(Binary, State.RootClassName);
    try
      if Preserved <> nil then
        Insertions := Preserved.Insertions;
      if (Length(Insertions) = 0) and ((Frames = nil) or (Frames.Count = 0)) then
      begin
        Text := TMemoryStream.Create;
        try
          ObjectBinaryToText(Patched, Text);
          WriteFileAtomically(Text, FileName);
        finally
          Text.Free;
        end;
      end
      else
        WriteTextAtomically(SpliceDfmText(DesignedFormText(Patched, Frames),
          Insertions), FileName);
    finally
      Patched.Free;
    end;
  finally
    Binary.Free;
  end;
end;

{ round trip }

function DescribeByte(Value: Byte): string;
begin
  if (Value >= 32) and (Value < 127) then
    Result := Format('$%.2x ''%s''', [Value, Char(Value)])
  else
    Result := Format('$%.2x', [Value]);
end;

function LineAround(const Data: TBytes; Offset: Integer; out LineNumber: Integer): string;
var
  Start, Stop, I: Integer;
begin
  LineNumber := 1;
  for I := 0 to Min(Offset, Length(Data)) - 1 do
    if Data[I] = 10 then
      Inc(LineNumber);
  Start := Min(Offset, Length(Data));
  while (Start > 0) and (Data[Start - 1] <> 10) do
    Dec(Start);
  Stop := Min(Offset, Length(Data));
  while (Stop < Length(Data)) and (Data[Stop] <> 13) and (Data[Stop] <> 10) do
    Inc(Stop);
  Result := '';
  for I := Start to Stop - 1 do
    Result := Result + Char(Data[I]);
end;

function CompareDfmFiles(const FileA, FileB: string; Log: TDesignLog;
  out Verdict: string): Boolean;
var
  A, B: TBytes;
  I, Shared, LineA, LineB: Integer;
  TextA, TextB: string;
begin
  A := TFile.ReadAllBytes(FileA);
  B := TFile.ReadAllBytes(FileB);
  Shared := Min(Length(A), Length(B));
  for I := 0 to Shared - 1 do
    if A[I] <> B[I] then
    begin
      TextA := LineAround(A, I, LineA);
      TextB := LineAround(B, I, LineB);
      Verdict := Format('FAIL %d', [I]);
      Log.AddFmt(lsError, 'expected %s, wrote %s',
        [DescribeByte(A[I]), DescribeByte(B[I])]);
      Log.AddFmt(lsError, 'original line %d: %s', [LineA, TextA]);
      Log.AddFmt(lsError, 'written  line %d: %s', [LineB, TextB]);
      Exit(False);
    end;
  if Length(A) <> Length(B) then
  begin
    TextA := LineAround(A, Shared, LineA);
    TextB := LineAround(B, Shared, LineB);
    Verdict := Format('FAIL %d', [Shared]);
    Log.AddFmt(lsError, 'original is %d byte(s), written is %d byte(s)',
      [Length(A), Length(B)]);
    if Length(A) > Length(B) then
      Log.AddFmt(lsError, 'missing from line %d: %s', [LineA, TextA])
    else
      Log.AddFmt(lsError, 'extra at line %d: %s', [LineB, TextB]);
    Exit(False);
  end;
  Verdict := 'PASS';
  Result := True;
end;

function RoundTripDfm(const InputFile: string; Log: TDesignLog;
  out Verdict: string): Boolean;
var
  Document: TDesignDocument;
  Designer: TFormDesigner;
  Loader: TFormLoader;
  TempFile: string;
begin
  TempFile := TPath.Combine(TPath.GetTempPath,
    'vsfe_roundtrip_' + TPath.GetFileName(InputFile));
  Loader := TFormLoader.Create(Log);
  try
    Loader.Prepare(InputFile);
    Document := CreateDesignDocument(Loader.RootKind);
    try
      Designer := TFormDesigner.Create(Document.HostForm, Document.Root, Log);
      try
        Loader.StreamInto(Document.Root);
        if Loader.RootKind = drFrame then
          AttachFrameToHost(Document);
        // The designer takes over the preserved model, whose placeholders are
        // parented into the document; freeing the document first frees them
        // twice.
        Designer.AttachLoaded(TempFile, Loader.ExtractEventMap,
          Loader.ExtractPreserved, Loader.ExtractFrames, Loader.ExtractAncestor,
          Loader.LoadedState);
        // A placeholder holds the tab slot of the component it stands for;
        // without it the controls after it are written with wrong TabOrders.
        Designer.ShowPlaceholders;
        Log.Add(lsInfo, Designer.DescribeDpi);
        SaveDesignedForm(Document.Root, Designer.EventMap, Designer.LoadedState,
          Designer.Frames, Designer.Preserved, Designer.Ancestor.Root, TempFile);
      finally
        Designer.Free;
      end;
    finally
      FreeDesignDocument(Document);
    end;
  finally
    Loader.Free;
  end;
  Log.AddFmt(lsInfo, 'round trip wrote %s', [TempFile]);
  Result := CompareDfmFiles(InputFile, TempFile, Log, Verdict);
end;

end.
