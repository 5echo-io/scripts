# ==============================================================================
# Launch-5echoNetRelay.ps1
# Launcher - laster ned og kjorer 5echo.io NetRelay installasjonsscript
# Loser problemet med $MyInvocation ved kjoring via iex/irm
#
# BRUK (en kommando i PowerShell):
#   irm "https://scripts.5echo.io/windows/install/netbird/Launch-5echoNetRelay.ps1" | iex
# Fra CMD:
#   powershell -ExecutionPolicy Bypass -Command "irm 'https://scripts.5echo.io/windows/install/netbird/Launch-5echoNetRelay.ps1' | iex"
# ==============================================================================

$ScriptUrl = "https://scripts.5echo.io/windows/install/netbird/5echo-NetRelay.ps1"
$LocalPath = "$env:TEMP\5echo-NetRelay-$(Get-Random).ps1"

Write-Host ""
Write-Host "  5echo.io NetRelay - Laster ned installasjonsscript..." -ForegroundColor Cyan

try {
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $ScriptUrl -OutFile $LocalPath -UseBasicParsing
} catch {
    Write-Host "  [FEIL] Kunne ikke laste ned script: $_" -ForegroundColor Red
    exit 1
}

try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $LocalPath
} finally {
    Remove-Item $LocalPath -ErrorAction SilentlyContinue
}
