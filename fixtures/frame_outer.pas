unit frame_outer;

// Fixture companion. A frame that uses a frame of its own, which the designer
// does not take apart - frame_nesting.dfm uses this one and keeps it verbatim
// instead. Nothing here is ever compiled or streamed.

interface

uses
  System.Classes,
  Vcl.Controls,
  Vcl.Forms,
  Vcl.StdCtrls,
  frame_child;

type
  TFrameOuter = class(TFrame)
    OuterLabel: TLabel;
    InnerFrame: TFrameChild;
  end;

implementation

{$R *.dfm}

end.
