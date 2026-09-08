object TypeRoundTripForm: TTypeRoundTripForm
  Left = 0
  Top = 0
  Caption = 'P0 Value Types'
  ClientHeight = 280
  ClientWidth = 420
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  TextHeight = 15
  object NameLabel: TLabel
    Left = 16
    Top = 19
    Width = 60
    Height = 15
    AutoSize = False
    Caption = '&Name'
    FocusControl = NameEdit
  end
  object NameEdit: TEdit
    Left = 88
    Top = 16
    Width = 200
    Height = 23
    TabOrder = 0
    Text = 'Round trip'
  end
  object KindCombo: TComboBox
    Left = 88
    Top = 48
    Width = 200
    Height = 23
    ItemIndex = 1
    TabOrder = 1
    Text = 'Second'
    Items.Strings = (
      'First'
      'Second'
      'Third')
  end
  object NotesMemo: TMemo
    Left = 88
    Top = 80
    Width = 200
    Height = 60
    Lines.Strings = (
      'First line'
      'Second line')
    TabOrder = 2
  end
  object OptionsGroup: TGroupBox
    Left = 16
    Top = 152
    Width = 272
    Height = 105
    Caption = 'Options'
    TabOrder = 3
    object EnabledCheck: TCheckBox
      Left = 16
      Top = 24
      Width = 97
      Height = 17
      Caption = 'Enabled'
      Checked = True
      State = cbChecked
      TabOrder = 0
    end
    object GrayedCheck: TCheckBox
      Left = 16
      Top = 47
      Width = 97
      Height = 17
      AllowGrayed = True
      Caption = 'Grayed'
      State = cbGrayed
      TabOrder = 1
    end
  end
end
