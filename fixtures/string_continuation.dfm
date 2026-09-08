object StringForm: TStringForm
  Left = 0
  Top = 0
  Caption = 'P00 String Continuation'
  ClientHeight = 160
  ClientWidth = 460
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object LongLabel: TLabel
    Left = 16
    Top = 16
    Width = 679
    Height = 15
    Caption = 
      'This caption was written across multiple source lines by the fix' +
      'ture author, mirroring how the IDE wraps long strings in a DFM f' +
      'ile.'
  end
  object UmlautLabel: TLabel
    Left = 16
    Top = 48
    Width = 161
    Height = 15
    Caption = 'Umlauts and symbols: '#196#214#220#223' '#8364
  end
  object MixedEdit: TEdit
    Left = 16
    Top = 80
    Width = 320
    Height = 23
    TabOrder = 0
    Text = 'Line one'#13#10'Line two (control chars inside one string)'
  end
end
