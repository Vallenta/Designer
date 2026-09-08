object EventForm: TEventForm
  Left = 0
  Top = 0
  Caption = 'P00 Event Handlers'
  ClientHeight = 160
  ClientWidth = 320
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  OnClose = FormClose
  OnCreate = FormCreate
  TextHeight = 15
  object EventButton: TButton
    Left = 24
    Top = 24
    Width = 120
    Height = 25
    Caption = 'Wired button'
    TabOrder = 0
    OnClick = EventButtonClick
  end
  object EventEdit: TEdit
    Left = 24
    Top = 72
    Width = 200
    Height = 23
    TabOrder = 1
    Text = 'Wired edit'
    OnChange = EventEditChange
  end
end
