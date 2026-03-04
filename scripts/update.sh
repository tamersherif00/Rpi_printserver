#!/bin/bash
# update.sh — Pull latest code and redeploy without a full reinstall.
#
# Usage (from anywhere in the repo):
#   sudo ./scripts/update.sh            # pull current branch
#   sudo ./scripts/update.sh main       # pull and switch to a specific branch
#
# What it does:
#   1. git pull (on the current or specified branch)
#   2. rsync src/ → /opt/printserver/  (preserves the venv)
#   3. Replaces /etc/systemd/system/printserver-web.service if it changed
#   4. systemctl daemon-reload (only when the unit file was updated)
#   5. systemctl restart printserver-web

set -euo pipefail

INSTALL_DIR="/opt/printserver"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BRANCH="${1:-}"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
die()       { log_error "$1"; exit 1; }

# ── 0. Root check ─────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Run with sudo:  sudo $0 ${BRANCH}"

# ── 1. git pull ───────────────────────────────────────────────────────────────
log_info "Pulling latest code from git..."
cd "$PROJECT_DIR"

if [[ -n "$BRANCH" ]]; then
    log_info "Switching to branch: $BRANCH"
    git fetch origin "$BRANCH"
    git checkout "$BRANCH"
fi

git pull

# ── 2. Sync application files (preserve venv) ─────────────────────────────────
log_info "Syncing src/ → $INSTALL_DIR/ (venv preserved)..."

if command -v rsync &>/dev/null; then
    rsync -a --delete \
          --exclude='venv/' \
          "$PROJECT_DIR/src/" "$INSTALL_DIR/"
else
    # rsync not available: copy each top-level item except venv
    for item in "$PROJECT_DIR/src"/*/; do
        name="$(basename "$item")"
        [[ "$name" == "venv" ]] && continue
        rm -rf "${INSTALL_DIR:?}/$name"
        cp -r "$item" "$INSTALL_DIR/$name"
    done
fi

# ── 3. Ensure runtime data directories exist ─────────────────────────────────
mkdir -p /var/log/printserver /var/lib/printserver

# ── 4. Update systemd unit if it changed ─────────────────────────────────────
SERVICE_SRC="$PROJECT_DIR/config/systemd/printserver-web.service"
SERVICE_DST="/etc/systemd/system/printserver-web.service"

if [[ -f "$SERVICE_SRC" ]]; then
    if ! diff -q "$SERVICE_SRC" "$SERVICE_DST" &>/dev/null; then
        log_info "Systemd unit file changed — installing and reloading daemon..."
        cp "$SERVICE_SRC" "$SERVICE_DST"
        systemctl daemon-reload
    else
        log_info "Systemd unit unchanged."
    fi
fi

# ── 5. Restart the web service ────────────────────────────────────────────────
log_info "Restarting printserver-web..."
systemctl restart printserver-web

log_info "Done. Service status:"
systemctl --no-pager status printserver-web --lines=5
