object BasicDataModule: TBasicDataModule
  Height = 240
  Width = 320
  object PollTimer: TTimer
    Interval = 250
    OnTimer = PollTimerTimer
    Left = 48
    Top = 32
  end
  object PictureDialog: TOpenDialog
    Filter = 'Images|*.png;*.bmp'
    Left = 152
    Top = 32
  end
end
