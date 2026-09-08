object EventRoundTripForm: TEventRoundTripForm
  Left = 0
  Top = 0
  Caption = 'P0 Event Round Trip'
  ClientHeight = 200
  ClientWidth = 360
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnClose = FormClose
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  TextHeight = 15
  object SharedButtonA: TButton
    Left = 24
    Top = 24
    Width = 120
    Height = 25
    Caption = 'Shared A'
    TabOrder = 0
    OnClick = SharedButtonClick
  end
  object SharedButtonB: TButton
    Left = 168
    Top = 24
    Width = 120
    Height = 25
    Caption = 'Shared B'
    TabOrder = 1
    OnClick = SharedButtonClick
  end
  object WiredEdit: TEdit
    Left = 24
    Top = 72
    Width = 264
    Height = 23
    TabOrder = 2
    Text = 'Wired edit'
    OnChange = WiredEditChange
    OnKeyPress = WiredEditKeyPress
  end
end
