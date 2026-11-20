# Odoo Stock Radar - full removal (stops tray, deletes tasks + autostart entry)
$ErrorActionPreference = 'SilentlyContinue'
# 殺托盤/掃描程序（排除自己——remove.ps1 的命令列也含 OdooStockRadar 字樣）
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*OdooStockRadar.ps1*" -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
# 刪排程（含 v1.1.2 的子資料夾備援版本）
foreach ($tn in @("OdooStockRadar Tray", "OdooStockRadar Scan", "OdooStockRadar\OdooStockRadar Tray", "OdooStockRadar\OdooStockRadar Scan")) {
    schtasks /Delete /TN "$tn" /F 2>&1 | Out-Null
}
# 刪開機自啟
try {
    $run = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Microsoft\Windows\CurrentVersion\Run", $true)
    $run.DeleteValue("OdooStockRadar")
    $run.Close()
} catch { }
Write-Host "[OK] Removed: tray stopped, scheduled tasks + autostart deleted."
Write-Host "Data folder (data\) kept - delete the whole folder manually if you want."
