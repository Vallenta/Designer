unit vfi_grand;

// Fixture companion. A third level, so that the chain has to be followed more
// than one step and the files streamed base-most first - an order two levels
// alone would not prove. Nothing here is ever compiled or streamed.

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  vfi_child;

type
  TVfiGrand = class(TVfiChild)
    GrandButton: TButton;
  end;

implementation

{$R *.dfm}

end.
