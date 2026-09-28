# Claude Desktop 繁體中文翻譯套件

將 macOS 版 Claude Desktop 應用程式翻譯為繁體中文（台灣）。已於 Claude Desktop 2.9939.x 驗證。

## 翻譯涵蓋範圍

同一份詞典 `data/translations.json`（英文訊息 → 繁中訊息，ICU MessageFormat 格式）套用到三個層級：

| 層級 | 來源 | 翻譯方式 |
|------|------|----------|
| 主程序字串（原生對話框、選單、企業政策說明） | `app.asar` 內 `.vite/build/*.js` 的 `defaultMessage` | 原始碼層級替換（零執行時開銷） |
| 桌面訊息目錄（視窗外框、原生提示） | `Contents/Resources/en-US.json` | 以翻譯後的目錄取代（保留備份） |
| Web UI（claude.ai 遠端內容，佔可見文字約 95%） | DOM | 注入 `mainView.js` 的 MutationObserver 即時翻譯 |

Web UI 翻譯支援：

- 一般字串（完全比對）
- 含變數的字串，例如 `Resets in {time}`（轉為正規表達式樣板）
- 複數與選擇字串，例如 `{count, plural, one {# file} other {# files}}`（依分支展開）
- 含連結或粗體的字串，例如 `Read our <link>privacy policy</link>`（依標籤拆成片段）
- `placeholder`、`title`、`aria-label` 屬性

對話內容、Claude 回應、輸入框、程式碼區塊與終端機不會被翻譯。

## 快速開始

### 前置需求

- macOS + Claude Desktop（`/Applications/Claude.app`）
- [Node.js](https://nodejs.org/) 與 asar CLI：`npm install -g @electron/asar`
- Python 3

### 部署翻譯

```bash
git clone https://github.com/jamie950315/Claude_App_TC.git
cd Claude_App_TC
./deploy.sh
```

腳本會關閉 Claude、套用翻譯、更新完整性雜湊、重新簽署，再重新開啟 Claude。

> 若在 Claude Desktop 內的 Claude Code 工作階段執行，關閉 Claude 會中斷該工作階段。請改用終端機執行，或使用 `./deploy.sh --no-launch` 後自行重新啟動 Claude。

### 其他指令

```bash
./deploy.sh --check       # 檢查目前翻譯狀態
./deploy.sh --undo        # 還原為未翻譯的原版應用程式
./deploy.sh --no-launch   # 部署但不關閉／重新開啟 Claude
CLAUDE_APP=/path/to/Claude.app ./deploy.sh   # 指定要處理的 app 副本（測試用）
```

## Claude Desktop 更新後

應用程式更新會覆蓋 `app.asar` 與 `en-US.json`，翻譯會被清除。重新執行：

```bash
./deploy.sh
```

偵測到未翻譯的原版檔案時，腳本會自動更新備份（`app.asar.bak`、`en-US.json.bak`），所以 `--undo` 永遠還原到目前版本。

### 補上新版本的新字串

`missing` 也會讀取 Claude 快取中的最新 claude.ai 程式碼（需 `pip install zstandard`），可抓到比 app 內附目錄更新的字串。

```bash
python3 lib/zhtw.py missing data/translations.json /Applications/Claude.app .work/in
# 將 .work/in/bNNN.json 翻譯為 .work/out/bNNN.json（key 相同）
python3 lib/zhtw.py merge data/translations.json .work/in .work/out
./deploy.sh
```

## 新增或修正翻譯

編輯 `data/translations.json`：

```json
{
  "English text": "中文翻譯",
  "Resets in {time}": "{time}後重設"
}
```

- Key 必須與英文原文**完全一致**（區分大小寫、含標點）；有變數時使用 ICU 原始格式
- 翻譯需保留相同的變數名稱、複數／選擇分支 key 與 `<tag>` 標籤
- 修改後執行 `./deploy.sh` 即可套用

## 專案結構

```
├── deploy.sh              # 部署／檢查／還原
├── lib/
│   ├── zhtw.py            # 建置步驟（注入、原始碼替換、目錄翻譯、擷取新字串、合併）
│   ├── icu.py             # ICU MessageFormat 解析器
│   └── inject.js          # Web UI 翻譯執行時
└── data/
    ├── translations.json  # 主翻譯詞典（約 34,000 組，涵蓋 2.9939.2）
    └── entitlements.plist # 重新簽署用 entitlements
```

## 疑難排解

| 問題 | 解決方式 |
|------|----------|
| 應用程式啟動後閃退 | ASAR header 雜湊不正確，執行 `./deploy.sh --check` 確認後重新部署 |
| Cowork 顯示「Invalid installation」 | Entitlements 遺失，確認 `data/entitlements.plist` 存在後重新部署 |
| 部分文字仍為英文 | 該字串可能不在詞典中，或由伺服器動態產生；找到確切文字後新增至 `translations.json` |
| 對話內容被翻譯 | 在 `lib/inject.js` 的 `SKIP` 選擇器加入該區塊 |
| `asar` 指令找不到 | `npm install -g @electron/asar` |

## 授權條款

本專案為個人工具，僅供學習與研究用途。Claude 為 Anthropic 的商標。
