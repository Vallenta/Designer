object NonVisualForm: TNonVisualForm
  Left = 0
  Top = 0
  Caption = 'P1.3 Nonvisual On Form'
  ClientHeight = 160
  ClientWidth = 360
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object StatusLabel: TLabel
    Left = 24
    Top = 24
    Width = 19
    Height = 15
    Caption = 'Idle'
  end
  object StartButton: TButton
    Left = 24
    Top = 56
    Width = 96
    Height = 25
    Caption = 'Start'
    TabOrder = 0
  end
  object PollTimer: TTimer
    Interval = 250
    OnTimer = PollTimerTimer
    Left = 216
    Top = 40
  end
end
