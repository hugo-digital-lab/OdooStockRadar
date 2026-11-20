' Odoo Stock Radar - tray resident app launcher (hidden, no console, do not wait)
' ASCII only: WSH reads .vbs as ANSI
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\OdooStockRadar.ps1""", 0, False
