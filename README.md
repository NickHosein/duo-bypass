# Duo Bypass Code Generator

> **⚠️ DISCLAIMER:** This project is an independent open-source initiative and is not affiliated with, endorsed by, or supported by Cisco Systems, Inc. or
> Duo Security.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
> WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

A self-service web application that allows authenticated users to generate Duo Security bypass codes through the Duo Admin API. Built with Flask and designed for enterprise environments, the application integrates with Active Directory for authentication and optionally supports Duo MFA as a second factor before granting access to the bypass code generation interface.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Features](#features)
- [Prerequisites](#prerequisites)
- [Project Structure](#project-structure)
- [Installation](#installation)
  - [Linux Installation](#linux-installation)
  - [Windows Installation (IIS)](#windows-installation-iis)
- [Configuration](#configuration)
  - [Duo Admin API](#duo-admin-api)
  - [Duo MFA (Optional)](#duo-mfa-optional)
  - [Active Directory / LDAP](#active-directory--ldap)
  - [TLS Certificates](#tls-certificates)
  - [Proxy Configuration](#proxy-configuration)
  - [Flask Settings](#flask-settings)
- [Bypass Code Duration Options](#bypass-code-duration-options)
- [Security Features](#security-features)
- [Log Management](#log-management)
  - [Linux Logs](#linux-logs)
  - [Windows Logs](#windows-logs)
- [Uninstallation](#uninstallation)
  - [Linux Uninstallation](#linux-uninstallation)
  - [Windows Uninstallation](#windows-uninstallation)
- [Service Management](#service-management)
  - [Linux Service Commands](#linux-service-commands)
  - [Windows Service Commands](#windows-service-commands)
- [Troubleshooting](#troubleshooting)

---

## Overview

The Duo Bypass Code Generator provides a secure, self-service portal for users to generate temporary Duo bypass codes. This is useful in scenarios where users have lost access to their primary Duo authentication device (e.g., a lost or broken phone) and need temporary access to Duo-protected resources without requiring help desk intervention.

### Workflow

1. User navigates to the web application over HTTPS.
2. User authenticates with their Active Directory credentials.
3. *(Optional)* User completes Duo MFA verification via the Duo Universal Prompt.
4. User selects a bypass code duration (15 minutes to 24 hours).
5. A single-use bypass code is generated via the Duo Admin API and displayed to the user.

---

## Architecture

### Linux

```text
Client --(HTTPS)--> Gunicorn (TLS termination, port 443)
                      |
                      v
                Flask Application
                |               |
                v               v
         Active Directory    Duo Admin API
       (LDAPS + Kerberos)       (HTTPS)
```

- **Web Server:** Gunicorn with native TLS termination
- **Authentication:** Kerberos GSSAPI via LDAP SASL bind
- **Service Management:** systemd
- **Log Rotation:** logrotate (daily, 30-day retention)

### Windows

```text
Client --(HTTPS)--> IIS (TLS termination, port 443)
                      | HttpPlatformHandler
                      v
                Flask Application (127.0.0.1 loopback)
                |               |
                v               v
         Active Directory    Duo Admin API
       (LDAPS + Simple Bind)    (HTTPS)
```

- **Web Server:** IIS with HttpPlatformHandler as reverse proxy
- **Authentication:** LDAP simple bind over TLS
- **TLS Termination:** IIS handles all TLS; Flask runs on HTTP loopback
- **Process Management:** IIS Application Pool with auto-restart
- **Log Rotation:** PowerShell scheduled task (daily at 2:00 AM, 30-day retention)

---

## Features

- **Self-Service Bypass Codes:** Users generate their own temporary Duo bypass codes without help desk involvement.
- **Active Directory Authentication:** Validates user credentials against AD via LDAPS.
  - *Linux:* Kerberos GSSAPI SASL bind
  - *Windows:* LDAP simple bind over TLS
- **Optional Duo MFA:** Optionally require Duo MFA (Universal Prompt via Web SDK) as a second factor before granting access.
- **Configurable Code Duration:** Users select bypass code validity from 15 minutes to 24 hours.
- **Rate Limiting:** Login attempts limited to 5 per minute; bypass code generation limited to 10 per hour.
- **CSRF Protection:** All forms protected with Flask-WTF CSRF tokens.
- **Security Headers:** `X-Content-Type-Options`, `X-Frame-Options`, `Strict-Transport-Security`, and `Content-Security-Policy` headers applied to all responses.
- **Session Management:** Sessions expire after 15 minutes of inactivity.
- **Input Sanitization:** Usernames validated against a strict allowlist pattern.
- **Automated Log Rotation:** Configurable log rotation on both platforms.
- **Interactive Installers:** Guided installation scripts for both Linux and Windows.
- **Uninstall Scripts:** Clean removal scripts for both platforms.

---

## Prerequisites

### Common

- **Python 3.10+**
- **Duo Admin API Application** configured in the Duo Admin Panel with permissions to look up users and create bypass codes.
- *(Optional)* **Duo Web SDK Application** configured in the Duo Admin Panel for MFA on login.
- **Active Directory** with LDAPS (port 636) enabled.
- **TLS Certificate** (and private key) for the web application hostname.
- **CA Bundle** (`.pem`) for validating LDAPS connections to Active Directory.

### Linux

- Debian/Ubuntu, RHEL/CentOS, or Fedora-based distribution
- Root access (`sudo`)
- Kerberos client libraries (`krb5-user` / `krb5-workstation`)
- `python3-venv` package
- Network access to the Duo API endpoints and Active Directory

### Windows

- Windows Server with IIS installed (Web-Server role)
- Administrator access
- **HttpPlatformHandler** IIS module — [Download](https://www.iis.net/downloads/microsoft/httpplatformhandler)
- *(Recommended)* **IIS URL Rewrite** module for HTTP-to-HTTPS redirect — [Download](https://www.iis.net/downloads/microsoft/url-rewrite)
- Python 3.10+ installed **system-wide** (not per-user), available in the system PATH
- TLS certificate imported into the Windows Certificate Store (`Local Machine > Personal`)
- Network access to the Duo API endpoints and Active Directory

---

## Project Structure

```text
duo-bypass/
├── duo-bypass.py           # Flask application (Linux version, Kerberos GSSAPI auth)
├── duo-bypass-windows.py   # Flask application (Windows version, LDAP simple bind auth)
├── requirements.txt        # Python dependencies
├── install-linux.sh        # Interactive Linux installer (Bash)
├── install.ps1             # Interactive Windows installer (PowerShell)
├── uninstall-linux.sh      # Linux uninstall script (Bash)
├── uninstall.ps1           # Windows uninstall script (PowerShell)
├── static/
│   ├── css/
│   │   └── style.css       # Application stylesheet
│   └── images/
│       ├── banner.jpg      # Page banner image
│       ├── logo.png        # Application logo
│       └── favicon.png     # Browser favicon
└── README.md               # This file
```

---

## Installation

Both installers are fully interactive and will prompt for all required configuration values. They handle dependency installation, virtual environment creation, file placement, permissions, service configuration, and firewall rules.

### Linux Installation

1. Place the following files in the same directory:
   - `install-linux.sh`
   - `duo-bypass.py`
   - `requirements.txt`
   - `static/` directory (with CSS and images)

2. Make the installer executable and run it as root:
   ```bash
   chmod +x install-linux.sh
   sudo ./install-linux.sh
   ```

3. The installer will perform all necessary setup steps, including installing dependencies, creating a service user, configuring Kerberos, and setting up systemd.

4. **Default Installation Paths:**

| Component | Path |
| :--- | :--- |
| Application files | `/opt/duo-bypass/` |
| Virtual environment | `/opt/duo-bypass/venv/` |
| Certificates | `/opt/duo-bypass/certs/` |
| Environment file | `/opt/duo-bypass/.env` |
| Gunicorn config | `/opt/duo-bypass/gunicorn.conf.py` |
| Logs | `/var/log/duo-bypass/` |
| Systemd service | `/etc/systemd/system/duo-bypass.service` |
| Logrotate config | `/etc/logrotate.d/duo-bypass` |
| Kerberos config | `/etc/krb5.conf` |

### Windows Installation (IIS)

1. Place the following files in the same directory:
   - `install.ps1`
   - `duo-bypass-windows.py`
   - `requirements.txt`
   - `static/` directory (with CSS and images)

2. Ensure the TLS certificate is imported into the Windows Certificate Store:
   ```powershell
   Import-PfxCertificate -FilePath "C:\path\to\cert.pfx" -CertStoreLocation Cert:\LocalMachine\My -Password (ConvertTo-SecureString -String "password" -AsPlainText -Force)
   ```

3. Run the installer as Administrator:
   ```powershell
   .\install.ps1
   ```

4. The installer will verify prerequisites, check the system clock, prompt for configuration, set up IIS, and configure permissions.

5. **Default Installation Paths:**

| Component | Path |
| :--- | :--- |
| Application files | `C:\inetpub\duo-bypass\` |
| Virtual environment | `C:\inetpub\duo-bypass\venv\` |
| Certificates | `C:\inetpub\duo-bypass\certs\` |
| Environment file | `C:\inetpub\duo-bypass\.env` |
| Web config | `C:\inetpub\duo-bypass\web.config` |
| Launch script | `C:\inetpub\duo-bypass\run_server.py` |
| Log rotation script | `C:\inetpub\duo-bypass\rotate-logs.ps1` |
| Logs | `C:\inetpub\duo-bypass\logs\` |
| IIS Site | `DuoBypass` |
| Application Pool | `DuoBypassPool` |
| Scheduled Task | `DuoBypass-LogRotation` |

---

## Configuration

All sensitive configuration values are stored in the `.env` file, which is created by the installer with restricted permissions. The installers prompt for all values interactively.

### Duo Admin API

These credentials are used to look up Duo users and generate bypass codes via the Duo Admin API.

| Variable | Description |
| :--- | :--- |
| `DUO_IKEY` | Duo Admin API Integration Key |
| `DUO_SKEY` | Duo Admin API Secret Key |
| `DUO_HOST` | Duo Admin API Hostname (e.g., `api-XXXXXXXX.duosecurity.com`) |

**Duo Admin Panel Setup:**
1. Log into the Duo Admin Panel.
2. Navigate to **Applications > Protect an Application**.
3. Search for **Admin API** and click **Protect**.
4. Grant the application **Grant read resource** and **Grant write resource** permissions (required for user lookup and bypass code creation).
5. Note the Integration Key (IKEY), Secret Key (SKEY), and API Hostname.

### Duo MFA (Optional)

Optionally require Duo MFA via the Universal Prompt before granting access. This requires a separate Duo Web SDK application.

| Variable | Description |
| :--- | :--- |
| `DUO_CLIENT_ID` | Duo Web SDK Client ID |
| `DUO_CLIENT_SECRET` | Duo Web SDK Client Secret |
| `DUO_API_HOST` | Duo Web SDK API Hostname |
| `DUO_REDIRECT_URI` | Callback URL (e.g., `https://duo-bypass.example.com/duo-callback`) |

If these variables are not set, users will authenticate with AD credentials only (no MFA).

**Duo Admin Panel Setup:**
1. Navigate to **Applications > Protect an Application**.
2. Search for **Web SDK** and click **Protect**.
3. Note the Client ID, Client Secret, and API Hostname.
4. Set the redirect URI to `https://<your-hostname>/duo-callback`.

### Active Directory / LDAP

| Setting | Description |
| :--- | :--- |
| LDAP Server | FQDN of your AD domain controller (e.g., `dc01.example.com`) |
| LDAP Port | 636 (LDAPS) |
| Kerberos Realm | AD domain in uppercase (e.g., `EXAMPLE.COM`) |
| LDAP Search Base | Base DN for searches (e.g., `DC=example,DC=com`) |

The application connects to AD over LDAPS (TLS-encrypted LDAP on port 636).
- **Linux:** Uses Kerberos GSSAPI SASL bind. The installer configures `/etc/krb5.conf`.
- **Windows:** Uses LDAP simple bind over TLS. Credentials are sent encrypted over the TLS connection.

### TLS Certificates

| Certificate | Purpose |
| :--- | :--- |
| CA Bundle (`.pem`) | Validates the AD domain controller's TLS certificate during LDAPS connections |
| TLS Certificate | Web application HTTPS certificate |
| TLS Private Key | Web application HTTPS private key |

- **Linux:** Certificate and key file paths are provided during installation. Gunicorn handles TLS termination directly.
- **Windows:** The TLS certificate must be imported into the Windows Certificate Store (Local Machine > Personal). IIS handles TLS termination. The CA bundle for LDAPS validation is copied to the application's `certs/` directory.

### Proxy Configuration

If the server requires an HTTP proxy for outbound internet access (to reach Duo API endpoints), the installers support configuring proxy settings.

| Variable | Description |
| :--- | :--- |
| `HTTP_PROXY` | Proxy URL (e.g., `http://proxy.example.com:8080`) |
| `HTTPS_PROXY` | Proxy URL (typically the same as HTTP_PROXY) |
| `NO_PROXY` | Comma-separated list of addresses to bypass the proxy |

The Windows installer prompts for proxy configuration and includes the values in both the `.env` file and the `web.config` environment variables.

### Flask Settings

| Variable | Description |
| :--- | :--- |
| `FLASK_SECRET_KEY` | Secret key for session signing (auto-generated by installer recommended) |

The session lifetime is set to 15 minutes. Sessions are permanent and expire after inactivity.

---

## Bypass Code Duration Options

Users select from the following bypass code durations when generating a code:

| Label | Duration |
| :--- | :--- |
| 15m | 15 minutes |
| 30m | 30 minutes |
| 1h | 1 hour (default) |
| 2h | 2 hours |
| 4h | 4 hours |
| 8h | 8 hours |
| 12h | 12 hours |
| 24h | 24 hours |

The maximum allowed duration is 24 hours (86,400 seconds). Each request generates a single bypass code.

---

## Security Features

| Feature | Description |
| :--- | :--- |
| **HTTPS Only** | All traffic is encrypted with TLS 1.2+ |
| **CSRF Protection** | Flask-WTF CSRF tokens on all forms |
| **Rate Limiting** | Login: 5 attempts/minute; Bypass codes: 10/hour |
| **Input Sanitization** | Usernames validated against `^[a-zA-Z0-9._-]+$`, max 64 characters |
| **Session Expiry** | Sessions expire after 15 minutes of inactivity |
| **Security Headers** | `X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`, `Strict-Transport-Security`, `Content-Security-Policy` |
| **No Caching** | `Cache-Control: no-store` on bypass code responses |
| **Restricted Permissions** | `.env` and certificate files have restrictive ACLs/permissions |
| **Secure Cookies** | `HttpOnly`, `SameSite=Lax` session cookies |
| **HTTP to HTTPS** | Automatic redirect via IIS URL Rewrite (Windows) or can be configured with Gunicorn (Linux) |
| **Request Filtering** | Windows: IIS request filtering limits content length and allowed HTTP verbs (GET, POST, HEAD) |
| **CSP** | Restricts resource loading to 'self' and Duo domains for form actions |

---

## Log Management

### Linux Logs

| Log File | Description |
| :--- | :--- |
| `/var/log/duo-bypass/access.log` | Gunicorn access log |
| `/var/log/duo-bypass/error.log` | Gunicorn error log |
| `journalctl -u duo-bypass` | Systemd service logs |

**Log Rotation:** Managed by logrotate (`/etc/logrotate.d/duo-bypass`):
- Rotated daily
- 30-day retention
- Compressed after 1 day (`delaycompress`)
- Gunicorn workers signaled with USR1 to reopen log files

**View logs:**
```bash
tail -f /var/log/duo-bypass/access.log
tail -f /var/log/duo-bypass/error.log
journalctl -u duo-bypass -f
```

### Windows Logs

| Log Location | Description |
| :--- | :--- |
| `C:\inetpub\duo-bypass\logs\flask-stdout*.log` | Flask application stdout/stderr |
| `%SystemDrive%\inetpub\logs\LogFiles\` | IIS access logs |

**Log Rotation:** Managed by a PowerShell scheduled task (`DuoBypass-LogRotation`):
- Runs daily at 2:00 AM
- Compresses logs older than 1 day
- Deletes logs older than 30 days
- Processes both Flask stdout logs and IIS logs
- Self-trims its own rotation log at 1 MB

**View logs:**
```powershell
Get-Content -Tail 50 -Wait C:\inetpub\duo-bypass\logs\flask-stdout*.log
dir $env:SystemDrive\inetpub\logs\LogFiles\
```

---

## Uninstallation

### Linux Uninstallation

1. Run the uninstall script as root:
   ```bash
   chmod +x uninstall-linux.sh
   sudo ./uninstall-linux.sh
   ```

2. The script will:
   - Stop and disable the systemd service
   - Remove the `cap_net_bind_service` capability from the Python binary
   - Remove the logrotate configuration
   - Optionally restore `/etc/krb5.conf` from backup
   - Remove the application directory (`/opt/duo-bypass`)
   - Remove the log directory (`/var/log/duo-bypass`)
   - Remove the runtime PID directory (`/run/duo-bypass`)
   - Optionally remove the service user account

3. **Items requiring manual cleanup after uninstall:**
   - `/etc/krb5.conf` (if not restored from backup)
   - DNS records or `/etc/hosts` entries
   - Duo Admin Panel applications (Web SDK, Admin API)
   - Firewall rules

### Windows Uninstallation

1. Run the uninstall script as Administrator:
   ```powershell
   .\uninstall.ps1
   ```

2. The script will:
   - Detect all installed components and display them
   - Stop the IIS site and Application Pool
   - Remove the IIS site and Application Pool
   - Remove the log rotation scheduled task
   - Remove Windows Firewall rules
   - Remove system environment variables
   - Optionally back up the `.env` file before deletion
   - Remove the installation directory
   - Optionally re-lock IIS configuration sections
   - Optionally remove IIS_IUSRS permissions from the Python directory
   - Optionally remove IIS_IUSRS write permissions from the temp directory
   - Optionally remove proxy environment variables

3. **Items not removed (may be shared with other applications):**
   - Python installation
   - IIS (Web Server role)
   - HttpPlatformHandler module
   - URL Rewrite module
   - DNS records
   - Duo Admin Panel applications

---

## Service Management

### Linux Service Commands

```bash
sudo systemctl start duo-bypass
sudo systemctl stop duo-bypass
sudo systemctl restart duo-bypass
sudo systemctl status duo-bypass
journalctl -u duo-bypass -f
sudo systemctl enable duo-bypass
sudo systemctl disable duo-bypass
```

### Windows Service Commands

```powershell
Start-Website -Name 'DuoBypass'
Stop-Website -Name 'DuoBypass'
Restart-WebAppPool -Name 'DuoBypassPool'
Get-Website -Name 'DuoBypass' | Select-Object Name, State
iisreset
```

---

## Troubleshooting

### Common Issues

**Application fails to start:**
- Verify all required environment variables are set in `.env`.
- Check that the Duo API credentials are correct.
- Ensure the LDAP server is reachable over port 636 (LDAPS).
- Verify the CA bundle is valid and can validate the AD server's TLS certificate.
- Check log files for detailed error messages.

**Authentication failures:**
- Verify the LDAP server FQDN is correct and resolvable.
- Confirm the Kerberos realm matches your AD domain (uppercase).
- Ensure the LDAP search base DN is correct.
- (Linux) Verify `/etc/krb5.conf` is correctly configured. Test with `kinit username@REALM`.
- (Windows) Verify the CA bundle path is correct and the file is readable by `IIS_IUSRS`.

**Duo API errors:**
- Verify the system clock is accurate (within 5 minutes). The Duo Admin API uses HMAC signatures that include the current time.
  - Linux: `ntpstat` or `timedatectl`
  - Windows: `w32tm /stripchart /computer:time.windows.com /dataonly /samples:1`
- Confirm the Duo IKEY, SKEY, and HOST are correct.
- If behind a proxy, ensure `HTTP_PROXY` and `HTTPS_PROXY` are configured.
- Check that the Duo Admin API application has the required permissions (read resource, write resource).

**Duo MFA not working:**
- Ensure all four Duo MFA variables are set: `DUO_CLIENT_ID`, `DUO_CLIENT_SECRET`, `DUO_API_HOST`, `DUO_REDIRECT_URI`.
- Verify the redirect URI matches exactly what is configured in the Duo Admin Panel.
- Check that the Duo Web SDK application health check passes (visible in application startup logs).

**Port binding issues (Linux):**
- If using port 443, ensure the Python binary has the `cap_net_bind_service` capability:
  ```bash
  getcap /opt/duo-bypass/venv/bin/python3
  ```
- Re-apply if needed:
  ```bash
  sudo setcap 'cap_net_bind_service=+ep' $(readlink -f /opt/duo-bypass/venv/bin/python3)
  ```

**IIS site won't start (Windows):**
- Check that HttpPlatformHandler is installed.
- Verify the TLS certificate is in the Local Machine Personal store and has a private key.
- Ensure no other site is using the same port and hostname binding.
- Check that Python is installed system-wide (not per-user) and accessible by `IIS_IUSRS`.
- Review Flask stdout logs: `C:\inetpub\duo-bypass\logs\flask-stdout*.log`
- Check Windows Event Viewer for IIS errors.

**CSRF token errors:**
- Ensure cookies are not being blocked by the browser.
- (Windows) The `WTF_CSRF_SSL_STRICT` setting is disabled to accommodate the IIS reverse proxy architecture. Ensure `ProxyFix` is properly configured.
- If the session expired, the user will need to log in again.

**Static assets not loading (no CSS/images):**
- Verify the `static/` directory exists in the installation directory with the correct structure.
- Check that `style.css`, `logo.png`, `banner.jpg`, and `favicon.png` are present.
- (Windows) Ensure `IIS_IUSRS` has read access to the `static/` directory.