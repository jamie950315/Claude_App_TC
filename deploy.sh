#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# Claude Desktop Traditional Chinese (zh-TW) Translation Deploy Script
# ============================================================================
#
# Usage:
#   ./deploy.sh              Deploy translation to Claude Desktop
#   ./deploy.sh --check      Check current translation status without modifying
#   ./deploy.sh --undo       Restore original (untranslated) app from backup
#   ./deploy.sh --no-launch  Deploy without quitting/relaunching Claude
#
# Prerequisites:
#   - macOS with Claude Desktop installed at /Applications/Claude.app
#   - Node.js + asar CLI: npm install -g @electron/asar
#   - Python 3
#
# Set CLAUDE_APP=/path/to/Claude.app to target a specific copy.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$SCRIPT_DIR/data"
ZHTW="$SCRIPT_DIR/lib/zhtw.py"

# Auto-detect Claude.app: explicit CLAUDE_APP, then local copy, then /Applications
if [ -n "${CLAUDE_APP:-}" ]; then
    APP_PATH="${CLAUDE_APP%/}"
elif [ -d "$SCRIPT_DIR/Claude.app" ]; then
    APP_PATH="$SCRIPT_DIR/Claude.app"
elif [ -d "/Applications/Claude.app" ]; then
    APP_PATH="/Applications/Claude.app"
else
    echo -e "\033[0;31m[x]\033[0m Claude.app not found in $SCRIPT_DIR or /Applications"
    exit 1
fi

RESOURCES="$APP_PATH/Contents/Resources"
ASAR_PATH="$RESOURCES/app.asar"
ASAR_BAK="$RESOURCES/app.asar.bak"
CATALOG="$RESOURCES/en-US.json"
CATALOG_BAK="$RESOURCES/en-US.json.bak"
PLIST_PATH="$APP_PATH/Contents/Info.plist"
WORK_DIR="$(mktemp -d)"

TRANSLATIONS="$DATA_DIR/translations.json"
ENTITLEMENTS="$DATA_DIR/entitlements.plist"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[x]${NC} $1"; }
info()  { echo -e "${CYAN}[i]${NC} $1"; }

cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT

is_installed_app() { [ "$APP_PATH" = "/Applications/Claude.app" ]; }

# ============================================================================
# Preflight checks
# ============================================================================
preflight() {
    local ok=true
    [ -d "$APP_PATH" ] || { err "Claude Desktop not found at $APP_PATH"; ok=false; }
    command -v asar &>/dev/null || { err "'asar' not found. Install with: npm install -g @electron/asar"; ok=false; }
    command -v python3 &>/dev/null || { err "python3 not found"; ok=false; }
    [ -f "$TRANSLATIONS" ] || { err "Translation file not found: $TRANSLATIONS"; ok=false; }
    [ -f "$ENTITLEMENTS" ] || { err "Entitlements file not found: $ENTITLEMENTS"; ok=false; }
    [ "$ok" = true ] || exit 1
}

# Electron integrity check uses the SHA256 of the asar header only
compute_header_hash() {
    python3 - "$1" << 'PYEOF'
import struct, hashlib, sys
with open(sys.argv[1], 'rb') as f:
    prefix = f.read(16)
    header_size = struct.unpack('<I', prefix[12:16])[0]
    print(hashlib.sha256(f.read(header_size)).hexdigest())
PYEOF
}

# True when the desktop catalog already contains Chinese text (i.e. was replaced by us)
catalog_translated() {
    python3 - "$1" << 'PYEOF'
import json, re, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
sys.exit(0 if any(re.search(r'[一-鿿]', v) for v in d.values()) else 1)
PYEOF
}

quit_claude() {
    if is_installed_app && [ "$LAUNCH" = true ]; then
        info "Closing Claude..."
        osascript -e 'quit app "Claude"' 2>/dev/null || true
        sleep 3
    fi
}

launch_claude() {
    if is_installed_app && [ "$LAUNCH" = true ]; then
        info "Launching Claude..."
        open -a Claude
    fi
}

resign() {
    info "Re-signing with entitlements..."
    codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" "$APP_PATH" 2>/dev/null
}

# ============================================================================
# --check: Show translation status
# ============================================================================
do_check() {
    info "Checking Claude Desktop translation status ($APP_PATH)"
    info "App version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_PATH")"
    echo

    local extract_dir="$WORK_DIR/check"
    asar extract "$ASAR_PATH" "$extract_dir" 2>/dev/null

    if grep -q "__czhtw" "$extract_dir/.vite/build/mainView.js" 2>/dev/null; then
        log "Web UI translation: ACTIVE (MutationObserver)"
    else
        warn "Web UI translation: NOT INJECTED"
    fi

    if grep -rqs "無法載入應用程式設定" "$extract_dir/.vite/build/"; then
        log "Main-process strings: TRANSLATED (source-level)"
    else
        warn "Main-process strings: NOT TRANSLATED"
    fi

    if [ -f "$CATALOG" ] && catalog_translated "$CATALOG"; then
        log "Desktop catalog (en-US.json): TRANSLATED"
    else
        warn "Desktop catalog (en-US.json): NOT TRANSLATED"
    fi

    local expected actual
    expected=$(/usr/libexec/PlistBuddy -c "Print :ElectronAsarIntegrity:Resources/app.asar:hash" "$PLIST_PATH" 2>/dev/null || echo "")
    actual=$(compute_header_hash "$ASAR_PATH")
    if [ "$expected" = "$actual" ]; then
        log "ASAR integrity hash: OK"
    else
        warn "ASAR integrity hash: MISMATCH (app will not launch)"
    fi

    if codesign -d --entitlements :- "$APP_PATH/Contents/MacOS/Claude" 2>&1 | grep -q "virtualization"; then
        log "Virtualization entitlement: PRESENT (Cowork should work)"
    else
        warn "Virtualization entitlement: MISSING (Cowork may show 'corrupted' error)"
    fi

    info "Translation dictionary: $(python3 -c "import json; print(len(json.load(open('$TRANSLATIONS'))))") entries"
    python3 "$ZHTW" stats "$TRANSLATIONS"
}

# ============================================================================
# --undo: Restore original app
# ============================================================================
do_undo() {
    warn "Restoring original Claude Desktop..."
    if [ ! -f "$ASAR_BAK" ]; then
        err "No backup found at $ASAR_BAK"
        exit 1
    fi

    quit_claude
    cp "$ASAR_BAK" "$ASAR_PATH"
    log "Restored app.asar from backup"
    if [ -f "$CATALOG_BAK" ]; then
        cp "$CATALOG_BAK" "$CATALOG"
        log "Restored en-US.json from backup"
    fi

    local hash
    hash=$(compute_header_hash "$ASAR_PATH")
    /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $hash" "$PLIST_PATH"
    resign
    log "Claude restored"
    launch_claude
}

# ============================================================================
# Main deploy
# ============================================================================
do_deploy() {
    log "Claude Desktop zh-TW Translation Deploy"
    info "App: $APP_PATH ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST_PATH"))"
    echo

    quit_claude

    # Step 1: Extract asar
    info "Extracting app.asar..."
    local extract_dir="$WORK_DIR/extract"
    asar extract "$ASAR_PATH" "$extract_dir"
    local build_dir="$extract_dir/.vite/build"
    local main_view="$build_dir/mainView.js"
    if [ ! -f "$main_view" ]; then
        err "mainView.js not found in asar! App structure may have changed."
        exit 1
    fi

    # Step 2: Backups. A clean (untranslated) asar means the app was installed or
    # updated since the last deploy, so any older backup is stale and is replaced.
    if ! grep -q "__czhtw" "$main_view"; then
        info "Backing up clean app.asar -> app.asar.bak"
        cp "$ASAR_PATH" "$ASAR_BAK"
    elif [ ! -f "$ASAR_BAK" ]; then
        warn "app.asar is already translated and no backup exists; --undo will be unavailable"
    fi
    if [ -f "$CATALOG" ] && ! catalog_translated "$CATALOG"; then
        info "Backing up clean en-US.json -> en-US.json.bak"
        cp "$CATALOG" "$CATALOG_BAK"
    fi

    # Step 3: Source-level replacement in main-process bundles (native dialogs, menus)
    info "Replacing defaultMessage strings in main-process bundles..."
    python3 "$ZHTW" patch-defaults "$TRANSLATIONS" "$build_dir"

    # Step 4: Inject the Web UI translator into the main view preload
    info "Injecting Web UI translator into mainView.js..."
    python3 "$ZHTW" inject "$TRANSLATIONS" "$main_view"

    # Step 5: Repack asar, keeping native modules and executables unpacked
    info "Repacking app.asar..."
    local new_asar="$WORK_DIR/app.asar"
    local unpack
    unpack=$(python3 "$ZHTW" unpack-pattern "$ASAR_PATH")
    if [ -n "$unpack" ]; then
        (cd "$extract_dir" && asar pack . "$new_asar" --unpack "$unpack")
    else
        (cd "$extract_dir" && asar pack . "$new_asar")
    fi
    python3 "$ZHTW" verify-unpacked "$ASAR_PATH" "$new_asar"

    # Step 6: Desktop message catalog (window chrome, menus, native prompts)
    local new_catalog="$WORK_DIR/en-US.json"
    if [ -f "$CATALOG_BAK" ]; then
        info "Translating desktop catalog en-US.json..."
        python3 "$ZHTW" catalog "$TRANSLATIONS" "$CATALOG_BAK" "$new_catalog"
    else
        warn "Desktop catalog backup missing; skipping en-US.json"
    fi

    # Step 7: Deploy files and update integrity hash
    info "Deploying..."
    local hash
    hash=$(compute_header_hash "$new_asar")
    cp "$new_asar" "$ASAR_PATH"
    if [ -d "$new_asar.unpacked" ]; then
        rsync -a "$new_asar.unpacked/" "$RESOURCES/app.asar.unpacked/"
    fi
    [ -f "$new_catalog" ] && cp "$new_catalog" "$CATALOG"
    /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $hash" "$PLIST_PATH"
    info "Integrity hash: $hash"

    # Step 8: Re-sign with entitlements
    resign

    echo
    log "Deploy complete! App: $APP_PATH"
    log "Translation entries: $(python3 -c "import json; print(len(json.load(open('$TRANSLATIONS'))))")"
    if is_installed_app; then
        launch_claude
        [ "$LAUNCH" = true ] || info "Restart Claude to load the translation."
    else
        info "Local app translated. To use, copy to /Applications or run directly."
    fi
}

# ============================================================================
# Entry point
# ============================================================================
LAUNCH=true
ACTION=deploy
for arg in "$@"; do
    case "$arg" in
        --check) ACTION=check ;;
        --undo) ACTION=undo ;;
        --no-launch) LAUNCH=false ;;
        --help|-h)
            echo "Usage: $0 [--check|--undo] [--no-launch]"
            echo
            echo "  (no args)    Deploy zh-TW translation to Claude Desktop"
            echo "  --check      Check current translation status"
            echo "  --undo       Restore original untranslated app from backup"
            echo "  --no-launch  Do not quit or relaunch Claude (restart it yourself)"
            echo
            echo "  CLAUDE_APP=/path/to/Claude.app $0   Target a specific app copy"
            exit 0
            ;;
        *)
            err "Unknown option: $arg"
            echo "Usage: $0 [--check|--undo] [--no-launch]"
            exit 1
            ;;
    esac
done

preflight
case "$ACTION" in
    check) do_check ;;
    undo) do_undo ;;
    deploy) do_deploy ;;
esac
