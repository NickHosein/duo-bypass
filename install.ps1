#Requires -RunAsAdministrator
#
# This project is an independent open-source initiative and is not affiliated with, endorsed by, or supported by Cisco Systems, Inc. or Duo Security.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# ================================================================
# Duo Bypass Code Generator - Windows Installation Script (IIS)
# Uses IIS with HttpPlatformHandler for TLS termination and process management.
# Flask runs on a local loopback port; IIS reverse-proxies to it over HTTP.
# ================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ====================================
# Helper Functions
# ====================================
function Write-Info    { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[OK]   $Message" -ForegroundColor Green }
function Write-Warn    { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err     { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red; exit 1 }

function Prompt-Value {
    param(
        [string]$PromptText,
        [string]$Default = "",
        [switch]$Secret,
        [switch]$Required
    )

    if ($Default) {
        $displayPrompt = "$PromptText [$Default]"
    } else {
        $displayPrompt = $PromptText
    }

    if ($Secret) {
        $secureVal = Read-Host -Prompt $displayPrompt -AsSecureString
        $plainVal = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureVal)
        )
    } else {
        $plainVal = Read-Host -Prompt $displayPrompt
    }

    if ([string]::IsNullOrWhiteSpace($plainVal)) {
        $plainVal = $Default
    }

    if ($Required -and [string]::IsNullOrWhiteSpace($plainVal)) {
        Write-Err "$PromptText is required."
    }

    return $plainVal
}

function Prompt-YesNo {
    param(
        [string]$PromptText,
        [string]$Default = "y"
    )

    $result = Read-Host -Prompt "$PromptText [$Default]"
    if ([string]::IsNullOrWhiteSpace($result)) { $result = $Default }

    return ($result -match "^[Yy]")
}

function Validate-Port {
    param([string]$Value, [string]$Label)
    if ($Value -notmatch '^\d+$' -or [int]$Value -lt 1 -or [int]$Value -gt 65535) {
        Write-Err "$Label must be a valid port number (1-65535). Got: $Value"
    }
}

function Escape-XmlValue {
    param([string]$Value)
    return $Value.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;").Replace("'", "&apos;")
}

# ====================================
# Banner
# ====================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor White
Write-Host "  Duo Bypass Code Generator - Windows Installer (IIS)" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor White
Write-Host ""

# ====================================
# Pre-flight Checks
# ====================================
Write-Info "Running pre-flight checks..."

# Check for Administrator
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err "This script must be run as Administrator."
}

# Check for Python 3
$pythonCmd = $null
foreach ($cmd in @("python", "python3")) {
    try {
        $ver = & $cmd --version 2>&1
        if ($ver -match "Python 3") {
            $pythonCmd = $cmd
            Write-Info "Found $ver"
            break
        }
    } catch { }
}
if (-not $pythonCmd) {
    Write-Err "Python 3 is required but was not found in PATH. Please install Python 3.10+ from https://www.python.org/downloads/"
}

# Check if Python is installed per-user (problematic for IIS)
$pythonPath = (Get-Command $pythonCmd).Source
if ($pythonPath -match '\\Users\\') {
    Write-Warn "Python appears to be installed per-user at: $pythonPath"
    Write-Warn "IIS runs under a service account that cannot access user profile directories."
    Write-Warn "Please reinstall Python using 'Install for all users' option."
    Write-Warn "Download from: https://www.python.org/downloads/"
    if (-not (Prompt-YesNo "Continue anyway?" "n")) {
        Write-Err "Please reinstall Python system-wide and re-run this script."
    }
}

# Check for IIS
$iisFeature = Get-WindowsFeature -Name Web-Server -ErrorAction SilentlyContinue
if (-not $iisFeature) {
    $iisOptional = Get-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole -ErrorAction SilentlyContinue
    if (-not $iisOptional -or $iisOptional.State -ne "Enabled") {
        Write-Warn "IIS (Web-Server) does not appear to be installed."
        if (Prompt-YesNo "Attempt to install IIS and required features now?" "y") {
            try {
                Install-WindowsFeature -Name Web-Server, Web-Scripting-Tools, Web-IP-Security -IncludeManagementTools -ErrorAction Stop
                Write-Success "IIS installed via Install-WindowsFeature."
            } catch {
                try {
                    Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole, IIS-WebServer, IIS-ManagementConsole, IIS-IPSecurity -All -NoRestart -ErrorAction Stop
                    Write-Success "IIS installed via Enable-WindowsOptionalFeature."
                } catch {
                    Write-Err "Failed to install IIS. Please install IIS manually and re-run this script."
                }
            }
        } else {
            Write-Err "IIS is required. Please install it and re-run this script."
        }
    }
} else {
    if ($iisFeature.Installed) {
        Write-Info "IIS is installed."
    } else {
        Write-Warn "IIS feature found but not installed."
        if (Prompt-YesNo "Install IIS now?" "y") {
            Install-WindowsFeature -Name Web-Server, Web-Scripting-Tools, Web-IP-Security -IncludeManagementTools
            Write-Success "IIS installed."
        } else {
            Write-Err "IIS is required. Please install it and re-run."
        }
    }
}

# Import WebAdministration module
try {
    Import-Module WebAdministration -ErrorAction Stop
    Write-Info "WebAdministration module loaded."
} catch {
    Write-Err "Failed to load WebAdministration PowerShell module. Ensure IIS Management Tools are installed."
}

# Check for HttpPlatformHandler
$httpPlatformPath = "$env:ProgramFiles\IIS\HttpPlatformHandler\HttpPlatformHandler.dll"
$httpPlatformV2Path = "$env:SystemRoot\System32\inetsrv\httpPlatformHandler.dll"
$httpPlatformInstalled = (Test-Path $httpPlatformPath) -or (Test-Path $httpPlatformV2Path)

$iisModules = & "$env:SystemRoot\System32\inetsrv\appcmd.exe" list module 2>$null
if ($iisModules -match "httpPlatformHandler") {
    $httpPlatformInstalled = $true
}

if (-not $httpPlatformInstalled) {
    Write-Host ""
    Write-Warn "HttpPlatformHandler is not detected."
    Write-Warn "This IIS module is required to proxy requests to Flask."
    Write-Host ""
    Write-Host "  Download from:" -ForegroundColor Yellow
    Write-Host "  https://www.iis.net/downloads/microsoft/httpplatformhandler" -ForegroundColor White
    Write-Host ""
    Write-Host "  Or install via Web Platform Installer:" -ForegroundColor Yellow
    Write-Host "  WebpiCmd.exe /Install /Products:HttpPlatformHandler" -ForegroundColor White
    Write-Host ""

    if (-not (Prompt-YesNo "Continue anyway? (you can install HttpPlatformHandler after)" "n")) {
        Write-Err "HttpPlatformHandler is required. Install it and re-run."
    }
} else {
    Write-Success "HttpPlatformHandler detected."
}

# Check for URL Rewrite module
$urlRewriteInstalled = $false
try {
    $rewriteModule = & "$env:SystemRoot\System32\inetsrv\appcmd.exe" list module 2>$null
    if ($rewriteModule -match "RewriteModule") {
        $urlRewriteInstalled = $true
        Write-Success "IIS URL Rewrite module detected."
    }
} catch { }

if (-not $urlRewriteInstalled) {
    Write-Warn "IIS URL Rewrite module not detected."
    Write-Warn "HTTP-to-HTTPS redirect will not work without it."
    Write-Warn "Download from: https://www.iis.net/downloads/microsoft/url-rewrite"
}

# Check for Dynamic IP Restrictions feature
Write-Info "Checking for IIS Dynamic IP Restrictions..."

$ipSecInstalled = $false

try {
    # Server OS (Windows Server)
    $ipSecFeature = Get-WindowsFeature -Name Web-IP-Security -ErrorAction SilentlyContinue
    if ($ipSecFeature -and $ipSecFeature.Installed) {
        $ipSecInstalled = $true
    }
} catch { }

if (-not $ipSecInstalled) {
    try {
        # Client OS (Windows 10/11) or fallback
        $ipSecOptional = Get-WindowsOptionalFeature -Online -FeatureName IIS-IPSecurity -ErrorAction SilentlyContinue
        if ($ipSecOptional -and $ipSecOptional.State -eq "Enabled") {
            $ipSecInstalled = $true
        }
    } catch { }
}

if ($ipSecInstalled) {
    Write-Success "IIS Dynamic IP Restrictions feature is installed."
} else {
    Write-Warn "IIS Dynamic IP Restrictions feature is not installed."
    if (Prompt-YesNo "Install it now? (required for rate limiting)" "y") {
        try {
            Install-WindowsFeature -Name Web-IP-Security -ErrorAction Stop
            $ipSecInstalled = $true
            Write-Success "Dynamic IP Restrictions installed."
        } catch {
            try {
                Enable-WindowsOptionalFeature -Online -FeatureName IIS-IPSecurity -All -NoRestart -ErrorAction Stop
                $ipSecInstalled = $true
                Write-Success "Dynamic IP Restrictions installed."
            } catch {
                Write-Warn "Could not install Dynamic IP Restrictions automatically."
                Write-Warn "Install manually: Server Manager > Web Server > Security > IP and Domain Restrictions"
            }
        }
    } else {
        Write-Warn "Rate limiting will not be enforced without Dynamic IP Restrictions."
    }
}

# Check system clock accuracy
Write-Info "Checking system clock accuracy..."
try {
    $w32tmOutput = & w32tm /stripchart /computer:time.windows.com /dataonly /samples:1 2>&1
    if ($w32tmOutput -match '([+-]?\d+\.\d+)s') {
        $skewSeconds = [math]::Abs([double]$Matches[1])
        if ($skewSeconds -gt 300) {
            Write-Warn "System clock is off by $($skewSeconds)s. Duo Admin API requires accurate time (within 5 minutes)."
            Write-Warn "Run: w32tm /resync /force"
        } else {
            Write-Success "System clock skew: $($skewSeconds)s (within tolerance)."
        }
    }
} catch {
    Write-Warn "Could not check system clock accuracy. Ensure NTP is configured."
}

Write-Success "Pre-flight checks passed."

# ====================================
# Default Paths
# ====================================
$DEFAULT_INSTALL_DIR  = "C:\inetpub\duo-bypass"
$DEFAULT_LOG_DIR      = "C:\inetpub\duo-bypass\logs"
$DEFAULT_IIS_SITE     = "DuoBypass"
$DEFAULT_APP_POOL     = "DuoBypassPool"

# ====================================
# Gather User Inputs
# ====================================
Write-Host ""
Write-Info "Please provide the following configuration values."
Write-Host ""

$INSTALL_DIR  = Prompt-Value -PromptText "Installation directory" -Default $DEFAULT_INSTALL_DIR
$LOG_DIR      = Prompt-Value -PromptText "Log directory" -Default $DEFAULT_LOG_DIR
$IIS_SITE     = Prompt-Value -PromptText "IIS Site name" -Default $DEFAULT_IIS_SITE
$APP_POOL     = Prompt-Value -PromptText "IIS Application Pool name" -Default $DEFAULT_APP_POOL
$LISTEN_PORT  = Prompt-Value -PromptText "HTTPS listen port" -Default "443"
$FLASK_INTERNAL_PORT = Prompt-Value -PromptText "Internal Flask port (loopback, not exposed externally)" -Default "5000"

Validate-Port $LISTEN_PORT "HTTPS listen port"
Validate-Port $FLASK_INTERNAL_PORT "Internal Flask port"

if ($LISTEN_PORT -eq $FLASK_INTERNAL_PORT) {
    Write-Err "HTTPS listen port and internal Flask port cannot be the same."
}

Write-Host ""
Write-Info "-- Web Application Hostname --"
Write-Info "This is the hostname or FQDN users will use to access the application."
Write-Info "This will be used for the IIS site binding and should match your TLS certificate."
Write-Info "Examples: duo-bypass.yourdomain.com, server01.yourdomain.com"
Write-Host ""

$DEFAULT_WEB_HOSTNAME = [System.Net.Dns]::GetHostEntry([System.Net.Dns]::GetHostName()).HostName
$WEB_HOSTNAME = Prompt-Value -PromptText "Web application hostname/FQDN" -Default $DEFAULT_WEB_HOSTNAME

Write-Host ""
Write-Info "-- Duo Admin API Configuration --"
$DUO_IKEY = Prompt-Value -PromptText "Duo Integration Key (IKEY)" -Required
$DUO_SKEY = Prompt-Value -PromptText "Duo Secret Key (SKEY)" -Required -Secret
$DUO_HOST = Prompt-Value -PromptText "Duo API Hostname (e.g., api-xxxxxxxx.duosecurity.com)" -Required

Write-Host ""
Write-Info "-- Duo MFA (Web SDK) Configuration --"
Write-Info "Optionally require Duo MFA before granting access to the bypass code page."
Write-Info "This requires a separate Duo 'Web SDK' application."
Write-Info "If skipped, users will only need AD credentials to log in."
Write-Host ""

$DUO_MFA_ENABLED   = $false
$DUO_CLIENT_ID     = ""
$DUO_CLIENT_SECRET = ""
$DUO_API_HOST      = ""
$DUO_REDIRECT_URI  = ""

if (Prompt-YesNo "Enable Duo MFA on login?" "n") {
    $DUO_MFA_ENABLED   = $true
    $DUO_CLIENT_ID     = Prompt-Value -PromptText "Duo Web SDK Client ID" -Required
    $DUO_CLIENT_SECRET = Prompt-Value -PromptText "Duo Web SDK Client Secret" -Required -Secret
    $DUO_API_HOST      = Prompt-Value -PromptText "Duo Web SDK API Hostname" -Default $DUO_HOST
    $DEFAULT_REDIRECT  = "https://$($WEB_HOSTNAME)/duo-callback"
    $DUO_REDIRECT_URI  = Prompt-Value -PromptText "Duo Redirect URI" -Default $DEFAULT_REDIRECT
} else {
    Write-Info "Duo MFA will not be configured. Users will authenticate with AD credentials only."
}

Write-Host ""
Write-Info "-- Active Directory / LDAP Configuration --"
$LDAP_SERVER      = Prompt-Value -PromptText "LDAP Server FQDN (e.g., dc01.yourdomain.com)" -Required
$KERBEROS_REALM   = Prompt-Value -PromptText "AD Domain (UPPERCASE, e.g., YOURDOMAIN.COM)" -Required
$LDAP_SEARCH_BASE = Prompt-Value -PromptText "LDAP Search Base DN (e.g., DC=your,DC=domain,DC=com)" -Required

Write-Host ""
Write-Info "-- Proxy Configuration --"
Write-Info "If this server requires an HTTP proxy for outbound internet access"
Write-Info "(e.g., to reach Duo API endpoints), configure it here."
Write-Host ""

$PROXY_URL = ""
$NO_PROXY = ""

if (Prompt-YesNo "Does this server require an HTTP proxy for outbound access?" "n") {
    $PROXY_URL = Prompt-Value -PromptText "Proxy URL (e.g., http://proxy.example.com:8080)" -Required
    $DOMAIN_LOWER = $KERBEROS_REALM.ToLower()
    $DEFAULT_NO_PROXY = "127.0.0.1,localhost,$($WEB_HOSTNAME),.$($DOMAIN_LOWER)"
    $NO_PROXY = Prompt-Value -PromptText "NO_PROXY (comma-separated bypass list)" -Default $DEFAULT_NO_PROXY
} else {
    Write-Info "No proxy configured."
}

Write-Host ""
Write-Info "-- IIS Rate Limiting --"
Write-Info "IIS Dynamic IP Restrictions will be configured to rate-limit clients."
Write-Host ""

$IIS_BEHIND_LB = $false
if (Prompt-YesNo "Is this IIS server behind a load balancer or reverse proxy?" "n") {
    $IIS_BEHIND_LB = $true
    Write-Info "IIS will evaluate X-Forwarded-For headers for client IP identification."
} else {
    Write-Info "IIS will use the direct client IP for rate limiting."
}

Write-Host ""
Write-Info "-- TLS Certificate --"
Write-Info "The TLS certificate must be imported into the Windows Certificate Store"
Write-Info "(Local Machine > Personal) for IIS to use it."
Write-Host ""

$CA_BUNDLE_PATH = Prompt-Value -PromptText "Path to CA bundle for AD LDAPS validation (.pem)" -Required

Write-Info "Checking for certificates in Local Machine Personal store..."
$certs = @(Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.HasPrivateKey } | Sort-Object NotAfter -Descending)

if ($certs.Count -gt 0) {
    Write-Host ""
    Write-Info "Available certificates with private keys:"
    Write-Host ""
    $i = 1
    foreach ($cert in $certs) {
        $san = ($cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq "Subject Alternative Name" }).Format($false)
        Write-Host "  [$i] Subject:    $($cert.Subject)"
        Write-Host "      Thumbprint: $($cert.Thumbprint)"
        Write-Host "      Expires:    $($cert.NotAfter)"
        if ($san) { Write-Host "      SAN:        $san" }
        Write-Host ""
        $i++
    }

    $certChoice = Prompt-Value -PromptText "Select certificate number (or 'manual' to enter a thumbprint)" -Default "1"

    if ($certChoice -eq "manual") {
        $TLS_THUMBPRINT = Prompt-Value -PromptText "Certificate thumbprint" -Required
    } else {
        $certIndex = [int]$certChoice - 1
        if ($certIndex -ge 0 -and $certIndex -lt $certs.Count) {
            $TLS_THUMBPRINT = $certs[$certIndex].Thumbprint
            Write-Success "Selected certificate: $($certs[$certIndex].Subject)"
        } else {
            Write-Err "Invalid selection."
        }
    }
} else {
    Write-Warn "No certificates with private keys found in Local Machine Personal store."
    Write-Host ""
    Write-Info "You can import a PFX certificate using:"
    Write-Host '  Import-PfxCertificate -FilePath "C:\path\to\cert.pfx" -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString -String "password" -AsPlainText -Force)'
    Write-Host ""
    $TLS_THUMBPRINT = Prompt-Value -PromptText "Certificate thumbprint (import the cert first, then enter thumbprint)" -Required
}

$selectedCert = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $TLS_THUMBPRINT }
if (-not $selectedCert) {
    Write-Warn "Certificate with thumbprint '$($TLS_THUMBPRINT)' not found in the store."
    Write-Warn "Make sure it is imported before starting the IIS site."
} else {
    Write-Success "Certificate validated: $($selectedCert.Subject)"
}

Write-Host ""
Write-Info "-- Flask Configuration --"

if (Prompt-YesNo "Auto-generate Flask secret key? (recommended)" "y") {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes($bytes)
    $FLASK_SECRET_KEY = [Convert]::ToBase64String($bytes)
    Write-Success "Secret key generated."
} else {
    $FLASK_SECRET_KEY = Prompt-Value -PromptText "Flask Secret Key" -Required -Secret
}

# ====================================
# Confirm Settings
# ====================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor White
Write-Host "  Configuration Summary" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor White
Write-Host ""
Write-Host "  Install directory:      $($INSTALL_DIR)"
Write-Host "  Log directory:          $($LOG_DIR)"
Write-Host "  IIS Site name:          $($IIS_SITE)"
Write-Host "  IIS Application Pool:   $($APP_POOL)"
Write-Host "  Web hostname:           $($WEB_HOSTNAME)"
Write-Host "  HTTPS listen port:      $($LISTEN_PORT)"
Write-Host "  Internal Flask port:    $($FLASK_INTERNAL_PORT) (loopback)"
Write-Host "  Architecture:           IIS - HttpPlatformHandler - Flask"
Write-Host ""
Write-Host "  Duo IKEY:               $($DUO_IKEY)"
Write-Host "  Duo Host:               $($DUO_HOST)"
if ($DUO_MFA_ENABLED) {
    Write-Host "  Duo MFA:                Enabled"
    Write-Host "  Duo MFA Client ID:      $($DUO_CLIENT_ID)"
    Write-Host "  Duo MFA API Host:       $($DUO_API_HOST)"
    Write-Host "  Duo Redirect URI:       $($DUO_REDIRECT_URI)"
} else {
    Write-Host "  Duo MFA:                Disabled (AD-only authentication)"
}
Write-Host ""
if ($PROXY_URL) {
    Write-Host "  Proxy:                  $($PROXY_URL)"
    Write-Host "  NO_PROXY:               $($NO_PROXY)"
} else {
    Write-Host "  Proxy:                  None (direct internet access)"
}
Write-Host "  Rate limiting:          IIS Dynamic IP Restrictions (30 req/min per IP)"
if ($IIS_BEHIND_LB) {
    Write-Host "  Proxy mode:             Enabled (X-Forwarded-For)"
} else {
    Write-Host "  Proxy mode:             Disabled (direct client IP)"
}
Write-Host ""
Write-Host "  LDAP Server:            ldaps://$($LDAP_SERVER)"
Write-Host "  AD Domain:              $($KERBEROS_REALM)"
Write-Host "  LDAP Search Base:       $($LDAP_SEARCH_BASE)"
Write-Host ""
Write-Host "  CA Bundle:              $($CA_BUNDLE_PATH)"
Write-Host "  TLS Cert Thumbprint:    $($TLS_THUMBPRINT)"
Write-Host ""

if (-not (Prompt-YesNo "Proceed with installation?" "y")) {
    Write-Info "Installation cancelled."
    exit 0
}

# ====================================
# Create Directories
# ====================================
Write-Host ""
Write-Info "Creating directories..."

$certsDir = Join-Path $INSTALL_DIR "certs"
foreach ($dir in @($INSTALL_DIR, $certsDir, $LOG_DIR)) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$APP_CA_PATH = Join-Path $certsDir "ca-chain.pem"
Copy-Item -Path $CA_BUNDLE_PATH -Destination $APP_CA_PATH -Force

Write-Success "Directories created and CA bundle copied."

# ====================================
# Copy Application Files
# ====================================
Write-Info "Copying application files..."

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition

$appFile = Join-Path $scriptDir "duo-bypass-windows.py"
$reqFile = Join-Path $scriptDir "requirements.txt"

if (-not (Test-Path $appFile)) {
    Write-Err "duo-bypass-windows.py not found in $scriptDir. Place it alongside this installer."
}
if (-not (Test-Path $reqFile)) {
    Write-Err "requirements.txt not found in $scriptDir. Place it alongside this installer."
}

# Copy as duo-bypass.py in the install directory (Flask app module name)
Copy-Item -Path $appFile -Destination (Join-Path $INSTALL_DIR "duo-bypass.py") -Force
Copy-Item -Path $reqFile -Destination (Join-Path $INSTALL_DIR "requirements.txt") -Force

Write-Success "Application files copied."

# ====================================
# Copy Static Assets
# ====================================
Write-Info "Copying static assets..."

$staticSrc = Join-Path $scriptDir "static"
$staticDst = Join-Path $INSTALL_DIR "static"

if (Test-Path $staticSrc) {
    # Remove existing static directory to prevent nested static\static\ structure
    if (Test-Path $staticDst) {
        Remove-Item -Path $staticDst -Recurse -Force
    }
    Copy-Item -Path $staticSrc -Destination $staticDst -Recurse -Force
    Write-Success "Static assets copied."
} else {
    Write-Warn "No 'static' directory found in $($scriptDir). Creating empty structure..."
    New-Item -ItemType Directory -Path (Join-Path $staticDst "css") -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $staticDst "images") -Force | Out-Null
    Write-Warn "Place your style.css in $($staticDst)\css\"
    Write-Warn "Place your logo.png, banner.jpg, and favicon.png in $($staticDst)\images\"
}

foreach ($check in @("static\css\style.css", "static\images\logo.png", "static\images\banner.jpg", "static\images\favicon.png")) {
    $checkPath = Join-Path $INSTALL_DIR $check
    if (-not (Test-Path $checkPath)) {
        Write-Warn "$check not found - the UI element will not be displayed."
    }
}

# ====================================
# Update Application Configuration
# ====================================
Write-Info "Updating application configuration..."

$appPyPath = Join-Path $INSTALL_DIR "duo-bypass.py"
$appContent = Get-Content -Path $appPyPath -Raw

$CA_BUNDLE_PY   = ($APP_CA_PATH -replace '\\', '/')
$LDAP_SERVER_PY = "ldaps://$LDAP_SERVER"

$appContent = $appContent.Replace("ca_certs_file='/path/to/your/ca-chain.pem'", "ca_certs_file='$CA_BUNDLE_PY'")
$appContent = $appContent.Replace("LDAP_SERVER = 'ldaps://your.ad.server'", "LDAP_SERVER = '$LDAP_SERVER_PY'")
$appContent = $appContent.Replace("KERBEROS_REALM = 'YOURDOMAIN.COM'", "KERBEROS_REALM = '$KERBEROS_REALM'")
$appContent = $appContent.Replace("LDAP_SEARCH_BASE = 'DC=your,DC=domain,DC=com'", "LDAP_SEARCH_BASE = '$LDAP_SEARCH_BASE'")

Set-Content -Path $appPyPath -Value $appContent -Encoding UTF8

# Verify replacements were applied
$verifyContent = Get-Content -Path $appPyPath -Raw
if ($verifyContent -match "your\.ad\.server") {
    Write-Warn "LDAP server placeholder may not have been replaced correctly. Please verify $($appPyPath)"
}
if ($verifyContent -match "YOURDOMAIN\.COM") {
    Write-Warn "Kerberos realm placeholder may not have been replaced correctly. Please verify $($appPyPath)"
}

Write-Success "Application configuration updated."

# ====================================
# Update requirements.txt for Windows
# ====================================
Write-Info "Updating requirements.txt for Windows..."

$reqPath = Join-Path $INSTALL_DIR "requirements.txt"
$reqContent = Get-Content -Path $reqPath -Raw

# Comment out gunicorn (Linux WSGI server) - IIS manages the Flask process
$reqContent = $reqContent -replace '(?m)^(gunicorn.*)$', '# $1  # Not needed on Windows (IIS manages the process)'
$reqContent = $reqContent -replace '(?m)^(waitress.*)$', '# $1  # Not needed on Windows (IIS manages the process)'

# Remove gssapi if present (Windows uses LDAP simple bind instead)
$reqContent = $reqContent -replace '(?m)^(gssapi.*)$', '# $1  # Not needed on Windows (using LDAP simple bind)'

Set-Content -Path $reqPath -Value $reqContent -Encoding UTF8

Write-Success "requirements.txt updated."

# ====================================
# Create .env File
# ====================================
Write-Info "Creating .env file..."

$envLines = @(
    "FLASK_SECRET_KEY=$FLASK_SECRET_KEY"
    "DUO_IKEY=$DUO_IKEY"
    "DUO_SKEY=$DUO_SKEY"
    "DUO_HOST=$DUO_HOST"
)

if ($DUO_MFA_ENABLED) {
    $envLines += @(
        "DUO_CLIENT_ID=$DUO_CLIENT_ID"
        "DUO_CLIENT_SECRET=$DUO_CLIENT_SECRET"
        "DUO_API_HOST=$DUO_API_HOST"
        "DUO_REDIRECT_URI=$DUO_REDIRECT_URI"
    )
}

if ($PROXY_URL) {
    $envLines += @(
        "HTTP_PROXY=$PROXY_URL"
        "HTTPS_PROXY=$PROXY_URL"
        "NO_PROXY=$NO_PROXY"
    )
}

Write-Host ""
Write-Info "-- Session Security --"
Write-Info "SESSION_COOKIE_SECURE should be enabled in production with a trusted TLS certificate."
Write-Info "If you are using a self-signed certificate for testing, disable it temporarily."
Write-Host ""

if (Prompt-YesNo "Is this a production deployment with a trusted TLS certificate?" "y") {
    # No additional env var needed — defaults to true
    Write-Info "SESSION_COOKIE_SECURE will be enabled (default)."
} else {
    $envLines += "FLASK_COOKIE_SECURE=false"
    Write-Warn "SESSION_COOKIE_SECURE disabled for testing. Re-enable for production."
}

$envPath = Join-Path $INSTALL_DIR ".env"
Set-Content -Path $envPath -Value ($envLines -join "`r`n") -Encoding UTF8

Write-Success ".env file created."

# ====================================
# Create Python Virtual Environment
# ====================================
Write-Info "Creating Python virtual environment..."

$venvPath = Join-Path $INSTALL_DIR "venv"

& $pythonCmd -m venv $venvPath

$venvPython = Join-Path $venvPath "Scripts\python.exe"
$venvPip    = Join-Path $venvPath "Scripts\pip.exe"

if (-not (Test-Path $venvPython)) {
    Write-Err "Failed to create virtual environment. Ensure python3 and venv module are installed."
}

Write-Info "Installing Python dependencies..."

if ($PROXY_URL) {
    & $venvPip install --quiet --upgrade pip --proxy $PROXY_URL
    & $venvPip install --quiet -r (Join-Path $INSTALL_DIR "requirements.txt") --proxy $PROXY_URL
} else {
    & $venvPip install --quiet --upgrade pip
    & $venvPip install --quiet -r (Join-Path $INSTALL_DIR "requirements.txt")
}

Write-Success "Python dependencies installed."

# ====================================
# Create Flask Launch Script
# ====================================
Write-Info "Creating Flask launch script..."

$launchScript = @"
import os
import sys

# Load .env file
env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '.env')
if os.path.exists(env_path):
    with open(env_path, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#') and '=' in line:
                key, _, value = line.partition('=')
                os.environ[key.strip()] = value.strip()

# Change to install directory so Flask can find static files
os.chdir(os.path.dirname(os.path.abspath(__file__)))

# Import the Flask app (duo-bypass.py has a hyphen, use importlib)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib
app_module = importlib.import_module('duo-bypass')
application = app_module.app

# HttpPlatformHandler sets HTTP_PLATFORM_PORT for the backend to listen on
port = int(os.environ.get('HTTP_PLATFORM_PORT', '$FLASK_INTERNAL_PORT'))

# Run Flask on loopback - IIS handles TLS and external connectivity
application.run(
    host='127.0.0.1',
    port=port,
    debug=False,
    use_reloader=False,
    threaded=True
)
"@

$launchScriptPath = Join-Path $INSTALL_DIR "run_server.py"
Set-Content -Path $launchScriptPath -Value $launchScript -Encoding UTF8

Write-Success "Flask launch script created."

# ====================================
# Create web.config for HttpPlatformHandler
# ====================================
Write-Info "Creating web.config for IIS HttpPlatformHandler..."

# Build environment variables XML block with XML-escaped values
$envVarLines = @(
    '          <environmentVariable name="FLASK_SECRET_KEY" value="' + (Escape-XmlValue $FLASK_SECRET_KEY) + '" />'
    '          <environmentVariable name="DUO_IKEY" value="' + (Escape-XmlValue $DUO_IKEY) + '" />'
    '          <environmentVariable name="DUO_SKEY" value="' + (Escape-XmlValue $DUO_SKEY) + '" />'
    '          <environmentVariable name="DUO_HOST" value="' + (Escape-XmlValue $DUO_HOST) + '" />'
)

if ($DUO_MFA_ENABLED) {
    $envVarLines += @(
        '          <environmentVariable name="DUO_CLIENT_ID" value="' + (Escape-XmlValue $DUO_CLIENT_ID) + '" />'
        '          <environmentVariable name="DUO_CLIENT_SECRET" value="' + (Escape-XmlValue $DUO_CLIENT_SECRET) + '" />'
        '          <environmentVariable name="DUO_API_HOST" value="' + (Escape-XmlValue $DUO_API_HOST) + '" />'
        '          <environmentVariable name="DUO_REDIRECT_URI" value="' + (Escape-XmlValue $DUO_REDIRECT_URI) + '" />'
    )
}

if ($PROXY_URL) {
    $envVarLines += @(
        '          <environmentVariable name="HTTP_PROXY" value="' + (Escape-XmlValue $PROXY_URL) + '" />'
        '          <environmentVariable name="HTTPS_PROXY" value="' + (Escape-XmlValue $PROXY_URL) + '" />'
        '          <environmentVariable name="NO_PROXY" value="' + (Escape-XmlValue $NO_PROXY) + '" />'
    )
}

$enableProxyMode = if ($IIS_BEHIND_LB) { "true" } else { "false" }

# Session cookie security (disabled for self-signed certificate testing)
$cookieSecureValue = if ($envLines -match "FLASK_COOKIE_SECURE=false") { "false" } else { "true" }
$envVarLines += '          <environmentVariable name="FLASK_COOKIE_SECURE" value="' + $cookieSecureValue + '" />'

$envVarBlock = $envVarLines -join "`r`n"

$webConfig = @"
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <system.webServer>
    <!--
      HttpPlatformHandler: IIS starts and manages the Flask process.
      IIS handles TLS on port $LISTEN_PORT and reverse-proxies to Flask
      on 127.0.0.1:%HTTP_PLATFORM_PORT% (dynamically assigned by IIS).
    -->
    <handlers>
      <add name="httpPlatformHandler"
           path="*"
           verb="*"
           modules="httpPlatformHandler"
           resourceType="Unspecified" />
    </handlers>

    <httpPlatform processPath="$venvPython"
                  arguments="$launchScriptPath"
                  stdoutLogEnabled="true"
                  stdoutLogFile="$LOG_DIR\flask-stdout"
                  startupTimeLimit="60"
                  startupRetryCount="3"
                  requestTimeout="00:02:00"
                  rapidFailsPerMinute="10"
                  forwardWindowsAuthToken="false">
      <environmentVariables>
$envVarBlock
      </environmentVariables>
    </httpPlatform>

    <!-- Security Headers -->
    <httpProtocol>
      <customHeaders>
        <remove name="X-Powered-By" />
        <add name="X-Content-Type-Options" value="nosniff" />
        <add name="X-Frame-Options" value="DENY" />
        <add name="Strict-Transport-Security" value="max-age=31536000; includeSubDomains" />
        <add name="Content-Security-Policy" value="default-src 'self'; img-src 'self'; style-src 'self'; form-action 'self' https://*.duosecurity.com" />
      </customHeaders>
    </httpProtocol>

    <!-- Redirect HTTP to HTTPS (requires URL Rewrite module) -->
    <rewrite>
      <rules>
        <rule name="HTTP to HTTPS Redirect" stopProcessing="true">
          <match url="(.*)" />
          <conditions>
            <add input="{HTTPS}" pattern="off" ignoreCase="true" />
          </conditions>
          <action type="Redirect" url="https://{HTTP_HOST}/{R:1}" redirectType="Permanent" />
        </rule>
      </rules>
    </rewrite>

    <!-- Security: Request Filtering and Rate Limiting -->
    <security>
      <requestFiltering>
        <requestLimits maxAllowedContentLength="1048576" />
        <verbs>
          <add verb="GET" allowed="true" />
          <add verb="POST" allowed="true" />
          <add verb="HEAD" allowed="true" />
        </verbs>
      </requestFiltering>

      <!--
        Dynamic IP Restrictions: Rate limiting at the IIS layer.
        - denyByRequestRate: Max 5 requests per 60 seconds per client IP.
          Covers login brute-force attempts.
        - denyByConcurrentRequests: Max 10 simultaneous connections per IP.
          Prevents connection flooding.
        - abortConnection: Drops the TCP connection immediately rather than
          returning a 403, giving the attacker less information.
        - enableProxyMode: If behind a load balancer, set to true so IIS
          evaluates X-Forwarded-For instead of the direct peer IP.
      -->
      <dynamicIpSecurity denyAction="AbortRequest" enableProxyMode="$enableProxyMode">
        <denyByRequestRate enabled="true" maxRequests="30" requestIntervalInMilliseconds="60000" />
        <denyByConcurrentRequests enabled="true" maxConcurrentRequests="15" />
      </dynamicIpSecurity>
    </security>

  </system.webServer>
</configuration>
"@

$webConfigPath = Join-Path $INSTALL_DIR "web.config"
Set-Content -Path $webConfigPath -Value $webConfig -Encoding UTF8

Write-Success "web.config created."

# ====================================
# Create Log Rotation Script
# ====================================
Write-Info "Creating log rotation script..."

$rotateScript = @'
#
# Duo Bypass Code Generator - Windows Log Rotation Script
#

$ErrorActionPreference = "SilentlyContinue"

$AppLogDir       = "APP_LOG_DIR_PLACEHOLDER"
$IISSiteName     = "IIS_SITE_PLACEHOLDER"
$RetentionDays   = 30
$CompressAfterDays = 1
$LogFile         = Join-Path $AppLogDir "log-rotation.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp - $Message" | Out-File -Append -FilePath $LogFile -Encoding UTF8
}

Write-Log "=== Log rotation started ==="

$cutoffDelete   = (Get-Date).AddDays(-$RetentionDays)
$cutoffCompress = (Get-Date).AddDays(-$CompressAfterDays)

# Delete old Flask stdout logs
Get-ChildItem -Path $AppLogDir -Filter "flask-stdout*.log" |
    Where-Object { $_.LastWriteTime -lt $cutoffDelete } |
    ForEach-Object {
        Remove-Item -Path $_.FullName -Force
        Write-Log "Deleted: $($_.Name)"
    }

# Delete old compressed logs
Get-ChildItem -Path $AppLogDir -Filter "flask-stdout*.zip" |
    Where-Object { $_.LastWriteTime -lt $cutoffDelete } |
    ForEach-Object {
        Remove-Item -Path $_.FullName -Force
        Write-Log "Deleted: $($_.Name)"
    }

# Compress logs older than threshold
Get-ChildItem -Path $AppLogDir -Filter "flask-stdout*.log" |
    Where-Object { $_.LastWriteTime -lt $cutoffCompress -and $_.Length -gt 0 } |
    ForEach-Object {
        $zipPath = $_.FullName + ".zip"
        if (-not (Test-Path $zipPath)) {
            Compress-Archive -Path $_.FullName -DestinationPath $zipPath -CompressionLevel Optimal
            Remove-Item -Path $_.FullName -Force
            Write-Log "Compressed: $($_.Name)"
        }
    }

# Rotate IIS logs
try {
    Import-Module WebAdministration -ErrorAction Stop
    $site = Get-Website -Name $IISSiteName
    if ($site) {
        $iisLogDir = Join-Path "$env:SystemDrive\inetpub\logs\LogFiles" "W3SVC$($site.id)"
        if (Test-Path $iisLogDir) {
            Get-ChildItem -Path $iisLogDir -Filter "*.log" |
                Where-Object { $_.LastWriteTime -lt $cutoffDelete } |
                ForEach-Object {
                    Remove-Item -Path $_.FullName -Force
                    Write-Log "Deleted IIS log: $($_.Name)"
                }

            Get-ChildItem -Path $iisLogDir -Filter "*.log" |
                Where-Object { $_.LastWriteTime -lt $cutoffCompress -and $_.Length -gt 0 } |
                ForEach-Object {
                    $zipPath = $_.FullName + ".zip"
                    if (-not (Test-Path $zipPath)) {
                        Compress-Archive -Path $_.FullName -DestinationPath $zipPath -CompressionLevel Optimal
                        Remove-Item -Path $_.FullName -Force
                        Write-Log "Compressed IIS log: $($_.Name)"
                    }
                }
        }
    }
} catch {
    Write-Log "Could not process IIS logs: $_"
}

# Trim rotation log
if (Test-Path $LogFile) {
    if ((Get-Item $LogFile).Length -gt 1MB) {
        $lines = Get-Content $LogFile -Tail 500
        Set-Content -Path $LogFile -Value $lines -Encoding UTF8
        Write-Log "Rotation log trimmed."
    }
}

Write-Log "=== Log rotation complete ==="
'@

# Replace placeholders in the rotation script
$rotateScript = $rotateScript.Replace("APP_LOG_DIR_PLACEHOLDER", $LOG_DIR)
$rotateScript = $rotateScript.Replace("IIS_SITE_PLACEHOLDER", $IIS_SITE)

$rotateScriptPath = Join-Path $INSTALL_DIR "rotate-logs.ps1"
Set-Content -Path $rotateScriptPath -Value $rotateScript -Encoding UTF8

Write-Success "Log rotation script created."

# ====================================
# Create Log Rotation Scheduled Task
# ====================================
Write-Info "Creating log rotation scheduled task..."

$taskName = "DuoBypass-LogRotation"

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$rotateScriptPath`""

$trigger = New-ScheduledTaskTrigger -Daily -At "02:00AM"

$principal = New-ScheduledTaskPrincipal `
    -UserId "NT AUTHORITY\SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "Daily log rotation for Duo Bypass Code Generator" | Out-Null

Write-Success "Log rotation scheduled task created (daily at 2:00 AM)."

# ====================================
# Create .gitignore
# ====================================
$gitignoreContent = @"
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
web.config
"@

Set-Content -Path (Join-Path $INSTALL_DIR ".gitignore") -Value $gitignoreContent -Encoding UTF8

# ====================================
# Unlock IIS Configuration Sections
# ====================================
Write-Info "Unlocking required IIS configuration sections..."

$sectionsToUnlock = @(
    "system.webServer/handlers",
    "system.webServer/security/requestFiltering",
    "system.webServer/security/dynamicIpSecurity",
    "system.webServer/httpProtocol"
)

if ($urlRewriteInstalled) {
    $sectionsToUnlock += "system.webServer/rewrite/rules"
}

$appcmd = Join-Path $env:SystemRoot "System32\inetsrv\appcmd.exe"

foreach ($section in $sectionsToUnlock) {
    try {
        $result = & $appcmd unlock config /section:$section 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Success "Unlocked: $section"
        } else {
            Write-Warn "Could not unlock: $section -- $result"
        }
    } catch {
        Write-Warn "Failed to unlock section: $section -- $_"
    }
}

# ====================================
# Set File Permissions (ACLs)
# ====================================
Write-Info "Setting file permissions..."

# Grant IIS_IUSRS read/execute access to the install directory
$iisUserRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\IIS_IUSRS", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow"
)

$installAcl = Get-Acl $INSTALL_DIR
$installAcl.AddAccessRule($iisUserRule)
Set-Acl -Path $INSTALL_DIR -AclObject $installAcl

# Grant IIS_IUSRS write to log directory
$iisWriteRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\IIS_IUSRS", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow"
)

$logAcl = Get-Acl $LOG_DIR
$logAcl.AddAccessRule($iisWriteRule)
Set-Acl -Path $LOG_DIR -AclObject $logAcl

# Restrict .env to Administrators, SYSTEM, and IIS_IUSRS (read only)
foreach ($restrictedFile in @($envPath)) {
    if (Test-Path $restrictedFile) {
        $acl = Get-Acl $restrictedFile
        $acl.SetAccessRuleProtection($true, $false)
        $acl.Access | ForEach-Object { $acl.RemoveAccessRule($_) | Out-Null }

        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            "BUILTIN\Administrators", "FullControl", "Allow"
        )))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            "NT AUTHORITY\SYSTEM", "FullControl", "Allow"
        )))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            "BUILTIN\IIS_IUSRS", "Read", "Allow"
        )))

        Set-Acl -Path $restrictedFile -AclObject $acl
    }
}

# Restrict certs directory
$certsDirAcl = Get-Acl $certsDir
$certsDirAcl.SetAccessRuleProtection($true, $false)
$certsDirAcl.Access | ForEach-Object { $certsDirAcl.RemoveAccessRule($_) | Out-Null }

$certsDirAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
)))
$certsDirAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    "NT AUTHORITY\SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow"
)))
$certsDirAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\IIS_IUSRS", "Read", "ContainerInherit,ObjectInherit", "None", "Allow"
)))
Set-Acl -Path $certsDir -AclObject $certsDirAcl

# Static assets
if (Test-Path $staticDst) {
    $staticAcl = Get-Acl $staticDst
    $staticAcl.AddAccessRule($iisUserRule)
    Set-Acl -Path $staticDst -AclObject $staticAcl
}

# Grant IIS_IUSRS read/execute to Python installation directory
$realPythonPath = (Get-Command $pythonCmd).Source
$pythonInstallDir = Split-Path -Parent $realPythonPath

$pythonAcl = Get-Acl $pythonInstallDir
$pythonAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\IIS_IUSRS", "ReadAndExecute", "ContainerInherit,ObjectInherit", "None", "Allow"
)))
Set-Acl -Path $pythonInstallDir -AclObject $pythonAcl
Write-Success "IIS_IUSRS granted access to Python directory: $($pythonInstallDir)"

# Grant IIS_IUSRS write to temp directory (for session/LDAP operations)
$tempDir = [System.IO.Path]::GetTempPath()
$tempAcl = Get-Acl $tempDir
$tempAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
    "BUILTIN\IIS_IUSRS", "Modify", "ContainerInherit,ObjectInherit", "None", "Allow"
)))
Set-Acl -Path $tempDir -AclObject $tempAcl
Write-Success "IIS_IUSRS granted write access to temp directory."

Write-Success "Permissions set."

# ====================================
# Configure IIS Application Pool
# ====================================
Write-Info "Configuring IIS Application Pool..."

if (Test-Path "IIS:\AppPools\$APP_POOL") {
    Write-Warn "Application Pool '$($APP_POOL)' already exists."
    if (Prompt-YesNo "Remove and recreate it?" "y") {
        Remove-WebAppPool -Name $APP_POOL
        Write-Success "Existing pool removed."
    }
}

if (-not (Test-Path "IIS:\AppPools\$APP_POOL")) {
    New-WebAppPool -Name $APP_POOL | Out-Null

    Set-ItemProperty "IIS:\AppPools\$APP_POOL" -Name managedRuntimeVersion -Value ""
    Set-ItemProperty "IIS:\AppPools\$APP_POOL" -Name managedPipelineMode -Value "Integrated"
    Set-ItemProperty "IIS:\AppPools\$APP_POOL" -Name startMode -Value "AlwaysRunning"
    Set-ItemProperty "IIS:\AppPools\$APP_POOL" -Name processModel.idleTimeout -Value ([TimeSpan]::FromMinutes(0))
    Set-ItemProperty "IIS:\AppPools\$APP_POOL" -Name recycling.periodicRestart.time -Value ([TimeSpan]::FromHours(24))

    Write-Success "Application Pool '$($APP_POOL)' created and configured."
}

# ====================================
# Configure IIS Website
# ====================================
Write-Info "Configuring IIS Website..."

$existingSite = Get-Website -Name $IIS_SITE -ErrorAction SilentlyContinue
if ($existingSite) {
    Write-Warn "IIS Site '$($IIS_SITE)' already exists."
    if (Prompt-YesNo "Remove and recreate it?" "y") {
        Remove-Website -Name $IIS_SITE
        Write-Success "Existing site removed."
    } else {
        Write-Warn "Skipping site creation. You may need to update it manually."
    }
}

# Check for port conflicts
$existingBindings = @(Get-WebBinding -Protocol "https" | Where-Object {
    $_.bindingInformation -match ":$($LISTEN_PORT):"
})

$conflictingSites = @(foreach ($b in $existingBindings) {
    Get-Website | Where-Object {
        $_.Name -ne $IIS_SITE -and
        ($_.Bindings.Collection.bindingInformation -contains $b.bindingInformation)
    }
})

if ($conflictingSites.Count -gt 0) {
    $siteNames = ($conflictingSites | Select-Object -ExpandProperty Name -Unique) -join ", "
    Write-Warn "Port $($LISTEN_PORT) is already in use by: $siteNames"
    if (-not (Prompt-YesNo "Continue anyway?" "n")) {
        Write-Err "Installation cancelled due to port conflict."
    }
}

if (-not (Get-Website -Name $IIS_SITE -ErrorAction SilentlyContinue)) {
    New-Website -Name $IIS_SITE `
        -PhysicalPath $INSTALL_DIR `
        -ApplicationPool $APP_POOL `
        -Port $LISTEN_PORT `
        -Ssl `
        -HostHeader $WEB_HOSTNAME `
        -Force | Out-Null

    $binding = Get-WebBinding -Name $IIS_SITE -Protocol "https"
    if ($binding) {
        $binding.AddSslCertificate($TLS_THUMBPRINT, "My")
        Write-Success "TLS certificate bound to site."
    } else {
        Write-Warn "Could not find HTTPS binding to attach certificate. Bind it manually in IIS Manager."
    }

    Write-Success "IIS Website '$($IIS_SITE)' created."

    if (Prompt-YesNo "Add HTTP (port 80) binding for automatic HTTPS redirect?" "y") {
        New-WebBinding -Name $IIS_SITE -Protocol "http" -Port 80 -HostHeader $WEB_HOSTNAME
        Write-Success "HTTP redirect binding added."
    }
}

# ====================================
# Validate Certificate Configuration
# ====================================
Write-Info "Validating certificate configuration..."

if (-not (Test-Path $APP_CA_PATH)) {
    Write-Warn "CA bundle not found at $($APP_CA_PATH)"
} else {
    Write-Success "CA bundle present."
}

$boundCert = Get-ChildItem -Path Cert:\LocalMachine\My | Where-Object { $_.Thumbprint -eq $TLS_THUMBPRINT }
if ($boundCert) {
    if ($boundCert.NotAfter -lt (Get-Date)) {
        Write-Warn "TLS certificate has EXPIRED ($($boundCert.NotAfter))."
    } elseif ($boundCert.NotAfter -lt (Get-Date).AddDays(30)) {
        Write-Warn "TLS certificate expires soon: $($boundCert.NotAfter)"
    } else {
        Write-Success "TLS certificate valid until $($boundCert.NotAfter)"
    }
}

# ====================================
# Windows Firewall Rules
# ====================================
Write-Host ""
if (Prompt-YesNo "Add Windows Firewall rule to allow inbound traffic on port $($LISTEN_PORT)?" "y") {
    $ruleName = "Duo Bypass Code Generator (Port $($LISTEN_PORT))"

    Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue

    New-NetFirewallRule `
        -DisplayName $ruleName `
        -Direction Inbound `
        -Protocol TCP `
        -LocalPort $LISTEN_PORT `
        -Action Allow `
        -Profile Domain,Private `
        -Description "Allow inbound HTTPS for Duo Bypass Code Generator (IIS)" | Out-Null

    Write-Success "Firewall rule added for port $($LISTEN_PORT)."

    if (Get-WebBinding -Name $IIS_SITE -Protocol "http" -ErrorAction SilentlyContinue) {
        $httpRuleName = "Duo Bypass Code Generator (HTTP Redirect Port 80)"
        Get-NetFirewallRule -DisplayName $httpRuleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue

        New-NetFirewallRule `
            -DisplayName $httpRuleName `
            -Direction Inbound `
            -Protocol TCP `
            -LocalPort 80 `
            -Action Allow `
            -Profile Domain,Private `
            -Description "Allow inbound HTTP for HTTPS redirect" | Out-Null

        Write-Success "Firewall rule added for port 80 (HTTP redirect)."
    }
} else {
    Write-Info "Skipping firewall configuration."
}

# ====================================
# Start the IIS Site
# ====================================
Write-Host ""
if (Prompt-YesNo "Start the IIS site now?" "n") {
    try {
        Start-Website -Name $IIS_SITE
        Start-Sleep -Seconds 3

        $siteState = (Get-Website -Name $IIS_SITE).State
        if ($siteState -eq "Started") {
            Write-Success "IIS site '$($IIS_SITE)' started successfully."
        } else {
            Write-Warn "Site state: $siteState - check IIS Manager and logs."
        }
    } catch {
        Write-Warn "Failed to start site: $_"
        Write-Warn "Check IIS Manager and $($LOG_DIR) for details."
    }
} else {
    Write-Info "Site installed but not started. Start with: Start-Website -Name '$($IIS_SITE)'"
}

# ====================================
# Summary
# ====================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor White
Write-Host "  Installation Complete" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor White
Write-Host ""
Write-Host "  Architecture:"
Write-Host ""
Write-Host "    Client --HTTPS--> IIS (port $($LISTEN_PORT)) --HTTP--> Flask (127.0.0.1)" -ForegroundColor Green
Write-Host "                       | TLS termination           | HttpPlatformHandler"
Write-Host "                       | Security headers           | Process management"
Write-Host "                       | Request filtering          | Auto-restart"
Write-Host ""
Write-Host "  Rate limiting:          IIS Dynamic IP Restrictions (30 req/min per IP)"
if (-not $ipSecInstalled) {
    Write-Warn "  Action Required: Install IIS IP and Domain Restrictions feature for rate limiting."
    Write-Warn "  Install-WindowsFeature -Name Web-IP-Security"
    Write-Host ""
}
Write-Host ""
Write-Host "  Install directory:      $($INSTALL_DIR)"
Write-Host "  Log directory:          $($LOG_DIR)"
Write-Host "  IIS Site:               $($IIS_SITE)"
Write-Host "  Application Pool:       $($APP_POOL)"
Write-Host ""
Write-Host "  Manage via IIS Manager or PowerShell:"
Write-Host "    Start-Website -Name '$($IIS_SITE)'"
Write-Host "    Stop-Website -Name '$($IIS_SITE)'"
Write-Host "    Restart-WebAppPool -Name '$($APP_POOL)'"
Write-Host ""
Write-Host "    Get-Website -Name '$($IIS_SITE)' | Select-Object Name, State"
Write-Host ""
Write-Host "  View logs:"
Write-Host "    Get-Content -Tail 50 -Wait $($LOG_DIR)\flask-stdout*.log"
Write-Host "    # IIS logs: $($env:SystemDrive)\inetpub\logs\LogFiles\"
Write-Host ""
if ($LISTEN_PORT -eq "443") {
    Write-Host "  Application URL:  https://$($WEB_HOSTNAME)/" -ForegroundColor Green
} else {
    Write-Host "  Application URL:  https://$($WEB_HOSTNAME):$($LISTEN_PORT)/" -ForegroundColor Green
}
Write-Host ""

if (-not $urlRewriteInstalled) {
    Write-Warn "  Action Required: Install IIS URL Rewrite module for HTTP-to-HTTPS redirect."
    Write-Warn "  https://www.iis.net/downloads/microsoft/url-rewrite"
    Write-Host ""
}

if (-not $httpPlatformInstalled) {
    Write-Warn "  Action Required: Install HttpPlatformHandler for IIS."
    Write-Warn "  https://www.iis.net/downloads/microsoft/httpplatformhandler"
    Write-Host ""
}

Write-Success "Done."
