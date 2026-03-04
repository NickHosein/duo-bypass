#Requires -RunAsAdministrator
#
# This project is an independent open-source initiative and is not affiliated with, endorsed by, or supported by Cisco Systems, Inc. or Duo Security.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# ================================================================
# Duo Bypass Code Generator - Windows Uninstall Script
# Removes IIS site, application pool, scheduled tasks, firewall
# rules, and application files installed by the installer.
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

function Prompt-YesNo {
    param(
        [string]$PromptText,
        [string]$Default = "y"
    )

    $result = Read-Host -Prompt "$PromptText [$Default]"
    if ([string]::IsNullOrWhiteSpace($result)) { $result = $Default }

    return ($result -match "^[Yy]")
}

# ====================================
# Banner
# ====================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor White
Write-Host "  Duo Bypass Code Generator - Windows Uninstaller" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor White
Write-Host ""

# ====================================
# Pre-flight Checks
# ====================================
Write-Info "Running pre-flight checks..."

$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Err "This script must be run as Administrator."
}

try {
    Import-Module WebAdministration -ErrorAction Stop
    Write-Info "WebAdministration module loaded."
} catch {
    Write-Warn "WebAdministration module not available. IIS components will be skipped."
}

Write-Success "Pre-flight checks passed."

# ====================================
# Defaults (match the installer)
# ====================================
$DEFAULT_INSTALL_DIR = "C:\inetpub\duo-bypass"
$DEFAULT_LOG_DIR     = "C:\inetpub\duo-bypass\logs"
$DEFAULT_IIS_SITE    = "DuoBypass"
$DEFAULT_APP_POOL    = "DuoBypassPool"

# ====================================
# Gather Configuration
# ====================================
Write-Host ""
Write-Info "Please confirm the installation settings to remove."
Write-Info "Press Enter to accept the defaults if they match your installation."
Write-Host ""

$INSTALL_DIR = Read-Host -Prompt "Installation directory [$DEFAULT_INSTALL_DIR]"
if ([string]::IsNullOrWhiteSpace($INSTALL_DIR)) { $INSTALL_DIR = $DEFAULT_INSTALL_DIR }

$LOG_DIR = Read-Host -Prompt "Log directory [$DEFAULT_LOG_DIR]"
if ([string]::IsNullOrWhiteSpace($LOG_DIR)) { $LOG_DIR = $DEFAULT_LOG_DIR }

$IIS_SITE = Read-Host -Prompt "IIS Site name [$DEFAULT_IIS_SITE]"
if ([string]::IsNullOrWhiteSpace($IIS_SITE)) { $IIS_SITE = $DEFAULT_IIS_SITE }

$APP_POOL = Read-Host -Prompt "IIS Application Pool name [$DEFAULT_APP_POOL]"
if ([string]::IsNullOrWhiteSpace($APP_POOL)) { $APP_POOL = $DEFAULT_APP_POOL }

# ====================================
# Detect Installed Components
# ====================================
Write-Host ""
Write-Info "Detecting installed components..."

$componentsFound = @()

# IIS Site
$siteExists = $false
try {
    $site = Get-Website -Name $IIS_SITE -ErrorAction SilentlyContinue
    if ($site) {
        $siteExists = $true
        $componentsFound += "IIS Site: $($IIS_SITE) (State: $($site.State))"

        # Detect listen port from bindings
        $bindings = @(Get-WebBinding -Name $IIS_SITE -ErrorAction SilentlyContinue)
        foreach ($b in $bindings) {
            $componentsFound += "  Binding: $($b.protocol) $($b.bindingInformation)"
        }
    }
} catch { }

# Application Pool
$poolExists = $false
try {
    if (Test-Path "IIS:\AppPools\$APP_POOL") {
        $poolExists = $true
        $componentsFound += "IIS Application Pool: $($APP_POOL)"
    }
} catch { }

# Installation directory
$installDirExists = Test-Path $INSTALL_DIR
if ($installDirExists) {
    $fileCount = @(Get-ChildItem -Path $INSTALL_DIR -Recurse -File -ErrorAction SilentlyContinue).Count
    $dirSize = "{0:N2} MB" -f ((Get-ChildItem -Path $INSTALL_DIR -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum / 1MB)
    $componentsFound += "Install directory: $($INSTALL_DIR) ($fileCount files, $dirSize)"
}

# Log directory (if different from install directory)
$logDirExists = Test-Path $LOG_DIR
if ($logDirExists -and $LOG_DIR -ne (Join-Path $INSTALL_DIR "logs")) {
    $logCount = @(Get-ChildItem -Path $LOG_DIR -Recurse -File -ErrorAction SilentlyContinue).Count
    $componentsFound += "Log directory: $($LOG_DIR) ($logCount files)"
}

# Scheduled task
$taskExists = $false
$taskName = "DuoBypass-LogRotation"
try {
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        $taskExists = $true
        $componentsFound += "Scheduled Task: $($taskName) (State: $($task.State))"
    }
} catch { }

# Firewall rules
$firewallRules = @()
try {
    $rules = @(Get-NetFirewallRule -DisplayName "Duo Bypass*" -ErrorAction SilentlyContinue)
    foreach ($rule in $rules) {
        $firewallRules += $rule
        $componentsFound += "Firewall Rule: $($rule.DisplayName)"
    }
} catch { }

# Environment variables
$envVarsToCheck = @("KRB5_CONFIG")
$envVarsFound = @()
foreach ($varName in $envVarsToCheck) {
    $val = [Environment]::GetEnvironmentVariable($varName, "Machine")
    if ($val) {
        $envVarsFound += $varName
        $componentsFound += "Environment Variable: $($varName) = $($val)"
    }
}

# ====================================
# Display Summary
# ====================================
Write-Host ""
if ($componentsFound.Count -eq 0) {
    Write-Warn "No Duo Bypass Code Generator components were detected."
    Write-Warn "Nothing to uninstall."
    exit 0
}

Write-Host "================================================================" -ForegroundColor White
Write-Host "  Components Found" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor White
Write-Host ""
foreach ($component in $componentsFound) {
    Write-Host "  $component"
}
Write-Host ""

Write-Host "================================================================" -ForegroundColor Red
Write-Host "  WARNING: This action is irreversible!" -ForegroundColor Red
Write-Host "================================================================" -ForegroundColor Red
Write-Host ""
Write-Warn "This will permanently remove all listed components."
Write-Warn "Ensure you have backed up any data you need before proceeding."
Write-Host ""

if (-not (Prompt-YesNo "Are you sure you want to uninstall?" "n")) {
    Write-Info "Uninstall cancelled."
    exit 0
}

Write-Host ""

# ====================================
# Stop IIS Site
# ====================================
if ($siteExists) {
    Write-Info "Stopping IIS site '$($IIS_SITE)'..."
    try {
        $siteState = (Get-Website -Name $IIS_SITE).State
        if ($siteState -eq "Started") {
            Stop-Website -Name $IIS_SITE -ErrorAction Stop
            Start-Sleep -Seconds 2
            Write-Success "IIS site stopped."
        } else {
            Write-Info "IIS site was already stopped."
        }
    } catch {
        Write-Warn "Could not stop IIS site: $_"
    }
}

# ====================================
# Stop Application Pool
# ====================================
if ($poolExists) {
    Write-Info "Stopping Application Pool '$($APP_POOL)'..."
    try {
        $poolState = (Get-Item "IIS:\AppPools\$APP_POOL").State
        if ($poolState -eq "Started") {
            Stop-WebAppPool -Name $APP_POOL -ErrorAction Stop
            Start-Sleep -Seconds 2
            Write-Success "Application Pool stopped."
        } else {
            Write-Info "Application Pool was already stopped."
        }
    } catch {
        Write-Warn "Could not stop Application Pool: $_"
    }
}

# ====================================
# Remove IIS Site
# ====================================
if ($siteExists) {
    Write-Info "Removing IIS site '$($IIS_SITE)'..."
    try {
        Remove-Website -Name $IIS_SITE -ErrorAction Stop
        Write-Success "IIS site removed."
    } catch {
        Write-Warn "Could not remove IIS site: $_"
    }
}

# ====================================
# Remove Application Pool
# ====================================
if ($poolExists) {
    Write-Info "Removing Application Pool '$($APP_POOL)'..."
    try {
        Remove-WebAppPool -Name $APP_POOL -ErrorAction Stop
        Write-Success "Application Pool removed."
    } catch {
        Write-Warn "Could not remove Application Pool: $_"
    }
}

# ====================================
# Remove Scheduled Task
# ====================================
if ($taskExists) {
    Write-Info "Removing scheduled task '$($taskName)'..."
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Write-Success "Scheduled task removed."
    } catch {
        Write-Warn "Could not remove scheduled task: $_"
    }
}

# ====================================
# Remove Firewall Rules
# ====================================
if ($firewallRules.Count -gt 0) {
    Write-Info "Removing firewall rules..."
    foreach ($rule in $firewallRules) {
        try {
            Remove-NetFirewallRule -DisplayName $rule.DisplayName -ErrorAction Stop
            Write-Success "Removed firewall rule: $($rule.DisplayName)"
        } catch {
            Write-Warn "Could not remove firewall rule '$($rule.DisplayName)': $_"
        }
    }
}

# ====================================
# Remove Environment Variables
# ====================================
if ($envVarsFound.Count -gt 0) {
    Write-Info "Removing system environment variables..."
    foreach ($varName in $envVarsFound) {
        try {
            [Environment]::SetEnvironmentVariable($varName, $null, "Machine")
            Write-Success "Removed environment variable: $($varName)"
        } catch {
            Write-Warn "Could not remove environment variable '$($varName)': $_"
        }
    }
}

# ====================================
# Remove Proxy Environment Variables
# ====================================
Write-Host ""
$proxyVars = @("HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY")
$proxyVarsSet = @()

foreach ($varName in $proxyVars) {
    $val = [Environment]::GetEnvironmentVariable($varName, "Machine")
    if ($val) {
        $proxyVarsSet += $varName
    }
}

if ($proxyVarsSet.Count -gt 0) {
    Write-Warn "The following proxy environment variables are set at the system level:"
    foreach ($varName in $proxyVarsSet) {
        $val = [Environment]::GetEnvironmentVariable($varName, "Machine")
        Write-Host "  $($varName) = $($val)"
    }
    Write-Host ""
    Write-Warn "These may be used by other applications on this server."

    if (Prompt-YesNo "Remove these proxy environment variables?" "n") {
        foreach ($varName in $proxyVarsSet) {
            try {
                [Environment]::SetEnvironmentVariable($varName, $null, "Machine")
                Write-Success "Removed environment variable: $($varName)"
            } catch {
                Write-Warn "Could not remove environment variable '$($varName)': $_"
            }
        }
    } else {
        Write-Info "Proxy environment variables left in place."
    }
}

# ====================================
# Remove Application Files
# ====================================
if ($installDirExists) {
    Write-Host ""
    Write-Info "Removing application files..."

    # Check if log directory is inside install directory
    $logInsideInstall = $LOG_DIR.StartsWith($INSTALL_DIR, [System.StringComparison]::OrdinalIgnoreCase)

    if (-not $logInsideInstall -and $logDirExists) {
        # Log directory is separate - ask about it independently
        if (Prompt-YesNo "Remove log directory '$($LOG_DIR)' and all log files?" "y") {
            try {
                Remove-Item -Path $LOG_DIR -Recurse -Force -ErrorAction Stop
                Write-Success "Log directory removed: $($LOG_DIR)"
            } catch {
                Write-Warn "Could not fully remove log directory: $_"
            }
        } else {
            Write-Info "Log directory preserved: $($LOG_DIR)"
        }
    }

    # Backup .env before deletion (in case user needs credentials)
    $envPath = Join-Path $INSTALL_DIR ".env"
    if (Test-Path $envPath) {
        $backupDir = Join-Path ([System.IO.Path]::GetTempPath()) "duo-bypass-backup"
        if (-not (Test-Path $backupDir)) {
            New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }
        $backupFile = Join-Path $backupDir ".env.backup.$(Get-Date -Format 'yyyyMMddHHmmss')"

        if (Prompt-YesNo "Back up .env file before deletion? (contains API keys)" "y") {
            try {
                Copy-Item -Path $envPath -Destination $backupFile -Force
                Write-Success "Backup saved to: $($backupFile)"
                Write-Warn "Remember to delete this backup after retrieving any needed credentials."
            } catch {
                Write-Warn "Could not back up .env file: $_"
            }
        }
    }

    # Remove the install directory
    Write-Info "Removing installation directory: $($INSTALL_DIR)"
    try {
        Remove-Item -Path $INSTALL_DIR -Recurse -Force -ErrorAction Stop
        Write-Success "Installation directory removed."
    } catch {
        Write-Warn "Could not fully remove installation directory: $_"
        Write-Warn "Some files may be locked. Try again after an IIS reset."
        Write-Warn "  iisreset"
        Write-Warn "  Remove-Item -Path '$($INSTALL_DIR)' -Recurse -Force"
    }
}

# ====================================
# Optional: Re-lock IIS Configuration Sections
# ====================================
Write-Host ""
Write-Info "The installer unlocked the following IIS configuration sections:"
Write-Host "  system.webServer/handlers"
Write-Host "  system.webServer/security/requestFiltering"
Write-Host "  system.webServer/httpProtocol"
Write-Host "  system.webServer/rewrite/rules (if URL Rewrite was installed)"
Write-Host ""
Write-Warn "Re-locking these sections may affect other applications that rely on them."

if (Prompt-YesNo "Re-lock these IIS configuration sections?" "n") {
    $appcmd = Join-Path $env:SystemRoot "System32\inetsrv\appcmd.exe"

    $sectionsToLock = @(
        "system.webServer/handlers",
        "system.webServer/security/requestFiltering",
        "system.webServer/httpProtocol"
    )

    # Check if URL Rewrite is installed before trying to lock its section
    try {
        $rewriteModule = & $appcmd list module 2>$null
        if ($rewriteModule -match "RewriteModule") {
            $sectionsToLock += "system.webServer/rewrite/rules"
        }
    } catch { }

    foreach ($section in $sectionsToLock) {
        try {
            $result = & $appcmd lock config /section:$section 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Success "Locked: $section"
            } else {
                Write-Warn "Could not lock: $section -- $result"
            }
        } catch {
            Write-Warn "Failed to lock section: $section -- $_"
        }
    }
} else {
    Write-Info "IIS configuration sections left unlocked."
}

# ====================================
# Optional: Remove IIS_IUSRS Permissions from Python Directory
# ====================================
Write-Host ""
$pythonCmd = $null
foreach ($cmd in @("python", "python3")) {
    try {
        $ver = & $cmd --version 2>&1
        if ($ver -match "Python 3") {
            $pythonCmd = $cmd
            break
        }
    } catch { }
}

if ($pythonCmd) {
    $pythonPath = (Get-Command $pythonCmd -ErrorAction SilentlyContinue).Source
    if ($pythonPath) {
        $pythonInstallDir = Split-Path -Parent $pythonPath

        Write-Info "The installer granted IIS_IUSRS read/execute access to:"
        Write-Host "  $($pythonInstallDir)"
        Write-Host ""
        Write-Warn "Other IIS applications using Python may need this access."

        if (Prompt-YesNo "Remove IIS_IUSRS permissions from the Python directory?" "n") {
            try {
                $acl = Get-Acl $pythonInstallDir
                $rulesToRemove = @($acl.Access | Where-Object {
                    $_.IdentityReference -match "IIS_IUSRS"
                })

                foreach ($rule in $rulesToRemove) {
                    $acl.RemoveAccessRule($rule) | Out-Null
                }

                Set-Acl -Path $pythonInstallDir -AclObject $acl
                Write-Success "IIS_IUSRS permissions removed from Python directory."
            } catch {
                Write-Warn "Could not remove permissions: $_"
            }
        } else {
            Write-Info "Python directory permissions left in place."
        }
    }
}

# ====================================
# Optional: Remove IIS_IUSRS Permissions from Temp Directory
# ====================================
Write-Host ""
$tempDir = [System.IO.Path]::GetTempPath()
Write-Info "The installer granted IIS_IUSRS write access to the temp directory:"
Write-Host "  $($tempDir)"
Write-Host ""
Write-Warn "Other IIS applications may need this access."

if (Prompt-YesNo "Remove IIS_IUSRS write permissions from the temp directory?" "n") {
    try {
        $acl = Get-Acl $tempDir
        $rulesToRemove = @($acl.Access | Where-Object {
            $_.IdentityReference -match "IIS_IUSRS" -and $_.FileSystemRights -match "Modify"
        })

        foreach ($rule in $rulesToRemove) {
            $acl.RemoveAccessRule($rule) | Out-Null
        }

        Set-Acl -Path $tempDir -AclObject $acl
        Write-Success "IIS_IUSRS write permissions removed from temp directory."
    } catch {
        Write-Warn "Could not remove permissions: $_"
    }
} else {
    Write-Info "Temp directory permissions left in place."
}

# ====================================
# Summary
# ====================================
Write-Host ""
Write-Host "================================================================" -ForegroundColor White
Write-Host "  Uninstall Complete" -ForegroundColor White
Write-Host "================================================================" -ForegroundColor White
Write-Host ""
Write-Host "  Removed components:"

if ($siteExists)    { Write-Host "    [x] IIS Site: $($IIS_SITE)" -ForegroundColor Green }
if ($poolExists)    { Write-Host "    [x] Application Pool: $($APP_POOL)" -ForegroundColor Green }
if ($taskExists)    { Write-Host "    [x] Scheduled Task: $($taskName)" -ForegroundColor Green }

if ($firewallRules.Count -gt 0) {
    foreach ($rule in $firewallRules) {
        Write-Host "    [x] Firewall Rule: $($rule.DisplayName)" -ForegroundColor Green
    }
}

if ($envVarsFound.Count -gt 0) {
    foreach ($varName in $envVarsFound) {
        Write-Host "    [x] Environment Variable: $($varName)" -ForegroundColor Green
    }
}

if ($installDirExists -and -not (Test-Path $INSTALL_DIR)) {
    Write-Host "    [x] Installation directory: $($INSTALL_DIR)" -ForegroundColor Green
} elseif ($installDirExists) {
    Write-Host "    [!] Installation directory may still exist: $($INSTALL_DIR)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Not removed (may be shared with other applications):"
Write-Host "    [ ] Python installation"
Write-Host "    [ ] MIT Kerberos for Windows (if installed)"
Write-Host "    [ ] IIS (Web Server role)"
Write-Host "    [ ] HttpPlatformHandler module"
Write-Host "    [ ] URL Rewrite module"
Write-Host ""

# Check if backup was created
if ($backupFile -and (Test-Path $backupFile)) {
    Write-Warn "  .env backup location: $($backupFile)"
    Write-Warn "  Delete this file after retrieving any needed API credentials."
    Write-Host ""
}

Write-Host "  If you need to perform a full IIS reset:"
Write-Host "    iisreset"
Write-Host ""

Write-Success "Done."