// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Palette.Favourites;

// Stores the palette's favourite pages and component classes as registry
// value names under two subkeys below HKEY_CURRENT_USER. Both are read once
// at construction and held in memory; a toggle changes the memory first and
// then writes or deletes the single value. Names are matched as plain text
// and never resolved against the component registry.
//
// No synchronization: one instance must be used from a single thread.

interface

uses
  System.Classes,
  Vallenta.FormEditor.Palette.Model;

type
  // Favourite pages and component classes. A page mark applies to every item
  // shown under that caption, including items added to the page later.
  TPaletteFavourites = class
  private
    FKey: string;
    FGroups: TStringList;
    FItems: TStringList;
    FLastError: string;
    procedure ReadNames(const ASubKey: string; ANames: TStringList);
    function Toggle(ANames: TStringList; const ASubKey,
      AName: string): Boolean;
  public
    // AKey is the path below HKEY_CURRENT_USER holding the two subkeys.
    // Construction only reads; the key is created by the first toggle.
    constructor Create(const AKey: string);
    destructor Destroy; override;
    // True when the page caption is marked; compared case-insensitively.
    function HasGroup(const ACaption: string): Boolean;
    // True when the class name is marked on its own, independent of any page
    // mark; compared case-insensitively.
    function HasItem(const AClassName: string): Boolean;
    // True when the class of AItem is marked, or AGroupCaption names a marked
    // page. AGroupCaption is the caption of the page AItem is shown under.
    function Holds(AItem: TPaletteItem; const AGroupCaption: string): Boolean;
    // Marks or unmarks the page, writing or deleting one registry value;
    // returns True when the page is now marked.
    function ToggleGroup(const ACaption: string): Boolean;
    // Marks or unmarks the component class, writing or deleting one registry
    // value; returns True when the class is now marked.
    function ToggleItem(const AClassName: string): Boolean;
    // Message of the most recent failed registry access, empty otherwise.
    // Every toggle clears it first; a failed write is not rolled back in the
    // in-memory lists, which are re-read only at construction.
    property LastError: string read FLastError;
  end;

implementation

uses
  Winapi.Windows,
  System.SysUtils,
  System.Win.Registry;

const
  // Registry subkeys below the key passed to Create.
  GroupsSubKey = 'FavouriteGroups';
  ItemsSubKey = 'FavouriteItems';
  // Data written with every mark; only the value name is ever read back.
  MarkValue = 1;

constructor TPaletteFavourites.Create(const AKey: string);
begin
  inherited Create;
  FKey := AKey;
  FGroups := TStringList.Create;
  FItems := TStringList.Create;
  FGroups.CaseSensitive := False;
  FItems.CaseSensitive := False;
  ReadNames(GroupsSubKey, FGroups);
  ReadNames(ItemsSubKey, FItems);
end;

destructor TPaletteFavourites.Destroy;
begin
  FItems.Free;
  FGroups.Free;
  inherited Destroy;
end;

// Reading must not pass CanCreate to OpenKey: creating the key here would
// leave a registry tree behind for an instance that marks nothing.
procedure TPaletteFavourites.ReadNames(const ASubKey: string;
  ANames: TStringList);
var
  Registry: TRegistry;
begin
  ANames.Clear;
  try
    Registry := TRegistry.Create(KEY_READ);
    try
      Registry.RootKey := HKEY_CURRENT_USER;
      if Registry.OpenKeyReadOnly(FKey + '\' + ASubKey) then
        Registry.GetValueNames(ANames);
    finally
      Registry.Free;
    end;
  except
    on E: Exception do
      FLastError := E.Message;
  end;
end;

function TPaletteFavourites.Toggle(ANames: TStringList; const ASubKey,
  AName: string): Boolean;
var
  Registry: TRegistry;
  Index: Integer;
begin
  FLastError := '';
  Index := ANames.IndexOf(AName);
  Result := Index < 0;
  if Result then
    ANames.Add(AName)
  else
    ANames.Delete(Index);
  try
    Registry := TRegistry.Create(KEY_READ or KEY_WRITE);
    try
      Registry.RootKey := HKEY_CURRENT_USER;
      if not Registry.OpenKey(FKey + '\' + ASubKey, True) then
        FLastError := Format('cannot open HKEY_CURRENT_USER\%s\%s',
          [FKey, ASubKey])
      else if Result then
        Registry.WriteInteger(AName, MarkValue)
      else if Registry.ValueExists(AName) then
        Registry.DeleteValue(AName);
    finally
      Registry.Free;
    end;
  except
    on E: Exception do
      FLastError := E.Message;
  end;
end;

function TPaletteFavourites.HasGroup(const ACaption: string): Boolean;
begin
  Result := FGroups.IndexOf(ACaption) >= 0;
end;

function TPaletteFavourites.HasItem(const AClassName: string): Boolean;
begin
  Result := FItems.IndexOf(AClassName) >= 0;
end;

function TPaletteFavourites.Holds(AItem: TPaletteItem;
  const AGroupCaption: string): Boolean;
begin
  Result := HasGroup(AGroupCaption) or HasItem(AItem.ComponentClass.ClassName);
end;

function TPaletteFavourites.ToggleGroup(const ACaption: string): Boolean;
begin
  Result := Toggle(FGroups, GroupsSubKey, ACaption);
end;

function TPaletteFavourites.ToggleItem(const AClassName: string): Boolean;
begin
  Result := Toggle(FItems, ItemsSubKey, AClassName);
end;

end.
