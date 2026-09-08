// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Core.Settings;

// Release-dependent constants of this build: the registry root for user
// state below HKEY_CURRENT_USER, the digits in RAD Studio package file
// names, and the VCL style name applied at startup. All are selected from
// CompilerVersion, so the target release is fixed at build time. Nothing here
// reads or writes the registry; callers open the key SettingsKey returns.

interface

const
  // Release identity of this build, and the registry root derived from it.
  // IdeVersion is the version segment of the IDE registry key and of
  // %PUBLIC%\Documents\Embarcadero\Studio, e.g. '23.0' in
  // HKEY_CURRENT_USER\Software\Embarcadero\BDS\23.0.
{$IF CompilerVersion = 35.0}
  IdeVersion = '22.0';
{$ELSEIF CompilerVersion = 36.0}
  IdeVersion = '23.0';
{$ELSEIF CompilerVersion = 37.0}
  IdeVersion = '37.0';
{$ELSE}
  {$MESSAGE FATAL 'Unsupported Delphi release: add its IdeVersion and PackageSuffix here.'}
{$IFEND}

  // The LIBSUFFIX RAD Studio gives its packages for this release, e.g. '370'
  // in 'rtl370.bpl'. Not derivable from IdeVersion.
{$IF CompilerVersion = 35.0}
  PackageSuffix = '280';
{$ELSEIF CompilerVersion = 36.0}
  PackageSuffix = '290';
{$ELSE}
  PackageSuffix = '370';
{$IFEND}

  // VCL style applied at startup. Must match the style name inside the .vsf
  // that VallentaDesigner.dproj links through Custom_Styles, selected by
  // DesignerStyleName in VallentaDesigner.Common.props.
{$IF CompilerVersion >= 37.0}
  DesignerStyle = 'Windows Modern';
{$ELSE}
  DesignerStyle = 'Windows10';
{$IFEND}

  // Path below HKEY_CURRENT_USER; the value carries no root key.
  SettingsRoot = 'Software\VallentaStudio\Designer\' + IdeVersion;

// Path of a subkey of SettingsRoot below HKEY_CURRENT_USER, e.g.
// SettingsKey('Palette'); no trailing separator.
function SettingsKey(const ASubKey: string): string;

implementation

function SettingsKey(const ASubKey: string): string;
begin
  Result := SettingsRoot + '\' + ASubKey;
end;

end.
