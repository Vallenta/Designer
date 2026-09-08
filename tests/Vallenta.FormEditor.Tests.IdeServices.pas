// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.IdeServices;

// Covers the BorlandIDEServices stub as a design package queries it during
// unit initialization and Register: the INTAServices main menu, action list,
// image list and toolbars, and the IOTAAboutBoxServices plugin-info calls.
//
// Setup calls BeginDesignerSession, which installs the stub as
// BorlandIDEServices while loading the configured design packages. The stub
// is created once per process, so a toolbar created by one test is still
// present in later tests.

interface

uses
  DUnitX.TestFramework;

type
  // The INTAServices and IOTAAboutBoxServices surface of the stub.
  [TestFixture]
  TIdeServiceTests = class
  public
    [Setup]
    procedure StartTheSession;
    [Test]
    procedure TheStubAnswersTheNativeServices;
    [Test]
    procedure TheNativeServicesHandOutRealObjects;
    [Test]
    procedure AToolbarNameAnswersTheSameToolbarEveryTime;
    [Test]
    procedure AMenuItemHandedOverLandsInTheMainMenu;
    [Test]
    procedure TheStubAnswersTheAboutBoxServices;
    [Test]
    procedure TheMainMenuCarriesTheProjectMenuAndItsOptionsItem;
  end;

implementation

uses
  System.SysUtils,
  Vcl.Menus,
  ToolsAPI,
  Vallenta.FormEditor.Tests.Environment;

function NativeServices: INTAServices;
begin
  Result := BorlandIDEServices as INTAServices;
end;

procedure TIdeServiceTests.StartTheSession;
begin
  BeginDesignerSession;
end;

procedure TIdeServiceTests.TheStubAnswersTheNativeServices;
var
  Native: INTAServices;
begin
  Assert.IsTrue(Supports(BorlandIDEServices, INTAServices, Native),
    'BorlandIDEServices does not answer INTAServices');
end;

procedure TIdeServiceTests.TheNativeServicesHandOutRealObjects;
var
  Native: INTAServices;
begin
  Native := NativeServices;
  Assert.IsNotNull(Native.MainMenu, 'INTAServices has no main menu');
  Assert.IsNotNull(Native.ActionList, 'INTAServices has no action list');
  Assert.IsNotNull(Native.ImageList, 'INTAServices has no image list');
  Assert.IsNotNull(Native.ToolBar['CustomToolBar'],
    'INTAServices has no toolbar under a name the IDE would know');
end;

// Toolbar lookup is case-insensitive; distinct names hold distinct toolbars.
procedure TIdeServiceTests.AToolbarNameAnswersTheSameToolbarEveryTime;
var
  Native: INTAServices;
begin
  Native := NativeServices;
  Assert.AreSame(Native.ToolBar['CustomToolBar'],
    Native.ToolBar['customtoolbar'],
    'one toolbar name answered two different toolbars');
  Assert.AreNotSame(Native.ToolBar['CustomToolBar'],
    Native.ToolBar['StandardToolBar'],
    'two toolbar names answered the same toolbar');
end;

// AddActionMenu ignores the menu name it is given: an item that has no parent
// is added to the main menu root.
procedure TIdeServiceTests.AMenuItemHandedOverLandsInTheMainMenu;
var
  Native: INTAServices;
  Item: TMenuItem;
begin
  Native := NativeServices;
  Item := TMenuItem.Create(nil);
  try
    Item.Caption := 'Project Settings';
    Native.AddActionMenu('ToolsMenu', nil, Item);
    Assert.AreSame(Native.MainMenu.Items, Item.Parent,
      'an item handed to AddActionMenu was not taken into the main menu');
  finally
    Item.Free;
  end;
end;

// AddPluginInfo and RemovePluginInfo are inert and return without raising.
procedure TIdeServiceTests.TheStubAnswersTheAboutBoxServices;
var
  AboutBox: IOTAAboutBoxServices;
begin
  Assert.IsTrue(Supports(BorlandIDEServices, IOTAAboutBoxServices, AboutBox),
    'BorlandIDEServices does not answer IOTAAboutBoxServices');
  AboutBox.AddPluginInfo('Vallenta', 'a plugin that is not there', 0);
  AboutBox.RemovePluginInfo(0);
end;

function ChildNamed(AParent: TMenuItem; const AName: string): TMenuItem;
var
  I: Integer;
begin
  for I := 0 to AParent.Count - 1 do
    if SameText(AParent[I].Name, AName) then
      Exit(AParent[I]);
  Result := nil;
end;

// A design package finds its insert point by component name: ProjectMenu
// under the main menu, then ProjectOptionsItem under that. Both names are
// pinned here because a missing one leaves the index at -1.
procedure TIdeServiceTests.TheMainMenuCarriesTheProjectMenuAndItsOptionsItem;
var
  ProjectMenu, Anchor, Added: TMenuItem;
  Position: Integer;
begin
  ProjectMenu := ChildNamed(NativeServices.MainMenu.Items, 'ProjectMenu');
  Assert.IsNotNull(ProjectMenu,
    'the main menu has no child named ProjectMenu');
  Anchor := ChildNamed(ProjectMenu, 'ProjectOptionsItem');
  Assert.IsNotNull(Anchor, 'ProjectMenu has no child named ProjectOptionsItem');
  Position := ProjectMenu.IndexOf(Anchor);
  Added := TMenuItem.Create(nil);
  try
    Added.Caption := 'DevExpress Settings';
    ProjectMenu.Insert(Position, Added);
    Added.Enabled := False;
    Assert.AreEqual(Position, ProjectMenu.IndexOf(Added),
      'the item did not land where the position said');
  finally
    Added.Free;
  end;
end;

end.
