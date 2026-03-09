#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Claude Desktop Traditional Chinese (zh-TW) Translation Deploy Script
# ============================================================================
#
# Usage:
#   ./deploy.sh          Deploy translation to Claude Desktop
#   ./deploy.sh --check  Check current translation status without modifying
#   ./deploy.sh --undo   Restore original (untranslated) app from backup
#
# Prerequisites:
#   - macOS with Claude Desktop installed at /Applications/Claude.app
#   - Node.js (for `asar` CLI tool)
#   - Python 3
#   - asar CLI: npm install -g @electron/asar
#
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"

# Auto-detect Claude.app: prefer local copy, fall back to /Applications
if [ -d "$SCRIPT_DIR/Claude.app" ]; then
    APP_PATH="$SCRIPT_DIR/Claude.app"
elif [ -d "/Applications/Claude.app" ]; then
    APP_PATH="/Applications/Claude.app"
else
    echo -e "\033[0;31m[x]\033[0m Claude.app not found in $SCRIPT_DIR or /Applications"
    exit 1
fi

RESOURCES="$APP_PATH/Contents/Resources"
ASAR_PATH="$RESOURCES/app.asar"
PLIST_PATH="$APP_PATH/Contents/Info.plist"
WORK_DIR="$(mktemp -d)"

# Files
TRANSLATIONS="$DATA_DIR/translations.json"
LOCALE_FILE="$DATA_DIR/ja-JP.json"
ENTITLEMENTS="$DATA_DIR/entitlements.plist"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[x]${NC} $1"; }
info()  { echo -e "${CYAN}[i]${NC} $1"; }

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ============================================================================
# Preflight checks
# ============================================================================
preflight() {
    local ok=true

    if [ ! -d "$APP_PATH" ]; then
        err "Claude Desktop not found at $APP_PATH"
        ok=false
    fi

    if ! command -v asar &>/dev/null; then
        err "'asar' not found. Install with: npm install -g @electron/asar"
        ok=false
    fi

    if ! command -v python3 &>/dev/null; then
        err "python3 not found"
        ok=false
    fi

    if [ ! -f "$TRANSLATIONS" ]; then
        err "Translation file not found: $TRANSLATIONS"
        ok=false
    fi

    if [ ! -f "$LOCALE_FILE" ]; then
        err "Locale file not found: $LOCALE_FILE"
        ok=false
    fi

    if [ ! -f "$ENTITLEMENTS" ]; then
        err "Entitlements file not found: $ENTITLEMENTS"
        ok=false
    fi

    if [ "$ok" = false ]; then
        exit 1
    fi
}

# ============================================================================
# Compute ASAR header SHA256 (Electron integrity check uses header hash only)
# ============================================================================
compute_header_hash() {
    local asar_file="$1"
    python3 -c "
import struct, hashlib
with open('$asar_file', 'rb') as f:
    prefix = f.read(16)
    header_size = struct.unpack('<I', prefix[12:16])[0]
    header = f.read(header_size)
    print(hashlib.sha256(header).hexdigest())
"
}

# ============================================================================
# Generate injection script from translations.json
# ============================================================================
generate_injection() {
    local output="$1"
    python3 - "$TRANSLATIONS" "$output" << 'PYEOF'
import json, sys

translations_path = sys.argv[1]
output_path = sys.argv[2]

with open(translations_path) as f:
    translations = json.load(f)

lines = []
for en, zh in sorted(translations.items()):
    en_esc = en.replace('\\', '\\\\').replace("'", "\\'")
    zh_esc = zh.replace('\\', '\\\\').replace("'", "\\'")
    lines.append(f"'{en_esc}':'{zh_esc}'")

dict_str = ',\n    '.join(lines)

script = f""";(function(){{
  'use strict';
  if(window.__czhtw)return;
  window.__czhtw=1;
  var D={{
    {dict_str}
  }};
  var V=new Set();for(var k in D)V.add(D[k]);
  var seen=new WeakSet();
  function trText(node){{
    var t=node.nodeValue;
    if(!t)return;
    if(V.has(t))return;
    var v=D[t];
    if(v!==undefined){{node.nodeValue=v;return;}}
    if(t.length<120){{
      var tt=t.trim();
      if(tt!==t&&(v=D[tt])!==undefined)node.nodeValue=t.replace(tt,v);
    }}
  }}
  function trEl(el){{
    if(!el)return;
    var nt=el.nodeType;
    if(nt===3){{trText(el);return;}}
    if(nt!==1)return;
    var tag=el.tagName;
    if(tag==='SCRIPT'||tag==='STYLE')return;
    if(el.isContentEditable)return;
    if(seen.has(el))return;
    seen.add(el);
    if(el.placeholder&&D[el.placeholder])el.placeholder=D[el.placeholder];
    if(el.title&&D[el.title])el.title=D[el.title];
    var al=el.ariaLabel;
    if(al&&D[al])el.ariaLabel=D[al];
    var fc=el.firstChild;
    if(!fc)return;
    if(!fc.nextSibling&&fc.nodeType===3){{trText(fc);return;}}
    var w=document.createTreeWalker(el,4,{{acceptNode:function(n){{
      var p=n.parentElement;
      if(!p)return 2;
      var pt=p.tagName;
      return(pt==='SCRIPT'||pt==='STYLE'||p.isContentEditable)?2:1;
    }}}});
    var n;while((n=w.nextNode()))trText(n);
  }}
  var queue=[];
  var rafId=0;
  function flush(){{
    rafId=0;
    var nodes=queue;
    queue=[];
    for(var i=0;i<nodes.length;i++)trEl(nodes[i]);
  }}
  var obs=new MutationObserver(function(muts){{
    for(var i=0;i<muts.length;i++){{
      var added=muts[i].addedNodes;
      for(var j=0;j<added.length;j++)queue.push(added[j]);
    }}
    if(!rafId)rafId=requestAnimationFrame(flush);
  }});
  function start(){{
    if(!document.body){{setTimeout(start,50);return;}}
    trEl(document.body);
    seen=new WeakSet();
    obs.observe(document.body,{{childList:true,subtree:true}});
  }}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',start);
  else start();
}})();
"""

with open(output_path, 'w') as f:
    f.write(script)

print(f"{len(translations)} translations, {len(script)} bytes")
PYEOF
}

# ============================================================================
# --check: Show translation status
# ============================================================================
do_check() {
    info "Checking Claude Desktop translation status..."
    echo

    if [ ! -f "$ASAR_PATH" ]; then
        err "app.asar not found"
        exit 1
    fi

    # Check if translation is injected
    local extract_dir="$WORK_DIR/check"
    asar extract "$ASAR_PATH" "$extract_dir" 2>/dev/null

    if grep -q "__czhtw" "$extract_dir/.vite/build/mainView.js" 2>/dev/null; then
        log "Web UI translation: ACTIVE"
    else
        warn "Web UI translation: NOT INJECTED"
    fi

    # Check locale file
    if [ -f "$RESOURCES/ja-JP.json" ]; then
        if grep -q "實際大小" "$RESOURCES/ja-JP.json" 2>/dev/null; then
            log "Electron native UI: TRANSLATED (zh-TW via ja-JP.json)"
        else
            warn "Electron native UI: ORIGINAL JAPANESE"
        fi
    else
        warn "Electron native UI: ja-JP.json NOT FOUND"
    fi

    # Check entitlements
    if codesign -d --entitlements :- "$APP_PATH/Contents/MacOS/Claude" 2>&1 | grep -q "virtualization" 2>/dev/null; then
        log "Virtualization entitlement: PRESENT (Cowork should work)"
    else
        warn "Virtualization entitlement: MISSING (Cowork may show 'corrupted' error)"
    fi

    # Show translation count
    local count
    count=$(python3 -c "import json; print(len(json.load(open('$TRANSLATIONS'))))" 2>/dev/null || echo "?")
    info "Translation dictionary: $count entries"
    info "Data directory: $DATA_DIR"
}

# ============================================================================
# --undo: Restore original app
# ============================================================================
do_undo() {
    warn "Restoring original Claude Desktop..."

    if [ ! -f "$RESOURCES/app.asar.bak" ]; then
        err "No backup found at $RESOURCES/app.asar.bak"
        err "Cannot restore without original backup."
        exit 1
    fi

    # Close Claude
    osascript -e 'quit app "Claude"' 2>/dev/null || true
    sleep 2

    # Restore asar
    cp "$RESOURCES/app.asar.bak" "$RESOURCES/app.asar"
    log "Restored app.asar from backup"

    # Restore locale
    if [ -f "$RESOURCES/ja-JP.json.bak" ]; then
        cp "$RESOURCES/ja-JP.json.bak" "$RESOURCES/ja-JP.json"
        log "Restored ja-JP.json from backup"
    fi

    # Recompute hash and re-sign
    local hash
    hash=$(compute_header_hash "$ASAR_PATH")
    /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $hash" "$PLIST_PATH"
    codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP_PATH" 2>/dev/null
    log "Re-signed app"

    open -a Claude
    log "Claude restored and launched"
}

# ============================================================================
# Main deploy
# ============================================================================
do_deploy() {
    log "Claude Desktop zh-TW Translation Deploy"
    echo

    # Step 1: Close Claude (only if modifying the installed app)
    if [ "$APP_PATH" = "/Applications/Claude.app" ]; then
        info "Closing Claude..."
        osascript -e 'quit app "Claude"' 2>/dev/null || true
        sleep 2
    else
        info "Using local app: $APP_PATH"
    fi

    # Step 2: Backup original asar (only if no backup exists)
    if [ ! -f "$RESOURCES/app.asar.bak" ]; then
        info "Creating backup: app.asar.bak"
        cp "$ASAR_PATH" "$RESOURCES/app.asar.bak"
    else
        info "Backup already exists: app.asar.bak"
    fi

    if [ ! -f "$RESOURCES/ja-JP.json.bak" ] && [ -f "$RESOURCES/ja-JP.json" ]; then
        cp "$RESOURCES/ja-JP.json" "$RESOURCES/ja-JP.json.bak"
    fi

    # Step 3: Extract asar
    info "Extracting app.asar..."
    local extract_dir="$WORK_DIR/extract"
    asar extract "$ASAR_PATH" "$extract_dir"

    # Step 4: Check if mainView.js exists
    local main_view="$extract_dir/.vite/build/mainView.js"
    if [ ! -f "$main_view" ]; then
        err "mainView.js not found in asar! App structure may have changed."
        exit 1
    fi

    # Step 5: Remove old injection if present
    if grep -q "__czhtw" "$main_view"; then
        info "Removing old translation injection..."
        python3 -c "
import re
with open('$main_view', 'r') as f:
    content = f.read()
# Remove old injection (everything between ;(function(){ ... })(); and sourcemap)
content = re.sub(r';\\(function\\(\\)\\{[\\s\\S]*?window\\.__czhtw[\\s\\S]*?\\}\\)\\(\\);\\n?', '', content)
with open('$main_view', 'w') as f:
    f.write(content)
"
    fi

    # Step 6: Generate and inject translation
    info "Generating translation injection script..."
    local injection_file="$WORK_DIR/injection.js"
    generate_injection "$injection_file"

    info "Injecting into mainView.js..."
    python3 -c "
with open('$main_view', 'r') as f:
    content = f.read()
with open('$injection_file', 'r') as f:
    injection = f.read()
marker = '//# sourceMappingURL=mainView.js.map'
if marker in content:
    content = content.replace(marker, injection + '\n' + marker)
else:
    content += '\n' + injection
with open('$main_view', 'w') as f:
    f.write(content)
print(f'mainView.js: {len(content):,} bytes')
"

    # Step 7: Repack asar
    info "Repacking app.asar..."
    local new_asar="$WORK_DIR/app.asar"
    (cd "$extract_dir" && asar pack . "$new_asar")

    # Step 8: Compute header hash
    info "Computing integrity hash..."
    local hash
    hash=$(compute_header_hash "$new_asar")
    info "Hash: $hash"

    # Step 9: Deploy
    info "Deploying..."
    cp "$new_asar" "$ASAR_PATH"
    cp "$LOCALE_FILE" "$RESOURCES/ja-JP.json"
    /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $hash" "$PLIST_PATH"

    # Step 10: Re-sign with entitlements
    info "Re-signing with entitlements..."
    codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP_PATH" 2>/dev/null

    # Step 11: Launch (only if modifying the installed app)
    if [ "$APP_PATH" = "/Applications/Claude.app" ]; then
        info "Launching Claude..."
        open -a Claude
    else
        info "Local app translated. To use, copy to /Applications or run directly."
    fi

    echo
    log "Deploy complete! App: $APP_PATH"
    log "Translation entries: $(python3 -c "import json; print(len(json.load(open('$TRANSLATIONS'))))")"
    log "Remember: Select 'Japanese' in Claude Settings > Language to activate menu translation"
}

# ============================================================================
# Entry point
# ============================================================================
preflight

case "${1:-}" in
    --check)
        do_check
        ;;
    --undo)
        do_undo
        ;;
    --help|-h)
        echo "Usage: $0 [--check|--undo|--help]"
        echo
        echo "  (no args)   Deploy zh-TW translation to Claude Desktop"
        echo "  --check     Check current translation status"
        echo "  --undo      Restore original untranslated app from backup"
        echo "  --help      Show this help"
        ;;
    "")
        do_deploy
        ;;
    *)
        err "Unknown option: $1"
        echo "Usage: $0 [--check|--undo|--help]"
        exit 1
        ;;
esac
