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
    [switch]$Uninstall
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

# Spinner - runs a scriptblock in the background and shows animation until done
function Invoke-WithSpinner {
    param(
        [string]$Message,
        [scriptblock]$ScriptBlock
    )

    $frames  = @("|", "/", "-", "\")
    $frameIdx = 0

    # Run the work in a background job
    $job = Start-Job -ScriptBlock $ScriptBlock

    # Animate while job is running
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

    # Clear spinner line and show done
    Write-Host "`r  OK  $Message   " -ForegroundColor Green

    # Return job output and clean up
    $result = Receive-Job $job
    Remove-Job $job -Force
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
    Write-Log "Unsupported architecture: $arch" "ERROR"
    exit 1
}

function Get-LatestNetbirdVersion {
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/netbirdio/netbird/releases/latest" -UseBasicParsing
        return $release.tag_name.TrimStart("v")
    } catch {
        Write-Log "Failed to fetch version from GitHub: $_" "ERROR"
        exit 1
    }
}

function Get-InstalledNetbirdVersion {
    $exe = "$InstallDir\netbird.exe"
    if (-not (Test-Path $exe)) { return $null }
    try {
        $output = & $exe version 2>&1
        if ($output -match "(\d+\.\d+\.\d+)") { return $matches[1] }
    } catch {}
    return $null
}

function Stop-NetbirdProcesses {
    @("netbird", "netbird-ui", "netrelay", "wt-go") | ForEach-Object {
        Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    }
}

function Test-NetbirdInstalled {
    $paths = @(
        "$env:ProgramFiles\NetRelay\netbird.exe",
        "$env:ProgramFiles\Netbird\netbird.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $true }
    }
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
    $MaskedExe = "$InstallDir\netrelay.exe"
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
        }
    }
}

function Invoke-Remasking {
    $MaskedExe = "$InstallDir\netrelay.exe"
    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($root in $roots) {
        Get-ChildItem -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
            $dn = (Get-ItemProperty -Path $_.PSPath -Name "DisplayName" -ErrorAction SilentlyContinue).DisplayName
            if ($dn -and ($dn -match "(?i)netbird" -or $dn -match "(?i)netrelay")) {
                Set-ItemProperty -Path $_.PSPath -Name "DisplayName" -Value $ServiceDisplayName -Force
                Set-ItemProperty -Path $_.PSPath -Name "Publisher"   -Value "5echo.io"          -Force
            }
        }
    }
    $sourceExe = "$InstallDir\netbird.exe"
    if (-not (Test-Path $sourceExe)) { $sourceExe = "$env:ProgramFiles\Netbird\netbird.exe" }
    if (Test-Path $sourceExe) {
        Stop-NetbirdProcesses
        Copy-Item $sourceExe -Destination $MaskedExe -Force -ErrorAction SilentlyContinue
    }
    Set-ServiceMasking
}

function Install-OpenSSH {
    # Run capability check in background job with 60s timeout
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

    $sshSvc = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
    if ($sshSvc) {
        Set-Service -Name "sshd" -StartupType Automatic
        Start-Service -Name "sshd" -ErrorAction SilentlyContinue
    }

    $fwSSH = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    if (-not $fwSSH) {
        New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" `
            -DisplayName "OpenSSH SSH Server (TCP-In)" `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
}

# ------------------------------------------------------------------------------
# TEMP DIRECTORY
# ------------------------------------------------------------------------------
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

# ------------------------------------------------------------------------------
# INSTALLATION CHECK - show menu if already installed
# ------------------------------------------------------------------------------
if (-not $UpdateOnly -and -not $Uninstall -and -not $ElevatedRun) {
    if (Test-NetbirdInstalled) {
        Write-Host ""
        Write-Host "  ========================================" -ForegroundColor DarkGray
        Write-Host "    $ServiceDisplayName" -ForegroundColor White
        Write-Host "  ========================================" -ForegroundColor DarkGray
        Write-Host ""
        Write-Host "  Software is already installed." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  [1] Uninstall completely"
        Write-Host "  [2] Cancel"
        Write-Host ""
        $choice = (Read-Host "  Select [1-2]").Trim()
        if ($choice -eq "1") {
            Write-Host ""
            $scriptPath = $MyInvocation.MyCommand.Definition
            $elevArgs   = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Uninstall"
            if (Test-IsAdmin) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$scriptPath" -Uninstall
            } else {
                Start-Process powershell.exe -ArgumentList $elevArgs -Verb RunAs -Wait
            }
            exit
        } else {
            Write-Host "  Cancelled." -ForegroundColor Gray
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

    Start-Process powershell.exe -ArgumentList $elevArgs -Verb RunAs -Wait
    if ($tempKeyFile) { Remove-Item $tempKeyFile -ErrorAction SilentlyContinue }
    exit
}

# ------------------------------------------------------------------------------
# HEADER
# ------------------------------------------------------------------------------
Write-Log "=== $ServiceDisplayName - $(if ($UpdateOnly) { 'UPDATE' } elseif ($Uninstall) { 'UNINSTALL' } else { 'INSTALLATION' }) started === User: $env:USERNAME | Machine: $env:COMPUTERNAME"

Write-Host ""
Write-Host "  ========================================" -ForegroundColor DarkGray
Write-Host "    $ServiceDisplayName" -ForegroundColor White
if ($UpdateOnly) {
    Write-Host "    Checking for updates..." -ForegroundColor DarkGray
} else {
    Write-Host "    Installing..." -ForegroundColor DarkGray
}
Write-Host "  ========================================" -ForegroundColor DarkGray
Write-Host ""

# ------------------------------------------------------------------------------
# UNINSTALL
# ------------------------------------------------------------------------------
if ($Uninstall) {
    Write-Log "Starting uninstall..."

    Invoke-WithSpinner "Stopping processes..." {
        @("netbird", "netbird-ui", "netrelay", "wt-go") | ForEach-Object {
            Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }

    Invoke-WithSpinner "Removing Scheduled Task..." {
        Unregister-ScheduledTask -TaskName "$using:UpdateTaskName" -Confirm:$false -ErrorAction SilentlyContinue
    }

    Invoke-WithSpinner "Uninstalling via MSI..." {
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
                        Start-Process "msiexec.exe" -ArgumentList "/x `"$productCode`" /qn /norestart" -Wait -WindowStyle Hidden
                    }
                }
            }
        }
    }

    Invoke-WithSpinner "Removing installation folders..." {
        @(
            "$env:ProgramFiles\NetRelay",
            "$env:ProgramFiles\Netbird",
            "$env:ProgramData\NetRelay"
        ) | ForEach-Object {
            if (Test-Path $_) { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    Invoke-WithSpinner "Cleaning registry and firewall rules..." {
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
        Remove-NetFirewallRule -DisplayName "*NetBird*"  -ErrorAction SilentlyContinue
        Remove-NetFirewallRule -DisplayName "*NetRelay*" -ErrorAction SilentlyContinue
    }

    Write-Log "=== Uninstall complete ==="
    Write-Host ""
    Write-Host "  $ServiceDisplayName has been completely uninstalled." -ForegroundColor Green
    Write-Host "  Note: OpenSSH and RDP have been kept (OS features)." -ForegroundColor DarkGray
    Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

# ------------------------------------------------------------------------------
# GET SETUP KEY
# ------------------------------------------------------------------------------
$SetupKey = ""
if (-not $UpdateOnly) {
    if ($ElevatedRun -and $KeyFile -and (Test-Path $KeyFile)) {
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
        Write-Host "  [ERROR] Setup key missing. Aborting." -ForegroundColor Red
        exit 1
    }
    Write-Host ""
}

# ------------------------------------------------------------------------------
# ARCHITECTURE AND VERSION
# ------------------------------------------------------------------------------
$Arch = Get-Architecture
Write-Log "Architecture: $Arch"

$NetbirdVersion = Invoke-WithSpinner "Fetching latest version..." {
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/netbirdio/netbird/releases/latest" -UseBasicParsing
        $release.tag_name.TrimStart("v")
    } catch { "latest" }
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

Invoke-WithSpinner "Downloading NetBird $NetbirdVersion..." {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $using:DownloadUrl -OutFile $using:MsiPath -UseBasicParsing
}
Write-Log "Download complete: $MsiPath"

# ------------------------------------------------------------------------------
# INSTALL
# ------------------------------------------------------------------------------
Stop-NetbirdProcesses

$MsiLog  = "$TempDir\msi_install.log"
$MsiArgs = @("/i", "`"$MsiPath`"", "/qn", "/norestart", "REBOOT=ReallySuppress", "STARTMENUSHORTCUTS=0", "DESKTOPSHORTCUT=0", "/log", "`"$MsiLog`"")

Invoke-WithSpinner "Installing $ServiceDisplayName..." {
    $p = Start-Process "msiexec.exe" -ArgumentList $using:MsiArgs -Wait -PassThru -WindowStyle Hidden
    $p.ExitCode
}
Write-Log "MSI installation complete."

# Copy binaries to custom folder
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
$defaultInstall = "$env:ProgramFiles\Netbird"
if (Test-Path "$defaultInstall\netbird.exe") {
    Copy-Item "$defaultInstall\*" -Destination $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
}

$NetbirdExe = "$InstallDir\netbird.exe"
if (-not (Test-Path $NetbirdExe)) { $NetbirdExe = "$defaultInstall\netbird.exe" }
if (-not (Test-Path $NetbirdExe)) {
    Write-Host "  [ERROR] netbird.exe not found after installation." -ForegroundColor Red
    Write-Log "netbird.exe not found after installation." "ERROR"
    exit 1
}

# ------------------------------------------------------------------------------
# REGISTER SETUP KEY
# ------------------------------------------------------------------------------
if (-not $UpdateOnly) {
    Invoke-WithSpinner "Connecting to NetBird network..." {
        & $using:NetbirdExe up --setup-key "$using:SetupKey" --log-level info 2>&1 | Out-Null
    }
    Write-Log "Setup key registered."
}

# ------------------------------------------------------------------------------
# RE-MASKING AFTER UPDATE
# ------------------------------------------------------------------------------
if ($UpdateOnly) {
    Invoke-WithSpinner "Re-applying masking..." { }
    Invoke-Remasking
}

# ------------------------------------------------------------------------------
# ENABLE NETBIRD SSH
# ------------------------------------------------------------------------------
Invoke-WithSpinner "Enabling NetBird SSH..." {
    $p = Start-Process $using:NetbirdExe -ArgumentList "ssh --allow-connections" -Wait -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
    if (-not $p -or $p.ExitCode -ne 0) {
        Start-Process $using:NetbirdExe -ArgumentList "up --allow-server-ssh" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
    }
}
Write-Log "NetBird SSH enabled."

# ------------------------------------------------------------------------------
# ENABLE WINDOWS OPENSSH (with timeout + fallback)
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
# ENABLE RDP
# ------------------------------------------------------------------------------
Invoke-WithSpinner "Enabling RDP..." {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0 -Type DWord -Force
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    $svc = Get-Service -Name "TermService" -ErrorAction SilentlyContinue
    if ($svc) {
        Set-Service -Name "TermService" -StartupType Automatic
        Start-Service -Name "TermService" -ErrorAction SilentlyContinue
    }
    $fw = Get-NetFirewallRule -DisplayName "*Remote Desktop*" -ErrorAction SilentlyContinue | Where-Object { $_.Direction -eq "Inbound" -and $_.Enabled -eq "True" }
    if (-not $fw) { Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue }
}
Write-Log "RDP enabled with NLA."

# ------------------------------------------------------------------------------
# MASKING
# ------------------------------------------------------------------------------
Invoke-WithSpinner "Applying identity masking..." {
    $MaskedExe = "$using:InstallDir\netrelay.exe"
    $sourceExe = "$using:InstallDir\netbird.exe"
    if (-not (Test-Path $sourceExe)) { $sourceExe = "$env:ProgramFiles\Netbird\netbird.exe" }
    if (Test-Path $sourceExe) {
        @("netbird", "netbird-ui", "netrelay", "wt-go") | ForEach-Object {
            Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        Copy-Item $sourceExe -Destination $MaskedExe -Force -ErrorAction SilentlyContinue
    }

    $roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    foreach ($root in $roots) {
        Get-ChildItem -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
            $dn = (Get-ItemProperty -Path $_.PSPath -Name "DisplayName" -ErrorAction SilentlyContinue).DisplayName
            if ($dn -and $dn -match "(?i)netbird") {
                Set-ItemProperty -Path $_.PSPath -Name "DisplayName"     -Value $using:ServiceDisplayName -Force
                Set-ItemProperty -Path $_.PSPath -Name "Publisher"       -Value "5echo.io"                -Force
                Set-ItemProperty -Path $_.PSPath -Name "DisplayIcon"     -Value $MaskedExe                -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $_.PSPath -Name "InstallLocation" -Value $using:InstallDir         -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $serviceNames = @("Netbird", "netbird", "NetBird")
    foreach ($svcName in $serviceNames) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            & sc.exe config $svcName displayname= "$using:ServiceDisplayName" 2>&1 | Out-Null
            & sc.exe description $svcName "$using:ServiceDisplayName - secure network connection" 2>&1 | Out-Null
            $svcRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$svcName"
            if (Test-Path $svcRegPath) {
                Set-ItemProperty -Path $svcRegPath -Name "DisplayName" -Value $using:ServiceDisplayName -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $svcRegPath -Name "Description" -Value "$using:ServiceDisplayName - secure network connection" -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $svcRegPath -Name "ImagePath"   -Value $MaskedExe -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $runPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
    )
    foreach ($regPath in $runPaths) {
        if (Test-Path $regPath) {
            @("Netbird", "NetbirdUI", "netbird-ui", "NetRelay") | ForEach-Object {
                Remove-ItemProperty -Path $regPath -Name $_ -ErrorAction SilentlyContinue
            }
        }
    }
    Get-Process -Name "netbird-ui" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Write-Log "Masking applied."

# ------------------------------------------------------------------------------
# REMOVE SHORTCUTS
# ------------------------------------------------------------------------------
Invoke-WithSpinner "Removing shortcuts..." {
    $desktopPaths = @(
        "$env:USERPROFILE\Desktop",
        "$env:PUBLIC\Desktop",
        [Environment]::GetFolderPath("CommonDesktopDirectory"),
        [Environment]::GetFolderPath("DesktopDirectory")
    )
    foreach ($desktop in $desktopPaths) {
        Get-ChildItem -Path $desktop -Filter "*.lnk" -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match "(?i)netbird|(?i)netrelay"
        } | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $startMenuPaths = @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        [Environment]::GetFolderPath("CommonPrograms"),
        [Environment]::GetFolderPath("Programs")
    )
    foreach ($startMenu in $startMenuPaths) {
        Get-ChildItem -Path $startMenu -Recurse -Filter "*.lnk" -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match "(?i)netbird|(?i)netrelay"
        } | Remove-Item -Force -ErrorAction SilentlyContinue

        Get-ChildItem -Path $startMenu -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match "(?i)netbird|(?i)netrelay"
        } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Log "Shortcuts removed."

# ------------------------------------------------------------------------------
# ENSURE NETBIRD SERVICE STARTS AUTOMATICALLY
# ------------------------------------------------------------------------------
Invoke-WithSpinner "Configuring service autostart..." {
    $serviceNames = @("Netbird", "netbird", "NetBird")
    foreach ($svcName in $serviceNames) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            Set-Service -Name $svcName -StartupType Automatic -ErrorAction SilentlyContinue
            & sc.exe config $svcName start= auto 2>&1 | Out-Null
            if ($svc.Status -ne "Running") {
                Start-Service -Name $svcName -ErrorAction SilentlyContinue
            }
        }
    }
    $nbExe = "$using:InstallDir\netbird.exe"
    if (-not (Test-Path $nbExe)) { $nbExe = "$env:ProgramFiles\Netbird\netbird.exe" }
    if (Test-Path $nbExe) { & $nbExe service start 2>&1 | Out-Null }
}
Write-Log "NetBird service autostart configured."

# ------------------------------------------------------------------------------
# SCHEDULED TASK
# ------------------------------------------------------------------------------
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

# Store script path for use inside job scope
$MyInvocation_Definition = $MyInvocation.MyCommand.Definition

# ------------------------------------------------------------------------------
# CLEAN UP
# ------------------------------------------------------------------------------
Remove-Item $MsiPath -ErrorAction SilentlyContinue
Write-Log "=== $ServiceDisplayName $(if ($UpdateOnly) { 'update' } else { 'installation' }) complete ==="

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
Write-Host "  Shortcuts     : Removed (desktop + start menu)" -ForegroundColor Cyan
Write-Host "  Autostart     : Enabled (service starts with Windows)" -ForegroundColor Cyan
Write-Host "  Auto-update   : Daily 03:00 + at startup" -ForegroundColor Cyan
Write-Host "  Log           : $LogFile" -ForegroundColor DarkGray
Write-Host ""
