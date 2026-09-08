object InspectorFrame: TInspectorFrame
  Left = 0
  Top = 0
  Width = 300
  Height = 520
  TabOrder = 0
  object TreeSplitter: TSplitter
    Left = 0
    Top = 204
    Width = 300
    Height = 5
    Cursor = crVSplit
    Align = alTop
  end
  object HeaderPanel: TPanel
    Left = 0
    Top = 0
    Width = 300
    Height = 24
    Align = alTop
    Alignment = taLeftJustify
    BevelOuter = bvNone
    Caption = '  Object Inspector'
    TabOrder = 0
  end
  object ComponentTree: TTreeView
    Left = 0
    Top = 24
    Width = 300
    Height = 180
    Align = alTop
    BorderStyle = bsNone
    HideSelection = False
    Indent = 19
    ReadOnly = True
    TabOrder = 1
    OnChange = ComponentTreeChange
    OnContextPopup = ComponentTreeContextPopup
  end
  object Tabs: TPageControl
    Left = 0
    Top = 209
    Width = 300
    Height = 311
    ActivePage = PropertiesTab
    Align = alClient
    TabOrder = 2
    object PropertiesTab: TTabSheet
      Caption = 'Properties'
    end
    object EventsTab: TTabSheet
      Caption = 'Events'
      ImageIndex = 1
    end
  end
end
