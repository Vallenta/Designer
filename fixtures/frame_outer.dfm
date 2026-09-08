object FrameOuter: TFrameOuter
  Left = 0
  Top = 0
  Width = 360
  Height = 240
  TabOrder = 0
  object OuterLabel: TLabel
    Left = 16
    Top = 8
    Width = 64
    Height = 15
    Caption = 'Outer frame'
  end
  inline InnerFrame: TFrameChild
    Left = 16
    Top = 32
    TabOrder = 0
    ExplicitLeft = 16
    ExplicitTop = 32
    inherited ActionButton: TButton
      Caption = 'Inner action'
    end
  end
end
