# Claude Desktop Traditional Chinese (zh-TW) Translation Kit

## Overview

This project translates `/Applications/Claude.app` (Electron desktop app, verified on 2.9939.x) to Traditional Chinese (Taiwan).
One dictionary, `data/translations.json` (English message → zh-TW message, ICU MessageFormat), feeds three layers:

| Layer | Where the text lives | Method |
|-------|----------------------|--------|
| A. Main-process strings (native dialogs, menus, enterprise policy docs) | `defaultMessage:"…"` in `app.asar` → `.vite/build/*.js` (index.js + `index.chunk-*.js`) | Source-level replacement |
| B. Desktop catalog (window chrome, native prompts) | `Contents/Resources/en-US.json` (react-intl catalog keyed by ID, loaded by the main process for the en-US locale) | Replaced with a translated copy (by English text) |
| C. Web UI (claude.ai, loaded remotely into the main view — ~95% of visible text) | DOM | MutationObserver injected into the `mainView.js` preload |

Notes on the current app structure:
- The web UI is still served remotely from claude.ai, but the app ships a full copy of its message catalog in
  `Resources/ion-dist/i18n/en-US.json` (~31k messages). That file is the source for new web UI strings.
- `app.asar.unpacked/` contains native modules and executables (`spawn-helper`, `github-mcp-server`, `*.node`).
  They must stay unpacked when repacking (`zhtw.py unpack-pattern` / `verify-unpacked`), otherwise the terminal
  and bundled MCP servers break.

## Commands

```bash
./deploy.sh              # deploy (quits and relaunches Claude)
./deploy.sh --no-launch  # deploy without quitting Claude; restart it yourself
./deploy.sh --check      # status: injection, catalog, integrity hash, entitlements
./deploy.sh --undo       # restore app.asar / en-US.json from backups
CLAUDE_APP=/path/to/Claude.app ./deploy.sh   # target a copy (testing)
```

Deploying replaces files inside the running app; running it from a Claude Code session inside Claude Desktop
kills that session when Claude quits. Use `--no-launch` there, or run it from Terminal.

Prerequisites: macOS, Python 3, Node.js + `npm install -g @electron/asar`.

## Project Structure

```
deploy.sh               # Deploy / check / undo
lib/zhtw.py             # All build steps (inject, patch-defaults, catalog, missing, merge, stats, asar helpers)
lib/icu.py              # Minimal ICU MessageFormat parser/expander
lib/inject.js           # Web UI runtime (MutationObserver); data is embedded at deploy time
data/translations.json  # Master dictionary (EN → zh-TW, ~34k messages; covers Claude 2.9939.2 + cached claude.ai bundles)
data/entitlements.plist # Entitlements for ad-hoc re-signing (virtualization is required by Cowork)
backup_v1/              # Old v1 scripts (reference only)
claude_intl_messages.json, claude_ui_strings_categorized.txt  # Old reference extracts (v1 era)
.work/                  # (gitignored) translation batches while updating
```

## Web UI runtime (lib/inject.js)

`zhtw.py inject` compiles the dictionary into:
- **exact** strings (`Map` lookup; also tried on the trimmed text),
- **templates**: messages with `{args}` become anchored regexes (`{name}` → `(.+?)`, plural `#` → number);
  plural/select messages are expanded per branch (English branch → same Chinese key, else `other`),
- **rich-text fragments**: `<link>…</link>` messages are split at tags, because React renders each part as a
  separate text node; fragments are paired by position (or by tag name if the order differs).

Templates are bucketed by 2-char literal prefix/suffix so a text node is tested against few regexes; misses are cached.
Translated: text nodes and `placeholder` / `title` / `aria-label` / `aria-description`.
Skipped (user content): the `SKIP` selector — chat messages, Claude responses, markdown, editors, `pre`/`code`, xterm.
If user content gets translated, extend `SKIP`.

The asar integrity hash (`ElectronAsarIntegrity` in Info.plist) is the SHA256 of the asar **header** only; the
script updates it and re-signs ad hoc with `data/entitlements.plist`. Wrong hash → crash on launch; missing
entitlements → Cowork "Invalid installation".

Backups: a clean (untranslated) `app.asar` / `en-US.json` found at deploy time always refreshes
`app.asar.bak` / `en-US.json.bak`, so backups follow app updates.

## Updating after a Claude Desktop release

```bash
python3 lib/zhtw.py missing data/translations.json /Applications/Claude.app .work/in   # untranslated → batches
# translate .work/in/bNNN.json → .work/out/bNNN.json (same keys), validate, then:
python3 lib/zhtw.py merge data/translations.json .work/in .work/out
./deploy.sh
```

`missing` reads the web catalog, the desktop catalog (prefers `en-US.json.bak`), main-process `defaultMessage`s
(prefers `app.asar.bak`), so it works on an already translated app, and the `defaultMessage`s of claude.ai bundles in
Claude's HTTP cache (`~/Library/Application Support/Claude/Cache/Cache_Data`, zstd, needs `pip install zstandard`):
the remote web UI is usually newer than the ion-dist catalog. Open the new pages in Claude first so they get cached.
Text that comes from server APIs (e.g. notification setting names) is in none of these and must be added by hand.

## Translation conventions

- Taiwan Traditional Chinese (設定, 檔案, 資料夾, 伺服器, 帳號, 預設, 連線…); never Simplified or mainland terms.
- Formal 「您」, concise labels, full-width punctuation in Chinese prose.
- Keep product/model/brand names and technical terms in English (Claude, Claude Code, Cowork, Opus, API, MCP, GitHub…).
- ICU must stay valid: same argument names, plural/select keys and `#`; same rich-text tag names, same order when possible.
- Keys are the exact English message (ICU source form), case- and punctuation-sensitive.
- Strings built at runtime without a catalog message (e.g. server-side text) need manual dictionary entries
  matching the rendered DOM text.
