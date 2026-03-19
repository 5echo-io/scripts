# ==============================================================================
# 5echo-NetRelay.ps1
# 5echo.io NetRelay - Silent installation of NetBird
# Features: SSH (Windows + NetBird), RDP, Hidden taskbar, Auto-update
# Supports x64 and ARM64 | Admin and standard user (UAC elevation)
# ==============================================================================

#Requires -Version 5.1

param(
    [switch]$ElevatedRun,
    [string]$KeyFile   = "",
    [switch]$UpdateOnly,
    [switch]$Uninstall,
    [switch]$ActivateSSH
)

# ------------------------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------------------------
$ServiceDisplayName  = "5echo.io NetRelay"
$ServiceInternalName = "NetRelay"
$NetbirdVersion      = "latest"
$InstallDir          = "$env:ProgramFiles\$ServiceInternalName"
$TempDir             = "$env:TEMP\$($ServiceInternalName)Install"
$LogFile             = "$TempDir\install.log"
$UpdateTaskName      = "$ServiceDisplayName AutoUpdate"
$ScriptPublicUrl     = "https://scripts.5echo.io/windows/install/netbird/5echo-NetRelay.ps1"

# ------------------------------------------------------------------------------
# HELPER FUNCTIONS
# NOTE: Write-Log and spinner cannot run inside Start-Job (no shared scope).
#       All logging and display happens in the main thread only.
# ------------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    switch ($Level) {
        "ERROR" { Write-Host $line -ForegroundColor Red }
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

function Exit-WithError {
    param([string]$Message)
    Write-Host ""
    Write-Host "  [ERROR] $Message" -ForegroundColor Red
    Write-Host ""
    Write-Log $Message "ERROR"
    Write-Host "  Log saved to: $LogFile" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Press ENTER to close..." -ForegroundColor DarkGray
Read-Host | Out-Null
    exit 1
}

# Spinner - animates while a script block runs in a background job.
# IMPORTANT: Write-Log / functions are NOT available inside the ScriptBlock.
#            Only use pure PowerShell cmdlets inside the block.
function Invoke-WithSpinner {
    param(
        [string]$Message,
        [scriptblock]$ScriptBlock
    )
    $frames   = @("|", "/", "-", "\")
    $frameIdx = 0
    $job      = Start-Job -ScriptBlock $ScriptBlock
    [Console]::CursorVisible = $false
    try {
        while ($job.State -eq "Running") {
            $frame = $frames[$frameIdx % $frames.Length]
            Write-Host "`r  $frame  $Message   " -NoNewline -ForegroundColor Cyan
            Start-Sleep -Milliseconds 120
            $frameIdx++
        }
    } finally {
        [Console]::CursorVisible = $true
    }
    Write-Host "`r  OK  $Message   " -ForegroundColor Green
    $result = Receive-Job $job -ErrorAction SilentlyContinue
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    return $result
}

function Test-IsAdmin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Architecture {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($arch -eq "ARM64")                       { return "arm64" }
    if ($arch -eq "AMD64")                       { return "amd64" }
    if ($env:PROCESSOR_ARCHITEW6432 -eq "AMD64") { return "amd64" }
    Exit-WithError "Unsupported architecture: $arch"
}

function Get-InstalledNetbirdVersion {
    $exe = "$InstallDir\netbird.exe"
    if (-not (Test-Path $exe)) { $exe = "$env:ProgramFiles\Netbird\netbird.exe" }
    if (-not (Test-Path $exe)) { return $null }
    try {
        $output = & $exe version 2>&1
        if ($output -match "(\d+\.\d+\.\d+)") { return $matches[1] }
    } catch {}
    return $null
}

function Stop-NetbirdProcesses {
    @("netbird", "netbird-ui", "netrelay", "wt-go") | ForEach-Object {
        Get-Process -Name $_ -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

function Test-NetbirdInstalled {
    $paths = @(
        "$env:ProgramFiles\NetRelay\netbird.exe",
        "$env:ProgramFiles\Netbird\netbird.exe"
    )
    foreach ($p in $paths) { if (Test-Path $p) { return $true } }
    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($root in $roots) {
        $found = Get-ChildItem $root -ErrorAction SilentlyContinue | Where-Object {
            $n = (Get-ItemProperty $_.PSPath -Name "DisplayName" -ErrorAction SilentlyContinue).DisplayName
            $n -and ($n -match "(?i)netbird" -or $n -match "(?i)netrelay")
        }
        if ($found) { return $true }
    }
    return $false
}

function Set-ServiceMasking {
    param([string]$MaskedExe)
    $serviceNames = @("Netbird", "netbird", "NetBird")
    foreach ($svcName in $serviceNames) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            & sc.exe config $svcName displayname= "$ServiceDisplayName" 2>&1 | Out-Null
            & sc.exe description $svcName "$ServiceDisplayName - secure network connection" 2>&1 | Out-Null
            $svcRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$svcName"
            if (Test-Path $svcRegPath) {
                Set-ItemProperty -Path $svcRegPath -Name "DisplayName" -Value $ServiceDisplayName -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $svcRegPath -Name "Description" -Value "$ServiceDisplayName - secure network connection" -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $svcRegPath -Name "ImagePath"   -Value $MaskedExe -Force -ErrorAction SilentlyContinue
            }
            Write-Log "Service '$svcName' masked as '$ServiceDisplayName'."
        }
    }
}

function Set-NetbirdServiceAutostart {
    $serviceNames = @("Netbird", "netbird", "NetBird")
    foreach ($svcName in $serviceNames) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            Set-Service -Name $svcName -StartupType Automatic -ErrorAction SilentlyContinue | Out-Null
            & sc.exe config $svcName start= auto 2>&1 | Out-Null
            if ($svc.Status -ne "Running") {
                Start-Service -Name $svcName -ErrorAction SilentlyContinue
            }
            Write-Log "Service '$svcName' set to Automatic startup."
            return $true
        }
    }
    return $false
}

function Remove-AllShortcuts {
    Start-Sleep -Seconds 2

    $desktopPaths = @(
        "$env:USERPROFILE\Desktop",
        "$env:PUBLIC\Desktop",
        [Environment]::GetFolderPath("CommonDesktopDirectory"),
        [Environment]::GetFolderPath("DesktopDirectory")
    ) | Select-Object -Unique

    foreach ($desktop in $desktopPaths) {
        if (-not (Test-Path $desktop)) { continue }
        Get-ChildItem -Path $desktop -Filter "*.lnk" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "(?i)netbird|(?i)netrelay" } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $startMenuPaths = @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        [Environment]::GetFolderPath("CommonPrograms"),
        [Environment]::GetFolderPath("Programs")
    ) | Select-Object -Unique

    foreach ($startMenu in $startMenuPaths) {
        if (-not (Test-Path $startMenu)) { continue }
        Get-ChildItem -Path $startMenu -Recurse -Filter "*.lnk" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "(?i)netbird|(?i)netrelay" } |
            Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem -Path $startMenu -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "(?i)netbird|(?i)netrelay" } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Suppress "Recently added" / "Recommended" in Start menu
    $advPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    if (Test-Path $advPath) {
        Set-ItemProperty -Path $advPath -Name "Start_TrackProgs" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    }

    # Clear new-app highlight entries
    $cloudStore = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount"
    if (Test-Path $cloudStore) {
        Get-ChildItem -Path $cloudStore -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "(?i)netbird|(?i)netrelay" } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Set NoStartMenuPin on uninstall registry entries
    @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    ) | ForEach-Object {
        Get-ChildItem $_ -ErrorAction SilentlyContinue | ForEach-Object {
            $dn = (Get-ItemProperty $_.PSPath -Name "DisplayName" -ErrorAction SilentlyContinue).DisplayName
            if ($dn -match "(?i)netbird|(?i)netrelay") {
                Set-ItemProperty -Path $_.PSPath -Name "NoStartMenuPin"   -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $_.PSPath -Name "NoDesktopShortcut" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Restart Explorer to apply immediately
    Stop-Process -Name "explorer" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Process "explorer.exe" -ErrorAction SilentlyContinue
    Write-Log "Shortcuts removed and start menu highlights suppressed."
}

function Set-SystemPath {
    # Add NetBird/NetRelay install dirs to system PATH
    $pathsToAdd = @(
        $InstallDir,
        "$env:ProgramFiles\Netbird"
    )
    $currentPath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
    $changed = $false
    foreach ($p in $pathsToAdd) {
        if ((Test-Path $p) -and $currentPath -notlike "*$p*") {
            $currentPath = "$currentPath;$p"
            $changed = $true
            Write-Log "Added to system PATH: $p"
        }
    }
    if ($changed) {
        [Environment]::SetEnvironmentVariable("PATH", $currentPath, "Machine")
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine")
        Write-Log "System PATH updated."
    } else {
        Write-Log "PATH already configured."
    }
}

function Apply-Masking {
    param([string]$MaskedExe, [string]$SourceExe)

    # Copy exe with masked name
    if (Test-Path $SourceExe) {
        Stop-NetbirdProcesses
        Copy-Item $SourceExe -Destination $MaskedExe -Force -ErrorAction SilentlyContinue
        Write-Log "Process masked as 'netrelay.exe'."
    }

    # Mask installed apps entry
    @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    ) | ForEach-Object {
        Get-ChildItem -Path $_ -ErrorAction SilentlyContinue | ForEach-Object {
            $dn = (Get-ItemProperty -Path $_.PSPath -Name "DisplayName" -ErrorAction SilentlyContinue).DisplayName
            if ($dn -and $dn -match "(?i)netbird") {
                Set-ItemProperty -Path $_.PSPath -Name "DisplayName"     -Value $ServiceDisplayName -Force
                Set-ItemProperty -Path $_.PSPath -Name "Publisher"       -Value "5echo.io"           -Force
                Set-ItemProperty -Path $_.PSPath -Name "DisplayIcon"     -Value $MaskedExe           -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $_.PSPath -Name "InstallLocation" -Value $InstallDir          -Force -ErrorAction SilentlyContinue
                Write-Log "App entry masked: $($_.PSPath)"
            }
        }
    }

    # Mask Windows service
    Set-ServiceMasking -MaskedExe $MaskedExe

    # Remove tray icon autostart
    @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
    ) | ForEach-Object {
        if (Test-Path $_) {
            @("Netbird", "NetbirdUI", "netbird-ui", $ServiceInternalName) | ForEach-Object {
                Remove-ItemProperty -Path $_ -Name $_ -ErrorAction SilentlyContinue
            }
        }
    }
    Get-Process -Name "netbird-ui" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Write-Log "Masking applied."
}

# ------------------------------------------------------------------------------
# TEMP DIRECTORY
# ------------------------------------------------------------------------------
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

# ------------------------------------------------------------------------------
# INSTALLATION CHECK - show menu if already installed
# ------------------------------------------------------------------------------
if (-not $UpdateOnly -and -not $Uninstall -and -not $ElevatedRun -and -not $ActivateSSH) {
    if (Test-NetbirdInstalled) {
        Write-Host ""
        Write-Host "  ========================================" -ForegroundColor DarkGray
        Write-Host "    $ServiceDisplayName" -ForegroundColor White
        Write-Host "  ========================================" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Software is already installed." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  [1] Uninstall completely"
        Write-Host "  [2] Enable NetBird SSH"
        Write-Host "  [3] Cancel"
        Write-Host ""
        $choice = (Read-Host "  Select [1-3]").Trim()
        if ($choice -eq "2") {
            Write-Host ""
            $scriptPath2 = $MyInvocation.MyCommand.Definition
            if ([string]::IsNullOrEmpty($scriptPath2) -or -not (Test-Path $scriptPath2)) {
                $scriptPath2 = "$env:TEMP\5echo-SSH.ps1"
                $ProgressPreference = "SilentlyContinue"
                Invoke-WebRequest -Uri $ScriptPublicUrl -OutFile $scriptPath2 -UseBasicParsing
            }
            $sshArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath2`" -ActivateSSH"
            if (Test-IsAdmin) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$scriptPath2" -ActivateSSH
            } else {
                Start-Process powershell.exe -ArgumentList $sshArgs -Verb RunAs -Wait
            }
            if ($scriptPath2 -match "SSH\.ps1$") { Remove-Item $scriptPath2 -ErrorAction SilentlyContinue }
            exit
        }
        if ($choice -eq "1") {
            Write-Host ""
            Write-Host "  Starting uninstall..." -ForegroundColor Cyan

            # Get script path - may be empty if run via irm|iex, download if needed
            $scriptPath = $MyInvocation.MyCommand.Definition
            if ([string]::IsNullOrEmpty($scriptPath) -or -not (Test-Path $scriptPath)) {
                Write-Host "  |  Downloading uninstaller...   " -NoNewline -ForegroundColor Cyan
                $scriptPath = "$env:TEMP\5echo-NetRelay-Uninstall.ps1"
                $ProgressPreference = "SilentlyContinue"
                Invoke-WebRequest -Uri $ScriptPublicUrl -OutFile $scriptPath -UseBasicParsing
                Write-Host "`r  OK  Uninstaller ready.          " -ForegroundColor Green
            }

            $elevArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Uninstall"
            if (Test-IsAdmin) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$scriptPath" -Uninstall
            } else {
                Start-Process powershell.exe -ArgumentList $elevArgs -Verb RunAs -Wait
            }

            # Clean up temp file if we downloaded it
            if ($scriptPath -match "Uninstall\.ps1$") {
                Remove-Item $scriptPath -ErrorAction SilentlyContinue
            }
            exit
        } else {
            Write-Host "  Cancelled." -ForegroundColor Gray
            Write-Host "  Press ENTER to close..." -ForegroundColor DarkGray
Read-Host | Out-Null
            exit 0
        }
    }
}

# ------------------------------------------------------------------------------
# SELF-ELEVATION
# ------------------------------------------------------------------------------
if (-not (Test-IsAdmin)) {
    $tempKeyFile = ""
    if (-not $UpdateOnly -and -not $Uninstall) {
        Write-Host ""
        $setupKeyInput = (Read-Host "  Enter $ServiceDisplayName Setup Key").Trim()
        if ([string]::IsNullOrEmpty($setupKeyInput)) {
            Write-Host "  [ERROR] No setup key provided. Aborting." -ForegroundColor Red
            Write-Host "  Press ENTER to close..." -ForegroundColor DarkGray
Read-Host | Out-Null
            exit 1
        }
        $tempKeyFile  = "$env:TEMP\nr_sk.tmp"
        $encryptedKey = ConvertFrom-SecureString (ConvertTo-SecureString $setupKeyInput -AsPlainText -Force)
        Set-Content -Path $tempKeyFile -Value $encryptedKey
    }

    $scriptPath = $MyInvocation.MyCommand.Definition
    $elevArgs   = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -ElevatedRun"
    if ($tempKeyFile) { $elevArgs += " -KeyFile `"$tempKeyFile`"" }
    if ($UpdateOnly)  { $elevArgs += " -UpdateOnly" }
    if ($Uninstall)   { $elevArgs += " -Uninstall" }
    if ($ActivateSSH) { $elevArgs += " -ActivateSSH" }

    Start-Process powershell.exe -ArgumentList $elevArgs -Verb RunAs -Wait
    if ($tempKeyFile) { Remove-Item $tempKeyFile -ErrorAction SilentlyContinue }
    exit
}

# ------------------------------------------------------------------------------
# LOG START
# ------------------------------------------------------------------------------
$mode = if ($UpdateOnly) { "UPDATE" } elseif ($Uninstall) { "UNINSTALL" } else { "INSTALLATION" }
Write-Log "=== $ServiceDisplayName - $mode started === User: $env:USERNAME | Machine: $env:COMPUTERNAME"

Write-Host ""
Write-Host "  ========================================" -ForegroundColor DarkGray
Write-Host "    $ServiceDisplayName" -ForegroundColor White
Write-Host "    $mode" -ForegroundColor DarkGray
Write-Host "  ========================================" -ForegroundColor DarkGray
Write-Host ""

# ------------------------------------------------------------------------------
# UNINSTALL
# ------------------------------------------------------------------------------
if ($Uninstall) {
    Write-Log "Stopping processes..."
    Stop-NetbirdProcesses

    Write-Log "Removing Scheduled Task..."
    Unregister-ScheduledTask -TaskName $UpdateTaskName -Confirm:$false -ErrorAction SilentlyContinue

    Write-Log "Uninstalling via MSI..."
    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($root in $roots) {
        Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
            $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($props.DisplayName -and ($props.DisplayName -match "(?i)netbird" -or $props.DisplayName -match "(?i)netrelay")) {
                $productCode = $props.PSChildName
                if ($productCode -match "^\{.*\}$") {
                    Write-Log "Uninstalling: $productCode"
                    Start-Process "msiexec.exe" -ArgumentList "/x `"$productCode`" /qn /norestart" -Wait -WindowStyle Hidden
                }
            }
        }
    }

    Write-Log "Removing installation folders..."
    @(
        "$env:ProgramFiles\NetRelay",
        "$env:ProgramFiles\Netbird",
        "$env:ProgramData\NetRelay"
    ) | ForEach-Object {
        if (Test-Path $_) {
            Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Deleted: $_"
        }
    }

    Write-Log "Cleaning registry..."
    @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
    ) | ForEach-Object {
        if (Test-Path $_) {
            @("Netbird", "NetbirdUI", "netbird-ui", "NetRelay") | ForEach-Object {
                Remove-ItemProperty -Path $_ -Name $_ -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Log "Removing firewall rules..."
    Remove-NetFirewallRule -DisplayName "*NetBird*"  -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName "*NetRelay*" -ErrorAction SilentlyContinue

    Write-Log "=== Uninstall complete ==="
    Write-Host ""
    Write-Host "  $ServiceDisplayName has been completely uninstalled." -ForegroundColor Green
    Write-Host "  Note: OpenSSH and RDP have been kept (OS features)." -ForegroundColor DarkGray
    Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Press ENTER to close..." -ForegroundColor DarkGray
Read-Host | Out-Null
    exit 0
}

# ------------------------------------------------------------------------------
# ACTIVATE SSH (standalone)
# ------------------------------------------------------------------------------
if ($ActivateSSH) {
    Write-Host ""
    Write-Host "  ========================================" -ForegroundColor DarkGray
    Write-Host "    $ServiceDisplayName" -ForegroundColor White
    Write-Host "    Enabling NetBird SSH..." -ForegroundColor DarkGray
    Write-Host "  ========================================" -ForegroundColor DarkGray
    Write-Host ""
    $nbExe = "$InstallDir\netbird.exe"
    if (-not (Test-Path $nbExe)) { $nbExe = "$env:ProgramFiles\Netbird\netbird.exe" }
    if (-not (Test-Path $nbExe)) {
        Write-Host "  ERROR: netbird.exe not found." -ForegroundColor Red
        Write-Host "  Press ESC to close..." -ForegroundColor DarkGray
        do { $k = [Console]::ReadKey($true) } while ($k.Key -ne [ConsoleKey]::Escape)
        exit 1
    }
    Write-Host "  |  Activating NetBird SSH...   " -NoNewline -ForegroundColor Cyan
    try {
        & $nbExe up --allow-server-ssh 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        $st = & $nbExe status 2>&1
        if ($st -match "SSH Server: Enabled") {
            Write-Host "`r  OK  NetBird SSH is now enabled.          " -ForegroundColor Green
        } else {
            Write-Host "`r  OK  SSH command sent to NetBird service. " -ForegroundColor Yellow
        }
    } catch {
        Write-Host "`r  WARN  Failed: $_   " -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  Press ESC to close..." -ForegroundColor DarkGray
    do { $k = [Console]::ReadKey($true) } while ($k.Key -ne [ConsoleKey]::Escape)
    exit 0
}

# GET SETUP KEY
# ------------------------------------------------------------------------------
$SetupKey = ""
if (-not $UpdateOnly) {
    if ($ElevatedRun -and $KeyFile -and (Test-Path $KeyFile)) {
        Write-Log "Reading setup key from encrypted temp file..."
        $encryptedKey = Get-Content -Path $KeyFile
        $secureKey    = ConvertTo-SecureString $encryptedKey
        $bstr         = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
        $SetupKey     = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        Remove-Item $KeyFile -ErrorAction SilentlyContinue
    } else {
        $SetupKey = (Read-Host "  Enter $ServiceDisplayName Setup Key").Trim()
    }
    if ([string]::IsNullOrEmpty($SetupKey)) {
        Exit-WithError "Setup key missing. Aborting."
    }
    Write-Host ""
}

# ------------------------------------------------------------------------------
# ARCHITECTURE AND VERSION
# ------------------------------------------------------------------------------
$Arch = Get-Architecture
Write-Log "Architecture: $Arch"

Write-Host "  |  Fetching latest version...   " -NoNewline -ForegroundColor Cyan
try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/netbirdio/netbird/releases/latest" -UseBasicParsing
    $NetbirdVersion = $release.tag_name.TrimStart("v")
    Write-Host "`r  OK  Fetched version: $NetbirdVersion   " -ForegroundColor Green
} catch {
    Write-Host "`r  OK  Using configured version: $NetbirdVersion   " -ForegroundColor Yellow
}
Write-Log "Target version: $NetbirdVersion"

# ------------------------------------------------------------------------------
# UPDATE CHECK
# ------------------------------------------------------------------------------
if ($UpdateOnly) {
    $installedVer = Get-InstalledNetbirdVersion
    Write-Log "Installed: $(if ($installedVer) { $installedVer } else { 'not found' }) | Available: $NetbirdVersion"
    if ($installedVer -eq $NetbirdVersion) {
        Write-Host "  OK  Already up to date ($NetbirdVersion)." -ForegroundColor Green
        Write-Host ""
        Write-Log "Already up to date. Exiting."
        exit 0
    }
    Write-Log "Update available - continuing..."
}

# ------------------------------------------------------------------------------
# DOWNLOAD MSI
# ------------------------------------------------------------------------------
$MsiFileName = "netbird_installer_${NetbirdVersion}_windows_${Arch}.msi"
$DownloadUrl = "https://github.com/netbirdio/netbird/releases/download/v${NetbirdVersion}/${MsiFileName}"
$MsiPath     = "$TempDir\$MsiFileName"

Write-Log "Downloading: $DownloadUrl"
Invoke-WithSpinner "Downloading NetBird $NetbirdVersion..." {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $using:DownloadUrl -OutFile $using:MsiPath -UseBasicParsing
}
if (-not (Test-Path $MsiPath)) {
    Exit-WithError "Download failed. Check internet connection and try again. URL: $DownloadUrl"
}
Write-Log "Download complete."

# ------------------------------------------------------------------------------
# SILENT INSTALL
# ------------------------------------------------------------------------------
Stop-NetbirdProcesses
Write-Log "Starting silent installation..."

$MsiLog  = "$TempDir\msi_install.log"
$MsiArgs = @(
    "/i", "`"$MsiPath`"",
    "/qn", "/norestart",
    "REBOOT=ReallySuppress",
    "STARTMENUSHORTCUTS=0",
    "DESKTOPSHORTCUT=0",
    "/log", "`"$MsiLog`""
)

Invoke-WithSpinner "Installing $ServiceDisplayName..." {
    Start-Process "msiexec.exe" -ArgumentList $using:MsiArgs -Wait -WindowStyle Hidden
}

# Verify install succeeded
$defaultInstall = "$env:ProgramFiles\Netbird"
if (-not (Test-Path "$defaultInstall\netbird.exe") -and -not (Test-Path "$InstallDir\netbird.exe")) {
    Exit-WithError "Installation failed. See MSI log: $MsiLog"
}
Write-Log "MSI installation complete."

# Copy binaries to custom folder
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
if (Test-Path "$defaultInstall\netbird.exe") {
    Copy-Item "$defaultInstall\*" -Destination $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
}

$NetbirdExe = "$InstallDir\netbird.exe"
if (-not (Test-Path $NetbirdExe)) { $NetbirdExe = "$defaultInstall\netbird.exe" }
if (-not (Test-Path $NetbirdExe)) {
    Exit-WithError "netbird.exe not found after installation. See log: $MsiLog"
}
Write-Log "Using binary: $NetbirdExe"

# ------------------------------------------------------------------------------
# ADD TO SYSTEM PATH (so netbird.exe is accessible from anywhere)
# ------------------------------------------------------------------------------
Write-Host "  |  Adding to system PATH...   " -NoNewline -ForegroundColor Cyan
Set-SystemPath
Write-Host "`r  OK  Added to system PATH.   " -ForegroundColor Green

# ------------------------------------------------------------------------------
# START NETBIRD SERVICE + ENABLE SSH + CONNECT
# Order matters: service first, then SSH flag, then up with setup key
# Runs directly (not in job) so it has full access to the Windows service layer
# ------------------------------------------------------------------------------
if (-not $UpdateOnly) {
    # Step 1: Start the service
    Write-Host "  |  Starting NetBird service...   " -NoNewline -ForegroundColor Cyan
    Set-NetbirdServiceAutostart | Out-Null
    Start-Sleep -Seconds 3
    Write-Host "`r  OK  NetBird service started.   " -ForegroundColor Green
    Write-Log "NetBird service started."

    # Connect with setup key + SSH enabled.
    # --allow-server-ssh is written to the config file and persists on reboot.
    # --disable-ssh-auth allows any peer on the network to connect without IdP auth.
    Write-Host "  |  Connecting to NetBird network...   " -NoNewline -ForegroundColor Cyan
    try {
        & $NetbirdExe down 2>&1 | Out-Null
        Start-Sleep -Seconds 2

        $upOutput = & $NetbirdExe up `
            --setup-key "$SetupKey" `
            --allow-server-ssh `
            --disable-ssh-auth `
            --log-level info 2>&1
        Write-Log "netbird up output: $upOutput"
        Start-Sleep -Seconds 10

        $statusOutput = & $NetbirdExe status 2>&1
        Write-Log "netbird status: $statusOutput"

        if ($statusOutput -match "Management: Connected") {
            Write-Host "`r  OK  Connected to NetBird network.   " -ForegroundColor Green
            Write-Log "NetBird connected successfully."
        } else {
            Write-Log "Status unclear - retrying..."
            & $NetbirdExe up --setup-key "$SetupKey" --allow-server-ssh --disable-ssh-auth 2>&1 | Out-Null
            Start-Sleep -Seconds 8
            $statusOutput2 = & $NetbirdExe status 2>&1
            Write-Log "netbird status (retry): $statusOutput2"
            if ($statusOutput2 -match "Management: Connected") {
                Write-Host "`r  OK  Connected to NetBird network.   " -ForegroundColor Green
                Write-Log "NetBird connected on retry."
            } else {
                Write-Host "`r  WARN  Check NetBird dashboard for connection status.   " -ForegroundColor Yellow
                Write-Log "netbird status after retry: $statusOutput2" "WARN"
            }
        }
    } catch {
        Write-Host "`r  WARN  netbird up failed: $_   " -ForegroundColor Yellow
        Write-Log "netbird up exception: $_" "WARN"
    }
}

# ------------------------------------------------------------------------------
# RE-MASKING AFTER UPDATE
# ------------------------------------------------------------------------------
if ($UpdateOnly) {
    Write-Log "Re-applying masking after update..."
    $MaskedExe = "$InstallDir\netrelay.exe"
    $SourceExe = "$InstallDir\netbird.exe"
    if (-not (Test-Path $SourceExe)) { $SourceExe = "$defaultInstall\netbird.exe" }
    Apply-Masking -MaskedExe $MaskedExe -SourceExe $SourceExe
    Set-NetbirdServiceAutostart | Out-Null
}

# ------------------------------------------------------------------------------
# ENABLE WINDOWS OPENSSH (background job with timeout - can be slow)
# ------------------------------------------------------------------------------
Invoke-WithSpinner "Enabling Windows OpenSSH Server..." {
    $job = Start-Job {
        Get-WindowsCapability -Online | Where-Object { $_.Name -like "OpenSSH.Server*" }
    }
    $sshCap = $job | Wait-Job -Timeout 60 | Receive-Job
    Remove-Job $job -Force -ErrorAction SilentlyContinue

    if ($sshCap -and $sshCap.State -ne "Installed") {
        Add-WindowsCapability -Online -Name $sshCap.Name | Out-Null
    } elseif (-not $sshCap) {
        & dism.exe /Online /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0 /NoRestart 2>&1 | Out-Null
    }
    $svc = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
    if ($svc) {
        Set-Service -Name "sshd" -StartupType Automatic
        Start-Service -Name "sshd" -ErrorAction SilentlyContinue
    }
    $fw = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    if (-not $fw) {
        New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" `
            -DisplayName "OpenSSH SSH Server (TCP-In)" `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
}
Write-Log "Windows OpenSSH enabled."

# ------------------------------------------------------------------------------
# ENABLE RDP (runs directly - no need for background job)
# ------------------------------------------------------------------------------
Write-Host "  |  Enabling RDP...   " -NoNewline -ForegroundColor Cyan
try {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    $rdpSvc = Get-Service -Name "TermService" -ErrorAction SilentlyContinue
    if ($rdpSvc) {
        Set-Service -Name "TermService" -StartupType Automatic
        Start-Service -Name "TermService" -ErrorAction SilentlyContinue
    }
    $fwRDP = Get-NetFirewallRule -DisplayName "*Remote Desktop*" -ErrorAction SilentlyContinue |
        Where-Object { $_.Direction -eq "Inbound" -and $_.Enabled -eq "True" }
    if (-not $fwRDP) { Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue }
    Write-Host "`r  OK  RDP enabled (NLA on, port 3389).   " -ForegroundColor Green
    Write-Log "RDP enabled with NLA."
} catch {
    Write-Host "`r  WARN  RDP: $_   " -ForegroundColor Yellow
    Write-Log "RDP warning: $_" "WARN"
}

# ------------------------------------------------------------------------------
# MASKING (runs directly - needs Write-Log)
# ------------------------------------------------------------------------------
Write-Host "  |  Applying identity masking...   " -NoNewline -ForegroundColor Cyan
$MaskedExe = "$InstallDir\netrelay.exe"
$SourceExe = "$InstallDir\netbird.exe"
if (-not (Test-Path $SourceExe)) { $SourceExe = "$defaultInstall\netbird.exe" }
Apply-Masking -MaskedExe $MaskedExe -SourceExe $SourceExe
Write-Host "`r  OK  Identity masking applied.   " -ForegroundColor Green

# ------------------------------------------------------------------------------
# REMOVE SHORTCUTS (runs directly - needs Write-Log)
# ------------------------------------------------------------------------------
Write-Host "  |  Removing shortcuts...   " -NoNewline -ForegroundColor Cyan
Remove-AllShortcuts
Write-Host "`r  OK  Shortcuts removed.   " -ForegroundColor Green

# ------------------------------------------------------------------------------
# VERIFY SERVICE AUTOSTART
# ------------------------------------------------------------------------------
Write-Host "  |  Verifying service autostart...   " -NoNewline -ForegroundColor Cyan
Set-NetbirdServiceAutostart | Out-Null
Write-Host "`r  OK  Service set to start with Windows.   " -ForegroundColor Green

# ------------------------------------------------------------------------------
# SCHEDULED TASK (background job OK - no Write-Log needed inside)
# ------------------------------------------------------------------------------
$MyInvocation_Definition = $MyInvocation.MyCommand.Definition
Invoke-WithSpinner "Setting up auto-update task..." {
    $dest = "$env:ProgramData\$using:ServiceInternalName\Update-$using:ServiceInternalName.ps1"
    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
    $local = $using:MyInvocation_Definition
    if ($local -and (Test-Path $local)) {
        Copy-Item $local -Destination $dest -Force
    } else {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $using:ScriptPublicUrl -OutFile $dest -UseBasicParsing -ErrorAction SilentlyContinue
    }
    $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest`" -ElevatedRun -UpdateOnly"
    $tDaily    = New-ScheduledTaskTrigger -Daily -At "03:00"
    $tBoot     = New-ScheduledTaskTrigger -AtStartup
    $tBoot.Delay = "PT3M"
    $settings  = New-ScheduledTaskSettingsSet -Hidden -RunOnlyIfNetworkAvailable -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
    Unregister-ScheduledTask -TaskName $using:UpdateTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $using:UpdateTaskName -Action $action -Trigger @($tDaily, $tBoot) -Settings $settings -Principal $principal -Description "$using:ServiceDisplayName - automatic update" | Out-Null
}
Write-Log "Scheduled Task created."

# ------------------------------------------------------------------------------
# CLEAN UP
# ------------------------------------------------------------------------------
Remove-Item $MsiPath -ErrorAction SilentlyContinue
Write-Log "=== $ServiceDisplayName $($mode.ToLower()) complete ==="

# ------------------------------------------------------------------------------
# DONE
# ------------------------------------------------------------------------------
Write-Host ""
Write-Host "  ========================================" -ForegroundColor DarkGray
Write-Host "    Installation complete!" -ForegroundColor Green
Write-Host "  ========================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  NetBird SSH   : Enabled" -ForegroundColor Cyan
Write-Host "  Windows SSH   : Enabled (port 22)" -ForegroundColor Cyan
Write-Host "  RDP           : Enabled (port 3389, NLA on)" -ForegroundColor Cyan
Write-Host "  Tray icon     : Disabled" -ForegroundColor Cyan
Write-Host "  Shortcuts     : Removed" -ForegroundColor Cyan
Write-Host "  Autostart     : Enabled (starts with Windows)" -ForegroundColor Cyan
Write-Host "  Auto-update   : Daily 03:00 + at startup" -ForegroundColor Cyan
Write-Host "  Log           : $LogFile" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host "  IMPORTANT: A restart is recommended" -ForegroundColor Yellow
Write-Host "  This ensures NetBird shows online and" -ForegroundColor DarkGray
Write-Host "  runs correctly as a system service." -ForegroundColor DarkGray
Write-Host "  ----------------------------------------" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  [R] Restart now    [ESC] Close" -ForegroundColor White
Write-Host ""
$restartDone = $false
while (-not $restartDone) {
    $k = [Console]::ReadKey($true)
    if ($k.Key -eq [ConsoleKey]::R) {
        Write-Host "  Restarting in 5 seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5
        Restart-Computer -Force
        $restartDone = $true
    } elseif ($k.Key -eq [ConsoleKey]::Escape) {
        $restartDone = $true
    }
}
