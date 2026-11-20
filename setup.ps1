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

# 建排程：先試標準名稱；被擋（存取被拒）再試自己的子資料夾；再被擋就誠實回報。
# 即使排程全部失敗，托盤 1.1.2 起內建自動掃描（啟動 1 分鐘後掃第一次，之後每 30 分鐘），功能不受影響。
function New-Task([string]$name, [int]$minutes, [string]$vbs) {
    try {
        schtasks /Create /F /TN "$name" /TR "wscript.exe $dir\$vbs" /SC MINUTE /MO $minutes 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { return $true }
    } catch { }
    try {
        schtasks /Create /F /TN "OdooStockRadar\$name" /TR "wscript.exe $dir\$vbs" /SC MINUTE /MO $minutes 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Host " - (info) task '$name' was created under folder \OdooStockRadar\ (root was blocked)"; return $true }
    } catch { }
    Write-Host " [!] task '$name' could NOT be created (access denied) - not fatal, the tray app has a built-in 30-min auto scan."
    return $false
}

$okTray = New-Task "OdooStockRadar Tray" 5  "start_tray.vbs"
$okScan = New-Task "OdooStockRadar Scan" 30 "start_scan.vbs"

try {
    $run = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Microsoft\Windows\CurrentVersion\Run", $true)
    $run.SetValue("OdooStockRadar", "wscript.exe $dir\start_tray.vbs")
    $run.Close()
    $okRun = $true
} catch { $okRun = $false }

# 立刻啟動托盤（不用等排程或下次登入）
try { Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $dir 'start_tray.vbs') + '"') } catch { }

Write-Host ""
if ($okRun) { Write-Host "[OK] Startup registered (HKCU Run)." } else { Write-Host "[!] HKCU Run registration failed - start the tray manually with start_tray.vbs." }
if ($okTray -and $okScan) { Write-Host "[OK] Scheduled tasks created (reviver 5 min + scan 30 min)." }
else { Write-Host "[OK] Program is ready. (Scheduled tasks were blocked by this PC - the tray has a built-in 30-min auto scan instead.)" }
Write-Host " The tray icon appears within a few seconds. Double-click it to open the radar."
Write-Host ""
Write-Host "Press any key to close..."
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
