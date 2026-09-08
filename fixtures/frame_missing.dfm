object FrameMissingForm: TFrameMissingForm
  Left = 0
  Top = 0
  Caption = 'P2 Frame Without Its File'
  ClientHeight = 240
  ClientWidth = 400
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object HostEdit: TEdit
    Left = 24
    Top = 16
    Width = 240
    Height = 23
    TabOrder = 0
    Text = 'Beside a frame nothing declares'
  end
  inline GhostFrame: TFrameGhost
    Left = 24
    Top = 56
    Width = 320
    Height = 120
    TabOrder = 1
    ExplicitLeft = 24
    ExplicitTop = 56
    inherited GhostButton: TButton
      Caption = 'Kept as found'
    end
  end
  object HostButton: TButton
    Left = 24
    Top = 192
    Width = 120
    Height = 25
    Caption = 'Host action'
    TabOrder = 2
  end
end
