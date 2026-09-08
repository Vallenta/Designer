object VfiBaseForm: TVfiBase
  Left = 0
  Top = 0
  Caption = 'P2 Inheritance Base'
  ClientHeight = 240
  ClientWidth = 400
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object BaseLabel: TLabel
    Left = 24
    Top = 16
    Width = 75
    Height = 15
    Caption = 'From the base'
  end
  object BaseButton: TButton
    Left = 24
    Top = 40
    Width = 120
    Height = 25
    Caption = 'Base action'
    TabOrder = 0
  end
  object BaseEdit: TEdit
    Left = 24
    Top = 80
    Width = 240
    Height = 23
    TabOrder = 1
    Text = 'Base text'
  end
end
