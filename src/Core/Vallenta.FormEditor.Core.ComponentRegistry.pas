// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Core.ComponentRegistry;

// Component classes offered on the component palette, from two sources: the
// table below, gated by BuiltInClassesActive and currently off, and classes
// contributed by loaded design packages. Package classes are registered for
// streaming by the package host, not here. The dynamic list is a unit-level
// array with no synchronization.
//
// A dynamic entry holds a class reference into a package module, so
// DropDynamicClasses must run before that package is unloaded.

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.StdCtrls,
  Vcl.ExtCtrls,
  Vcl.Dialogs;

type
  // Palette group of a built-in table entry.
  TPaletteGroupKind = (pgStandard, pgAdditional, pgSystem, pgWin32, pgDialogs);

  // One entry of the built-in component table.
  TDesignerClassEntry = record
    ComponentClass: TComponentClass;
    Group: TPaletteGroupKind;
  end;

  // A class contributed by a loaded package. Page is the palette page name
  // the package registered it under; PackagePath is the package file it was
  // loaded from.
  TDynamicClassEntry = record
    ComponentClass: TComponentClass;
    Page: string;
    PackagePath: string;
  end;

const
  // The built-in component table, its group captions, and its switch.

  // False because the loaded design packages register the standard
  // components themselves and one class must not come from two sources.
  BuiltInClassesActive = False;

  PaletteGroupCaptions: array [TPaletteGroupKind] of string = (
    'Standard', 'Additional', 'System', 'Win32', 'Dialogs');

  DesignerClasses: array [0 .. 12] of TDesignerClassEntry = (
    (ComponentClass: TButton; Group: pgStandard),
    (ComponentClass: TEdit; Group: pgStandard),
    (ComponentClass: TLabel; Group: pgStandard),
    (ComponentClass: TPanel; Group: pgStandard),
    (ComponentClass: TCheckBox; Group: pgStandard),
    (ComponentClass: TComboBox; Group: pgStandard),
    (ComponentClass: TMemo; Group: pgStandard),
    (ComponentClass: TGroupBox; Group: pgStandard),
    (ComponentClass: TImage; Group: pgAdditional),
    (ComponentClass: TTimer; Group: pgSystem),
    (ComponentClass: TImageList; Group: pgWin32),
    (ComponentClass: TOpenDialog; Group: pgDialogs),
    (ComponentClass: TSaveDialog; Group: pgDialogs));

// Registers the built-in table for streaming; no-op while BuiltInClassesActive
// is False.
procedure RegisterDesignerClasses;

// The class names this registry holds, comma-separated: the built-in table
// when active, then the dynamic entries in registration order.
function RegisteredClassNames: string;

// Adds a class contributed by a loaded package. Returns False and adds
// nothing when the class name is already held, matched case-insensitively.
function AddDynamicClass(AComponentClass: TComponentClass;
  const APage, APackagePath: string): Boolean;

// Classes contributed by loaded packages, in registration order. The result
// shares storage with the internal array and must not be modified.
function DynamicClasses: TArray<TDynamicClassEntry>;

// Clears the dynamic entries. Must run before the packages are unloaded; the
// streaming registration itself is removed by UnloadPackage.
procedure DropDynamicClasses;

implementation

uses
  System.SysUtils;

var
  Dynamic: TArray<TDynamicClassEntry>;

function IsClassNameTaken(const AClassName: string): Boolean;
var
  I: Integer;
begin
  if BuiltInClassesActive then
    for I := Low(DesignerClasses) to High(DesignerClasses) do
      if SameText(DesignerClasses[I].ComponentClass.ClassName, AClassName) then
        Exit(True);
  for I := 0 to High(Dynamic) do
    if SameText(Dynamic[I].ComponentClass.ClassName, AClassName) then
      Exit(True);
  Result := False;
end;

function AddDynamicClass(AComponentClass: TComponentClass;
  const APage, APackagePath: string): Boolean;
var
  Entry: TDynamicClassEntry;
begin
  Result := not IsClassNameTaken(AComponentClass.ClassName);
  if not Result then
    Exit;
  Entry.ComponentClass := AComponentClass;
  Entry.Page := APage;
  Entry.PackagePath := APackagePath;
  Dynamic := Dynamic + [Entry];
end;

function DynamicClasses: TArray<TDynamicClassEntry>;
begin
  Result := Dynamic;
end;

procedure DropDynamicClasses;
begin
  Dynamic := nil;
end;

procedure RegisterDesignerClasses;
var
  Classes: array of TPersistentClass;
  I: Integer;
begin
  if not BuiltInClassesActive then
    Exit;
  SetLength(Classes, Length(DesignerClasses));
  for I := Low(DesignerClasses) to High(DesignerClasses) do
    Classes[I - Low(DesignerClasses)] := DesignerClasses[I].ComponentClass;
  RegisterClasses(Classes);
end;

function RegisteredClassNames: string;
var
  I: Integer;

  procedure Append(const AClassName: string);
  begin
    if Result <> '' then
      Result := Result + ', ';
    Result := Result + AClassName;
  end;

begin
  Result := '';
  if BuiltInClassesActive then
    for I := Low(DesignerClasses) to High(DesignerClasses) do
      Append(DesignerClasses[I].ComponentClass.ClassName);
  for I := 0 to High(Dynamic) do
    Append(Dynamic[I].ComponentClass.ClassName);
end;

end.
