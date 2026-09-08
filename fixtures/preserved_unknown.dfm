object PreservedForm: TPreservedForm
  Left = 0
  Top = 0
  Caption = 'P2 Preserved Unknowns'
  ClientHeight = 300
  ClientWidth = 480
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  SomeUnknownFormOption = True
  TextHeight = 15
  object TopPanel: TPanel
    Left = 0
    Top = 0
    Width = 480
    Height = 60
    Align = alTop
    BevelOuter = bvLowered
    TabOrder = 0
    object TitleLabel: TLabel
      Left = 16
      Top = 20
      Width = 109
      Height = 15
      Caption = 'Nested layout fixture'
    end
  end
  object FancyGrid1: TFancyGrid
    Left = 16
    Top = 72
    Width = 240
    Height = 120
    Columns = <
      item
        Caption = 'One'
        Width = 40
      end
      item
        Caption = 'Two'
        Options = [goEdit, goSort]
      end>
    Hint = 
      'a hint long enough that the writer splits it over more than one ' +
      'written line'#13#10'and carrying character codes as well '#8364
    Layout = (
      'alpha'
      'beta')
    Glyph.Data = {0A0000004142434445464748494A}
    TabOrder = 1
    object FancyColumn1: TFancyColumn
      Caption = 'Kept as found'
      Width = 80
    end
  end
  object ClientPanel: TPanel
    Left = 0
    Top = 200
    Width = 480
    Height = 100
    Align = alBottom
    BevelOuter = bvNone
    TabOrder = 2
    object SideButton: TButton
      Left = 16
      Top = 16
      Width = 120
      Height = 25
      MysteryList = (
        'one'
        'two')
      Caption = 'Side action'
      TabOrder = 0
    end
  end
  object MysteryTimer1: TMysteryTimer
    Left = 320
    Top = 216
  end
end
