object MessagesFrame: TMessagesFrame
  Left = 0
  Top = 0
  Width = 900
  Height = 150
  TabOrder = 0
  object HeaderPanel: TPanel
    Left = 0
    Top = 0
    Width = 900
    Height = 24
    Align = alTop
    Alignment = taLeftJustify
    BevelOuter = bvNone
    Caption = '  Messages'
    TabOrder = 0
  end
  object LogList: TListBox
    Left = 0
    Top = 24
    Width = 900
    Height = 126
    Style = lbOwnerDrawFixed
    Align = alClient
    BorderStyle = bsNone
    ItemHeight = 17
    PopupMenu = LogMenu
    TabOrder = 1
    OnDrawItem = LogListDrawItem
  end
  object LogMenu: TPopupMenu
    Left = 800
    Top = 48
    object CopyItem: TMenuItem
      Caption = '&Copy all'
      OnClick = CopyItemClick
    end
    object ClearItem: TMenuItem
      Caption = 'C&lear'
      OnClick = ClearItemClick
    end
  end
end
