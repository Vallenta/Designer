object FrameHostForm: TFrameHostForm
  Left = 0
  Top = 0
  Caption = 'P2 Frame Host'
  ClientHeight = 300
  ClientWidth = 400
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object HostLabel: TLabel
    Left = 24
    Top = 16
    Width = 89
    Height = 15
    Caption = 'The frame below'
  end
  inline ChildFrame: TFrameChild
    Left = 24
    Top = 48
    Width = 320
    Height = 160
    TabOrder = 0
    ExplicitLeft = 24
    ExplicitTop = 48
    inherited ActionButton: TButton
      Caption = 'Overridden by the host'
    end
    inherited HintEdit: TEdit
      Text = 'Overridden by the host'
    end
  end
  object HostButton: TButton
    Left = 24
    Top = 232
    Width = 120
    Height = 25
    Caption = 'Host action'
    TabOrder = 1
  end
end
