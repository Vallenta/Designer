object PicaForm: TPicaForm
  Left = 0
  Top = 0
  Caption = 'P3.1 Package Components'
  ClientHeight = 220
  ClientWidth = 420
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object PicaCombo: THandyComboBox
    Left = 24
    Top = 24
    Width = 180
    Height = 23
    Sorted = True
    TabOrder = 0
    ID = -1
    OnMouseDown = PicaComboMouseDown
  end
  object PicaList: TSortListView
    Left = 24
    Top = 64
    Width = 372
    Height = 130
    Columns = <>
    ReadOnly = True
    TabOrder = 1
    ViewStyle = vsReport
    SortModes = <>
    HatSumme = True
  end
  object CloseButton: TButton
    Left = 320
    Top = 24
    Width = 76
    Height = 25
    Caption = 'Close'
    TabOrder = 2
  end
end
