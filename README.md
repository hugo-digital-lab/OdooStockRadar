# Odoo 庫存雷達（OdooStockRadar）

> 宏勤生活科技／LC生活科技 兩倉庫存自動監看小工具
> Windows 單機常駐、零依賴（不需 Python／不需管理員權限）、可完全脫離 AI 助手獨立運作
> 本文件＝安裝手冊＋架構規格＋維運手冊＋接手指南。**交給下一個 AI 或工程師，讀完這份即可無縫接手。**

---

## 0. 這是什麼（30 秒版）

每 30 分鐘向自架 Odoo（`http://114.32.3.230:88`，db=`em`，唯讀 API key）抓「享物總倉＋禾洛智能雲倉」兩倉的可售庫存，與上次快照比對：

- **有變動** → 右下角跳深色通知卡（≤3 筆逐行、>3 筆自動改兩行摘要）＋寫歷史報告檔
- **沒變動** → 完全安靜
- 托盤圖示點兩下 → 「庫存雷達」視窗：歷史明細（卡片式）、全料號搜尋（含在途）、立即檢查
- 掛掉 → 5 分鐘內自動復活；開機 → 自動啟動
- **⚙ 設定**：內建設定視窗（托盤右鍵／工具列），填完按儲存立即生效，不用改檔案、不用重啟；首次安裝 Key 未填時自動彈出

---

## 📥 安裝教學（第一次使用，約 5 分鐘）

> 需要的東西：Hugo 給你的 **API key**。建議放在 `D:\OdooStockRadar`（路徑不要有空白）。

1. **下載**：GitHub repo 頁面 → 綠色 **Code** → **Download ZIP** → 解壓縮
   - 若 Windows 擋下載的腳本：先對**ZIP 檔**右鍵 → 內容 → 勾「**解除封鎖**」→ 確定，再解壓縮
2. **安裝**：雙擊 **`setup.bat`** → 幾秒後**設定視窗會自動彈出**
3. **填四格**（找 Hugo 拿）：Odoo 網址／資料庫／帳號／API Key → 按**儲存**（立即生效，不用重啟）
   - （替代方案：用記事本改 `config.json` 也可以，但容易改壞 JSON——建議用設定視窗）
   - 這一步自動登錄：每 30 分鐘掃描、每 5 分鐘托盤健檢、開機自動啟動
4. **確認**：幾秒後右下角出現 🔵 青色訊號條圖示 → 點兩下打開雷達視窗，看到「▶ ODOO 庫存變動雷達」即完成
5. 之後每次開機自動啟動，不用再理它

| 常見安裝問題 | 解法 |
|---|---|
| setup.bat 視窗一閃即逝 | 對 `setup.ps1` 右鍵 → 以 PowerShell 執行，看錯誤訊息 |
| 顯示「路徑含空白」 | 把資料夾移到無空白路徑（如 `D:\OdooStockRadar`） |
| 裝完沒看到通知 | 通知**有變動才跳**；先按托盤右鍵 → 立即檢查一次測試 |
| 安裝時出現「錯誤: 存取被拒」 | 公司電腦封鎖排程工作——**不影響使用**：v1.1.2 起托盤內建每 30 分自動掃描（新版會顯示 `[OK] Program is ready`） |

---

## 🖱 使用教學（每天怎麼用）

### 托盤圖示（右下角青色訊號條）
- **點兩下**：開啟雷達視窗
- **右鍵選單**：看庫存變動紀錄／立即檢查一次／**⚙ 設定**／🔍 檢查更新／結束常駐

### 通知卡（右下角自動跳出）
- **有庫存變動才會跳**；7 秒後自動消失；**點一下卡片**直接開雷達視窗
- ≤3 筆：一行一筆（料號＋品名＋±增減，綠=增加 紅=減少）；>3 筆：自動改兩行摘要（出貨/進貨筆數與總量）

### 雷達視窗
- **歷史明細**：最上面最新；每個時段一張卡——第一行料號＋品名，第二行兩倉明細，第三行合計與增減
- **🔍 搜尋框**：打料號（如 `211442`）或品名關鍵字（如 `投影機`）；**空格分隔＝多條件**（如 `yaber 投影機`）
  - 每筆顯示：享物／禾洛／**合計**即時庫存、**在途**（黃色，進貨未達）、無庫存標紅 ⚠
  - 按 Esc 或 ✕ 清除搜尋，回到歷史明細
- **⟳ 立即檢查**：馬上連 Odoo 查一次（背景執行，視窗不會卡）
- **↻ 重新整理**：重讀本地紀錄
- **⚙ 設定**：圖形化填寫連線資訊，儲存立即生效
- **⤓ 檢查更新**：手動檢查有沒有新版程式（有新版會詢問是否自動更新）
- 視窗每分鐘自動刷新；**關閉視窗只是縮回托盤**，程式繼續運作

### 日常建議
- **上架前**：搜尋料號確認可售數量（順便看黃色「在途」）
- **收到 ▼ 通知**：確認通路上的上架數量是否要下修（避免超賣）
- **收到 ▲ 通知**：進貨入庫了，記得補上架數量

---

## 1. 商業背景

- 公司透過瑪黑 MARAIS、PChome 等通路賣貨，商品庫存在自家 Odoo（em 資料庫）管理
- 兩個出貨倉：**享物總倉**、**禾洛智能雲倉**。可售庫存＝兩倉 `quantity - reserved_quantity` 合計
- 料號規則：`default_code` 以 `21` 開頭（共約 1605 個）
- 在途數量：`product.product.incoming_qty`（進貨未達）
- 監看目的：通路下單扣庫時即時知道，避免超賣；進貨入庫即時知道，及時補上架數量

---

## 2. 系統架構

### 2.1 檔案結構

```
OdooStockRadar\
├── OdooStockRadar.ps1   ★ 唯一程式檔（托盤+掃描+視窗+搜尋+更新檢查，約 1100 行）
├── config.json          設定檔（含 API key —— 絕不上傳 GitHub）
├── config.sample.json   同事用的範本
├── setup.ps1 / setup.bat     一鍵安裝（註冊排程＋開機自啟）
├── remove.ps1 / remove.bat   一鍵移除
├── start_tray.vbs       托盤隱藏啟動器（排程與登錄檔指向它）
├── start_scan.vbs       單次掃描啟動器（排程指向它）
├── version.json         版本資訊（更新檢查的比對來源）
├── README.md            本文件
└── data\                執行期資料（自動產生）
    ├── snapshot.json    上次快照（比對基準）
    ├── reports\changes_yyyyMMdd_HHmm.txt   每波變動明細（>200 份自動清舊）
    ├── watch.log        每次掃描一行執行紀錄
    ├── .tray_alive      托盤心跳（每 20 秒）
    └── crash.log        當機記錄（有才存在）
```

### 2.2 程序與排程拓撲

```
[開機登入] ──→ HKCU Run "OdooStockRadar" ─┐
                                          ├─→ wscript start_tray.vbs
[排程] OdooStockRadar Tray (每5分) ───────┘     └─→ powershell -Hidden -File OdooStockRadar.ps1
     （托盤活著→Mutex 秒退；死了→重啟）              = 托盤常駐程序（NotifyIcon+視窗+watcher）

[排程] OdooStockRadar Scan (每30分) ──→ wscript start_scan.vbs
                                             └─→ powershell -Hidden -File ...ps1 -Scan
                                                  = 單次掃描程序（跑完就退）
```

- 托盤與掃描是**不同程序**：掃描寫 `reports\*.txt` → 托盤的 `FileSystemWatcher` 偵測 → 跳通知卡＋刷新視窗
- 兩者用 `OdooStockRadarScanMutex` 互斥，避免同時寫 snapshot

### 2.3 掃描資料流（-Scan 模式的完整流程）

```
authenticate(db,user,apikey) → uid
→ stock.location search_read (domain=[])      → 本地過濾 complete_name 尾段 ∈ {享物總倉,禾洛智能雲倉}
→ product.product search_read                 → 本地過濾 default_code 字首 "21"
  domain=[["default_code","!=",false]]  fields=[id,default_code,display_name,incoming_qty]
→ stock.quant search_read                     → 逐筆 (quantity - reserved) 依 (料號,庫位) 加總
  domain=[["location_id","in",<兩倉id>]] fields=[product_id,location_id,quantity,reserved_quantity]
→ 組新快照 snapshot.json（讀舊快照 → 比對 total）
→ 有差異：寫 reports\changes_*.txt（托盤 watcher 會跳通知）
  無差異：watch.log 記一行 OK，結束
→ reports 超過 200 份自動刪最舊
```

---

## 3. 設定檔 config.json（完整 schema）

| 欄位 | 必填 | 說明 |
|---|---|---|
| url | ✅ | Odoo 網址，例 `http://114.32.3.230:88` |
| db | ✅ | 資料庫名，例 `em` |
| user | ✅ | 帳號（API key 綁定用） |
| key | ✅ | Odoo API key（Odoo→設定→使用者→API 金鑰產生）。**只在本機，不上傳** |
| prefix | ✅ | 料號字首，例 `"21"` |
| sellLocations | ✅ | 可售倉位名稱陣列（以 complete_name 尾段比對），例 `["享物總倉","禾洛智能雲倉"]` |
| dataDir | ✅ | 資料資料夾絕對路徑，例 `D:\\OdooStockRadar\\data` |
| version | ✅ | 目前版本（更新檢查的「本地版號」，自我更新後自動同步） |
| updateCheckUrl | ➖ | version.json 的 raw 網址；空字串＝更新檢查回報「未設定」 |
| githubToken | ➖ | fine-grained PAT（私人 repo 抓 version.json / 主程式用） |

---

## 4. 資料格式

### 4.1 snapshot.json

```json
{
  "fetched_at": "2026-11-20 12:10",
  "products": {
    "211202": {
      "name": "[211202] LC-垃圾桶配件-垃圾袋盒L01 ...",
      "享物總倉": 378, "禾洛智能雲倉": 840,
      "total": 1218, "incoming": 600
    }
  }
}
```
- 寫入時用 UTF-8 **無 BOM**（`[IO.File]::WriteAllText` + `UTF8Encoding($false)`）
- 「無變動」輪次不重寫快照（fetched_at 維持上次有變動時間——正常）

### 4.2 reports\changes_yyyyMMdd_HHmm.txt（托盤解析依賴此格式，改格式＝托盤要同步改）

```
📦 Odoo 庫存變動通知（YYYY-MM-DD HH:MM，享物總倉＋禾洛智能雲倉合計）
                                                    ← 空行
• <code> <全名>｜享物總倉 <舊>→<新>、禾洛智能雲倉 <舊>→<新>｜合計 <舊>→<新>（▲n 或 ▼n）
  （新出現的料號 loc 段為「新出現：享物總倉 x、禾洛智能雲倉 y」；歸零為「兩倉已歸零」）
…另有 N 筆變動較小未列出（僅 >60 筆時）                    ← 有才出現
ℹ️ 另有 N 個料號兩倉之間有調撥（合計不變）：code、code   ← 有調撥才出現
                                                    ← 空行
基準時間: <舊快照 fetched_at>
本次比對: <ts>
```
- 分隔字元固定：`｜`(全形直線) 分三段、`、` 分庫位、`（▲n）`（全形括號）結尾
- 托盤 RenderCard 以 `｜` Split(3 段) 解析——**動格式兩邊要同步**

### 4.3 watch.log

每次掃描一行：`YYYY-MM-DD HH:mm:ss OK: N changed, M moved (1605 codes) @ ts`／`BASELINE: ...`／`ERROR: ...`

---

## 5. Odoo 連線規格（最重要的一節）

### 5.1 傳輸：XML-RPC（不要用 /jsonrpc！）

- 端點：`/xmlrpc/2/common`（authenticate）、`/xmlrpc/2/object`（execute_kw）
- **此伺服器的 `/jsonrpc` 端點有 bug：會把 domain 陣列壓平**（實測 2026-11-20：bool/int leaf 報
  `'bool' object is not subscriptable`、字串 leaf 報 `Invalid leaf`——巢狀全毀）。XML-RPC 同結構正常。
  Python 舊版也是走 XML-RPC。

### 5.2 wire 格式（三層巢狀——最容易錯的地方）

`execute_kw` 的第 6 參數 = **[ domain ]**（args 外殼包著 domain）：

```xml
<param><value><array><data>
  <value><array><data>          <!-- domain = [ leaf ] -->
    <value><string>default_code</string></value>
    <value><string>!=</string></value>
    <value><boolean>0</boolean></value>
  </data></array></value>
</data></array></value></param>
```

PowerShell 端正確寫法（**不能用 `@(,@(leaf))` 內嵌字面值——`@()` 對已存在陣列不會多包一層**）：

```powershell
$leaf     = @("default_code", "!=", $false)
$domain   = ,$leaf          # 逗號運算子才會真正包一層 → [leaf]
$argsWrap = ,$domain        # 再包一層 → [ [leaf] ] = execute_kw 的 args
XmlRpc "/xmlrpc/2/object" "execute_kw" @($db, $uid, $key, $model, $method, $argsWrap, $kwargs)
```

- 認證：`/xmlrpc/2/common` `authenticate(db, user, apikey, @{})` → uid
- 過濾策略：**domain 只做最簡單的條件，其餘本地過濾**（此伺服器對顯示欄位的伺服器端過濾不可靠）

### 5.3 可售庫存定義

```
可售 = Σ_{倉∈{享物總倉,禾洛智能雲倉}} (quant.quantity − quant.reserved_quantity)
```

---

## 6. 通知與視窗（C# WinForms，內嵌於 ps1 的 Add-Type）

- 托盤：NotifyIcon + ContextMenuStrip（看紀錄／立即檢查一次／🔍檢查更新／結束常駐）
- 通知卡 ToastPopup：無邊框圓角、NOACTIVATE+TOPMOST（不搶焦點）、淡入→7 秒→淡出、點擊開視窗、
  寬度 MeasureString 自適應；≤3 筆逐行（料號+品名+±量）、>3 筆兩行摘要（出貨/進貨筆數與總量）
- 雷達視窗：深色主題（#0F172A）、標題列暗色（DwmSetWindowAttribute attr 20）、
  工具列 FlowLayoutPanel（⟳立即檢查/↻重新整理/🔍搜尋框/✕/⤓檢查更新——**勿用固定座標，會互相遮擋**）、
  RichTextBox 卡片式明細（▲綠#4ADE80 ▼紅#F87171 料號青#22D3EE）
- 通知觸發：FileSystemWatcher(reports, Created) → 讀新報告（retry 6×400ms）→ ToastPopup；
  **啟動時補跳 15 分鐘內沒看過的報告**（排程在托盤掛掉期間掃的不會漏）
- 效能三件套：內容簽章比對（沒變整份跳過）、WM_SETREDRAW(0x000B) 包住重繪、字體快取

---

## 7. 更新機制（GitHub 私人 repo）

- repo：`hugo-digital-lab/OdooStockRadar`（private，default branch `main`）
- `version.json`：`{"version":"1.0.0","updated":"...","notes":"..."}` —— 更新檢查的比對來源
- **發佈新版 SOP**：改 OdooStockRadar.ps1 → 把 `version.json` 的 version 升號 →
  複製一份主程式到 `history\OdooStockRadar_vX.Y.Z.ps1`（版本留檔）→ `CHANGELOG.md` 加一節 →
  推上 repo（ps1＋version.json＋history＋CHANGELOG）。完成。
- **版本回退**：從 `history\` 取出任何舊版 ps1 覆蓋本機，或推回 main 並把 version.json 降號。
- 使用者按 ⤓ 檢查更新（純手動，不自動輪詢）→
  抓 version.json → 版本不同 → 詢問 → 下載新版 ps1（驗證長度>5000 且含 StockTrayApp）→
  覆寫自身 → 同步 config.version → `Start-Process wscript start_tray.vbs`（新實例等 Mutex 15 秒）→
  `Application.Exit()` 舊實例釋放 → 新實例接手
- token：fine-grained PAT，Resource owner 限自己、只選本 repo、Contents 權限
  - Hugo 機器：Read and write（推送用）
  - 同事機器：建議另發 **Read-only** token（只內建在同事 config）
- 推送方式：REST `PUT /repos/{owner}/{repo}/contents/{path}`（body 含 base64 + 既有檔案的 sha）

---

## 8. 維運手冊

| 症狀 | 檢查 | 處理 |
|---|---|---|
| 通知很久沒跳 | `data\watch.log` 尾端 | 全是 no change＝正常；有 ERROR 看下節 |
| 圖示消失 | `data\.tray_alive` mtime | >2 分鐘＝死了；排程 5 分鐘內會救回，或手動跑 start_tray.vbs |
| 視窗卡頓 | crash.log | 應為空；有內容貼給維護者 |
| 改了 config 沒生效 | — | 重啟托盤（右鍵→結束常駐→start_tray.vbs） |
| API key 換了 | 改 config.json 的 key | 重啟托盤 |
| 想改掃描頻率 | 排程工作「OdooStockRadar Scan」/SC MINUTE /MO n | 或 setup.ps1 改後重跑 |

**回滾到舊系統**（Python + Hermes cron，已暫停保留於 `D:\hermes\workspace\stock_monitor\`）：
`schtasks /Delete /TN "OdooStockRadar Scan" /F` → 恢復 Hermes cron job `e2a8a5986a22`。

**改程式的安全測試程序**（勿直接動正式排程）：
1. 編譯測試：把 `[StockTrayApp]::Run(...)` 行換成 `Write-Output 'COMPILE OK'` 跑一次（只驗 C# 編譯）
2. 掃描測試：`powershell -File OdooStockRadar.ps1 -Scan`（真連 Odoo，會寫報告）
3. 通知測試：改 data\snapshot.json 任一 total → 再 -Scan → 應跳通知卡＋寫報告（快照自動修回真值）
4. 都過了才重啟托盤

---

## 9. 地雷清單（每一條都真實踩過）

1. **/jsonrpc 會壓平 domain**——一律用 XML-RPC（§5.1）
2. **execute_kw 第 6 參數是 [domain] 不是 domain**——三層巢狀，PS 端用 `,$x` 逗號運算子包層（§5.2）
3. **PS 的 `@($arr)` 不會多包一層**——要包層用 `,` 逗號運算子
4. **`$pid` 是 PS 唯讀自動變數**——不可當迴圈變數
5. **WebClient 沒有 Timeout 屬性**——要控時改用 HttpWebRequest
6. **.ps1 含中文必須 UTF-8 with BOM**；.vbs/.bat 只能純 ASCII（WSH/cmd 會用 ANSI 讀，中文註解直接損毀）
7. **寫 JSON 給非 PS 工具讀 → UTF-8 無 BOM**（`UTF8Encoding($false)`）；PS `Out-File -Encoding utf8` 會帶 BOM
8. **常駐程序只能由 Windows 啟動**（HKCU Run + schtasks）；從任何 AI 工具（cron/execute_code）分離啟動的程序會隨該次執行被清掉
9. **powershell 直跑常駐會帶主控台**，主控台關閉訊號以 0xC000013A 殺程序——必須經 wscript（GUI 子系統）啟動
10. **通知裡的提示文字用 Label**——塞進 RichTextBox 會出現藍底選取/連結樣式殘留
11. **工具列別用固定座標**——用 FlowLayoutPanel，否則按鈕互相遮擋
12. **config.json（含 key）絕不上 GitHub**；.gitignore 已排除 config.json 與 data/
13. **PS 寫的 JSON 帶 BOM**——跨工具讀取注意（C# ReadAllText 沒問題）

---

## 10. 給接手 AI／工程師的環境事實

- 機器：Windows 11 Pro 25H2，Dell i5-8250U 20GB，C: 119GB SSD + D: 932GB HDD
- PowerShell 5.1（內建）——內嵌 C# 是 **C# 5**：無字串插值、無 `?.`、無 expression-bodied members
- 使用者：Hugo（電商供應商），語言 zh-hant；GitHub 帳號 hugo-digital-lab
- 相關路徑：本工具 `D:\OdooStockRadar\`；舊 Python 版（保留回滾）`D:\hermes\workspace\stock_monitor\`
- Hermes cron job `e2a8a5986a22` 已 paused（舊掃描排程，回滾用）
- Odoo 帳號為**唯讀** API 權限——任何寫入 Odoo 的需求需另行授權

## 11. 路線圖（未實作構想）

- 夜間（22:00–08:00）掃描降頻 60 分鐘（省資源，非必要）
- 同事機器改用唯讀 token（分發時產生第二顆）
- 通知卡加「關閉」按鈕（目前點擊＝開視窗，7 秒自動消失）
- LINE Messaging API 推播（手機端通知）
- PChome/瑪黑上架數量與 Odoo 庫存的對帳報表

---

## 📜 版本進度

| 版本 | 日期 | 重點優化 |
|---|---|---|
| **v1.2.0** | 2026-11-20 | **⚙ 設定視窗**：圖形化填寫、儲存立即生效免重啟；首次安裝自動彈出引導——告別手改 config.json |
| **v1.1.3** | 2026-11-20 | 更新來源內建預設＋免 token 更新（公開 repo）；config.sample.json 移除內部網址/帳號 |
| **v1.1.2** | 2026-11-20 | 托盤內建 30 分自動掃描（排程被封鎖也照常運作）；setup 誠實回報＋被擋自動改子資料夾任務＋安裝完立即啟動托盤 |
| **v1.1.1** | 2026-11-20 | 修復：線上更新寫檔補回 BOM（無 BOM 會讓更新後無法啟動）；更新完成顯示 ✅ 提示框 |
| **v1.1.0** | 2026-11-20 | 卡片「剩餘」格式＋逐項增減上色（綠/紅/灰）；段落縮排排版＋卡片間距；報告只留 3 天；⟳ 立即檢查顯示「⏳ 檢查中…」；版本比較防呆；crash 記錄器 |
| **v1.0.0** | 2026-11-20 | 首個獨立版本：托盤常駐＋30 分自動掃描＋雷達視窗（搜尋/在途）＋通知卡＋⤓ 檢查更新＋5 分鐘自癒＋開機自啟 |

> 每版詳細內容見 [CHANGELOG.md](CHANGELOG.md)；所有版本程式檔留檔於 `history/`。

**實測紀錄（2026-11-20）**：線上更新全流程已端到端驗證——偵測新版 → 詢問 → 下載 → ✅ 完成框 → 自動重啟接手，托盤存活、版號自動同步。

---

*目前版本 v1.1.1 ｜ 文件更新 2026-11-20 ｜ 維護：Hugo + Hermes Agent*
