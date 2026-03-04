#!/usr/bin/env bash
# This project is an independent open-source initiative and is not affiliated with, endorsed by, or supported by Cisco Systems, Inc. or Duo Security.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# ————————————————————————————————————————————————————————————————————————————
# Duo Bypass Code Generator — Linux Uninstallation Script
# ————————————————————————————————————————————————————————————————————————————
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Defaults (should match install.sh)
INSTALL_DIR="/opt/duo-bypass"
LOG_DIR="/var/log/duo-bypass"
SERVICE_NAME="duo-bypass"
SERVICE_USER="duo-bypass"

info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

prompt_yes_no() {
    local prompt_text="$1"
    local default="${2:-y}"
    local result
    read -rp "$prompt_text [${default}]: " result
    result="${result:-$default}"
    case "$result" in
        [Yy]*) return 0 ;;
        *)     return 1 ;;
    esac
}

echo ""
echo "————————————————————————————————————————————————————————————————————————"
echo "  Duo Bypass Code Generator — Linux Uninstaller"
echo "————————————————————————————————————————————————————————————————————————"
echo ""

# Check for root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)."
fi

# ————————————————————————————————————
# Verify installation exists
# ————————————————————————————————————
if [[ ! -d "$INSTALL_DIR" ]] && ! systemctl list-unit-files "$SERVICE_NAME.service" &>/dev/null; then
    warn "No installation found at $INSTALL_DIR and no systemd service found."
    if ! prompt_yes_no "Continue anyway?" "n"; then
        info "Uninstallation cancelled."
        exit 0
    fi
fi

# ————————————————————————————————————
# Show what will be removed
# ————————————————————————————————————
echo ""
info "The following will be removed:"
echo ""
echo "  Systemd service:      $SERVICE_NAME"
echo "  Install directory:    $INSTALL_DIR"
echo "  Log directory:        $LOG_DIR"
echo "  Runtime directory:    /run/$SERVICE_NAME"
echo "  Logrotate config:     /etc/logrotate.d/$SERVICE_NAME"
echo "  Service user:         $SERVICE_USER (optional)"
echo "  Kerberos config:      /etc/krb5.conf (optional restore)"
echo ""

if ! prompt_yes_no "Are you sure you want to uninstall Duo Bypass Code Generator?" "n"; then
    info "Uninstallation cancelled."
    exit 0
fi

# ————————————————————————————————————
# 1. Stop and Disable Service
# ————————————————————————————————————
info "Stopping and disabling systemd service..."
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl stop "$SERVICE_NAME"
    success "Service stopped."
fi
if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
    systemctl disable "$SERVICE_NAME" &>/dev/null || true
fi
rm -f "/etc/systemd/system/$SERVICE_NAME.service"
systemctl daemon-reload
success "Service removed."

# ————————————————————————————————————
# 2. Remove Python setcap Capability
# ————————————————————————————————————
info "Removing port binding capabilities..."
if [[ -f "$INSTALL_DIR/venv/bin/python3" ]]; then
    REAL_PYTHON_PATH=$(readlink -f "$INSTALL_DIR/venv/bin/python3" 2>/dev/null || true)
    if [[ -n "$REAL_PYTHON_PATH" ]] && [[ -f "$REAL_PYTHON_PATH" ]]; then
        if getcap "$REAL_PYTHON_PATH" 2>/dev/null | grep -q cap_net_bind_service; then
            setcap -r "$REAL_PYTHON_PATH" 2>/dev/null || true
            success "Removed cap_net_bind_service from $REAL_PYTHON_PATH"
        else
            info "No capabilities found on Python binary."
        fi
    fi
else
    info "Python virtual environment not found. Skipping capability removal."
fi

# ————————————————————————————————————
# 3. Remove Logrotate Configuration
# ————————————————————————————————————
info "Removing logrotate configuration..."
if [[ -f "/etc/logrotate.d/$SERVICE_NAME" ]]; then
    rm -f "/etc/logrotate.d/$SERVICE_NAME"
    success "Logrotate config removed."
else
    info "No logrotate config found."
fi

# ————————————————————————————————————
# 4. Restore Kerberos Configuration
# ————————————————————————————————————
info "Checking for Kerberos configuration backups..."
BACKUPS=$(ls -t /etc/krb5.conf.bak.* 2>/dev/null || true)

if [[ -n "$BACKUPS" ]]; then
    LATEST_BACKUP=$(echo "$BACKUPS" | head -n 1)
    echo ""
    info "Found Kerberos backup(s):"
    echo "$BACKUPS" | while read -r backup; do
        echo "    $backup"
    done
    echo ""

    if prompt_yes_no "Restore $LATEST_BACKUP to /etc/krb5.conf?" "y"; then
        cp "$LATEST_BACKUP" /etc/krb5.conf
        success "Restored /etc/krb5.conf from backup."
    fi

    if prompt_yes_no "Remove all Kerberos backup files?" "y"; then
        rm -f /etc/krb5.conf.bak.*
        success "Kerberos backups removed."
    fi
else
    warn "No Kerberos backup found. /etc/krb5.conf will remain as is."
fi

# ————————————————————————————————————
# 5. Remove Application Directory
# ————————————————————————————————————
info "Removing application directory..."
if [[ -d "$INSTALL_DIR" ]]; then
    # Show what's inside before removing
    info "Contents of $INSTALL_DIR:"
    ls -la "$INSTALL_DIR" 2>/dev/null | while read -r line; do
        echo "    $line"
    done
    echo ""

    if prompt_yes_no "Remove $INSTALL_DIR and all contents?" "y"; then
        rm -rf "$INSTALL_DIR"
        success "Removed $INSTALL_DIR"
    else
        warn "$INSTALL_DIR was preserved."
    fi
else
    info "Install directory $INSTALL_DIR not found."
fi

# ————————————————————————————————————
# 6. Remove Log Directory
# ————————————————————————————————————
info "Removing log directory..."
if [[ -d "$LOG_DIR" ]]; then
    if prompt_yes_no "Remove $LOG_DIR and all logs?" "y"; then
        rm -rf "$LOG_DIR"
        success "Removed $LOG_DIR"
    else
        warn "$LOG_DIR was preserved."
    fi
else
    info "Log directory $LOG_DIR not found."
fi

# ————————————————————————————————————
# 7. Remove Runtime Directory
# ————————————————————————————————————
info "Removing runtime directory..."
if [[ -d "/run/$SERVICE_NAME" ]]; then
    rm -rf "/run/$SERVICE_NAME"
    success "Removed /run/$SERVICE_NAME"
else
    info "Runtime directory not found."
fi

# ————————————————————————————————————
# 8. Remove Service User
# ————————————————————————————————————
if id "$SERVICE_USER" &>/dev/null; then
    echo ""
    if prompt_yes_no "Remove the service user account '$SERVICE_USER'?" "y"; then
        userdel "$SERVICE_USER" 2>/dev/null || true
        success "Service user '$SERVICE_USER' removed."
    else
        warn "Service user '$SERVICE_USER' was preserved."
    fi
else
    info "Service user '$SERVICE_USER' not found."
fi

# ————————————————————————————————————
# Summary
# ————————————————————————————————————
echo ""
echo "————————————————————————————————————————————————————————————————————————"
echo "  Uninstallation Complete"
echo "————————————————————————————————————————————————————————————————————————"
echo ""
echo "  The following were cleaned up:"
echo "    - Systemd service"
echo "    - Python capabilities"
echo "    - Logrotate configuration"
echo "    - Runtime PID directory"

[[ ! -d "$INSTALL_DIR" ]] && echo "    - Application directory ($INSTALL_DIR)"
[[ ! -d "$LOG_DIR" ]] && echo "    - Log directory ($LOG_DIR)"
! id "$SERVICE_USER" &>/dev/null && echo "    - Service user ($SERVICE_USER)"

echo ""
echo "  Items that may require manual cleanup:"
echo "    - /etc/krb5.conf (if not restored)"
echo "    - DNS records or /etc/hosts entries"
echo "    - Duo Admin Panel applications (Web SDK, Admin API)"
echo "    - Firewall rules"
echo ""
success "Done."