unit vfi_child;

// Fixture companion. The ancestor chain reads the class a root descends from
// out of this unit, which is the whole reason it exists - nothing here is ever
// compiled or streamed. The ancestor it names lives in vfi_base.pas.

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  vfi_base;

type
  TVfiChild = class(TVfiBase)
    ChildEdit: TEdit;
  end;

implementation

{$R *.dfm}

end.
