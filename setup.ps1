# Odoo Stock Radar - user-level setup (no admin required)
# Registers: startup (HKCU Run) + scheduled tasks (scan every 30 min, tray reviver every 5 min)
# NOTE: install to a path WITHOUT spaces (scheduled task quoting limitation)
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
if ($dir -match ' ') { Write-Host "[!] Install path contains spaces - please use a path like D:\OdooStockRadar"; exit 1 }
if (-not (Test-Path (Join-Path $dir 'config.json'))) {
    Copy-Item (Join-Path $dir 'config.sample.json') (Join-Path $dir 'config.json')
    Write-Host "[!] config.json created from sample. Edit it (Odoo URL / db / user / key), then re-run setup.ps1."
    exit 1
}
if (-not (Test-Path (Join-Path $dir 'data'))) { New-Item -ItemType Directory -Path (Join-Path $dir 'data') | Out-Null }

schtasks /Create /F /TN "OdooStockRadar Tray" /TR "wscript.exe $dir\start_tray.vbs" /SC MINUTE /MO 5 | Out-Null
schtasks /Create /F /TN "OdooStockRadar Scan" /TR "wscript.exe $dir\start_scan.vbs" /SC MINUTE /MO 30 | Out-Null

$run = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Microsoft\Windows\CurrentVersion\Run", $true)
$run.SetValue("OdooStockRadar", "wscript.exe $dir\start_tray.vbs")
$run.Close()

Write-Host "[OK] Setup complete."
Write-Host " - Startup: HKCU Run + task 'OdooStockRadar Tray' (reviver every 5 min)"
Write-Host " - Scan: task 'OdooStockRadar Scan' every 30 min"
Write-Host " The tray icon appears within a few seconds. Right-click it to open the radar."
