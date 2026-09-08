object FrameNestingForm: TFrameNestingForm
  Left = 0
  Top = 0
  Caption = 'P2 Frame Inside A Frame'
  ClientHeight = 320
  ClientWidth = 400
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object HostLabel: TLabel
    Left = 24
    Top = 8
    Width = 89
    Height = 15
    Caption = 'The frame below'
  end
  inline OuterFrame: TFrameOuter
    Left = 24
    Top = 32
    Width = 360
    Height = 240
    TabOrder = 0
    ExplicitLeft = 24
    ExplicitTop = 32
    inherited OuterLabel: TLabel
      Caption = 'Overridden by the host'
    end
  end
  object HostButton: TButton
    Left = 24
    Top = 280
    Width = 120
    Height = 25
    Caption = 'Host action'
    TabOrder = 1
  end
end
