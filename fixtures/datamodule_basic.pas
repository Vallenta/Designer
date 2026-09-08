unit datamodule_basic;

// Fixture companion. The root classifier reads the ancestor of the root class
// out of this unit, which is the whole reason it exists - nothing here is ever
// compiled or streamed.

interface

uses
  System.Classes,
  Vcl.ExtCtrls,
  Vcl.Dialogs;

type
  TBasicDataModule = class(TDataModule)
    PollTimer: TTimer;
    PictureDialog: TOpenDialog;
    procedure PollTimerTimer(Sender: TObject);
  end;

implementation

{$R *.dfm}

end.
