# Odoo 庫存雷達（獨立版 v1.0.0）——托盤常駐 + 排程掃描 + 搜尋 + 更新檢查，單檔程式
# 用法：
#   一般啟動（托盤常駐）      : powershell -File OdooStockRadar.ps1
#   排程掃描一次（無 UI）     : powershell -File OdooStockRadar.ps1 -Scan
# 設定檔：同資料夾 config.json（遺失時會自動產生範本後結束）
param([switch]$Scan)

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
                $locPart = "$($SellLocs[0]) $(FmtQty $ch.oa)→$(FmtQty $ch.na)、$($SellLocs[1]) $(FmtQty $ch.ob)→$(FmtQty $ch.nb)"
            }
            elseif ($ch.hasNew) {
                $locPart = "新出現：$($SellLocs[0]) $(FmtQty $ch.na)、$($SellLocs[1]) $(FmtQty $ch.nb)"
            }
            else { $locPart = "兩倉已歸零" }
            $lines.Add("• $($ch.code) $nm｜$locPart｜合計 $(FmtQty $ch.ot)→$(FmtQty $ch.nt)（$arrow$(FmtQty ([math]::Abs($ch.d)))）")
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

    public StockTray(string dataDir, string ver, Action scanNow, Action checkUpdate)
    {
        baseDir = dataDir;
        version = ver;
        updateCheckFn = checkUpdate;
        sync = new Control();
        var h0 = sync.Handle;

        icon = new NotifyIcon();
        icon.Icon = MakeIcon();
        icon.Text = "Odoo 庫存雷達（點兩下看紀錄）";
        icon.Visible = true;

        var menu = new ContextMenuStrip();
        menu.Items.Add("看庫存變動紀錄", null, new EventHandler((s, e) => ShowWin()));
        menu.Items.Add("立即檢查一次", null, new EventHandler((s, e) => { scanNow(); NotifySoon(); }));
        menu.Items.Add("🔍 檢查更新", null, new EventHandler((s, e) => checkUpdate()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("結束常駐", null, new EventHandler((s, e) => { icon.Visible = false; Application.Exit(); }));
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
                    if (l.StartsWith("•")) { RenderBullet(l); }
                    else if (l.StartsWith("ℹ") || l.StartsWith("…"))
                    {
                        Append("      " + l + "\n", Color.FromArgb(100, 116, 139), 9f, false);
                    }
                }
                Append("\n", Color.FromArgb(15, 23, 42), 2f, false);
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
            b1.Margin = new Padding(8, 8, 3, 0);
            panel.Controls.Add(b1);
            var b2 = NewBtn("↻ 重新整理", Color.FromArgb(148, 163, 184));
            b2.Click += new EventHandler((s, e) => FillContent(true));
            b2.Margin = new Padding(3, 8, 3, 0);
            panel.Controls.Add(b2);

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

    void ScanNow() { if (ScanRequested != null) ScanRequested(); }
    public event Action ScanRequested;

    void RenderBullet(string line)
    {
        // 卡片解析：• 代碼 品名｜庫位明細｜合計（▲/▼n） → 兩行結構
        Color light = Color.FromArgb(226, 232, 240);
        Color mid = Color.FromArgb(148, 163, 184);
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

        string loc = parts[1].Replace("享物總倉", "享物").Replace("禾洛智能雲倉", "禾洛").Replace("、", "  ・  ");
        string total = parts[2];
        bool up = total.Contains('▲');
        Color ac = up ? green : red;

        string baseT = total;
        string delta = "";
        int paren = total.IndexOf('（');
        if (paren >= 0) { baseT = total.Substring(0, paren); delta = total.Substring(paren); }

        Append("      ", light, 10f, false);
        Append(up ? "▲ " : "▼ ", ac, 11f, true);
        Append(code + "  ", cyan, 11f, true);
        Append(name + "\n", light, 10f, false);
        Append("         " + loc + "\n", mid, 9.5f, false);
        Append("         " + baseT, light, 9.5f, false);
        Append(delta + "\n", ac, 9.5f, true);
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
    public static void Run(string dataDir, string version, Action scanNow, Action checkUpdate)
    {
        bool createdNew;
        var mutex = new System.Threading.Mutex(true, "OdooStockRadarMutex", out createdNew);
        if (!createdNew) return;
        Application.EnableVisualStyles();
        var tray = new StockTray(dataDir, version, scanNow, checkUpdate);
        tray.ScanRequested += scanNow;
        Application.Run(tray);
        GC.KeepAlive(mutex);
    }
}
'@

Add-Type -TypeDefinition $src -ReferencedAssemblies System.Windows.Forms,System.Drawing,System.Core,System.Web.Extensions

$updateAction = [Action]{
    if ([string]::IsNullOrWhiteSpace([string]$Conf.updateCheckUrl)) {
        [System.Windows.Forms.MessageBox]::Show("尚未設定更新來源。請在 config.json 填入 updateCheckUrl（GitHub version.json 網址）。", "檢查更新") | Out-Null
    }
    else {
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Encoding = [System.Text.Encoding]::UTF8
            $wc.Headers.Add("Authorization", "Bearer " + $Conf.githubToken)
            $info = $wc.DownloadString([string]$Conf.updateCheckUrl) | ConvertFrom-Json
            $remote = [string]$info.version
            if ($remote -ne [string]$Conf.version) {
                [System.Windows.Forms.MessageBox]::Show("有新版本 $remote（目前 $($Conf.version)）。請下載最新版 OdooStockRadar.ps1 覆蓋本檔，然後托盤右鍵→結束常駐→重新啟動。", "檢查更新") | Out-Null
            }
            else {
                [System.Windows.Forms.MessageBox]::Show("已是最新版本 $($Conf.version)。", "檢查更新") | Out-Null
            }
        }
        catch {
            [System.Windows.Forms.MessageBox]::Show("檢查更新失敗：" + $_.Exception.Message, "檢查更新") | Out-Null
        }
    }
}

$scanAction = [Action]{
    # 背景程序掃描：UI 不卡（等 report 檔出來，watcher 會自動刷新＋跳通知）
    Start-Process powershell.exe -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', (Join-Path $ScriptDir 'OdooStockRadar.ps1'), '-Scan' -WindowStyle Hidden
}
[StockTrayApp]::Run([string]$Conf.dataDir, [string]$Conf.version, $scanAction, $updateAction)
