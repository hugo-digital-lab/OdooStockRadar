# Odoo Stock Radar - full removal (stops tray, deletes tasks + autostart entry)
$ErrorActionPreference = 'SilentlyContinue'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*OdooStockRadar*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
schtasks /Delete /TN "OdooStockRadar Tray" /F
schtasks /Delete /TN "OdooStockRadar Scan" /F
$run = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Microsoft\Windows\CurrentVersion\Run", $true)
$run.DeleteValue("OdooStockRadar")
$run.Close()
Write-Host "[OK] Removed. Data folder (data\) kept - delete it manually if you want."
