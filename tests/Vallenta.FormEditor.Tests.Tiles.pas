// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.Tiles;

// Covers IsNonVisual and TileAt of Vallenta.FormEditor.Surface.Tiles: which
// components of a root are drawn as tiles, and which tile a point hits.
// A TControl is not tiled, nor is a component whose GetParentComponent
// returns a parent; every other component owned by the root is.

interface

uses
  DUnitX.TestFramework;

type
  // Tile eligibility of root-owned components, and tile hit testing.
  [TestFixture]
  TTileTests = class
  public
    [Test]
    procedure APlainNonVisualComponentStandsAsATile;
    [Test]
    procedure AControlStandsAsNoTile;
    [Test]
    procedure ASubComponentAParentPresentsStandsAsNoTile;
    [Test]
    procedure TileHitTestingPassesOverAParentedSubComponent;
  end;

implementation

uses
  System.Classes,
  System.Types,
  Vcl.Controls,
  Vallenta.FormEditor.Surface.Tiles;

type
  // Test double for a grid view or level: a component that returns a parent
  // from GetParentComponent, as TcxGridDBTableView and TcxGridLevel do under
  // a TcxGrid.
  TSubComponent = class(TComponent)
  private
    FParentComponent: TComponent;
  public
    function GetParentComponent: TComponent; override;
    function HasParent: Boolean; override;
    procedure SetParentComponent(AParent: TComponent); override;
  end;

function TSubComponent.GetParentComponent: TComponent;
begin
  Result := FParentComponent;
end;

function TSubComponent.HasParent: Boolean;
begin
  Result := FParentComponent <> nil;
end;

procedure TSubComponent.SetParentComponent(AParent: TComponent);
begin
  FParentComponent := AParent;
end;

{ TTileTests }

procedure TTileTests.APlainNonVisualComponentStandsAsATile;
var
  Root: TComponent;
begin
  Root := TComponent.Create(nil);
  try
    Assert.IsTrue(IsNonVisual(TComponent.Create(Root)),
      'a root-owned component nothing presents was denied its tile');
  finally
    Root.Free;
  end;
end;

procedure TTileTests.AControlStandsAsNoTile;
var
  Root: TComponent;
begin
  Root := TComponent.Create(nil);
  try
    Assert.IsFalse(IsNonVisual(TControl.Create(Root)),
      'a control got a tile beside its own window');
  finally
    Root.Free;
  end;
end;

procedure TTileTests.ASubComponentAParentPresentsStandsAsNoTile;
var
  Root, Grid: TComponent;
  View, Level, SubLevel: TSubComponent;
begin
  Root := TComponent.Create(nil);
  try
    Grid := TControl.Create(Root);
    View := TSubComponent.Create(Root);
    View.SetParentComponent(Grid);
    Level := TSubComponent.Create(Root);
    Level.SetParentComponent(Grid);
    SubLevel := TSubComponent.Create(Root);
    SubLevel.SetParentComponent(Level);
    Assert.IsFalse(IsNonVisual(View),
      'a view its grid presents got a tile of its own');
    Assert.IsFalse(IsNonVisual(Level),
      'a level its grid presents got a tile of its own');
    Assert.IsFalse(IsNonVisual(SubLevel),
      'a level nested below another level got a tile of its own');
  finally
    Root.Free;
  end;
end;

procedure TTileTests.TileHitTestingPassesOverAParentedSubComponent;
var
  Root, Timer, Grid: TComponent;
  View: TSubComponent;
begin
  Root := TComponent.Create(nil);
  try
    Timer := TComponent.Create(Root);
    Grid := TControl.Create(Root);
    View := TSubComponent.Create(Root);
    View.SetParentComponent(Grid);
    // Timer and View keep DesignInfo at 0, so both tile rectangles contain
    // (5, 5), and TileAt reaches View first, searching by descending index.
    Assert.AreSame(Timer, TileAt(Root, Point(5, 5)),
      'the hit went past the tile to a sub-component that has none');
    Assert.IsNull(TileAt(Root, Point(500, 500)),
      'empty surface hit something');
  finally
    Root.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TTileTests);

end.
