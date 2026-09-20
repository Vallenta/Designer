// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Surface.Guides;

// Alignment guide geometry: the segments joining a rectangle to the
// neighbours sharing one of its edges, and the offset that snaps an edge onto
// the nearest neighbour edge within reach. Pure functions over rectangles in
// one coordinate space; no window is touched.

interface

uses
  System.Types;

type
  // Edge of a rectangle a guide is measured on.
  TGuideEdge = (geLeft, geRight, geTop, geBottom);
  TGuideEdges = set of TGuideEdge;

  // Orientation of a guide segment.
  TGuideAxis = (gaVertical, gaHorizontal);

  // One guide line in the coordinates of the rectangles it was computed
  // from. Vertical: X = Position, Y from Start to Finish. Horizontal:
  // Y = Position, X from Start to Finish. Finish is exclusive.
  TGuideSegment = record
    Axis: TGuideAxis;
    Position: Integer;
    Start: Integer;
    Finish: Integer;
    class operator Equal(const A, B: TGuideSegment): Boolean;
    class operator NotEqual(const A, B: TGuideSegment): Boolean;
  end;

  // Per axis, whether a neighbour edge lies within reach and the offset that
  // moves the measured edge onto it; DX and DY are 0 on an axis without one.
  TGuidePull = record
    OnX: Boolean;
    DX: Integer;
    OnY: Boolean;
    DY: Integer;
  end;

const
  AllGuideEdges = [geLeft, geRight, geTop, geBottom];

// One segment per edge of ATarget that at least one neighbour shares, in the
// order left, right, top, bottom. A vertical segment spans from the smallest
// top to the largest bottom over ATarget and the neighbours sharing the edge,
// a horizontal one from the smallest left to the largest right. Position is
// the outermost pixel column or row inside the rectangle: Left and Top as
// they are, Right - 1 and Bottom - 1.
function AlignmentGuides(const ATarget: TRect;
  const ANeighbours: array of TRect): TArray<TGuideSegment>;

// Measures every edge in AEdges of ATarget against the same edge of every
// neighbour, at most ADistance pixels apart. Per axis the nearest wins; at
// equal distance the left or top edge. An edge already on a neighbour edge
// reports its axis with an offset of 0.
function PullToGuides(const ATarget: TRect; const ANeighbours: array of TRect;
  AEdges: TGuideEdges; ADistance: Integer): TGuidePull;

// True when both arrays hold the same segments in the same order.
function SameGuides(const A, B: TArray<TGuideSegment>): Boolean;

implementation

uses
  System.Math;

const
  EdgeAxes: array [TGuideEdge] of TGuideAxis = (gaVertical, gaVertical,
    gaHorizontal, gaHorizontal);

class operator TGuideSegment.Equal(const A, B: TGuideSegment): Boolean;
begin
  Result := (A.Axis = B.Axis) and (A.Position = B.Position) and
    (A.Start = B.Start) and (A.Finish = B.Finish);
end;

class operator TGuideSegment.NotEqual(const A, B: TGuideSegment): Boolean;
begin
  Result := not (A = B);
end;

function EdgeValue(const ARect: TRect; AEdge: TGuideEdge): Integer;
begin
  case AEdge of
    geLeft: Result := ARect.Left;
    geRight: Result := ARect.Right;
    geTop: Result := ARect.Top;
  else
    Result := ARect.Bottom;
  end;
end;

function AlignmentGuides(const ATarget: TRect;
  const ANeighbours: array of TRect): TArray<TGuideSegment>;
var
  Edge: TGuideEdge;
  I, Value, Start, Finish: Integer;
  Found: Boolean;
  Segment: TGuideSegment;
begin
  Result := nil;
  for Edge := Low(TGuideEdge) to High(TGuideEdge) do
  begin
    Value := EdgeValue(ATarget, Edge);
    Found := False;
    if EdgeAxes[Edge] = gaVertical then
    begin
      Start := ATarget.Top;
      Finish := ATarget.Bottom;
    end
    else
    begin
      Start := ATarget.Left;
      Finish := ATarget.Right;
    end;
    for I := 0 to High(ANeighbours) do
    begin
      if EdgeValue(ANeighbours[I], Edge) <> Value then
        Continue;
      Found := True;
      if EdgeAxes[Edge] = gaVertical then
      begin
        Start := Min(Start, ANeighbours[I].Top);
        Finish := Max(Finish, ANeighbours[I].Bottom);
      end
      else
      begin
        Start := Min(Start, ANeighbours[I].Left);
        Finish := Max(Finish, ANeighbours[I].Right);
      end;
    end;
    if not Found then
      Continue;
    Segment.Axis := EdgeAxes[Edge];
    if Edge in [geRight, geBottom] then
      Segment.Position := Value - 1
    else
      Segment.Position := Value;
    Segment.Start := Start;
    Segment.Finish := Finish;
    Result := Result + [Segment];
  end;
end;

function PullToGuides(const ATarget: TRect; const ANeighbours: array of TRect;
  AEdges: TGuideEdges; ADistance: Integer): TGuidePull;
var
  Edge: TGuideEdge;
  I, Offset, Distance, BestX, BestY: Integer;
begin
  Result := Default(TGuidePull);
  BestX := ADistance + 1;
  BestY := ADistance + 1;
  for Edge := Low(TGuideEdge) to High(TGuideEdge) do
  begin
    if not (Edge in AEdges) then
      Continue;
    for I := 0 to High(ANeighbours) do
    begin
      Offset := EdgeValue(ANeighbours[I], Edge) - EdgeValue(ATarget, Edge);
      Distance := Abs(Offset);
      if Distance > ADistance then
        Continue;
      if EdgeAxes[Edge] = gaVertical then
      begin
        if Distance < BestX then
        begin
          BestX := Distance;
          Result.OnX := True;
          Result.DX := Offset;
        end;
      end
      else if Distance < BestY then
      begin
        BestY := Distance;
        Result.OnY := True;
        Result.DY := Offset;
      end;
    end;
  end;
end;

function SameGuides(const A, B: TArray<TGuideSegment>): Boolean;
var
  I: Integer;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  for I := 0 to High(A) do
    if A[I] <> B[I] then
      Exit(False);
  Result := True;
end;

end.
