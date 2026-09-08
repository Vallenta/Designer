// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.InspectorRows;

// Which editing control the inspector offers for a property row: the pick
// list paValueList fills, or the ellipsis button paDialog - or
// paCustomDropDown without paValueList - shows. The designer session starts
// once per process, on the first case to run: it registers the standard
// property editors in-process and loads the installed design-time packages.
//
// Editor attributes reach the rows only while the HostedEditors setting is on;
// otherwise TPropertyModel builds the rows from type information, where
// HasDialog is False for every row.

interface

uses
  DUnitX.TestFramework;

type
  // The editing tool a row reports for the attributes of its editor.
  [TestFixture]
  TInspectorRowTests = class
  public
    [Test]
    procedure ACustomDropDownRowIsEditedThroughItsPickList;
    [Test]
    procedure ADialogRowIsEditedThroughItsDialog;
  end;

implementation

uses
  System.Classes,
  System.SysUtils,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.ExtCtrls,
  DesignIntf,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Streaming.RootClassifier,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Surface.FormDesigner,
  Vallenta.FormEditor.Inspector.PropertyModel,
  Vallenta.FormEditor.Tests.Environment;

type
  TInspectorSession = record
    Document: TDesignDocument;
    Log: TDesignLog;
    Designer: TFormDesigner;
    Control: TPanel;
    Model: TPropertyModel;
    procedure Build;
    procedure Release;
    function RowNamed(const AName: string): TPropertyRow;
  end;

procedure TInspectorSession.Build;
begin
  BeginDesignerSession;
  Log := TDesignLog.Create;
  Document := CreateDesignDocument(drForm);
  Designer := TFormDesigner.Create(Document.HostForm, Document.Root, Log);
  Control := TPanel.Create(Document.Root);
  Control.Parent := Document.HostForm;
  Control.SetBounds(10, 10, 100, 50);
  Model := TPropertyModel.Create;
  Model.Log := Log;
  Model.BuildMany([TPersistent(Control)], Document.Root, Designer.EventMap,
    False, Designer.HostDesigner);
end;

procedure TInspectorSession.Release;
begin
  FreeAndNil(Model);
  FreeAndNil(Designer);
  FreeDesignDocument(Document);
  FreeAndNil(Log);
end;

function TInspectorSession.RowNamed(const AName: string): TPropertyRow;
var
  Row: TPropertyRow;
begin
  Result := nil;
  for Row in Model.Rows do
    if SameText(Row.Name, AName) then
      Exit(Row);
end;

{ TInspectorRowTests }

// Pins that the Align row offers a pick list and reports no dialog. The rule
// that separates them - paCustomDropDown without paValueList means an
// ellipsis - is exercised only when a loaded design-time package registers an
// Align editor reporting both attributes; the default TEnumProperty reports
// paValueList without paCustomDropDown.
procedure TInspectorRowTests.ACustomDropDownRowIsEditedThroughItsPickList;
var
  Session: TInspectorSession;
  Row: TPropertyRow;
begin
  Session.Build;
  try
    Row := Session.RowNamed('Align');
    Assert.IsNotNull(Row, 'the model has no Align row');
    Assert.IsTrue(Length(Row.PickList) > 0, 'the Align row offers no choices');
    Assert.IsFalse(Row.HasDialog,
      'the Align row asks for an ellipsis button beside its pick list');
  finally
    Session.Release;
  end;
end;

// Rows built from type information report HasDialog False, so a run whose
// rows do not come from the hosted editors fails here while
// ACustomDropDownRowIsEditedThroughItsPickList still passes. Font's paDialog
// comes from TFontProperty, which InstallStandardEditors registers in-process
// rather than a design-time package.
procedure TInspectorRowTests.ADialogRowIsEditedThroughItsDialog;
var
  Session: TInspectorSession;
  Row: TPropertyRow;
begin
  Session.Build;
  try
    Row := Session.RowNamed('Font');
    Assert.IsNotNull(Row, 'the model has no Font row');
    Assert.IsTrue(Row.HasDialog, 'the Font row asks for no dialog');
  finally
    Session.Release;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TInspectorRowTests);

end.
