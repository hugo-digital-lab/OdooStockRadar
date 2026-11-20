# Odoo 庫存雷達（獨立版 v1.3.1）——托盤常駐 + 排程掃描 + 搜尋 + 更新檢查，單檔程式
# 用法：
#   一般啟動（托盤常駐）      : powershell -File OdooStockRadar.ps1
#   排程掃描一次（無 UI）     : powershell -File OdooStockRadar.ps1 -Scan
#   恢復監看（桌面捷徑用）    : powershell -File OdooStockRadar.ps1 -Resume
# 設定檔：同資料夾 config.json（遺失時會自動產生範本後結束）
param([switch]$Scan, [switch]$Resume)

$ErrorActionPreference = 'Stop'

# ===== 讀設定 =====
$ScriptDir = $PSScriptRoot
$ConfigPath = Join-Path $ScriptDir "config.json"
if (-not (Test-Path $ConfigPath)) {
    $sample = @{
        url = "http://ODOO-IP:PORT"; db = "你的資料庫名"; user = "帳號@gmail.com"
        key = "PUT-YOUR-ODOO-API-KEY-HERE"; prefix = "21"
        sellLocations = @("享物總倉", "禾洛智能雲倉")
        dataDir = (Join-Path $ScriptDir "data"); version = "1.0.0"; updateCheckUrl = ""
    }
    $sample | ConvertTo-Json -Depth 6 | Out-File -FilePath $ConfigPath -Encoding utf8
    Write-Output "已產生 config.json 範本，請填入 Odoo 連線資訊後重新執行。"
    exit 1
}
$Conf = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $Conf.dataDir) { $Conf | Add-Member -NotePropertyName dataDir -NotePropertyValue (Join-Path $ScriptDir "data") }
if (-not (Test-Path $Conf.dataDir)) { New-Item -ItemType Directory -Path $Conf.dataDir -Force | Out-Null }
$ReportsDir = Join-Path $Conf.dataDir "reports"
if (-not (Test-Path $ReportsDir)) { New-Item -ItemType Directory -Path $ReportsDir -Force | Out-Null }
$SnapshotPath = Join-Path $Conf.dataDir "snapshot.json"
$LogPath = Join-Path $Conf.dataDir "watch.log"
$SellLocs = @($Conf.sellLocations)

# 暫停旗標：暫停期間，復活器與排程掃描都直接退出；只有桌面捷徑（-Resume）會清旗標啟動
if (-not $Resume -and (Test-Path (Join-Path $Conf.dataDir '.paused'))) { exit 0 }

function Write-Log([string]$msg) {
    try { Add-Content -Path $LogPath -Value ("{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $msg) -Encoding UTF8 } catch { }
}
function FmtQty([double]$v) {
    $r = [math]::Round($v, 2)
    if ($r -eq [math]::Floor($r)) { return [string][long]$r }
    return $r.ToString("0.##")
}

# ===== Odoo XML-RPC（與 Python 版同線路，此伺服器的 /jsonrpc 有 domain 壓平 bug 故棄用） =====
$script:Uid = 0
function XmlValue($obj) {
    if ($null -eq $obj) { return "<value/>" }
    if ($obj -is [bool]) { return "<value><boolean>" + $(if ($obj) { "1" } else { "0" }) + "</boolean></value>" }
    if ($obj -is [int] -or $obj -is [long]) { return "<value><int>" + [long]$obj + "</int></value>" }
    if ($obj -is [double]) { return "<value><double>" + $obj.ToString([System.Globalization.CultureInfo]::InvariantCulture) + "</double></value>" }
    if ($obj -is [string]) { return "<value><string>" + [System.Security.SecurityElement]::Escape($obj) + "</string></value>" }
    if ($obj -is [System.Collections.IDictionary]) {
        $s = "<value><struct>"
        foreach ($k in $obj.Keys) { $s += "<member><name>" + [System.Security.SecurityElement]::Escape([string]$k) + "</name>" + (XmlValue $obj[$k]) + "</member>" }
        return $s + "</struct></value>"
    }
    if ($obj -is [System.Collections.IEnumerable]) {
        $s = "<value><array><data>"
        foreach ($e in $obj) { $s += XmlValue $e }
        return $s + "</data></array></value>"
    }
    throw ("XML-RPC 不支援的型別: " + $obj.GetType().Name)
}
function ParseValue($vnode) {
    $child = $null
    foreach ($c in $vnode.ChildNodes) { if ($c.NodeType -eq "Element") { $child = $c; break } }
    if ($null -eq $child) { return $null }
    switch ($child.Name) {
        "string" { return $child.InnerText }
        "int" { return [int]$child.InnerText }
        "i4" { return [int]$child.InnerText }
        "double" { return [double]$child.InnerText }
        "boolean" { return ($child.InnerText -eq "1") }
        "array" {
            $data = $child.SelectSingleNode("data")
            $list = @()
            if ($data) { foreach ($v in $data.SelectNodes("value")) { $list += ,(ParseValue $v) } }
            return ,$list
        }
        "struct" {
            $h = @{}
            foreach ($m in $child.SelectNodes("member")) {
                $nm = $m.SelectSingleNode("name").InnerText
                $h[$nm] = ParseValue $m.SelectSingleNode("value")
            }
            return $h
        }
        default { return $child.InnerText }
    }
}
function XmlRpc([string]$path, [string]$method, $rpcParams) {
    $x = '<?xml version="1.0"?><methodCall><methodName>' + $method + '</methodName><params>'
    foreach ($p in $rpcParams) { $x += '<param>' + (XmlValue $p) + '</param>' }
    $x += '</params></methodCall>'
    $wc = New-Object System.Net.WebClient
    $wc.Encoding = [System.Text.Encoding]::UTF8
    $wc.Headers.Add("Content-Type", "text/xml")
    $raw = $wc.UploadString(($Conf.url.TrimEnd('/') + $path), $x)
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($raw)
    $fault = $doc.SelectSingleNode("/methodResponse/fault")
    if ($fault) {
        $fs = "未知錯誤"
        try { $fs = $fault.SelectSingleNode("value/struct/member[name='faultString']/value/string").InnerText } catch { }
        throw ("Odoo XML-RPC fault: " + $fs)
    }
    $pv = $doc.SelectSingleNode("/methodResponse/params/param/value")
    return ,(ParseValue $pv)
}
function Nz($v) { if ($null -eq $v) { return 0.0 } else { return [double]$v } }

function Invoke-StockScan {
    # 互斥鎖：避免手動+排程同時掃描寫壞快照
    $scanMutex = New-Object System.Threading.Mutex($false, "OdooStockRadarScanMutex")
    $owned = $true
    try { $owned = $scanMutex.WaitOne(0) } catch { $owned = $true }
    if (-not $owned) { return }
    try {
        $script:Uid = XmlRpc "/xmlrpc/2/common" "authenticate" @($Conf.db, $Conf.user, $Conf.key, @{})
        if (-not $Uid) { throw "Odoo 認證失敗（API key 可能已更換或撤銷）" }

        # 1) 全部庫位 → 本地挑出可售兩倉（避開 RPC 端名稱過濾被吞的怪癖）
        $locAll = XmlRpc "/xmlrpc/2/object" "execute_kw" @($Conf.db, $Uid, $Conf.key, "stock.location", "search_read", @(), @{ fields = @("id", "complete_name") })
        $locMap = @{}
        foreach ($l in $locAll) {
            $short = ([string]$l.complete_name).Split("/")[-1].Trim()
            if ($SellLocs -contains $short) { $locMap[[int]$l.id] = $short }
        }
        if ($locMap.Count -eq 0) { throw "找不到可售庫位: " + ($SellLocs -join "/") }

        # 2) 全部產品 → 本地過濾料號前綴
        #    wire 格式：execute_kw 第 6 參數 = [ [ leaf ] ]（args 外殼 + domain + leaf，三層）
        $leafP = @("default_code", "!=", $false)
        $domainP = ,$leafP
        $argsP = ,$domainP
        $prodAll = XmlRpc "/xmlrpc/2/object" "execute_kw" @($Conf.db, $Uid, $Conf.key, "product.product", "search_read", $argsP, @{ fields = @("id", "default_code", "display_name", "incoming_qty") })
        $watch = @{}
        foreach ($p in $prodAll) {
            $dc = [string]$p.default_code
            if ($dc.StartsWith($Conf.prefix)) { $watch[[int]$p.id] = $p }
        }

        # 3) 兩倉的 stock.quant → 彙計可售（quantity - reserved）
        $leafQ = @("location_id", "in", @($locMap.Keys))
        $domainQ = ,$leafQ
        $argsQ = ,$domainQ
        $quants = XmlRpc "/xmlrpc/2/object" "execute_kw" @($Conf.db, $Uid, $Conf.key, "stock.quant", "search_read", $argsQ, @{ fields = @("product_id", "location_id", "quantity", "reserved_quantity") })
        $agg = @{}
        foreach ($q in $quants) {
            $prodId = [int]$q.product_id[0]
            if (-not $watch.ContainsKey($prodId)) { continue }
            $lid = [int]$q.location_id[0]
            $sell = (Nz $q.quantity) - (Nz $q.reserved_quantity)
            $k = "$prodId|$lid"
            if ($agg.ContainsKey($k)) { $agg[$k] += $sell } else { $agg[$k] = $sell }
        }

        # 4) 組新快照
        $ts = Get-Date -Format "yyyy-MM-dd HH:mm"
        $new = @{}
        foreach ($prodId in $watch.Keys) {
            $p = $watch[$prodId]
            $code = [string]$p.default_code
            $a = 0.0; $b = 0.0
            foreach ($lid in $locMap.Keys) {
                $v = 0.0; if ($agg.ContainsKey("$prodId|$lid")) { $v = $agg["$prodId|$lid"] }
                if ($locMap[$lid] -eq $SellLocs[0]) { $a += $v } else { $b += $v }
            }
            $incoming = Nz $p.incoming_qty
            $new[$code] = @{
                name = [string]$p.display_name
                ($SellLocs[0]) = [math]::Round($a, 2)
                ($SellLocs[1]) = [math]::Round($b, 2)
                total = [math]::Round($a + $b, 2)
                incoming = [math]::Round($incoming, 2)
            }
        }

        # 5) 載入舊快照比對
        $old = $null
        if (Test-Path $SnapshotPath) {
            try { $old = (Get-Content $SnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json).products } catch { }
        }
        if ($null -eq $old -or $old.PSObject.Properties.Count -eq 0) {
            @{ fetched_at = $ts; products = $new } | ConvertTo-Json -Depth 8 | Out-File -FilePath $SnapshotPath -Encoding utf8
            Write-Log "BASELINE: $($new.Count) codes @ $ts"
            return
        }

        # 6) 比對 → 報告
        $allCodes = @($new.Keys) + @($old.PSObject.Properties.Name | Where-Object { -not $new.ContainsKey($_) }) | Select-Object -Unique
        $changed = New-Object System.Collections.ArrayList
        $moved = New-Object System.Collections.ArrayList
        foreach ($c in ($allCodes | Sort-Object)) {
            $o = $old.PSObject.Properties[$c]
            $hasNew = $new.ContainsKey($c)
            $ot = 0.0; $oa = 0.0; $ob = 0.0
            if ($o) { $ot = Nz $o.Value.total; $oa = Nz $o.Value.PSObject.Properties[$SellLocs[0]].Value; $ob = Nz $o.Value.PSObject.Properties[$SellLocs[1]].Value }
            $nt = 0.0; $na = 0.0; $nb = 0.0
            if ($hasNew) { $nt = Nz $new[$c].total; $na = Nz $new[$c][$SellLocs[0]]; $nb = Nz $new[$c][$SellLocs[1]] }
            $otR = [math]::Round($ot, 2); $ntR = [math]::Round($nt, 2)
            if ($o -and $hasNew -and $otR -eq $ntR) {
                if (([math]::Round($oa,2) -ne [math]::Round($na,2)) -or ([math]::Round($ob,2) -ne [math]::Round($nb,2))) { [void]$moved.Add($c) }
                continue
            }
            $d = [math]::Round($nt - $ot, 2)
            $oname = if ($o) { [string]$o.Value.name } else { [string]$new[$c].name }
            [void]$changed.Add(@{ abs = [math]::Abs($d); code = $c; oname = $oname; oa = $oa; ob = $ob; na = $na; nb = $nb; ot = $ot; nt = $nt; d = $d; hasNew = $hasNew; hasOld = [bool]$o })
        }

        $maxLines = 60
        if ($changed.Count -eq 0 -and $moved.Count -eq 0) {
            Write-Log "OK: no change ($($new.Count) codes) @ $ts"
            if (-not $Scan) { }
            return
        }
        $sorted = $changed | Sort-Object { -$_.abs }
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add("📦 Odoo 庫存變動通知（$ts，$($SellLocs[0])＋$($SellLocs[1])合計）")
        $lines.Add("")
        $i = 0
        foreach ($ch in $sorted) {
            if ($i -ge $maxLines) { break }
            $nm = $ch.oname -replace ("^\[" + $ch.code + "\]\s*"), ""
            $arrow = if ($ch.d -gt 0) { "▲" } else { "▼" }
            if ($ch.hasOld -and $ch.hasNew) {
                $locPart = "$($SellLocs[0]) $(FmtQty $ch.oa)→剩餘$(FmtQty $ch.na)、$($SellLocs[1]) $(FmtQty $ch.ob)→剩餘$(FmtQty $ch.nb)"
            }
            elseif ($ch.hasNew) {
                $locPart = "新出現：$($SellLocs[0]) 剩餘$(FmtQty $ch.na)、$($SellLocs[1]) 剩餘$(FmtQty $ch.nb)"
            }
            else { $locPart = "兩倉已歸零" }
            $lines.Add("• $($ch.code) $nm｜$locPart｜合計 $(FmtQty $ch.ot)→剩餘$(FmtQty $ch.nt)（$arrow$(FmtQty ([math]::Abs($ch.d)))）")
            $i++
        }
        if ($changed.Count -gt $maxLines) { $lines.Add("…另有 $($changed.Count - $maxLines) 筆變動較小未列出，完整清單：reports/") }
        if ($moved.Count -gt 0) {
            $mv = ($moved | Select-Object -First 15) -join "、"
            if ($moved.Count -gt 15) { $mv += "…" }
            $lines.Add("ℹ️ 另有 $($moved.Count) 個料號兩倉之間有調撥（合計不變）：$mv")
        }
        $report = ($lines -join "`r`n")

        # 7) 寫報告檔 + 快照 + 清舊
        $stamp = Get-Date -Format "yyyyMMdd_HHmm"
        $report | Out-File -FilePath (Join-Path $ReportsDir "changes_$stamp.txt") -Encoding utf8
        $snapJson = @{ fetched_at = $ts; products = $new } | ConvertTo-Json -Depth 8
        [System.IO.File]::WriteAllText($SnapshotPath, $snapJson, (New-Object System.Text.UTF8Encoding($false)))
        $reps = @(Get-ChildItem $ReportsDir -Filter "changes_*.txt" | Sort-Object Name)
        if ($reps.Count -gt 200) { $reps | Select-Object -First ($reps.Count - 200) | ForEach-Object { Remove-Item $_.FullName -ErrorAction SilentlyContinue } }
        # 報告只保留 3 天；watch.log 超過 400 行時修剪到最後 300 行
        try {
            $cutoff = (Get-Date).AddDays(-3)
            Get-ChildItem $ReportsDir -Filter "changes_*.txt" |
                Where-Object { $_.LastWriteTime -lt $cutoff } |
                Remove-Item -Force -ErrorAction SilentlyContinue
            if ((Test-Path $LogPath) -and ((Get-Item $LogPath).Length -gt 60KB)) {
                $lines = [System.IO.File]::ReadAllLines($LogPath)
                [System.IO.File]::WriteAllLines($LogPath, $lines[($lines.Count - 300)..($lines.Count - 1)])
            }
        }
        catch { }
        Write-Log ("OK: {0} changed, {1} moved ({2} codes) @ {3}" -f $changed.Count, $moved.Count, $new.Count, $ts)
    }
    catch {
        Write-Log ("ERROR: " + $_.Exception.Message)
    }
    finally { $scanMutex.ReleaseMutex() | Out-Null }
}

# ===== 排程掃描模式：掃完就結束，不載入 UI =====
if ($Scan) { Invoke-StockScan; exit 0 }

# ===== 以下托盤常駐（C# WinForms 內嵌） =====
$src = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Windows.Forms;

public class StockTray : ApplicationContext
{
    NotifyIcon icon;
    Form win;
    RichTextBox box;
    Label stamp;
    Control sync;
    Dictionary<string, string> nameMap;
    List<Sku> skus;
    string searchQuery;
    string snapTime;
    string lastSig = null;
    Dictionary<string, Font> fontCache = new Dictionary<string, Font>();
    string baseDir;
    string version;
    Action updateCheckFn;

    class Sku { public string Code; public string Name; public double X; public double Y; public double Total; public double Incoming; }

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);
    [DllImport("user32.dll")]
    static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);

    public Action settingsFn;
    public Action uninstallFn;
    public Action pauseFn;

    public StockTray(string dataDir, string ver, Action scanNow, Action checkUpdate, Action openSettings, Action uninstall, Action pause)
    {
        baseDir = dataDir;
        version = ver;
        updateCheckFn = checkUpdate;
        settingsFn = openSettings;
        uninstallFn = uninstall;
        pauseFn = pause;
        sync = new Control();
        var h0 = sync.Handle;

        icon = new NotifyIcon();
        icon.Icon = MakeIcon();
        icon.Text = "Odoo 庫存雷達（點兩下看紀錄）";
        icon.Visible = true;

        var menu = new ContextMenuStrip();
        menu.Items.Add("看庫存變動紀錄", null, new EventHandler((s, e) => ShowWin()));
        menu.Items.Add("立即檢查一次", null, new EventHandler((s, e) => { scanNow(); NotifySoon(); }));
        menu.Items.Add("⚙ 設定", null, new EventHandler((s, e) => { if (openSettings != null) openSettings(); }));
        menu.Items.Add("🔍 檢查更新", null, new EventHandler((s, e) => checkUpdate()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("⏸ 暫停監看", null, new EventHandler((s, e) => { if (pauseFn != null) pauseFn(); }));
        menu.Items.Add("⛔ 解除安裝", null, new EventHandler((s, e) => { if (uninstallFn != null) uninstallFn(); }));
        menu.Items.Add("結束常駐", null, new EventHandler((s, e) =>
        {
            var r = MessageBox.Show("結束後，5 分鐘復活排程會自動把程式救回來。\n要永久停止請改用「⛔ 解除安裝」。\n\n確定現在結束？", "結束常駐",
                MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (r == DialogResult.Yes) { icon.Visible = false; Application.Exit(); }
        }));
        icon.ContextMenuStrip = menu;
        icon.DoubleClick += new EventHandler((s, e) => ShowWin());
        icon.BalloonTipClicked += new EventHandler((s, e) => ShowWin());

        var watcher = new FileSystemWatcher(Path.Combine(baseDir, "reports"), "*.txt");
        watcher.Created += new FileSystemEventHandler((s, e) => OnReport(e.FullPath));
        watcher.EnableRaisingEvents = true;

        // 啟動時：若 15 分鐘內有沒看過的報告（排程在托盤掛掉期間掃的）→ 補跳通知
        try
        {
            var files = Directory.GetFiles(Path.Combine(baseDir, "reports"), "changes_*.txt");
            if (files.Length > 0)
            {
                var newest = files.OrderByDescending(f => f).First();
                if ((DateTime.Now - File.GetLastWriteTime(newest)).TotalMinutes < 15) OnReport(newest);
            }
        }
        catch { }

        LoadSnapshot();
        WriteHeartbeat();
        var t = new System.Windows.Forms.Timer();
        t.Interval = 20000;
        t.Tick += new EventHandler((s, e) => WriteHeartbeat());
        t.Start();

        var refresh = new System.Windows.Forms.Timer();
        refresh.Interval = 60000;
        refresh.Tick += new EventHandler((s, e) => { if (win != null && win.Visible) FillContent(false); });
        refresh.Start();

        // 內建自動掃描：啟動 1 分鐘後掃第一次（建基準），之後每 30 分鐘一次。
        // 即使排程工作被公司電腦封鎖（schtasks 存取被拒），掃描仍會照常運作。
        var autoScan = new System.Windows.Forms.Timer();
        int autoTick = 0;
        autoScan.Interval = 60000;
        autoScan.Tick += new EventHandler((s, e) =>
        {
            autoTick++;
            if (autoTick == 1) { ScanNow(); autoScan.Interval = 30 * 60 * 1000; }
        });
        autoScan.Start();
    }

    void NotifySoon()
    {
        var ot = new System.Windows.Forms.Timer();
        ot.Interval = 9000;
        ot.Tick += new EventHandler((s, e) => { ot.Stop(); if (win != null && win.Visible) FillContent(true); });
        ot.Start();
    }

    Icon MakeIcon()
    {
        // 優先使用安裝資料夾裡的 radar.ico（與桌面捷徑同款科技風）
        try
        {
            string icoPath = Path.GetFullPath(Path.Combine(baseDir, "..", "radar.ico"));
            if (File.Exists(icoPath)) return new Icon(icoPath);
        }
        catch { }
        var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using (var b = new SolidBrush(Color.FromArgb(34, 211, 238)))
            {
                g.FillRectangle(b, 2, 18, 6, 12);
                g.FillRectangle(b, 10, 12, 6, 18);
                g.FillRectangle(b, 18, 6, 6, 24);
            }
            using (var b2 = new SolidBrush(Color.FromArgb(74, 222, 128)))
            {
                g.FillEllipse(b2, 24, 2, 6, 6);
            }
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    void WriteHeartbeat()
    {
        try { File.WriteAllText(Path.Combine(baseDir, ".tray_alive"), DateTime.Now.ToString("s")); } catch { }
    }

    void OnReport(string path)
    {
        string text = null;
        for (int i = 0; i < 6; i++)
        {
            try { text = File.ReadAllText(path); if (text.Length > 0) break; } catch { }
            System.Threading.Thread.Sleep(400);
        }
        if (text == null) return;
        string[] lines = text.Replace("\r", "").Split('\n');
        string timeTxt = "";
        if (lines.Length > 0)
        {
            int p0 = lines[0].IndexOf('（');
            int p1 = lines[0].IndexOf('，');
            if (p0 >= 0 && p1 > p0) timeTxt = lines[0].Substring(p0 + 1, p1 - p0 - 1);
        }
        var parts = new List<string[]>(); // {delta, name, code}
        string note = null;
        foreach (var l in lines)
        {
            string ln = l.TrimStart();
            if (ln.StartsWith("•"))
            {
                string b = ln.Substring(1).Trim();
                int sp2 = b.IndexOf(' ');
                string code = sp2 > 0 ? b.Substring(0, sp2) : b;
                int pp = b.LastIndexOf('（');
                string delta = pp >= 0 ? b.Substring(pp + 1).TrimEnd('）') : "";
                parts.Add(new[] { delta, "", code });
            }
            else if (ln.StartsWith("ℹ") && note == null) note = ln;
        }
        if (parts.Count == 0 && note == null) return;
        // 品名從快照反查（全名）
        try
        {
            var ser = new System.Web.Script.Serialization.JavaScriptSerializer();
            var snap = ser.Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(baseDir, "snapshot.json")));
            var prods = snap["products"] as Dictionary<string, object>;
            foreach (var p in parts)
            {
                string code = p[2];
                if (prods != null && prods.ContainsKey(code))
                {
                    var o = prods[code] as Dictionary<string, object>;
                    if (o != null && o.ContainsKey("name")) p[1] = ((string)o["name"]).Replace("[" + code + "]", "").Trim();
                }
                if (p[1].Length == 0) p[1] = code;
                p[1] = Regex.Replace(p[1], @"\([^)]*\)", "");
                p[1] = p[1].Replace("/(家必宜)", "").Replace("(家必宜)", "").Replace("(停售)", "").Replace("(出清)", "")
                           .Replace("-FINAL", "").Replace("FINAL", "").Replace("　", " ").Trim(' ', '-', '/', '　');
                while (p[1].Contains("  ")) p[1] = p[1].Replace("  ", " ");
                if (p[1].Length == 0) p[1] = code;
                if (p[1].Length > 16) p[1] = p[1].Substring(0, 16) + "…";
            }
        }
        catch { }
        foreach (var p in parts)
        {
            string sign = p[0].StartsWith("▲") ? "+" : "-";
            p[0] = sign + p[0].TrimStart('▲', '▼');
        }
        string title = "庫存變動 " + parts.Count + " 筆" + (timeTxt.Length > 4 ? " ・ " + timeTxt.Substring(timeTxt.Length - 5) : "");
        List<string[]> rows;
        string note2;
        if (parts.Count <= 3)
        {
            rows = new List<string[]>();
            foreach (var p in parts) rows.Add(new[] { p[2] + "  " + p[1], p[0] });
            note2 = null;
        }
        else
        {
            double outN = 0, inN = 0; int outC = 0, inC = 0;
            foreach (var p in parts)
            {
                double v = 0; double.TryParse(p[0], out v);
                if (v < 0) { outN += -v; outC++; } else if (v > 0) { inN += v; inC++; }
            }
            rows = new List<string[]>();
            if (outC > 0) rows.Add(new[] { "出貨 " + outC + " 項商品", "-" + FmtS(outN) });
            if (inC > 0) rows.Add(new[] { "進貨 " + inC + " 項商品", "+" + FmtS(inN) });
            note2 = "點一下開啟完整明細";
        }
        sync.BeginInvoke((Action)(() =>
        {
            var toast = new ToastPopup(title, rows, note2, new Action(ShowWin));
            toast.Show();
            if (win != null && win.Visible) FillContent(true);
        }));
    }

    static string FmtS(double v)
    {
        double r = Math.Round(v, 2);
        return r == Math.Floor(r) ? ((long)r).ToString() : r.ToString("0.##");
    }

    Button NewBtn(string text, Color fc)
    {
        var b = new Button();
        b.Text = text;
        b.AutoSize = true;
        b.FlatStyle = FlatStyle.Flat;
        b.FlatAppearance.BorderColor = Color.FromArgb(51, 65, 85);
        b.FlatAppearance.BorderSize = 1;
        b.FlatAppearance.MouseOverBackColor = Color.FromArgb(51, 65, 85);
        b.BackColor = Color.FromArgb(15, 23, 42);
        b.ForeColor = fc;
        b.Font = new Font("Microsoft JhengHei", 9.5f, FontStyle.Bold);
        b.Cursor = Cursors.Hand;
        return b;
    }

    Color Def() { return Color.FromArgb(226, 232, 240); }

    Font GetFont(float size, bool bold)
    {
        string k = size + "|" + bold;
        Font f;
        if (!fontCache.TryGetValue(k, out f))
        {
            f = new Font("Consolas", size, bold ? FontStyle.Bold : FontStyle.Regular);
            fontCache[k] = f;
        }
        return f;
    }

    void Append(string text, Color c, float size, bool bold)
    {
        box.SelectionStart = box.TextLength;
        box.SelectionLength = 0;
        box.SelectionColor = c;
        box.SelectionFont = GetFont(size, bold);
        box.AppendText(text);
    }

    void AppendBullet(string line)
    {
        Color def = Def();
        int i = 0;
        while (i < line.Length)
        {
            if (line[i] == '▲')
            {
                Append(line.Substring(i), Color.FromArgb(74, 222, 128), 10f, true);
                return;
            }
            if (line[i] == '▼')
            {
                Append(line.Substring(i), Color.FromArgb(248, 113, 113), 10f, true);
                return;
            }
            if (char.IsDigit(line[i]))
            {
                int j = i;
                while (j < line.Length && char.IsDigit(line[j])) j++;
                string num = line.Substring(i, j - i);
                if (num.Length == 6 && num.StartsWith("21"))
                    Append(num, Color.FromArgb(34, 211, 238), 10f, true);
                else
                    Append(num, def, 10f, false);
                i = j;
                continue;
            }
            int k = i;
            while (k < line.Length && line[k] != '▲' && line[k] != '▼' && !char.IsDigit(line[k])) k++;
            Append(line.Substring(i, k - i), def, 10f, false);
            i = k;
        }
    }

    void LoadSnapshot()
    {
        skus = new List<Sku>();
        nameMap = new Dictionary<string, string>();
        snapTime = "";
        try
        {
            var ser = new System.Web.Script.Serialization.JavaScriptSerializer();
            var snap = ser.Deserialize<Dictionary<string, object>>(File.ReadAllText(Path.Combine(baseDir, "snapshot.json")));
            object ft;
            if (snap.TryGetValue("fetched_at", out ft)) snapTime = (ft as string) ?? "";
            var prods = snap["products"] as Dictionary<string, object>;
            if (prods == null) return;
            foreach (var kv in prods)
            {
                var p = kv.Value as Dictionary<string, object>;
                if (p == null) continue;
                string nm = p.ContainsKey("name") ? (p["name"] as string) : null;
                Sku s = new Sku();
                s.Code = kv.Key;
                s.Name = nm ?? kv.Key;
                s.X = ToD(p, "享物總倉");
                s.Y = ToD(p, "禾洛智能雲倉");
                s.Total = ToD(p, "total");
                s.Incoming = ToD(p, "incoming");
                skus.Add(s);
                if (!string.IsNullOrEmpty(nm)) nameMap[kv.Key] = nm;
            }
        }
        catch { }
    }

    static double ToD(Dictionary<string, object> d, string key)
    {
        object o;
        if (d != null && d.TryGetValue(key, out o) && o != null)
        {
            try { return Convert.ToDouble(o); } catch { }
        }
        return 0;
    }

    static double ToDbl(string s)
    {
        double v = 0;
        double.TryParse(s, out v);
        return v;
    }

    static string Fmt(double v)
    {
        double r = Math.Round(v, 2);
        return r == Math.Floor(r) ? ((long)r).ToString() : r.ToString("0.##");
    }

    void RenderSearch()
    {
        Append("  🔎 搜尋「" + searchQuery + "」", Color.FromArgb(34, 211, 238), 12f, true);
        Append("  ・ 快照：" + snapTime + "\n\n", Color.FromArgb(100, 116, 139), 8.5f, false);
        var toks = searchQuery.ToLower().Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
        var hits = skus.Where(s => toks.All(t => (s.Code.ToLower() + " " + s.Name.ToLower()).Contains(t)));
        if (toks.Length == 1 && toks[0].All(char.IsDigit))
            hits = hits.OrderByDescending(s => s.Code == searchQuery ? 1 : 0).ThenBy(s => s.Code);
        else
            hits = hits.OrderBy(s => s.Code);
        var list = hits.ToList();
        if (list.Count == 0)
        {
            Append("  （找不到符合的料號或品名）\n", Color.FromArgb(100, 116, 139), 10f, false);
            return;
        }
        foreach (var s in list.Take(60))
        {
            Append("   ▸ ", Color.FromArgb(100, 116, 139), 10f, false);
            Append(s.Code + "  ", Color.FromArgb(34, 211, 238), 10.5f, true);
            Append(s.Name + "\n", Color.FromArgb(226, 232, 240), 9.5f, false);
            string detail = "享物 " + Fmt(s.X) + " ・ 禾洛 " + Fmt(s.Y) + " ・ 合計 " + Fmt(s.Total);
            if (s.Total <= 0)
            {
                Append("      " + detail, Color.FromArgb(100, 116, 139), 9.5f, false);
                if (s.Incoming > 0) Append(" ・ 在途 " + Fmt(s.Incoming), Color.FromArgb(251, 191, 36), 9.5f, true);
                Append("  ⚠ 無庫存\n", Color.FromArgb(248, 113, 113), 9.5f, true);
            }
            else
            {
                Append("      " + detail, Color.FromArgb(148, 163, 184), 9.5f, false);
                if (s.Incoming > 0)
                    Append(" ・ 在途 " + Fmt(s.Incoming) + "\n", Color.FromArgb(251, 191, 36), 9.5f, true);
                else
                    Append("\n", Color.FromArgb(148, 163, 184), 9.5f, false);
            }
        }
        if (list.Count > 60)
            Append("\n  …共 " + list.Count + " 筆，僅顯示前 60 筆，請輸入更精確的關鍵字\n", Color.FromArgb(100, 116, 139), 9f, false);
        else
            Append("\n  共 " + list.Count + " 筆\n", Color.FromArgb(100, 116, 139), 9f, false);
    }

    void FillContent() { FillContent(true); }

    string PrettyStamp(string fname)
    {
        int u = fname.IndexOf('_');
        string s = u >= 0 ? fname.Substring(u + 1) : fname;
        if (s.Length >= 13)
            return s.Substring(4, 2) + "-" + s.Substring(6, 2) + " " + s.Substring(9, 2) + ":" + s.Substring(11, 2);
        return s;
    }

    void FillContent(bool scrollTop)
    {
        string sig = "";
        try
        {
            var sigParts = new List<string>();
            foreach (var f in Directory.GetFiles(Path.Combine(baseDir, "reports"), "changes_*.txt"))
                sigParts.Add(Path.GetFileName(f) + File.GetLastWriteTimeUtc(f).Ticks);
            sigParts.Sort();
            FileInfo li = new FileInfo(Path.Combine(baseDir, "watch.log"));
            sig = string.Join(";", sigParts.ToArray()) + "|" + (li.Exists ? li.Length : 0) + "|" + (searchQuery ?? "");
        }
        catch { }
        if (sig == lastSig && win != null && win.Visible)
        {
            if (stamp != null) stamp.Text = "更新於 " + DateTime.Now.ToString("HH:mm:ss");
            return;
        }
        lastSig = sig;
        bool redraw = false;
        try
        {
            if (box.IsHandleCreated)
            {
                SendMessage(box.Handle, 0x000B, IntPtr.Zero, IntPtr.Zero);
                redraw = true;
            }
        }
        catch { }
        int anchor = 0;
        try { anchor = box.GetCharIndexFromPosition(new Point(2, 2)); } catch { }
        LoadSnapshot();
        box.Clear();
        if (searchQuery == null) RenderHistory(); else RenderSearch();
        if (stamp != null) { stamp.Text = "更新於 " + DateTime.Now.ToString("HH:mm:ss"); }
        try
        {
            box.SelectionStart = scrollTop ? 0 : Math.Min(anchor, box.TextLength);
            box.SelectionLength = 0;
            box.ScrollToCaret();
        }
        catch { }
        if (redraw)
        {
            try
            {
                SendMessage(box.Handle, 0x000B, (IntPtr)1, IntPtr.Zero);
                box.Invalidate();
            }
            catch { }
        }
    }

    void RenderHistory()
    {
        Append("  ▶ ODOO 庫存變動雷達 v" + version + "\n", Color.FromArgb(34, 211, 238), 13f, true);
        Append("  享物＋禾洛 ・ 最新在上 ・ 快照：" + snapTime + "\n\n", Color.FromArgb(100, 116, 139), 8.5f, false);
        try
        {
            var files = Directory.GetFiles(Path.Combine(baseDir, "reports"), "changes_*.txt")
                                 .OrderByDescending(f => f).Take(15);
            bool any = false;
            foreach (var f in files)
            {
                any = true;
                string st = PrettyStamp(Path.GetFileNameWithoutExtension(f));
                var all = File.ReadAllLines(f);
                int cnt = 0;
                foreach (var l in all) if (l.TrimStart().StartsWith("•")) cnt++;
                Append("  ● " + st, Color.FromArgb(94, 234, 212), 10.5f, true);
                Append("  ・ " + cnt + " 筆變動\n", Color.FromArgb(100, 116, 139), 9f, false);
                foreach (var line in all)
                {
                    string l = line.TrimEnd();
                    if (l.StartsWith("•")) { RenderBullet(l); Append("\n", Color.FromArgb(15, 23, 42), 4f, false); }
                    else if (l.StartsWith("ℹ") || l.StartsWith("…"))
                    {
                        Append("      " + l + "\n", Color.FromArgb(100, 116, 139), 9f, false);
                    }
                }
                Append("\n", Color.FromArgb(15, 23, 42), 9f, false);
            }
            if (!any) Append("  （還沒有任何變動紀錄）\n", Color.FromArgb(100, 116, 139), 9f, false);
        }
        catch (Exception ex) { Append("  讀取失敗: " + ex.Message + "\n", Color.FromArgb(248, 113, 113), 9f, false); }

        Append("  ── 執行紀錄 ──\n", Color.FromArgb(94, 234, 212), 9f, true);
        try
        {
            var lines = File.ReadAllLines(Path.Combine(baseDir, "watch.log"));
            for (int i = Math.Max(0, lines.Length - 15); i < lines.Length; i++)
                Append("  " + lines[i] + "\n", Color.FromArgb(100, 116, 139), 8.5f, false);
        }
        catch (Exception ex) { Append("  " + ex.Message + "\n", Color.FromArgb(248, 113, 113), 8.5f, false); }
    }

    void ShowWin()
    {
        if (win == null)
        {
            win = new Form();
            win.Text = "Odoo 庫存雷達";
            win.Icon = MakeIcon();
            win.Size = new Size(780, 600);
            win.BackColor = Color.FromArgb(15, 23, 42);
            var wa = Screen.PrimaryScreen.WorkingArea;
            win.StartPosition = FormStartPosition.Manual;
            win.Location = new Point(wa.Right - 800, wa.Bottom - 640);

            var panel = new FlowLayoutPanel();
            panel.Dock = DockStyle.Top;
            panel.Height = 48;
            panel.BackColor = Color.FromArgb(30, 41, 59);
            panel.FlowDirection = FlowDirection.LeftToRight;
            panel.WrapContents = false;

            var b1 = NewBtn("⟳ 立即檢查", Color.FromArgb(34, 211, 238));
            b1.Click += new EventHandler((s, e) => { ScanNow(); });
            scanBtn = b1;
            b1.Margin = new Padding(8, 8, 3, 0);
            panel.Controls.Add(b1);
            var b2 = NewBtn("↻ 重新整理", Color.FromArgb(148, 163, 184));
            b2.Click += new EventHandler((s, e) => FillContent(true));
            b2.Margin = new Padding(3, 8, 3, 0);
            panel.Controls.Add(b2);
            var bSet = NewBtn("⚙ 設定", Color.FromArgb(148, 163, 184));
            bSet.Click += new EventHandler((s, e) => { if (settingsFn != null) settingsFn(); });
            bSet.Margin = new Padding(3, 8, 3, 0);
            panel.Controls.Add(bSet);

            var lbl = new Label();
            lbl.Text = "🔍";
            lbl.AutoSize = true;
            lbl.ForeColor = Color.FromArgb(148, 163, 184);
            lbl.Font = new Font("Segoe UI Emoji", 10f);
            lbl.Margin = new Padding(8, 12, 0, 0);
            panel.Controls.Add(lbl);

            var tb = new TextBox();
            tb.Width = 175;
            tb.BackColor = Color.FromArgb(15, 23, 42);
            tb.ForeColor = Color.FromArgb(226, 232, 240);
            tb.BorderStyle = BorderStyle.FixedSingle;
            tb.Font = new Font("Microsoft JhengHei", 9.5f);
            tb.Margin = new Padding(4, 10, 3, 0);
            tb.KeyDown += new KeyEventHandler((s, e) =>
            {
                if (e.KeyCode == Keys.Enter) e.SuppressKeyPress = true;
                if (e.KeyCode == Keys.Escape) { tb.Text = ""; e.SuppressKeyPress = true; }
            });
            tb.TextChanged += new EventHandler((s, e) =>
            {
                searchQuery = tb.Text.Trim();
                if (searchQuery.Length == 0) searchQuery = null;
                if (win != null) FillContent(true);
            });
            panel.Controls.Add(tb);

            var b3 = NewBtn("✕", Color.FromArgb(148, 163, 184));
            b3.Click += new EventHandler((s, e) => { tb.Text = ""; });
            b3.Margin = new Padding(3, 8, 3, 0);
            panel.Controls.Add(b3);

            var b4 = NewBtn("⤓ 檢查更新", Color.FromArgb(251, 191, 36));
            b4.Click += new EventHandler((s, e) => { if (updateCheckFn != null) updateCheckFn(); });
            b4.Margin = new Padding(3, 8, 3, 0);
            panel.Controls.Add(b4);

            stamp = new Label();
            stamp.Text = "";
            stamp.AutoSize = true;
            stamp.ForeColor = Color.FromArgb(100, 116, 139);
            stamp.Font = new Font("Segoe UI", 9f);
            stamp.Margin = new Padding(16, 14, 0, 0);
            panel.Controls.Add(stamp);

            box = new RichTextBox();
            box.Dock = DockStyle.Fill;
            box.ReadOnly = true;
            box.BorderStyle = BorderStyle.None;
            box.BackColor = Color.FromArgb(15, 23, 42);
            box.ForeColor = Color.FromArgb(226, 232, 240);
            box.Font = new Font("Consolas", 10f);
            box.DetectUrls = false;
            box.ScrollBars = RichTextBoxScrollBars.Vertical;

            win.Controls.Add(box);
            win.Controls.Add(panel);
            win.FormClosing += new FormClosingEventHandler((s, e) =>
            {
                if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; win.Hide(); }
            });
        }
        FillContent(true);
        win.Show();
        win.Activate();
        try
        {
            int v = 1;
            DwmSetWindowAttribute(win.Handle, 20, ref v, 4);
            DwmSetWindowAttribute(win.Handle, 19, ref v, 4);
        }
        catch { }
    }

    Button scanBtn;
    int scanPollGrace;
    System.Windows.Forms.Timer scanPoll;

    void ScanNow()
    {
        if (ScanRequested != null) ScanRequested();
        // 狀態顯示：按鈕換文字為「⏳ 檢查中…」（不停用——停用態在深色下會變黑塊；
        // 重複點擊無害，掃描互斥鎖會讓多餘的掃描程序自行退出），用互斥鎖輪詢何時結束
        try
        {
            if (scanBtn != null) { scanBtn.Text = "⏳ 檢查中…"; }
            if (scanPoll == null)
            {
                scanPoll = new System.Windows.Forms.Timer();
                scanPoll.Interval = 800;
                scanPoll.Tick += new EventHandler((s, e) =>
                {
                    if (scanPollGrace > 0) { scanPollGrace--; return; }
                    bool busy = true;
                    try
                    {
                        using (var m = new System.Threading.Mutex(false, "OdooStockRadarScanMutex"))
                        {
                            bool owned = false;
                            try { owned = m.WaitOne(0); }
                            catch (System.Threading.AbandonedMutexException) { owned = true; }
                            busy = !owned;
                            if (owned) { try { m.ReleaseMutex(); } catch { } }
                        }
                    }
                    catch { }
                    if (!busy)
                    {
                        scanPoll.Stop();
                        if (scanBtn != null) { scanBtn.Text = "⟳ 立即檢查"; }
                    }
                });
            }
            scanPollGrace = 2;
            scanPoll.Stop();
            scanPoll.Start();
        }
        catch { }
    }
    public event Action ScanRequested;

    // ===== 設定視窗：讀入現有 config JSON → 欄位編輯 → 回傳新 JSON（null=取消） =====
    public static string ShowSettingsDialog(string json)
    {
        var ser = new System.Web.Script.Serialization.JavaScriptSerializer();
        var d = ser.Deserialize<Dictionary<string, object>>(json);
        Color bg = Color.FromArgb(15, 23, 42);
        Color field = Color.FromArgb(30, 41, 59);
        Color fg = Color.FromArgb(226, 232, 240);
        Color lbl = Color.FromArgb(148, 163, 184);

        var f = new Form();
        f.Text = "⚙ Odoo 庫存雷達 — 設定";
        f.BackColor = bg;
        f.Size = new Size(600, 310);
        f.FormBorderStyle = FormBorderStyle.FixedDialog;
        f.MaximizeBox = false; f.MinimizeBox = false;
        f.StartPosition = FormStartPosition.CenterScreen;
        f.TopMost = true;

        Font fl = new Font("Consolas", 9f);
        Font ft = new Font("Consolas", 9.5f);
        // 料號字首／更新來源／GitHub Token 為固定值，不開放編輯（config 原值保留）
        string[] labels = new string[] { "Odoo 網址", "資料庫", "帳號", "API Key", "倉位（、分隔）" };
        string[] keys = new string[] { "url", "db", "user", "key", "sellLocations" };
        var boxes = new Dictionary<string, TextBox>();
        int y = 16;
        for (int i = 0; i < labels.Length; i++)
        {
            var l = new Label();
            l.Text = labels[i];
            l.ForeColor = lbl; l.Font = fl;
            l.SetBounds(16, y + 3, 150, 20);
            f.Controls.Add(l);
            var tb = new TextBox();
            tb.BackColor = field; tb.ForeColor = fg; tb.BorderStyle = BorderStyle.FixedSingle;
            string val = "";
            if (d.ContainsKey(keys[i]) && d[keys[i]] != null)
            {
                if (keys[i] == "sellLocations")
                {
                    var arr = d[keys[i]] as System.Collections.IEnumerable;
                    if (arr != null) { var parts = new List<string>(); foreach (var o in arr) parts.Add(o.ToString()); val = string.Join("、", parts.ToArray()); }
                }
                else val = d[keys[i]].ToString();
            }
            tb.Text = val;
            tb.SetBounds(170, y, 400, 24);
            f.Controls.Add(tb);
            boxes[keys[i]] = tb;
            y += 36;
        }

        var hint = new Label();
        hint.Text = "倉位名稱需與 Odoo 庫位一致；儲存後立即生效，免重啟。";
        hint.ForeColor = lbl; hint.Font = fl;
        hint.SetBounds(16, y + 4, 540, 20);
        f.Controls.Add(hint);

        var ok = new Button();
        ok.Text = "儲存";
        ok.BackColor = Color.FromArgb(34, 211, 238); ok.ForeColor = Color.FromArgb(15, 23, 42);
        ok.FlatStyle = FlatStyle.Flat; ok.Font = new Font("Consolas", 9.5f, FontStyle.Bold);
        ok.SetBounds(392, y + 26, 82, 30);
        ok.Click += new EventHandler((s, e) =>
        {
            if (!boxes["url"].Text.Trim().StartsWith("http"))
            {
                MessageBox.Show("Odoo 網址要以 http:// 或 https:// 開頭。", "設定"); return;
            }
            string k = boxes["key"].Text.Trim();
            if (k.Length == 0 || k.Contains("PUT-YOUR") || k.Contains("在這裡貼上"))
            {
                MessageBox.Show("請填入 API Key（Odoo → 設定 → 使用者 → API 金鑰 產生）。", "設定"); return;
            }
            f.DialogResult = DialogResult.OK;
        });
        f.Controls.Add(ok);

        var cancel = new Button();
        cancel.Text = "取消";
        cancel.BackColor = Color.FromArgb(51, 65, 85); cancel.ForeColor = fg;
        cancel.FlatStyle = FlatStyle.Flat; cancel.Font = ft;
        cancel.SetBounds(486, y + 26, 82, 30);
        cancel.Click += new EventHandler((s, e) => { f.DialogResult = DialogResult.Cancel; });
        f.Controls.Add(cancel);

        f.ShowDialog();
        if (f.DialogResult != DialogResult.OK) return null;

        d["url"] = boxes["url"].Text.Trim();
        d["db"] = boxes["db"].Text.Trim();
        d["user"] = boxes["user"].Text.Trim();
        d["key"] = boxes["key"].Text.Trim();
        var locs = new List<object>();
        foreach (var p in boxes["sellLocations"].Text.Split(new char[] { '、', ',', '，', ';' }, StringSplitOptions.RemoveEmptyEntries))
            locs.Add(p.Trim());
        d["sellLocations"] = locs;
        return ser.Serialize(d);
    }

    void RenderBullet(string line)
    {
        // 卡片解析：• 代碼 品名｜庫位明細｜合計（▲/▼n） → 三行結構，逐項依增減上色
        Color light = Color.FromArgb(226, 232, 240);
        Color mid = Color.FromArgb(100, 116, 139);
        Color label = Color.FromArgb(148, 163, 184);
        Color cyan = Color.FromArgb(34, 211, 238);
        Color green = Color.FromArgb(74, 222, 128);
        Color red = Color.FromArgb(248, 113, 113);

        string[] parts = line.Split('｜');
        if (parts.Length < 3) { AppendBullet(line); Append("\n", light, 10f, false); return; }

        string head = parts[0].TrimStart('•', ' ').Trim();
        int sp = head.IndexOf(' ');
        if (sp < 0) { AppendBullet(line); Append("\n", light, 10f, false); return; }
        string code = head.Substring(0, sp);
        string name = head.Substring(sp + 1).Trim();

        // 合計方向
        var tm = Regex.Match(parts[2], @"(\d+(?:\.\d+)?)→(?:剩餘)?(\d+(?:\.\d+)?)");
        double ot = tm.Success ? ToDbl(tm.Groups[1].Value) : 0;
        double nt = tm.Success ? ToDbl(tm.Groups[2].Value) : 0;
        bool up = nt > ot; bool down = nt < ot;
        Color ac = up ? green : (down ? red : mid);

        // 第一行：▲/▼ + 料號 + 品名（全名）—— 用段落縮排，不靠空格
        box.SelectionIndent = 26;
        Append(up ? "▲ " : (down ? "▼ " : "＝ "), ac, 10f, true);
        Append(code + "  ", cyan, 10f, true);
        Append(name + "\n", light, 9f, false);

        // 第二行：庫位對（相容 a→b 與 a→剩餘b 兩種格式），逐對上色
        box.SelectionIndent = 26;
        var pairs = Regex.Matches(parts[1], @"([^、：]+?)\s*(\d+(?:\.\d+)?)→(?:剩餘)?(\d+(?:\.\d+)?)");
        if (pairs.Count == 0)
        {
            Append(parts[1].Trim() + "\n", mid, 9f, false);
        }
        else
        {
            bool first = true;
            foreach (System.Text.RegularExpressions.Match m in pairs)
            {
                string lbl = m.Groups[1].Value.Trim()
                    .Replace("享物總倉", "享物").Replace("禾洛智能雲倉", "禾洛")
                    .Replace("新出現：", "");
                double a = ToDbl(m.Groups[2].Value);
                double b = ToDbl(m.Groups[3].Value);
                Color pc = b > a ? green : (b < a ? red : mid);
                if (!first) Append(" ・ ", mid, 9f, false);
                Append(lbl + " ", label, 8.5f, false);
                Append(Fmt(a) + "→剩餘" + Fmt(b), pc, 9f, b != a);
                first = false;
            }
            Append("\n", light, 9f, false);
        }

        // 第三行：合計（依方向上色）
        box.SelectionIndent = 26;
        Append("合計 ", label, 8.5f, false);
        Append(Fmt(ot) + "→剩餘" + Fmt(nt), ac, 9.5f, true);
        if (nt != ot)
            Append("（" + (up ? "▲" : "▼") + Fmt(Math.Abs(nt - ot)) + "）", ac, 9f, true);
        Append("\n", light, 9f, false);
        box.SelectionIndent = 0;
    }
}

public class ToastPopup : Form
{
    Timer t;
    int phase = 0;
    int ticks = 0;
    Action onClick;

    public ToastPopup(string title, List<string[]> rows, string note, Action clickAction)
    {
        onClick = clickAction;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        ShowInTaskbar = false;
        TopMost = true;
        int contentLines = rows.Count + (note != null ? 1 : 0);
        int h = 48 + contentLines * 28 + 12;
        if (h < 118) h = 118;
        int w = 300;
        using (var g = CreateGraphics())
        {
            float mw = g.MeasureString("📦 " + title, new Font("Microsoft JhengHei", 11f, FontStyle.Bold)).Width;
            foreach (var it in rows)
                mw = Math.Max(mw, g.MeasureString(it[0] + "    " + it[1], new Font("Microsoft JhengHei", 11f, FontStyle.Bold)).Width);
            w = (int)Math.Ceiling(mw) + 46;
        }
        if (w < 300) w = 300;
        if (w > 600) w = 600;
        Size = new Size(w, h);
        BackColor = Color.FromArgb(15, 23, 42);

        var lbl = new Label();
        lbl.Text = "📦 " + title;
        lbl.AutoSize = true;
        lbl.ForeColor = Color.FromArgb(34, 211, 238);
        lbl.Font = new Font("Microsoft JhengHei", 11f, FontStyle.Bold);
        lbl.Location = new Point(20, 12);
        lbl.BackColor = Color.Transparent;
        Controls.Add(lbl);

        var rb = new RichTextBox();
        rb.BorderStyle = BorderStyle.None;
        rb.BackColor = Color.FromArgb(15, 23, 42);
        rb.ReadOnly = true;
        rb.DetectUrls = false;
        rb.Font = new Font("Microsoft JhengHei", 10.5f);
        rb.Location = new Point(20, 44);
        rb.Size = new Size(w - 40, h - 58);
        int n = 0;
        foreach (var it in rows)
        {
            bool up = it[1].StartsWith("+");
            if (n > 0) rb.AppendText("\n");
            AppendC(rb, it[0], Color.FromArgb(248, 250, 252), 10.5f, false);
            AppendC(rb, "   " + it[1], up ? Color.FromArgb(74, 222, 128) : Color.FromArgb(248, 113, 113), 11f, true);
            n++;
        }
        rb.SelectionStart = 0;
        rb.SelectionLength = 0;
        Controls.Add(rb);

        if (note != null)
        {
            var nl = new Label();
            nl.Text = note;
            nl.AutoSize = true;
            nl.ForeColor = Color.FromArgb(100, 116, 139);
            nl.Font = new Font("Microsoft JhengHei", 9f);
            nl.Location = new Point(20, h - 26);
            nl.BackColor = Color.Transparent;
            Controls.Add(nl);
        }

        Click += new EventHandler((s, e) => ActivateRadar());
        rb.Click += new EventHandler((s, e) => ActivateRadar());
        lbl.Click += new EventHandler((s, e) => ActivateRadar());

        Load += new EventHandler((s, e) =>
        {
            var wa = Screen.PrimaryScreen.WorkingArea;
            Location = new Point(wa.Right - Width - 14, wa.Bottom - Height - 14);
            Opacity = 0;
            t.Start();
        });

        t = new Timer();
        t.Interval = 40;
        t.Tick += new EventHandler((s, e) =>
        {
            ticks++;
            if (phase == 0)
            {
                Opacity = Math.Min(1.0, Opacity + 0.15);
                if (Opacity >= 1.0) phase = 1;
            }
            else if (phase == 1)
            {
                if (ticks > 175) phase = 2;
            }
            else
            {
                Opacity -= 0.08;
                if (Opacity <= 0) { t.Stop(); Close(); }
            }
        });

        var path = new System.Drawing.Drawing2D.GraphicsPath();
        int rad = 12;
        path.AddArc(0, 0, rad, rad, 180, 90);
        path.AddArc(w - rad - 1, 0, rad, rad, 270, 90);
        path.AddArc(w - rad - 1, h - rad - 1, rad, rad, 0, 90);
        path.AddArc(0, h - rad - 1, rad, rad, 90, 90);
        path.CloseFigure();
        Region = new Region(path);
    }

    void ActivateRadar()
    {
        t.Stop();
        Close();
        if (onClick != null) onClick();
    }

    static void AppendC(RichTextBox rb, string text, Color c, float size, bool bold)
    {
        rb.SelectionStart = rb.TextLength;
        rb.SelectionLength = 0;
        rb.SelectionColor = c;
        rb.SelectionFont = new Font("Microsoft JhengHei", size, bold ? FontStyle.Bold : FontStyle.Regular);
        rb.AppendText(text);
    }

    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            cp.ExStyle |= 0x8;
            cp.ExStyle |= 0x08000000;
            return cp;
        }
    }
}

public static class StockTrayApp
{
    public static void Run(string dataDir, string version, Action scanNow, Action checkUpdate, Action openSettings, Action uninstallFn, Action pauseFn, bool needsSetup)
    {
        // Mutex(false) + WaitOne(15s)：更新重啟時，新實例會等舊的釋放後接手；
        // 5 分鐘復活器在托盤還活著時觸發 → 等 15 秒逾時後自行退出
        var mutex = new System.Threading.Mutex(false, "OdooStockRadarMutex");
        bool acquired = false;
        try { acquired = mutex.WaitOne(15000); }
        catch (System.Threading.AbandonedMutexException) { acquired = true; }
        if (!acquired) return;
        Application.ThreadException += new System.Threading.ThreadExceptionEventHandler((s, e) =>
        {
            try { File.AppendAllText(Path.Combine(dataDir, "crash.log"), DateTime.Now + " [UI] " + e.Exception + "\n"); } catch { }
        });
        AppDomain.CurrentDomain.UnhandledException += new UnhandledExceptionEventHandler((s, e) =>
        {
            try { File.AppendAllText(Path.Combine(dataDir, "crash.log"), DateTime.Now + " [APP] " + e.ExceptionObject + "\n"); } catch { }
        });
        Application.EnableVisualStyles();
        var tray = new StockTray(dataDir, version, scanNow, checkUpdate, openSettings, uninstallFn, pauseFn);
        tray.ScanRequested += scanNow;
        // 第一次安裝（key 還是 placeholder）→ 1.5 秒後自動彈出設定視窗
        if (needsSetup)
        {
            var stTimer = new System.Windows.Forms.Timer();
            stTimer.Interval = 1500;
            stTimer.Tick += new EventHandler((s, e) => { stTimer.Stop(); if (tray.settingsFn != null) tray.settingsFn(); });
            stTimer.Start();
        }
        Application.Run(tray);
        mutex.ReleaseMutex();
    }
}
'@

Add-Type -TypeDefinition $src -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Core,System.Web.Extensions

function Test-VersionNewer([string]$remote, [string]$local) {
    # 逐段數字比較：1.1.0 > 1.0.9；無法解析時退回字串不等判斷
    try {
        $r = $remote.Split('.'); $l = $local.Split('.')
        for ($i = 0; $i -lt [Math]::Max($r.Count, $l.Count); $i++) {
            $rv = 0; $lv = 0
            if ($i -lt $r.Count) { [void][int]::TryParse($r[$i], [ref]$rv) }
            if ($i -lt $l.Count) { [void][int]::TryParse($l[$i], [ref]$lv) }
            if ($rv -gt $lv) { return $true }
            if ($rv -lt $lv) { return $false }
        }
        return $false
    }
    catch { return $remote -ne $local }
}

$updateAction = [Action]{
    try {
        # 更新來源：config 沒填就用內建預設（公開 repo，免 token）
        $updateUrl = [string]$Conf.updateCheckUrl
        if ([string]::IsNullOrWhiteSpace($updateUrl)) {
            $updateUrl = "https://raw.githubusercontent.com/hugo-digital-lab/OdooStockRadar/main/version.json"
        }
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        # 公開 repo 的 raw 下載不需要 token；只有私人 repo 才帶 Authorization
        if (-not [string]::IsNullOrWhiteSpace([string]$Conf.githubToken)) {
            $wc.Headers.Add("Authorization", "Bearer " + $Conf.githubToken)
        }
        $info = $wc.DownloadString($updateUrl) | ConvertFrom-Json
        $remote = [string]$info.version
        $local = [string]$Conf.version
        if ($remote -eq $local) {
            [System.Windows.Forms.MessageBox]::Show("已是最新版本 $local。", "檢查更新") | Out-Null
            return
        }
        if (-not (Test-VersionNewer $remote $local)) {
            [System.Windows.Forms.MessageBox]::Show("遠端版本 $remote 不比目前 $local 新。", "檢查更新") | Out-Null
            return
        }
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "有新版本 $remote（目前 $local）。要現在下載並自動更新嗎？",
            "檢查更新", [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ("$ans" -ne "Yes") { return }

        # 下載新版主程式（raw，跟 version.json 同資料夾）
        $wc2 = New-Object System.Net.WebClient
        $wc2.Encoding = [System.Text.Encoding]::UTF8
        if (-not [string]::IsNullOrWhiteSpace([string]$Conf.githubToken)) {
            $wc2.Headers.Add("Authorization", "Bearer " + $Conf.githubToken)
        }
        $ps1Url = ([string]$Conf.updateCheckUrl) -replace "version\.json.*$", "OdooStockRadar.ps1"
        $newPs1 = $wc2.DownloadString($ps1Url).TrimStart([char]0xFEFF)
        if ($newPs1.Length -lt 5000 -or -not $newPs1.Contains("StockTrayApp")) {
            throw "下載內容異常（長度 $($newPs1.Length)）"
        }
        $self = Join-Path $ScriptDir "OdooStockRadar.ps1"
        # 關鍵：必須帶 BOM 寫回（PS 5.1 讀無 BOM+中文腳本會用 ANSI 解析 → 啟動即失敗）
        [System.IO.File]::WriteAllText($self, $newPs1, (New-Object System.Text.UTF8Encoding($true)))

        # 同步 config 的 version 欄位
        $cfgPath = Join-Path $ScriptDir "config.json"
        $cfgObj = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $cfgObj.version = $remote
        [System.IO.File]::WriteAllText($cfgPath, ($cfgObj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
        $Conf.version = $remote

        # 完成提示（下載很快，以完成框代替進度條），按確定後才重啟
        [System.Windows.Forms.MessageBox]::Show(
            "✅ 已更新到 $remote。\n按下確定後程式會自動重新啟動。".Replace("\n", [Environment]::NewLine),
            "檢查更新") | Out-Null

        # 重啟：啟動新托盤（會等舊的釋放 Mutex），再結束自己
        Start-Process wscript.exe -ArgumentList ('"' + (Join-Path $ScriptDir 'start_tray.vbs') + '"')
        [System.Windows.Forms.Application]::Exit()
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("檢查更新失敗：" + $_.Exception.Message, "檢查更新") | Out-Null
    }
}

$scanAction = [Action]{
    # 背景程序掃描：UI 不卡（等 report 檔出來，watcher 會自動刷新＋跳通知）
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (Join-Path $ScriptDir 'OdooStockRadar.ps1'), '-Scan' -WindowStyle Hidden
}

$settingsAction = [Action]{
    # 設定視窗：程式自己組 JSON → 寫檔 → 原地套用（免重啟）
    try {
        $current = $Conf | ConvertTo-Json -Depth 6
        $result = [StockTray]::ShowSettingsDialog($current)
        if ($result) {
            $new = $result | ConvertFrom-Json
            [System.IO.File]::WriteAllText($ConfigPath, $result, (New-Object System.Text.UTF8Encoding($false)))
            $Conf.url = [string]$new.url
            $Conf.db = [string]$new.db
            $Conf.user = [string]$new.user
            $Conf.key = [string]$new.key
            $Conf.prefix = [string]$new.prefix
            $Conf.sellLocations = @($new.sellLocations)
            $Conf.updateCheckUrl = [string]$new.updateCheckUrl
            $Conf.githubToken = [string]$new.githubToken
            $script:SellLocs = @($new.sellLocations)
            Write-Log "SETTINGS: config updated via settings dialog"
        }
    }
    catch {
        Write-Log ("SETTINGS ERROR: " + $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show("設定儲存失敗：" + $_.Exception.Message, "設定") | Out-Null
    }
}

$uninstallAction = [Action]{
    # 解除安裝：刪排程＋自啟 → 關閉托盤（資料保留）
    try {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "要解除安裝嗎？`n`n・停止監看並關閉托盤`n・移除 5 分鐘復活器與 30 分鐘掃描排程`n・移除開機自動啟動`n・資料夾與歷史資料保留（可手動刪除）`n`n之後隨時可以重新執行 setup.bat 裝回來。",
            "解除安裝", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ("$ans" -ne "Yes") { return }
        # 排程不存在時 schtasks 會寫 stderr；Stop 偏好會把 2>&1 轉成例外——先放寬
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        foreach ($tn in @("OdooStockRadar Tray", "OdooStockRadar Scan", "OdooStockRadar\OdooStockRadar Tray", "OdooStockRadar\OdooStockRadar Scan")) {
            try { Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction Stop | Out-Null } catch { }
            schtasks /Delete /TN $tn /F 2>&1 | Out-Null
        }
        try {
            $run = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Software\Microsoft\Windows\CurrentVersion\Run", $true)
            $run.DeleteValue("OdooStockRadar")
            $run.Close()
        } catch { }
        # 桌面捷徑與暫停旗標一併清掉（重裝時乾淨啟動）
        try {
            Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) '庫存雷達.lnk') -Force -ErrorAction SilentlyContinue
            Remove-Item (Join-Path ([string]$Conf.dataDir) '.paused') -Force -ErrorAction SilentlyContinue
        } catch { }
        $ErrorActionPreference = $prevEap
        Write-Log "UNINSTALL: removed by user from tray menu"
        [System.Windows.Forms.MessageBox]::Show(
            "✅ 已解除安裝完成。`n`n・監看已停止，托盤即將關閉`n・排程與開機自動啟動已移除`n・資料夾與歷史資料保留（要徹底清除請手動刪除整個資料夾）`n`n之後要再使用：重新下載 ZIP，執行 setup.bat 即可裝回。",
            "解除安裝") | Out-Null
        [System.Windows.Forms.Application]::Exit()
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("解除安裝失敗：" + $_.Exception.Message, "解除安裝") | Out-Null
    }
}

$pauseAction = [Action]{
    # 暫停監看：寫旗標 → 關閉托盤；復活器與排程會因旗標休息，桌面捷徑可恢復
    try {
        [System.IO.File]::WriteAllText((Join-Path ([string]$Conf.dataDir) '.paused'), (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), (New-Object System.Text.UTF8Encoding($false)))
        Write-Log "PAUSED: monitor paused by user from tray menu"
        [System.Windows.Forms.MessageBox]::Show(
            "⏸ 已暫停監看，托盤即將關閉。`n`n暫停期間：不會自動掃描、復活器也不會啟動。`n恢復方式：點兩下桌面「庫存雷達」捷徑即可恢復。", "暫停監看") | Out-Null
        [System.Windows.Forms.Application]::Exit()
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("暫停失敗：" + $_.Exception.Message, "暫停監看") | Out-Null
    }
}

$needsSetup = ([string]::IsNullOrWhiteSpace([string]$Conf.key) -or ([string]$Conf.key -match 'PUT-YOUR|在這裡貼上'))
[StockTrayApp]::Run([string]$Conf.dataDir, [string]$Conf.version, $scanAction, $updateAction, $settingsAction, $uninstallAction, $pauseAction, $needsSetup)
