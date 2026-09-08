unit frame_child;

// Fixture companion. The root classifier reads the ancestor of the root class
// out of this unit, which is the whole reason it exists - nothing here is ever
// compiled or streamed. frame_host.dfm uses this frame, which is what makes it
// the fixture for inline frames.

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls;

type
  TFrameChild = class(TFrame)
    TitleLabel: TLabel;
    ActionButton: TButton;
    HintEdit: TEdit;
  end;

implementation

{$R *.dfm}

end.
