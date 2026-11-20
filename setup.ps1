# Odoo Stock Radar - user-level setup (no admin required)
# Registers: startup (HKCU Run) + scheduled tasks (scan every 30 min, tray reviver every 5 min)
# NOTE: install to a path WITHOUT spaces (scheduled task quoting limitation)
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
if ($dir -match ' ') { Write-Host "[!] Install path contains spaces - please use a path like D:\OdooStockRadar"; exit 1 }

# 第一次安裝：用程式碼直接組 config（不讀 sample 檔，避免任何格式問題）
# dataDir 自動指向本機資料夾（每台機器路徑不同也不會錯）
$firstRun = $false
if (-not (Test-Path (Join-Path $dir 'config.json'))) {
    $firstRun = $true
    $cfg = [ordered]@{
        url = "http://ODOO-IP:PORT"
        db = "你的資料庫名"
        user = "帳號@gmail.com"
        key = "PUT-YOUR-ODOO-API-KEY-HERE"
        prefix = "21"
        sellLocations = @("倉位名稱A", "倉位名稱B")
        dataDir = (Join-Path $dir 'data')
        version = "1.0.0"
        updateCheckUrl = "https://raw.githubusercontent.com/hugo-digital-lab/OdooStockRadar/main/version.json"
        githubToken = ""
    }
    [System.IO.File]::WriteAllText((Join-Path $dir 'config.json'), ($cfg | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "[i] config.json created - dataDir auto-set to this folder."
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

# 桌面捷徑（啟動/恢復監看）
try {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut((Join-Path $desktop '庫存雷達.lnk'))
    $sc.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $sc.Arguments = ('"' + (Join-Path $dir 'resume_tray.vbs') + '"')
    $sc.WorkingDirectory = $dir
    $sc.Description = 'Odoo 庫存雷達（啟動/恢復監看）'
    $sc.Save()
    Write-Host "[OK] Desktop shortcut '庫存雷達' created."
} catch { Write-Host "[!] Desktop shortcut creation failed (not fatal)." }

# 重新安裝時清除舊的暫停旗標，確保啟動
Remove-Item (Join-Path (Join-Path $dir 'data') '.paused') -Force -ErrorAction SilentlyContinue

# 立刻啟動托盤（不用等排程或下次登入）；第一次安裝時托盤會自動彈出設定視窗
try { Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $dir 'start_tray.vbs') + '"') } catch { }

Write-Host ""
if ($okRun) { Write-Host "[OK] Startup registered (HKCU Run)." } else { Write-Host "[!] HKCU Run registration failed - start the tray manually with start_tray.vbs." }
if ($okTray -and $okScan) { Write-Host "[OK] Scheduled tasks created (reviver 5 min + scan 30 min)." }
else { Write-Host "[OK] Program is ready. (Scheduled tasks were blocked by this PC - the tray has a built-in 30-min auto scan instead.)" }
if ($firstRun) { Write-Host "[i] First run: the settings window will pop up in a few seconds - fill in Odoo URL / db / user / API key and press Save." }
else { Write-Host " The tray icon appears within a few seconds. Double-click it to open the radar." }
Write-Host ""
Write-Host "Press any key to close..."
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
