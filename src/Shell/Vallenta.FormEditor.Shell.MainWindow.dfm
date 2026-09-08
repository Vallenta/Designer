object MainDesignerForm: TMainDesignerForm
  Left = 0
  Top = 0
  Caption = 'Vallenta Designer'
  ClientHeight = 700
  ClientWidth = 1100
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Menu = MainMenu
  Position = poScreenCenter
  OnActivate = FormActivate
  OnClose = FormClose
  OnCloseQuery = FormCloseQuery
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  TextHeight = 15
  object MessagesSplitter: TSplitter
    Left = 0
    Top = 545
    Width = 1100
    Height = 5
    Cursor = crVSplit
    Align = alBottom
  end
  object PaletteSplitter: TSplitter
    Left = 180
    Top = 0
    Width = 5
    Height = 545
  end
  object InspectorSplitter: TSplitter
    Left = 795
    Top = 0
    Width = 5
    Height = 545
    Align = alRight
  end
  object MessagesZone: TPanel
    Left = 0
    Top = 550
    Width = 1100
    Height = 150
    Align = alBottom
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 0
    ExplicitTop = 542
    ExplicitWidth = 1098
  end
  object PaletteZone: TPanel
    Left = 0
    Top = 0
    Width = 180
    Height = 545
    Align = alLeft
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 1
    ExplicitHeight = 537
  end
  object InspectorZone: TPanel
    Left = 800
    Top = 0
    Width = 300
    Height = 545
    Align = alRight
    BevelOuter = bvNone
    ShowCaption = False
    TabOrder = 2
    ExplicitLeft = 798
    ExplicitHeight = 537
  end
  object DesignSurfaceBox: TScrollBox
    Left = 185
    Top = 0
    Width = 610
    Height = 545
    Align = alClient
    BorderStyle = bsNone
    Color = clAppWorkSpace
    ParentColor = False
    TabOrder = 3
    ExplicitWidth = 608
    ExplicitHeight = 537
  end
  object MainMenu: TMainMenu
    Left = 240
    Top = 16
    object FileMenu: TMenuItem
      Caption = '&File'
      object FileSaveItem: TMenuItem
        Action = SaveAction
      end
      object FileSeparator: TMenuItem
        Caption = '-'
      end
      object FileCloseItem: TMenuItem
        Action = CloseWindowAction
      end
    end
    object EditMenu: TMenuItem
      Caption = '&Edit'
      object EditUndoItem: TMenuItem
        Action = UndoAction
      end
      object EditRedoItem: TMenuItem
        Action = RedoAction
      end
      object EditClipboardSeparator: TMenuItem
        Caption = '-'
      end
      object EditCutItem: TMenuItem
        Action = CutAction
      end
      object EditCopyItem: TMenuItem
        Action = CopyAction
      end
      object EditPasteItem: TMenuItem
        Action = PasteAction
      end
      object EditSeparator: TMenuItem
        Caption = '-'
      end
      object EditBringToFrontItem: TMenuItem
        Action = BringToFrontAction
      end
      object EditSendToBackItem: TMenuItem
        Action = SendToBackAction
      end
      object EditOrderSeparator: TMenuItem
        Caption = '-'
      end
      object EditAlignItem: TMenuItem
        Action = AlignAction
      end
      object EditSizeItem: TMenuItem
        Action = SizeAction
      end
      object EditTabOrderItem: TMenuItem
        Action = TabOrderAction
      end
      object EditCreationOrderItem: TMenuItem
        Action = CreationOrderAction
      end
    end
    object ViewMenu: TMenuItem
      Caption = '&View'
      object ViewPaletteItem: TMenuItem
        Action = TogglePaletteAction
        AutoCheck = True
      end
      object ViewInspectorItem: TMenuItem
        Action = ToggleInspectorAction
        AutoCheck = True
      end
      object ViewMessagesItem: TMenuItem
        Action = ToggleMessagesAction
        AutoCheck = True
      end
    end
    object ToolsMenu: TMenuItem
      Caption = '&Tools'
      object ToolsPackagesItem: TMenuItem
        Action = PackagesAction
      end
    end
  end
  object ActionList: TActionList
    OnUpdate = ActionListUpdate
    Left = 320
    Top = 16
    object SaveAction: TAction
      Category = 'File'
      Caption = '&Save'
      ShortCut = 16467
      OnExecute = SaveActionExecute
    end
    object CloseWindowAction: TAction
      Category = 'File'
      Caption = '&Close'
      ShortCut = 16471
      OnExecute = CloseWindowActionExecute
    end
    object UndoAction: TAction
      Category = 'Edit'
      Caption = '&Undo'
      ShortCut = 16474
      OnExecute = UndoActionExecute
    end
    object RedoAction: TAction
      Category = 'Edit'
      Caption = '&Redo'
      ShortCut = 16473
      OnExecute = RedoActionExecute
    end
    object CutAction: TAction
      Category = 'Edit'
      Caption = 'Cu&t'
      ShortCut = 16472
      OnExecute = CutActionExecute
    end
    object CopyAction: TAction
      Category = 'Edit'
      Caption = '&Copy'
      ShortCut = 16451
      OnExecute = CopyActionExecute
    end
    object PasteAction: TAction
      Category = 'Edit'
      Caption = '&Paste'
      ShortCut = 16470
      OnExecute = PasteActionExecute
    end
    object BringToFrontAction: TAction
      Category = 'Edit'
      Caption = '&Bring to Front'
      OnExecute = BringToFrontActionExecute
    end
    object SendToBackAction: TAction
      Category = 'Edit'
      Caption = 'Sen&d to Back'
      OnExecute = SendToBackActionExecute
    end
    object AlignAction: TAction
      Category = 'Edit'
      Caption = '&Align...'
      OnExecute = AlignActionExecute
    end
    object SizeAction: TAction
      Category = 'Edit'
      Caption = 'S&ize...'
      OnExecute = SizeActionExecute
    end
    object TabOrderAction: TAction
      Category = 'Edit'
      Caption = '&Tab Order...'
      OnExecute = TabOrderActionExecute
    end
    object CreationOrderAction: TAction
      Category = 'Edit'
      Caption = 'Creation &Order (nonvisual)...'
      OnExecute = CreationOrderActionExecute
    end
    object TogglePaletteAction: TAction
      Category = 'View'
      Caption = '&Palette'
      OnExecute = TogglePaletteActionExecute
    end
    object ToggleInspectorAction: TAction
      Category = 'View'
      Caption = '&Object Inspector'
      OnExecute = ToggleInspectorActionExecute
    end
    object ToggleMessagesAction: TAction
      Category = 'View'
      Caption = '&Messages'
      OnExecute = ToggleMessagesActionExecute
    end
    object PackagesAction: TAction
      Category = 'Tools'
      Caption = '&Packages...'
      OnExecute = PackagesActionExecute
    end
  end
end
