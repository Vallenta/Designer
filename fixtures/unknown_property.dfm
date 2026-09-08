object UnknownPropForm: TUnknownPropForm
  Left = 0
  Top = 0
  Caption = 'P00 Unknown Property'
  ClientHeight = 140
  ClientWidth = 320
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  SomeUnknownFormOption = True
  TextHeight = 15
  object SurvivorButton: TButton
    Left = 24
    Top = 24
    Width = 160
    Height = 25
    BogusFutureProperty = 42
    Caption = 'I still loaded'
    TabOrder = 0
  end
end
