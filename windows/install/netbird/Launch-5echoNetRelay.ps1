# ==============================================================================
# Launch-5echoNetRelay.ps1
# Launcher - downloads and runs 5echo.io NetRelay installation script
# Solves the $MyInvocation issue when running via iex/irm
#
# USAGE (one command in PowerShell):
#   irm "https://scripts.5echo.io/windows/install/netbird/Launch-5echoNetRelay.ps1" | iex
# From CMD:
#   powershell -ExecutionPolicy Bypass -Command "irm 'https://scripts.5echo.io/windows/install/netbird/Launch-5echoNetRelay.ps1' | iex"
# ==============================================================================

$ScriptUrl = "https://scripts.5echo.io/windows/install/netbird/5echo-NetRelay.ps1"
$LocalPath = "$env:TEMP\5echo-NetRelay-$(Get-Random).ps1"

Write-Host ""
Write-Host "  5echo.io NetRelay - Downloading installation script..." -ForegroundColor Cyan

try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $ScriptUrl -OutFile $LocalPath -UseBasicParsing
} catch {
    Write-Host "  [ERROR] Could not download script: $_" -ForegroundColor Red
    Write-Host "  Press ENTER to close..." -ForegroundColor Yellow
    Read-Host | Out-Null
    exit 1
}

try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $LocalPath
} finally {
    Remove-Item $LocalPath -ErrorAction SilentlyContinue
}
