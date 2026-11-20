' OdooStockRadar resume launcher (clears pause flag and starts tray)
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir_ = fso.GetParentFolderName(WScript.ScriptFullName)
If fso.FileExists(dir_ & "\data\.paused") Then
  fso.DeleteFile dir_ & "\data\.paused"
End If
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir_ & "\OdooStockRadar.ps1"" -Resume", 0, False
