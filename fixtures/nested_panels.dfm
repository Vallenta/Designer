object NestedForm: TNestedForm
  Left = 0
  Top = 0
  Caption = 'P00 Nested Panels'
  ClientHeight = 300
  ClientWidth = 480
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
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
  object ClientPanel: TPanel
    Left = 0
    Top = 60
    Width = 480
    Height = 240
    Align = alClient
    BevelOuter = bvNone
    TabOrder = 1
    object SidePanel: TPanel
      Left = 320
      Top = 0
      Width = 160
      Height = 240
      Align = alRight
      TabOrder = 0
      object SideButton: TButton
        Left = 16
        Top = 16
        Width = 120
        Height = 25
        Caption = 'Side action'
        TabOrder = 0
      end
    end
    object InnerEdit: TEdit
      Left = 16
      Top = 16
      Width = 240
      Height = 23
      TabOrder = 1
      Text = 'Inside alClient panel'
    end
  end
end
