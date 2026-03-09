# Claude Desktop 繁體中文翻譯套件

將 macOS 版 Claude Desktop 應用程式翻譯為繁體中文（台灣）。

## 翻譯涵蓋範圍

| 層級 | 來源 | 翻譯方式 |
|------|------|----------|
| Electron 原生對話框（錯誤提示、權限請求） | `index.js` 中的 `defaultMessage` | 原始碼層級字串替換（零執行時開銷） |
| Web UI（claude.ai 遠端內容） | `mainView.js` 注入 | MutationObserver 即時 DOM 翻譯 |
| Quick Entry 視窗 | `zh_TW.lproj/Localizable.strings` | macOS 原生本地化（應用程式已內建） |

Web UI 佔可見文字的 94%，使用 5,232 組英中對照詞典進行即時翻譯。

## 快速開始

### 前置需求

- macOS + Claude Desktop（`/Applications/Claude.app`）
- [Node.js](https://nodejs.org/)
- Python 3
- asar CLI：`npm install -g @electron/asar`

### 部署翻譯

```bash
git clone https://github.com/jamie950315/Claude_App_TC.git
cd Claude_App_TC
./deploy.sh
```

### 其他指令

```bash
./deploy.sh --check   # 檢查目前翻譯狀態
./deploy.sh --undo    # 還原為未翻譯的原版應用程式
```

## 運作原理

部署腳本使用兩層互補的翻譯策略：

### 層級 A：原始碼層級替換

針對 `app.asar` 內的 `index.js`，以正規表達式將 `defaultMessage:"English"` 直接替換為 `defaultMessage:"中文"`。涵蓋約 282 組字串（錯誤對話框、權限提示、更新通知、右鍵選單等），**零執行時開銷**。

### 層級 B：MutationObserver 注入

將翻譯腳本注入 `mainView.js`，在 Web UI 載入時即時翻譯 DOM 中的文字節點：

- 使用 `Map` 字典，O(1) 查詢效能
- `TreeWalker` 遍歷所有文字節點
- 翻譯元素屬性：`placeholder`、`title`、`ariaLabel`
- `MutationObserver` 搭配 `characterData: true` 監聽新增節點與文字變更
- `requestAnimationFrame` 批次處理，避免效能衝擊

### ASAR 完整性處理

Electron 啟動時會驗證 `app.asar` 的完整性。腳本會自動：

1. 計算修改後 asar 的 **header SHA256 雜湊**（非整個檔案）
2. 更新 `Info.plist` 中的 `ElectronAsarIntegrity` 雜湊值
3. 使用正確的 entitlements 重新簽署應用程式

## Claude Desktop 更新後

應用程式更新會覆蓋 `app.asar`，翻譯會被清除。只需重新執行：

```bash
./deploy.sh
```

腳本會自動備份新版 asar（若尚無備份）、注入翻譯、重新簽署。

## 新增翻譯詞條

編輯 `data/translations.json`，加入新的英中對照：

```json
{
  "English text": "中文翻譯"
}
```

注意事項：
- Key 必須與 DOM 中的文字**完全一致**（區分大小寫、含標點符號）
- React 可能將句子拆分至多個 DOM 節點，需分別新增每個片段
- 修改後執行 `./deploy.sh` 即可套用

## 專案結構

```
├── deploy.sh              # 主要部署腳本
├── CLAUDE.md              # AI 助手參考文件
├── README.md              # 本文件
└── data/
    ├── translations.json  # 主翻譯詞典（5,232 組）
    └── entitlements.plist # macOS 簽署用 entitlements
```

## 疑難排解

| 問題 | 解決方式 |
|------|----------|
| 應用程式啟動後閃退 | ASAR header 雜湊不正確，重新執行 `./deploy.sh` |
| Cowork 顯示「Invalid installation」 | Entitlements 遺失，確認 `data/entitlements.plist` 存在後重新部署 |
| 部分文字仍為英文 | 該字串可能不在詞典中，找到確切文字後新增至 `translations.json` |
| `asar` 指令找不到 | `npm install -g @electron/asar` |

## 授權條款

本專案為個人工具，僅供學習與研究用途。Claude 為 Anthropic 的商標。
