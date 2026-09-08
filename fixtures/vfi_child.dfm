inherited VfiChildForm: TVfiChild
  Caption = 'P2 Inheritance Child'
  TextHeight = 15
  inherited BaseButton: TButton
    Caption = 'Changed in the child'
  end
  object ChildEdit: TEdit
    Left = 24
    Top = 120
    Width = 240
    Height = 23
    TabOrder = 2
    Text = 'Added by the child'
  end
end
