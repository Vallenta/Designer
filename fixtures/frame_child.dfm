object FrameChild: TFrameChild
  Left = 0
  Top = 0
  Width = 320
  Height = 160
  TabOrder = 0
  object TitleLabel: TLabel
    Left = 16
    Top = 16
    Width = 82
    Height = 15
    Caption = 'Frame contents'
  end
  object ActionButton: TButton
    Left = 16
    Top = 48
    Width = 120
    Height = 25
    Caption = 'Do something'
    TabOrder = 0
  end
  object HintEdit: TEdit
    Left = 16
    Top = 96
    Width = 240
    Height = 23
    TabOrder = 1
    Text = 'From the frame'
  end
end
