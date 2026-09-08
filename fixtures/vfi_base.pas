unit vfi_base;

// Fixture companion. The ancestor chain reads the class a root descends from
// out of this unit, which is the whole reason it exists - nothing here is ever
// compiled or streamed. vfi_child descends from this one.

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls;

type
  TVfiBase = class(TForm)
    BaseButton: TButton;
    BaseEdit: TEdit;
    BaseLabel: TLabel;
  end;

implementation

{$R *.dfm}

end.
