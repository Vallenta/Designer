unit frame_basic;

// Fixture companion. The root classifier reads the ancestor of the root class
// out of this unit, which is the whole reason it exists - nothing here is ever
// compiled or streamed.

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls;

type
  TBasicFrame = class(TFrame)
    CaptionLabel: TLabel;
    ActionButton: TButton;
  end;

implementation

{$R *.dfm}

end.
