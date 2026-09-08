inherited VfiGrandForm: TVfiGrand
  Caption = 'P2 Inheritance Grandchild'
  TextHeight = 15
  inherited BaseLabel: TLabel
    Width = 144
    Caption = 'Changed by the grandchild'
    ExplicitWidth = 144
  end
  inherited ChildEdit: TEdit
    Text = 'Changed a level down'
  end
  object GrandButton: TButton
    Left = 24
    Top = 160
    Width = 120
    Height = 25
    Caption = 'Grandchild action'
    TabOrder = 3
  end
end
