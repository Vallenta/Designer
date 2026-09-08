// VallentaDesigner - standalone DFM editor for form files.
// Part of Vallenta Studio, professional developer tooling for Object Pascal.
// Copyright (c) 2026 Michael Stagge
// SPDX-License-Identifier: MIT
// Released under the MIT license; see the LICENSE file in the project root.

unit Vallenta.FormEditor.Tests.DesignerDiscovery;

// How a component package reaches the designer from a component it holds:
// System.Classes.FindRootDesigner walks the owner chain to the ownerless
// root and queries it for IDesignerNotify, returning nil when a component on
// the way is not in csDesigning. TCustomForm routes that query to its
// designer hook; packages cast the result to DesignIntf.IDesigner.
//
// One case calls BeginDesignerSession, which loads the packages configured
// under the designer's settings key together with the hosted form designer
// package; they stay loaded for the rest of the process, and the runner
// unloads them after the run.

interface

uses
  DUnitX.TestFramework;

type
  // Designer lookup from a component of a designed document, and the active
  // component designer of a started designer session.
  [TestFixture]
  TDesignerDiscoveryTests = class
  public
    [Test]
    procedure FindRootDesignerReachesTheDesignerOfADesignedDocument;
    [Test]
    procedure TheFoundDesignerAnswersTheDesignIntfDesigner;
    [Test]
    procedure TheHostedSessionAnswersAnActiveComponentDesigner;
  end;

implementation

uses
  System.Classes,
  System.SysUtils,
  DesignIntf,
  ComponentDesigner,
  Vallenta.FormEditor.Core.Log,
  Vallenta.FormEditor.Streaming.RootClassifier,
  Vallenta.FormEditor.Streaming.Loader,
  Vallenta.FormEditor.Surface.FormDesigner,
  Vallenta.FormEditor.Tests.Environment;

type
  TComponentAccess = class(TComponent);

  // One designed document built in code rather than from a form file: a root
  // form with a designer attached and one owned child. CreateDesignDocument
  // leaves a drForm root out of design mode, so Build sets csDesigning on it;
  // FindRootDesigner returns nil at the first component of the owner chain
  // that lacks that state.
  TDiscoverySession = record
    Document: TDesignDocument;
    Log: TDesignLog;
    Designer: TFormDesigner;
    Child: TComponent;
    procedure Build;
    procedure Release;
  end;

procedure TDiscoverySession.Build;
begin
  Log := TDesignLog.Create;
  Document := CreateDesignDocument(drForm);
  Designer := TFormDesigner.Create(Document.HostForm, Document.Root, Log);
  Child := TComponent.Create(Document.Root);
  TComponentAccess(Document.Root).SetDesigning(True);
end;

procedure TDiscoverySession.Release;
begin
  FreeAndNil(Designer);
  FreeDesignDocument(Document);
  FreeAndNil(Log);
end;

{ TDesignerDiscoveryTests }

procedure TDesignerDiscoveryTests.FindRootDesignerReachesTheDesignerOfADesignedDocument;
var
  Session: TDiscoverySession;
  Found: IDesignerNotify;
begin
  Session.Build;
  try
    Found := FindRootDesigner(Session.Child);
    Assert.IsNotNull(Found,
      'the root of a designed document named no designer');
  finally
    // Cleared before the designer is freed: TFormDesigner is not reference
    // counted, so the scope-exit _Release would run on a freed object.
    Found := nil;
    Session.Release;
  end;
end;

procedure TDesignerDiscoveryTests.TheFoundDesignerAnswersTheDesignIntfDesigner;
var
  Session: TDiscoverySession;
  Found: IDesignerNotify;
  Host: IDesigner;
begin
  Session.Build;
  try
    Found := FindRootDesigner(Session.Child);
    Host := Found as IDesigner;
    Assert.IsNotNull(Host,
      'the designer found over the root answered no DesignIntf.IDesigner');
  finally
    Host := nil;
    Found := nil;
    Session.Release;
  end;
end;

// Editor dialogs a package opens read ComponentDesigner.ActiveDesigner and
// its environment before they show. No designer window here activates a root,
// so BeginDesignerSession activates the .dfm component designer with no root.
procedure TDesignerDiscoveryTests.TheHostedSessionAnswersAnActiveComponentDesigner;
begin
  BeginDesignerSession;
  Assert.IsNotNull(ActiveDesigner,
    'the hosted session answers no active component designer');
  Assert.IsNotNull(ActiveDesigner.Environment,
    'the active component designer carries no environment');
end;

initialization
  TDUnitX.RegisterTestFixture(TDesignerDiscoveryTests);

end.
