object TeeForm: TTeeForm
  Left = 0
  Top = 0
  Cursor = crCross
  Caption = 'TeeChart Package Test'
  ClientHeight = 300
  ClientWidth = 520
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object FormChart: TChart
    Left = 16
    Top = 16
    Width = 488
    Height = 220
    Title.Text.Strings = (
      'Quarterly totals')
    TabOrder = 0
    OnClick = FormChartClick
    DefaultCanvas = 'TGDIPlusCanvas'
    ColorPaletteIndex = 13
  end
  object CloseButton: TButton
    Left = 428
    Top = 252
    Width = 76
    Height = 25
    Caption = 'Close'
    TabOrder = 1
  end
  object ButtonPen1: TButtonPen
    Left = 112
    Top = 248
    Caption = 'ButtonPen1'
    TabOrder = 2
  end
  object OpenDialog1: TOpenDialog
    Left = 40
    Top = 248
  end
end
