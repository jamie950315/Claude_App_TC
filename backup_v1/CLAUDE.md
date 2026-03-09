# Claude Desktop Traditional Chinese (zh-TW) Translation Kit

## Overview

This project translates `/Applications/Claude.app` (Electron-based desktop app) to Traditional Chinese (Taiwan). The app has **three UI layers**, each translated differently:

| Layer | Source | Method |
|-------|--------|--------|
| 1. Electron native UI (menu bar, dialogs) | `ja-JP.json` locale file | Replace JSON locale file in Resources/ |
| 2. Web UI (claude.ai remote content) | MutationObserver JS injection | Inject script into `mainView.js` inside `app.asar` |
| 3. Quick Entry window | `zh_TW.lproj/Localizable.strings` | macOS native localization (already handled by app) |

Layer 2 (Web UI) is where 99% of visible text lives and where this toolkit focuses.

## Quick Start

```bash
# Deploy translation (after Claude app update wipes it)
./deploy.sh

# Check current translation status
./deploy.sh --check

# Restore original untranslated app
./deploy.sh --undo
```

## Prerequisites

- macOS with Claude Desktop installed at `/Applications/Claude.app`
- Node.js + asar CLI: `npm install -g @electron/asar`
- Python 3

## Project Structure

```
TranslateThisApp/
├── deploy.sh                    # Main deployment script
├── CLAUDE.md                    # This file (instructions for AI)
├── data/
│   ├── translations.json        # Master dictionary (5,000+ EN→zh-TW pairs)
│   ├── ja-JP.json               # Electron native UI locale (menu bar)
│   └── entitlements.plist       # macOS entitlements for codesigning
└── claude_intl_messages.json    # Raw react-intl IDs (reference for updates)
```

## How the Translation Works

### The Injection Script

`deploy.sh` generates a self-contained JavaScript IIFE from `data/translations.json` and injects it into the Electron preload script (`mainView.js` inside `app.asar`). The script:

1. Builds a dictionary object `D` mapping English strings to Chinese translations
2. Creates a reverse `Set` of translated values to avoid re-translating
3. Uses a `TreeWalker` to find and translate all text nodes in the DOM
4. Translates element attributes: `placeholder`, `title`, `ariaLabel`
5. Sets up a `MutationObserver` to catch dynamically added content
6. Batches mutations via `requestAnimationFrame` for performance

The script is injected just before `//# sourceMappingURL=mainView.js.map` in mainView.js.

### ASAR Integrity (Critical)

Electron validates `app.asar` integrity on launch. After modifying the asar:

1. **Compute the HEADER hash** (NOT the whole file hash):
   ```python
   import struct, hashlib
   with open('app.asar', 'rb') as f:
       prefix = f.read(16)
       header_size = struct.unpack('<I', prefix[12:16])[0]
       header = f.read(header_size)
       hash = hashlib.sha256(header).hexdigest()
   ```
2. **Update Info.plist**: Set `ElectronAsarIntegrity > Resources/app.asar > hash` to the new hash
3. **Re-sign with entitlements**: `codesign --force --deep --sign - --entitlements entitlements.plist /Applications/Claude.app`

If the hash is wrong, the app crashes on launch. If entitlements are missing, the Cowork feature breaks with "Invalid installation" error.

### Locale Hijacking (Menu Bar)

Claude Desktop uses `@formatjs/intl` for Electron native UI. It loads locale files matching `/[a-z]{2}-[A-Z]{2}\.json/` from `Contents/Resources/`. Since there's no `zh-TW` locale built in, we hijack `ja-JP.json` (Japanese) and replace its content with Chinese translations. The user must select **Japanese** in Claude Settings → Language to activate menu translations.

## When Claude Desktop Updates

When the app updates, the translation will be wiped because the app.asar is replaced. To restore:

```bash
cd /Users/jamie/Downloads/TranslateThisApp
./deploy.sh
```

The script automatically:
- Closes Claude
- Backs up the new app.asar (if no backup exists)
- Extracts, injects translation, repacks
- Updates the integrity hash
- Re-signs with proper entitlements
- Relaunches Claude

## Adding New Translations

### Finding untranslated strings

1. Open Claude Desktop and navigate to the page with untranslated text
2. Note the exact English text that needs translation

### Updating translations.json

Edit `data/translations.json` to add new entries:

```json
{
  "English text": "中文翻譯",
  "Another string": "另一個字串"
}
```

**Important rules:**
- Keys must match the **exact** text as it appears in the DOM (case-sensitive, including punctuation)
- For React-fragmented text (sentences split by inline elements like `<a>`), you need to add each fragment separately
- Example: "Read our " + "privacy policy" + " for details." needs three entries
- After editing, run `./deploy.sh` to apply

### Extracting new strings from app updates

If Claude Desktop adds new UI strings after an update, extract them from the JavaScript bundles:

```bash
# Extract app.asar
asar extract /Applications/Claude.app/Contents/Resources/app.asar /tmp/claude_extract

# Find react-intl defaultMessage strings
grep -oP 'defaultMessage:"[^"]*"' /tmp/claude_extract/.vite/build/*.js | \
  sed 's/.*defaultMessage:"//;s/"$//' | sort -u > /tmp/new_strings.txt
```

Compare with existing translations to find what's new:

```python
import json
with open('data/translations.json') as f:
    existing = json.load(f)
with open('/tmp/new_strings.txt') as f:
    new_strings = [line.strip() for line in f if line.strip()]
missing = [s for s in new_strings if s not in existing]
print(f"{len(missing)} new strings to translate")
for s in missing[:20]:
    print(f"  {s}")
```

### Translating new strings

When translating, follow these conventions:
- Use Taiwan-standard Traditional Chinese (not HK or mainland simplified)
- Keep technical terms in English when they are industry-standard (e.g., "API", "JSON", "Claude")
- Use "您" (formal) for user-facing text
- Common term mapping:
  - Settings → 設定
  - Chat/Conversation → 對話
  - Project → 專案
  - Search → 搜尋
  - Delete → 刪除
  - Cancel → 取消
  - Save → 儲存
  - Share → 分享
  - Upload/Download → 上傳/下載

## Troubleshooting

### App crashes on launch
- The ASAR header hash in Info.plist is wrong. Re-run `./deploy.sh`.

### Cowork shows "Invalid installation"
- Entitlements were lost during signing. Make sure `data/entitlements.plist` exists and contains `com.apple.security.virtualization`. Re-run `./deploy.sh`.

### Some text still in English
- The string may not be in `translations.json`. Find the exact text and add it.
- React may split text across multiple DOM nodes. Add each fragment separately.
- Dynamic strings with runtime values (e.g., "Resets in 2 hr 32 min") cannot be matched by static dictionary. These require regex-based translation (not yet implemented).
- ICU plural/select format strings (e.g., `{count, plural, one {# item} other {# items}}`) are handled by react-intl at runtime and cannot be intercepted.

### Menu bar still in English
- Go to Claude Settings → Language → select **Japanese** (日本語). This activates our hijacked ja-JP.json.

### `asar` command not found
```bash
npm install -g @electron/asar
```

## Architecture Notes

- **mainView.js** is the preload script for the main WebContentsView that loads claude.ai
- The injection runs in the **renderer process** context (has access to `document`, `window`)
- The `__czhtw` flag on `window` prevents double-injection
- `seen` WeakSet is reset after initial pass so the MutationObserver can process updated nodes
- Performance: ~5,000 dictionary entries add ~280KB to mainView.js but cause negligible runtime overhead thanks to O(1) object property lookup and RAF batching
