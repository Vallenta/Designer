object Form1: TForm1
  Left = 0
  Top = 0
  Caption = 'P00 Basic Form'
  ClientHeight = 220
  ClientWidth = 360
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  DesignSize = (
    360
    220)
  TextHeight = 15
  object Button1: TButton
    Left = 24
    Top = 24
    Width = 120
    Height = 25
    Caption = 'Click me'
    TabOrder = 0
  end
  object Edit1: TEdit
    Left = 24
    Top = 72
    Width = 240
    Height = 23
    Anchors = [akLeft, akTop, akRight]
    TabOrder = 1
    Text = 'Hello DFM'
  end
  object Memo1: TMemo
    Left = 24
    Top = 104
    Width = 185
    Height = 89
    Lines.Strings = (
      'Memo1'
      'Memo2')
    TabOrder = 2
  end
end
