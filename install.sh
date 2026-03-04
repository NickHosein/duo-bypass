#!/usr/bin/env bash
#
# This project is an independent open-source initiative and is not affiliated with, endorsed by, or supported by Cisco Systems, Inc. or Duo Security.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# ──────────────────────────────────────────────────────────
# Duo Bypass Code Generator — Linux Installation Script
# ──────────────────────────────────────────────────────────
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default installation directory
DEFAULT_INSTALL_DIR="/opt/duo-bypass"
DEFAULT_LOG_DIR="/var/log/duo-bypass"
DEFAULT_SERVICE_USER="duo-bypass"

# ──────────────────────────────────────
# Helper functions
# ──────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

prompt() {
    local var_name="$1"
    local prompt_text="$2"
    local default_value="${3:-}"
    local is_secret="${4:-false}"

    if [[ -n "$default_value" ]]; then
        prompt_text="$prompt_text [$default_value]"
    fi

    if [[ "$is_secret" == "true" ]]; then
        read -rsp "$prompt_text: " value
        echo ""
    else
        read -rp "$prompt_text: " value
    fi

    value="${value:-$default_value}"

    if [[ -z "$value" ]]; then
        error "$var_name is required."
    fi

    eval "$var_name='$value'"
}

prompt_yes_no() {
    local prompt_text="$1"
    local default="${2:-y}"
    local result

    read -rp "$prompt_text [${default}]: " result
    result="${result:-$default}"

    case "$result" in
        [Yy]*) return 0 ;;
        [Nn]*) return 1 ;;
        *)     return 0 ;;
    esac
}

# ──────────────────────────────────────
# Pre-flight checks
# ──────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════"
echo "  Duo Bypass Code Generator — Linux Installer"
echo "════════════════════════════════════════════════════"
echo ""

# Check for root
if [[ $EUID -ne 0 ]]; then
    error "This script must be run as root (use sudo)."
fi

# Detect package manager
if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt"
    info "Detected Debian/Ubuntu-based system."
elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
    info "Detected RHEL/CentOS/Fedora-based system."
elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
    info "Detected Fedora/RHEL 8+-based system."
else
    error "Unsupported package manager. Install dependencies manually."
fi

# ──────────────────────────────────────
# Gather user inputs
# ──────────────────────────────────────
echo ""
info "Please provide the following configuration values."
echo ""

# Installation paths
prompt INSTALL_DIR "Installation directory" "$DEFAULT_INSTALL_DIR"
prompt LOG_DIR "Log directory" "$DEFAULT_LOG_DIR"
prompt SERVICE_USER "Service user account" "$DEFAULT_SERVICE_USER"


prompt LISTEN_PORT "HTTPS listen port" "443"

echo ""
info "—— Web Application Hostname ——"
info "This is the hostname or FQDN users will use to access the application."
info "If using a SAN certificate, enter the SAN hostname."
info "Examples: duo-bypass.yourdomain.com, server01.yourdomain.com"
echo ""

DEFAULT_WEB_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
prompt WEB_HOSTNAME "Web application hostname/FQDN" "$DEFAULT_WEB_HOSTNAME"

echo ""
info "── Duo API Configuration ──"
prompt DUO_IKEY "Duo Integration Key (IKEY)" ""
prompt DUO_SKEY "Duo Secret Key (SKEY)" "" "true"
prompt DUO_HOST "Duo API Hostname (e.g., api-xxxxxxxx.duosecurity.com)" ""

echo ""
info "—— Duo MFA (Web SDK) Configuration ——"
info "Optionally require Duo MFA before granting access to the bypass code page."
info "This requires a separate Duo 'Web SDK' application."
info "If skipped, users will only need AD credentials to log in."
echo ""

DUO_CLIENT_ID=""
DUO_CLIENT_SECRET=""
DUO_API_HOST=""

if prompt_yes_no "Enable Duo MFA on login?" "n"; then
    DUO_MFA_ENABLED=true
    prompt DUO_CLIENT_ID "Duo Web SDK Client ID" ""
    prompt DUO_CLIENT_SECRET "Duo Web SDK Client Secret" "" "true"
    prompt DUO_API_HOST "Duo Web SDK API Hostname" "$DUO_HOST"

    DEFAULT_REDIRECT="https://${WEB_HOSTNAME}/duo-callback"
    prompt DUO_REDIRECT_URI "Duo Redirect URI" "$DEFAULT_REDIRECT"
else
    DUO_MFA_ENABLED=false
    DUO_REDIRECT_URI=""
    info "Duo MFA will not be configured. Users will authenticate with AD credentials only."
fi

echo ""
info "── Active Directory / Kerberos Configuration ──"
prompt LDAP_SERVER "LDAP Server FQDN (e.g., dc01.yourdomain.com)" ""
prompt KERBEROS_REALM "Kerberos Realm (UPPERCASE, e.g., YOURDOMAIN.COM)" ""
prompt LDAP_SEARCH_BASE "LDAP Search Base DN (e.g., DC=your,DC=domain,DC=com)" ""

echo ""
info "── TLS Certificate Paths ──"
prompt CA_BUNDLE_PATH "Path to CA bundle for AD LDAPS validation (.pem)" ""
prompt TLS_CERT_PATH "Path to web front end TLS certificate (.pem or .crt)" ""
prompt TLS_KEY_PATH "Path to web front end TLS private key (.pem or .key)" ""

echo ""
info "── Flask Configuration ──"
# Generate a random secret key
GENERATED_SECRET=$(python3 -c "import os, base64; print(base64.b64encode(os.urandom(32)).decode())" 2>/dev/null || openssl rand -base64 32)
if prompt_yes_no "Auto-generate Flask secret key? (recommended)" "y"; then
    FLASK_SECRET_KEY="$GENERATED_SECRET"
    success "Secret key generated."
else
    prompt FLASK_SECRET_KEY "Flask Secret Key" "" "true"
fi

# ──────────────────────────────────────
# Confirm settings
# ──────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════"
echo "  Configuration Summary"
echo "════════════════════════════════════════════════════"
echo ""
echo "  Install directory:    $INSTALL_DIR"
echo "  Log directory:        $LOG_DIR"
echo "  Service user:         $SERVICE_USER"
echo "  Web hostname:         $WEB_HOSTNAME"
echo "  Listen port:          $LISTEN_PORT"
echo ""
echo "  Duo IKEY:             $DUO_IKEY"
echo "  Duo Host:             $DUO_HOST"
if [[ "$DUO_MFA_ENABLED" == "true" ]]; then
    echo "  Duo MFA:              Enabled"
    echo "  Duo MFA Client ID:    $DUO_CLIENT_ID"
    echo "  Duo MFA API Host:     $DUO_API_HOST"
    echo "  Duo Redirect URI:     $DUO_REDIRECT_URI"
else
    echo "  Duo MFA:              Disabled (AD-only authentication)"
fi
echo ""
echo "  LDAP Server:          ldaps://$LDAP_SERVER"
echo "  Kerberos Realm:       $KERBEROS_REALM"
echo "  LDAP Search Base:     $LDAP_SEARCH_BASE"
echo ""
echo "  CA Bundle:            $CA_BUNDLE_PATH"
echo "  TLS Certificate:      $TLS_CERT_PATH"
echo "  TLS Private Key:      $TLS_KEY_PATH"
echo ""

if ! prompt_yes_no "Proceed with installation?" "y"; then
    info "Installation cancelled."
    exit 0
fi

# ──────────────────────────────────────
# Install system dependencies
# ──────────────────────────────────────
echo ""
info "Installing system dependencies..."

case "$PKG_MANAGER" in
    apt)
        apt-get update -qq
        apt-get install -y -qq krb5-user libkrb5-dev python3 python3-pip python3-venv
        ;;
    yum)
        yum install -y -q krb5-workstation krb5-devel python3 python3-pip
        ;;
    dnf)
        dnf install -y -q krb5-workstation krb5-devel python3 python3-pip
        ;;
esac

success "System dependencies installed."

# ──────────────────────────────────────
# Create service user
# ──────────────────────────────────────
if ! id "$SERVICE_USER" &>/dev/null; then
    info "Creating service user '$SERVICE_USER'..."
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
    success "Service user created."
else
    info "Service user '$SERVICE_USER' already exists."
fi

# ──────────────────────────────────────
# Create directories
# ──────────────────────────────────────
info "Creating directories..."

mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/certs"
mkdir -p "$LOG_DIR"

APP_CA_PATH="$INSTALL_DIR/certs/ca-chain.pem"
APP_CERT_PATH="$INSTALL_DIR/certs/server.crt"
APP_KEY_PATH="$INSTALL_DIR/certs/server.key"

cp "$CA_BUNDLE_PATH" "$APP_CA_PATH"
cp "$TLS_CERT_PATH" "$APP_CERT_PATH"
cp "$TLS_KEY_PATH" "$APP_KEY_PATH"

success "Certificates copied to $INSTALL_DIR/certs/"

success "Directories created."

# ──────────────────────────────────────
# Copy application files
# ──────────────────────────────────────
info "Copying application files..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy the main application file
if [[ -f "$SCRIPT_DIR/duo-bypass.py" ]]; then
    cp "$SCRIPT_DIR/duo-bypass.py" "$INSTALL_DIR/duo-bypass.py"
else
    error "duo-bypass.py not found in $SCRIPT_DIR. Place it alongside this installer."
fi

# Copy requirements.txt
if [[ -f "$SCRIPT_DIR/requirements.txt" ]]; then
    cp "$SCRIPT_DIR/requirements.txt" "$INSTALL_DIR/requirements.txt"
else
    error "requirements.txt not found in $SCRIPT_DIR. Place it alongside this installer."
fi

success "Application files copied."

# ————————————————————————————————————
# Copy static assets
# ————————————————————————————————————
info "Copying static assets..."

if [[ -d "$SCRIPT_DIR/static" ]]; then
    cp -r "$SCRIPT_DIR/static" "$INSTALL_DIR/static"
    success "Static assets copied."
else
    warn "No 'static' directory found in $SCRIPT_DIR. Creating empty structure..."
    mkdir -p "$INSTALL_DIR/static/css"
    mkdir -p "$INSTALL_DIR/static/images"
    warn "Place your style.css in $INSTALL_DIR/static/css/"
    warn "Place your logo.png and banner.jpg in $INSTALL_DIR/static/images/"
fi

# Verify required files exist
if [[ ! -f "$INSTALL_DIR/static/css/style.css" ]]; then
    warn "style.css not found in static/css/ — the UI will not be styled."
fi

if [[ ! -f "$INSTALL_DIR/static/images/logo.png" ]]; then
    warn "logo.png not found in static/images/ — no logo will be displayed."
fi

if [[ ! -f "$INSTALL_DIR/static/images/banner.jpg" ]]; then
    warn "banner.jpg not found in static/images/ — no banner will be displayed."
fi

if [[ ! -f "$INSTALL_DIR/static/images/favicon.png" ]]; then
    warn "favicon.png not found in static/images/ — no favicon will be displayed."
fi

# ──────────────────────────────────────
# Update application configuration
# ──────────────────────────────────────
info "Updating application configuration..."

# Derive the domain components for krb5.conf
DOMAIN_LOWER=$(echo "$KERBEROS_REALM" | tr '[:upper:]' '[:lower:]')

sed -i "s|ca_certs_file='/path/to/your/ca-chain.pem'|ca_certs_file='${CA_BUNDLE_PATH}'|g" "$INSTALL_DIR/duo-bypass.py"
sed -i "s|LDAP_SERVER = 'ldaps://your.ad.server'|LDAP_SERVER = 'ldaps://${LDAP_SERVER}'|g" "$INSTALL_DIR/duo-bypass.py"
sed -i "s|KERBEROS_REALM = 'YOURDOMAIN.COM'|KERBEROS_REALM = '${KERBEROS_REALM}'|g" "$INSTALL_DIR/duo-bypass.py"
sed -i "s|LDAP_SEARCH_BASE = 'DC=your,DC=domain,DC=com'|LDAP_SEARCH_BASE = '${LDAP_SEARCH_BASE}'|g" "$INSTALL_DIR/duo-bypass.py"
sed -i "s|certfile='/path/to/cert.pem'|certfile='${TLS_CERT_PATH}'|g" "$INSTALL_DIR/duo-bypass.py"
sed -i "s|keyfile='/path/to/key.pem'|keyfile='${TLS_KEY_PATH}'|g" "$INSTALL_DIR/duo-bypass.py"
sed -i "s|port=443,|port=${LISTEN_PORT},|g" "$INSTALL_DIR/duo-bypass.py"

success "Application configuration updated."

# ──────────────────────────────────────
# Create .env file
# ──────────────────────────────────────
info "Creating .env file..."

cat > "$INSTALL_DIR/.env" <<EOF
FLASK_SECRET_KEY=${FLASK_SECRET_KEY}
DUO_IKEY=${DUO_IKEY}
DUO_SKEY=${DUO_SKEY}
DUO_HOST=${DUO_HOST}
EOF

if [[ "$DUO_MFA_ENABLED" == "true" ]]; then
    cat >> "$INSTALL_DIR/.env" <<EOF
DUO_CLIENT_ID=${DUO_CLIENT_ID}
DUO_CLIENT_SECRET=${DUO_CLIENT_SECRET}
DUO_API_HOST=${DUO_API_HOST}
DUO_REDIRECT_URI=${DUO_REDIRECT_URI}
EOF
fi

chmod 600 "$INSTALL_DIR/.env"
success ".env file created."

# ──────────────────────────────────────
# Configure Kerberos
# ──────────────────────────────────────
info "Configuring Kerberos (/etc/krb5.conf)..."

# Backup existing krb5.conf
if [[ -f /etc/krb5.conf ]]; then
    cp /etc/krb5.conf "/etc/krb5.conf.bak.$(date +%Y%m%d%H%M%S)"
    warn "Existing /etc/krb5.conf backed up."
fi

cat > /etc/krb5.conf <<EOF
[libdefaults]
    default_realm = ${KERBEROS_REALM}
    dns_lookup_realm = false
    dns_lookup_kdc = true
    forwardable = true
    rdns = false

[realms]
    ${KERBEROS_REALM} = {
        kdc = ${LDAP_SERVER}
        admin_server = ${LDAP_SERVER}
    }

[domain_realm]
    .${DOMAIN_LOWER} = ${KERBEROS_REALM}
    ${DOMAIN_LOWER} = ${KERBEROS_REALM}
EOF

success "Kerberos configured."

# ──────────────────────────────────────
# Create Python virtual environment
# ──────────────────────────────────────
info "Creating Python virtual environment..."

# Ensure python3-venv is available (required on Ubuntu/Debian)
if ! python3 -m venv --help &>/dev/null; then
    warn "python3-venv not available. Installing..."
    case "$PKG_MANAGER" in
        apt)
            apt-get install -y -qq python3-venv python3-full
            ;;
        yum|dnf)
            # venv is typically included with python3 on RHEL-based systems
            $PKG_MANAGER install -y -q python3-libs
            ;;
    esac
fi

# Create the venv
python3 -m venv "$INSTALL_DIR/venv"

# Verify it was created successfully
if [[ ! -f "$INSTALL_DIR/venv/bin/python3" ]]; then
    error "Failed to create virtual environment. Check that python3-venv is installed."
fi

source "$INSTALL_DIR/venv/bin/activate"

info "Installing Python dependencies..."
pip install --quiet --upgrade pip
pip install --quiet -r "$INSTALL_DIR/requirements.txt"

# Verify gunicorn was installed
if [[ ! -f "$INSTALL_DIR/venv/bin/gunicorn" ]]; then
    error "Gunicorn not found after pip install. Check requirements.txt."
fi

info "Granting port 443 permissions to the Python binary..."

# Resolve the symlink to the actual binary path
REAL_PYTHON_PATH=$(readlink -f "$INSTALL_DIR/venv/bin/python3")

# Apply the capability to the real binary
if setcap 'cap_net_bind_service=+ep' "$REAL_PYTHON_PATH"; then
    success "Capabilities applied to $REAL_PYTHON_PATH"
else
    warn "Failed to apply capabilities. You may need to run the service as root or use a port > 1024."
fi

deactivate
success "Python dependencies installed."

# ──────────────────────────────────────
# Create Gunicorn config
# ──────────────────────────────────────
info "Creating Gunicorn configuration..."

cat > "$INSTALL_DIR/gunicorn.conf.py" <<EOF

# Server socket
bind = '0.0.0.0:${LISTEN_PORT}'

# TLS
certfile = '${APP_CERT_PATH}'
keyfile = '${APP_KEY_PATH}'

# PID file (used by logrotate to signal log reopening)
pidfile = '/run/duo-bypass/duo-bypass.pid'

# Workers
workers = 4
threads = 2
timeout = 30
graceful_timeout = 10

# Logging
accesslog = '${LOG_DIR}/access.log'
errorlog = '${LOG_DIR}/error.log'
loglevel = 'info'

# Security
limit_request_line = 4094
limit_request_fields = 50
limit_request_field_size = 8190
EOF

cat >> "$INSTALL_DIR/gunicorn.conf.py" << 'GUNICORN_HOOK'

# Enforce TLS 1.2 minimum via post_fork hook
def post_fork(server, worker):
    """After forking a worker, update the SSL context to enforce TLS 1.2+."""
    for listener in server.LISTENERS:
        if hasattr(listener, 'sock') and hasattr(listener.sock, 'context'):
            ctx = listener.sock.context
            ctx.minimum_version = ssl.TLSVersion.TLSv1_2
            ctx.set_ciphers('HIGH:!aNULL:!MD5')
GUNICORN_HOOK

success "Gunicorn configuration created."

# ──────────────────────────────────────
# Create .gitignore
# ──────────────────────────────────────
cat > "$INSTALL_DIR/.gitignore" <<'EOF'
.env
*.pem
*.key
*.crt
__pycache__/
*.pyc
venv/
*.egg-info/
*.log
logs/
.DS_Store
Thumbs.db
krb5cc_*
EOF

# ──────────────────────────────────────
# Create systemd service
# ──────────────────────────────────────
info "Creating systemd service..."

cat > /etc/systemd/system/duo-bypass.service <<EOF
[Unit]
Description=Duo Bypass Code Generator
After=network.target

[Service]
Type=notify
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/.env
ExecStart=${INSTALL_DIR}/venv/bin/gunicorn -c ${INSTALL_DIR}/gunicorn.conf.py duo-bypass:app
Restart=on-failure
RestartSec=5
RuntimeDirectory=duo-bypass
PIDFile=/run/duo-bypass/duo-bypass.pid

[Install]
WantedBy=multi-user.target
EOF

success "Systemd service created."

# ──────────────────────────────────────
# Configure log rotation
# ──────────────────────────────────────
info "Configuring log rotation..."

cat > /etc/logrotate.d/duo-bypass << 'LOGROTATE_EOF'
/var/log/duo-bypass/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 0640 duo-bypass duo-bypass
    dateext
    dateformat -%Y%m%d

    postrotate
        PIDFILE="/run/duo-bypass/duo-bypass.pid"
        if [ -f "$PIDFILE" ]; then
            kill -USR1 $(cat "$PIDFILE")
        else
            MAINPID=$(systemctl show -p MainPID --value duo-bypass.service)
            if [ -n "$MAINPID" ] && [ "$MAINPID" != "0" ]; then
                kill -USR1 $MAINPID
            fi
        fi
    endscript
}
LOGROTATE_EOF

# Verify the config is valid
if logrotate -d /etc/logrotate.d/duo-bypass &>/dev/null; then
    success "Log rotation configured (daily, 30-day retention)."
else
    warn "Log rotation config may have issues. Check /etc/logrotate.d/duo-bypass"
fi

# ──────────────────────────────────────
# Set file permissions
# ──────────────────────────────────────
info "Setting file permissions..."

chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
chown -R "$SERVICE_USER:$SERVICE_USER" "$LOG_DIR"
chmod 600 "$INSTALL_DIR/.env"
chmod 600 "$APP_KEY_PATH"
chmod 644 "$APP_CERT_PATH" "$APP_CA_PATH"
chmod 750 "$INSTALL_DIR"
chmod 750 "$LOG_DIR"

# Static assets
if [[ -d "$INSTALL_DIR/static" ]]; then
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/static"
    find "$INSTALL_DIR/static" -type d -exec chmod 755 {} \;
    find "$INSTALL_DIR/static" -type f -exec chmod 644 {} \;
    success "Static asset permissions set."
fi

success "Permissions set successfully."

# ──────────────────────────────────────
# Validate certificate files
# ──────────────────────────────────────
info "Validating certificate files..."

if [[ ! -f "$CA_BUNDLE_PATH" ]]; then
    warn "CA bundle not found at $CA_BUNDLE_PATH — you must place it there before starting."
fi

if [[ ! -f "$TLS_CERT_PATH" ]]; then
    warn "TLS certificate not found at $TLS_CERT_PATH — you must place it there before starting."
fi

if [[ ! -f "$TLS_KEY_PATH" ]]; then
    warn "TLS private key not found at $TLS_KEY_PATH — you must place it there before starting."
fi

# ──────────────────────────────────────
# Enable and optionally start the service
# ──────────────────────────────────────
systemctl daemon-reload
systemctl enable duo-bypass

echo ""
if prompt_yes_no "Start the service now?" "n"; then
    systemctl start duo-bypass
    sleep 2
    if systemctl is-active --quiet duo-bypass; then
        success "Service started successfully."
    else
        warn "Service may have failed to start. Check: journalctl -u duo-bypass"
    fi
else
    info "Service installed but not started. Start with: sudo systemctl start duo-bypass"
fi

# ──────────────────────────────────────
# Summary
# ──────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════"
echo "  Installation Complete"
echo "════════════════════════════════════════════════════"
echo ""
echo "  Install directory:    $INSTALL_DIR"
echo "  Log directory:        $LOG_DIR"
echo "  Service user:         $SERVICE_USER"
echo "  Systemd service:      duo-bypass"
echo ""
echo "  Manage the service:"
echo "    sudo systemctl start duo-bypass"
echo "    sudo systemctl stop duo-bypass"
echo "    sudo systemctl restart duo-bypass"
echo "    sudo systemctl status duo-bypass"
echo ""
echo "  View logs:"
echo "    journalctl -u duo-bypass -f"
echo "    tail -f $LOG_DIR/access.log"
echo "    tail -f $LOG_DIR/error.log"
echo ""
if [[ "$LISTEN_PORT" == "443" ]]; then
    echo "  Application URL:  https://${WEB_HOSTNAME}/"
else
    echo "  Application URL:  https://${WEB_HOSTNAME}:${LISTEN_PORT}/"
fi
echo ""
success "Done."