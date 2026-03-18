# ==============================================================================
# 5echo-NetRelay.ps1
# 5echo.io NetRelay - Stille installasjon av NetBird
# Funksjoner: SSH (Windows + NetBird), RDP, Skjult taskbar, Auto-oppdatering
# Stotter x64 og ARM64 | Admin og vanlig bruker (UAC-elevation)
# ==============================================================================

#Requires -Version 5.1

param(
    [switch]$ElevatedRun,
    [string]$KeyFile   = "",
    [switch]$UpdateOnly,
    [switch]$Uninstall
)

# ------------------------------------------------------------------------------
# KONFIGURASJON
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
# HJELPEFUNKSJONER
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
    Write-Log "Ikke-stottet arkitektur: $arch" "ERROR"
    exit 1
}

function Get-LatestNetbirdVersion {
    Write-Log "Henter siste versjon fra GitHub..."
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/netbirdio/netbird/releases/latest" -UseBasicParsing
        return $release.tag_name.TrimStart("v")
    } catch {
        Write-Log "Kunne ikke hente versjon fra GitHub: $_" "ERROR"
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
    Write-Log "Stopper eventuelle kjorende prosesser..."
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
            & sc.exe description $svcName "$ServiceDisplayName - sikker nettverkstilkobling" 2>&1 | Out-Null
            $svcRegPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$svcName"
            if (Test-Path $svcRegPath) {
                Set-ItemProperty -Path $svcRegPath -Name "DisplayName" -Value $ServiceDisplayName -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $svcRegPath -Name "Description" -Value "$ServiceDisplayName - sikker nettverkstilkobling" -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $svcRegPath -Name "ImagePath"   -Value $MaskedExe -Force -ErrorAction SilentlyContinue
            }
            Write-Log "Service '$svcName' maskert som '$ServiceDisplayName'."
        }
    }
}

function Invoke-Remasking {
    Write-Log "Kjorer re-maskering..."
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
                Write-Log "Re-maskert: $($_.PSPath)"
            }
        }
    }
    $sourceExe = "$InstallDir\netbird.exe"
    if (-not (Test-Path $sourceExe)) { $sourceExe = "$env:ProgramFiles\Netbird\netbird.exe" }
    if (Test-Path $sourceExe) {
        Stop-NetbirdProcesses
        Copy-Item $sourceExe -Destination $MaskedExe -Force -ErrorAction SilentlyContinue
        Write-Log "netrelay.exe oppdatert."
    }
    Set-ServiceMasking
    Write-Log "Re-maskering fullfort."
}

# ------------------------------------------------------------------------------
# TEMP-MAPPE (trengs tidlig for logging)
# ------------------------------------------------------------------------------
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

# ------------------------------------------------------------------------------
# INSTALLASJONSSJEKK - vis meny dersom allerede installert
# ------------------------------------------------------------------------------
if (-not $UpdateOnly -and -not $Uninstall -and -not $ElevatedRun) {
    if (Test-NetbirdInstalled) {
        Write-Host ""
        Write-Host "========================================"
        Write-Host "  $ServiceDisplayName"
        Write-Host "========================================"
        Write-Host ""
        Write-Host "  Programvaren er allerede installert." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  [1] Avinstaller komplett"
        Write-Host "  [2] Avbryt"
        Write-Host ""
        $choice = (Read-Host "Velg [1-2]").Trim()
        if ($choice -eq "1") {
            Write-Host ""
            Write-Host "  Starter avinstallasjon..." -ForegroundColor Cyan
            $scriptPath = $MyInvocation.MyCommand.Definition
            $elevArgs   = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Uninstall"
            if (Test-IsAdmin) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$scriptPath" -Uninstall
            } else {
                Start-Process powershell.exe -ArgumentList $elevArgs -Verb RunAs -Wait
            }
            exit
        } else {
            Write-Host "  Avbrutt." -ForegroundColor Gray
            exit 0
        }
    }
}

# ------------------------------------------------------------------------------
# SELF-ELEVATION - Kjor pa nytt som admin om nodvendig
# ------------------------------------------------------------------------------
if (-not (Test-IsAdmin)) {
    Write-Host "[$ServiceDisplayName] Ikke administrator - ber om forhoyede rettigheter via UAC..."

    $tempKeyFile = ""
    if (-not $UpdateOnly -and -not $Uninstall) {
        $setupKeyInput = (Read-Host "Skriv inn $ServiceDisplayName Setup Key").Trim()
        if ([string]::IsNullOrEmpty($setupKeyInput)) {
            Write-Host "[ERROR] Ingen setup key oppgitt. Avbryter."
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
# LOGG START
# ------------------------------------------------------------------------------
Write-Log "=== $ServiceDisplayName - $(if ($UpdateOnly) { 'OPPDATERING' } elseif ($Uninstall) { 'AVINSTALLASJON' } else { 'INSTALLASJON' }) starter ==="
Write-Log "Kjorer som: $env:USERNAME | Maskin: $env:COMPUTERNAME"

# ------------------------------------------------------------------------------
# AVINSTALLASJON
# ------------------------------------------------------------------------------
if ($Uninstall) {
    Write-Log "Stopper prosesser..."
    Stop-NetbirdProcesses

    Write-Log "Fjerner Scheduled Task..."
    Unregister-ScheduledTask -TaskName $UpdateTaskName -Confirm:$false -ErrorAction SilentlyContinue

    Write-Log "Avinstallerer via MSI..."
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
                    Write-Log "Avinstallerer: $productCode"
                    Start-Process "msiexec.exe" -ArgumentList "/x `"$productCode`" /qn /norestart" -Wait -WindowStyle Hidden
                }
            }
        }
    }

    Write-Log "Fjerner installasjonsmapper..."
    @(
        "$env:ProgramFiles\NetRelay",
        "$env:ProgramFiles\Netbird",
        "$env:ProgramData\NetRelay"
    ) | ForEach-Object {
        if (Test-Path $_) {
            Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "Slettet: $_"
        }
    }

    Write-Log "Rydder registry..."
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

    Write-Log "Fjerner brannmurregler..."
    Remove-NetFirewallRule -DisplayName "*NetBird*"  -ErrorAction SilentlyContinue
    Remove-NetFirewallRule -DisplayName "*NetRelay*" -ErrorAction SilentlyContinue

    Write-Log "=== Avinstallasjon fullfort ==="
    Write-Host ""
    Write-Host "  $ServiceDisplayName er fullstendig avinstallert." -ForegroundColor Green
    Write-Host "  Merk: OpenSSH og RDP er beholdt (OS-funksjoner)." -ForegroundColor DarkGray
    Write-Host "  Logg: $LogFile" -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

# ------------------------------------------------------------------------------
# HENT SETUP KEY (kun ved ny installasjon)
# ------------------------------------------------------------------------------
$SetupKey = ""
if (-not $UpdateOnly) {
    if ($ElevatedRun -and $KeyFile -and (Test-Path $KeyFile)) {
        Write-Log "Leser setup key fra kryptert temp-fil..."
        $encryptedKey = Get-Content -Path $KeyFile
        $secureKey    = ConvertTo-SecureString $encryptedKey
        $bstr         = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
        $SetupKey     = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        Remove-Item $KeyFile -ErrorAction SilentlyContinue
    } else {
        $SetupKey = (Read-Host "Skriv inn $ServiceDisplayName Setup Key").Trim()
    }

    if ([string]::IsNullOrEmpty($SetupKey)) {
        Write-Log "Setup key mangler. Avbryter." "ERROR"
        exit 1
    }
}

# ------------------------------------------------------------------------------
# ARKITEKTUR OG VERSJON
# ------------------------------------------------------------------------------
$Arch = Get-Architecture
Write-Log "Arkitektur: $Arch"

if ($NetbirdVersion -eq "latest") { $NetbirdVersion = Get-LatestNetbirdVersion }
Write-Log "Malversjon: $NetbirdVersion"

# ------------------------------------------------------------------------------
# OPPDATERINGSSJEKK
# ------------------------------------------------------------------------------
if ($UpdateOnly) {
    $installedVer = Get-InstalledNetbirdVersion
    Write-Log "Installert  : $(if ($installedVer) { $installedVer } else { 'ikke funnet' })"
    Write-Log "Tilgjengelig: $NetbirdVersion"
    if ($installedVer -eq $NetbirdVersion) {
        Write-Log "$ServiceDisplayName er allerede oppdatert ($NetbirdVersion). Avslutter."
        exit 0
    }
    Write-Log "Oppdatering tilgjengelig - fortsetter..."
}

# ------------------------------------------------------------------------------
# LAST NED MSI
# ------------------------------------------------------------------------------
$MsiFileName = "netbird_installer_${NetbirdVersion}_windows_${Arch}.msi"
$DownloadUrl = "https://github.com/netbirdio/netbird/releases/download/v${NetbirdVersion}/${MsiFileName}"
$MsiPath     = "$TempDir\$MsiFileName"

Write-Log "Laster ned: $DownloadUrl"
try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $MsiPath -UseBasicParsing
    Write-Log "Nedlasting fullfort."
} catch {
    Write-Log "Nedlasting feilet: $_" "ERROR"
    exit 1
}

# ------------------------------------------------------------------------------
# STOPP PROSESSER + STILLE INSTALLASJON
# ------------------------------------------------------------------------------
Stop-NetbirdProcesses
Write-Log "Starter stille installasjon..."

$MsiLog  = "$TempDir\msi_install.log"
$MsiArgs = @(
    "/i", "`"$MsiPath`"",
    "/qn",
    "/norestart",
    "REBOOT=ReallySuppress",
    "STARTMENUSHORTCUTS=0",
    "DESKTOPSHORTCUT=0",
    "/log", "`"$MsiLog`""
)

$proc     = Start-Process "msiexec.exe" -ArgumentList $MsiArgs -Wait -PassThru -WindowStyle Hidden
$exitCode = $proc.ExitCode

if ($exitCode -eq 0) {
    Write-Log "Installasjon fullfort (exit: $exitCode)"
} elseif ($exitCode -eq 3010) {
    Write-Log "Installasjon fullfort - restart anbefales (exit: 3010)" "WARN"
} else {
    Write-Log "Installasjon feilet (exit: $exitCode). Se: $MsiLog" "ERROR"
    exit $exitCode
}

# ------------------------------------------------------------------------------
# KOPIER BINARFILER TIL TILPASSET MAPPE
# ------------------------------------------------------------------------------
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
$defaultInstall = "$env:ProgramFiles\Netbird"
if (Test-Path "$defaultInstall\netbird.exe") {
    Write-Log "Kopierer binarfiler til $InstallDir..."
    Copy-Item "$defaultInstall\*" -Destination $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
}

$NetbirdExe = "$InstallDir\netbird.exe"
if (-not (Test-Path $NetbirdExe)) { $NetbirdExe = "$defaultInstall\netbird.exe" }
if (-not (Test-Path $NetbirdExe)) {
    Write-Log "netbird.exe ikke funnet etter installasjon." "ERROR"
    exit 1
}
Write-Log "Bruker binar: $NetbirdExe"

# ------------------------------------------------------------------------------
# REGISTRER SETUP KEY
# ------------------------------------------------------------------------------
if (-not $UpdateOnly) {
    Write-Log "Registrerer med setup key..."
    $upProc = Start-Process $NetbirdExe `
        -ArgumentList "up --setup-key `"$SetupKey`" --log-level info" `
        -Wait -PassThru -WindowStyle Hidden
    if ($upProc.ExitCode -eq 0) {
        Write-Log "Tilkoblet og registrert."
    } else {
        Write-Log "netbird up feilet (exit: $($upProc.ExitCode)). Sjekk setup key." "WARN"
    }
}

# ------------------------------------------------------------------------------
# RE-MASKERING ETTER OPPDATERING
# ------------------------------------------------------------------------------
if ($UpdateOnly) { Invoke-Remasking }

# ------------------------------------------------------------------------------
# AKTIVER NETBIRD SSH
# ------------------------------------------------------------------------------
Write-Log "Aktiverer NetBird SSH..."
$sshProc = Start-Process $NetbirdExe -ArgumentList "ssh --allow-connections" -Wait -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue
if (-not $sshProc -or $sshProc.ExitCode -ne 0) {
    Start-Process $NetbirdExe -ArgumentList "up --allow-server-ssh" -Wait -WindowStyle Hidden -ErrorAction SilentlyContinue
}
Write-Log "NetBird SSH aktivert."

# ------------------------------------------------------------------------------
# AKTIVER WINDOWS OPENSSH SERVER
# ------------------------------------------------------------------------------
Write-Log "Aktiverer Windows OpenSSH Server..."
$sshCap = Get-WindowsCapability -Online | Where-Object { $_.Name -like "OpenSSH.Server*" }
if ($sshCap -and $sshCap.State -ne "Installed") {
    Add-WindowsCapability -Online -Name $sshCap.Name | Out-Null
    Write-Log "OpenSSH Server installert."
} else {
    Write-Log "OpenSSH Server allerede installert."
}
$sshSvc = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
if ($sshSvc) {
    Set-Service -Name "sshd" -StartupType Automatic
    Start-Service -Name "sshd" -ErrorAction SilentlyContinue
    Write-Log "sshd startet (Automatic)."
}
$fwSSH = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
if (-not $fwSSH) {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" `
        -DisplayName "OpenSSH SSH Server (TCP-In)" `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    Write-Log "Brannmurregel SSH (port 22) lagt til."
}

# ------------------------------------------------------------------------------
# AKTIVER RDP
# ------------------------------------------------------------------------------
Write-Log "Aktiverer RDP..."
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" `
    -Name "fDenyTSConnections" -Value 0 -Type DWord -Force
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
    -Name "UserAuthentication" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
$rdpSvc = Get-Service -Name "TermService" -ErrorAction SilentlyContinue
if ($rdpSvc) {
    Set-Service -Name "TermService" -StartupType Automatic
    Start-Service -Name "TermService" -ErrorAction SilentlyContinue
    Write-Log "Remote Desktop Services startet (Automatic)."
}
$fwRDP = Get-NetFirewallRule -DisplayName "*Remote Desktop*" -ErrorAction SilentlyContinue |
    Where-Object { $_.Direction -eq "Inbound" -and $_.Enabled -eq "True" }
if (-not $fwRDP) {
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue
}
Write-Log "RDP aktivert med NLA."

# ------------------------------------------------------------------------------
# MASKERING - PROSESSNAVN (Task Manager)
# ------------------------------------------------------------------------------
Write-Log "Maskerer prosessnavn i Task Manager..."
$MaskedExe = "$InstallDir\netrelay.exe"
$sourceExe = "$InstallDir\netbird.exe"
if (-not (Test-Path $sourceExe)) { $sourceExe = "$env:ProgramFiles\Netbird\netbird.exe" }
if (Test-Path $sourceExe) {
    Stop-NetbirdProcesses
    Copy-Item $sourceExe -Destination $MaskedExe -Force -ErrorAction SilentlyContinue
    Write-Log "Prosess vil vises som 'netrelay' i Task Manager."
} else {
    Write-Log "Kunne ikke finne netbird.exe for omdoping." "WARN"
}

# ------------------------------------------------------------------------------
# MASKERING - INSTALLERTE APPLIKASJONER
# ------------------------------------------------------------------------------
Write-Log "Maskerer oppforing under Installerte applikasjoner..."
$uninstallRoots = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
)
foreach ($root in $uninstallRoots) {
    Get-ChildItem -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
        $dn = (Get-ItemProperty -Path $_.PSPath -Name "DisplayName" -ErrorAction SilentlyContinue).DisplayName
        if ($dn -and $dn -match "(?i)netbird") {
            Set-ItemProperty -Path $_.PSPath -Name "DisplayName"     -Value $ServiceDisplayName -Force
            Set-ItemProperty -Path $_.PSPath -Name "Publisher"       -Value "5echo.io"           -Force
            Set-ItemProperty -Path $_.PSPath -Name "DisplayIcon"     -Value $MaskedExe           -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $_.PSPath -Name "InstallLocation" -Value $InstallDir          -Force -ErrorAction SilentlyContinue
            Write-Log "App-oppforing maskert: $($_.PSPath)"
        }
    }
}

# ------------------------------------------------------------------------------
# MASKERING - WINDOWS SERVICE
# ------------------------------------------------------------------------------
Write-Log "Maskerer Windows Service..."
Set-ServiceMasking

# ------------------------------------------------------------------------------
# DEAKTIVER TASKBAR / TRAY-IKON
# ------------------------------------------------------------------------------
Write-Log "Deaktiverer taskbar-ikon..."
$runPaths = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
)
foreach ($regPath in $runPaths) {
    if (Test-Path $regPath) {
        @("Netbird", "NetbirdUI", "netbird-ui", $ServiceInternalName) | ForEach-Object {
            Remove-ItemProperty -Path $regPath -Name $_ -ErrorAction SilentlyContinue
        }
    }
}
Get-Process -Name "netbird-ui" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Write-Log "Taskbar-ikon deaktivert."

# ------------------------------------------------------------------------------
# OPPRETT SCHEDULED TASK - AUTOMATISK OPPDATERING
# ------------------------------------------------------------------------------
Write-Log "Oppretter Scheduled Task for automatisk oppdatering..."

$scriptDestination = "$env:ProgramData\$ServiceInternalName\Update-$ServiceInternalName.ps1"
New-Item -ItemType Directory -Path (Split-Path $scriptDestination) -Force | Out-Null

$localScriptPath = $MyInvocation.MyCommand.Definition
if ($localScriptPath -and (Test-Path $localScriptPath)) {
    Copy-Item $localScriptPath -Destination $scriptDestination -Force
    Write-Log "Script kopiert til $scriptDestination"
} else {
    Write-Log "Ingen lokal fil - laster ned fra $ScriptPublicUrl..."
    try {
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $ScriptPublicUrl -OutFile $scriptDestination -UseBasicParsing
        Write-Log "Script lastet ned til $scriptDestination"
    } catch {
        Write-Log "Kunne ikke laste ned script for auto-oppdatering: $_" "WARN"
    }
}

$taskAction    = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptDestination`" -ElevatedRun -UpdateOnly"
$triggerDaily  = New-ScheduledTaskTrigger -Daily -At "03:00"
$triggerBoot   = New-ScheduledTaskTrigger -AtStartup
$triggerBoot.Delay = "PT3M"
$taskSettings  = New-ScheduledTaskSettingsSet -Hidden -RunOnlyIfNetworkAvailable -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
$taskPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Unregister-ScheduledTask -TaskName $UpdateTaskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $UpdateTaskName -Action $taskAction `
    -Trigger @($triggerDaily, $triggerBoot) -Settings $taskSettings -Principal $taskPrincipal `
    -Description "$ServiceDisplayName - daglig automatisk oppdatering" | Out-Null

Write-Log "Scheduled Task '$UpdateTaskName' opprettet (daglig kl. 03:00 + ved oppstart)."

# ------------------------------------------------------------------------------
# RYDD OPP
# ------------------------------------------------------------------------------
Write-Log "Rydder opp temp-filer..."
Remove-Item $MsiPath -ErrorAction SilentlyContinue

# ------------------------------------------------------------------------------
# FERDIG
# ------------------------------------------------------------------------------
Write-Log "=== $ServiceDisplayName $(if ($UpdateOnly) { 'oppdatering' } else { 'installasjon' }) fullfort ==="
Write-Host ""
Write-Host "  $ServiceDisplayName er klar." -ForegroundColor Green
Write-Host ""
Write-Host "  NetBird SSH   : Aktivert" -ForegroundColor Cyan
Write-Host "  Windows SSH   : Aktivert (port 22)" -ForegroundColor Cyan
Write-Host "  RDP           : Aktivert (port 3389, NLA pa)" -ForegroundColor Cyan
Write-Host "  Taskbar-ikon  : Deaktivert" -ForegroundColor Cyan
Write-Host "  Auto-update   : Daglig kl. 03:00 + ved oppstart" -ForegroundColor Cyan
Write-Host "  Logg          : $LogFile" -ForegroundColor DarkGray
Write-Host ""
