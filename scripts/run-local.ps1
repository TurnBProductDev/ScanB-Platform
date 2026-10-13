<#
.SYNOPSIS
  Start the AI Bot, the Messaging service and the Web App locally, for testing
  in a browser.

.DESCRIPTION
  Opens three windows: the AI Bot on :8001, the Messaging service on :8010 and
  the Web App on https://localhost:5000. Port 5000 is not a preference - it is
  the localhost redirect URI registered in Entra ID, so sign-in only works on
  that port.

  Run it as a file (powershell -File ...\scripts\run-local.ps1). Pasted into a
  prompt it cannot find the repos, because it locates them from its own path.

  Both read local development config that is NOT in git:
    TurnB_ScanB_WebApplication/appsettings.Development.json   (Messaging block)
    ScanB-Messaging/.env                                      (matching keys)

  The Messaging service stores data in Azurite, so conversations survive a
  restart. It asks the Web App who people are, so you message your REAL
  colleagues from the local database.

.EXAMPLE
  .\run-local.ps1
  .\run-local.ps1 -Stop
#>
param([switch]$Stop)

if (-not $PSCommandPath) {
    Write-Host 'Run this as a file, not pasted:  powershell -ExecutionPolicy Bypass -File C:\dev\ScanB\ScanB-Platform\scripts\run-local.ps1' -ForegroundColor Red
    return
}

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Base = Split-Path -Parent $Root
$Web  = Join-Path $Base 'TurnB_ScanB_WebApplication_latest\TurnB_ScanB_WebApplication'
$Msg  = Join-Path $Base 'ScanB-Messaging'
$Bot  = Join-Path $Base 'ScanB-AI-Bot'

function Stop-OnPort([int]$Port, [string]$Label) {
    $pids = (netstat -ano | Select-String ":$Port\s.*LISTENING" | ForEach-Object {
        ($_ -split '\s+')[-1] }) | Sort-Object -Unique
    foreach ($processId in $pids) {
        if ($processId -match '^\d+$') {
            taskkill /PID $processId /F | Out-Null
            Write-Host "  stopped $Label (pid $processId)" -ForegroundColor DarkGray
        }
    }
}

Write-Host ''
Write-Host 'Stopping anything already on these ports...' -ForegroundColor Cyan
Stop-OnPort 5000 'web app'
Stop-OnPort 8010 'messaging'
Stop-OnPort 8001 'ai bot'
if ($Stop) { Write-Host 'Stopped.' -ForegroundColor Green; return }

# Azurite: where the Messaging service keeps conversations locally.
docker start scanb-azurite 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host 'Azurite is not set up. Creating it...' -ForegroundColor Yellow
    docker run -d --name scanb-azurite -p 127.0.0.1:10000-10002:10000-10002 `
        mcr.microsoft.com/azure-storage/azurite `
        azurite --blobHost 0.0.0.0 --queueHost 0.0.0.0 --tableHost 0.0.0.0 --loose --skipApiVersionCheck | Out-Null
}

foreach ($needed in @("$Web\appsettings.Development.json", "$Msg\.env")) {
    if (-not (Test-Path $needed)) {
        Write-Host "MISSING: $needed" -ForegroundColor Red
        Write-Host '  See TurnB_ScanB_WebApplication/docs/messaging-setup.md (Development section).' -ForegroundColor Red
        return
    }
}

Write-Host 'Starting the AI Bot on http://localhost:8001 ...' -ForegroundColor Cyan
# "server" matters: a bare main.py starts the console chat instead.
Start-Process -FilePath (Join-Path $Bot '.venv\Scripts\python.exe') -ArgumentList 'main.py', 'server' -WorkingDirectory $Bot

Write-Host 'Starting the Messaging service on http://localhost:8010 ...' -ForegroundColor Cyan
$py = Join-Path $Msg '.venv\Scripts\python.exe'
Start-Process -FilePath $py -ArgumentList '-m', 'uvicorn', 'messaging.main:app', '--port', '8010' -WorkingDirectory $Msg

Write-Host 'Starting the Web App on https://localhost:5000 ...' -ForegroundColor Cyan
# Set on this session so the child process inherits them: Start-Process
# -Environment needs PowerShell 7, and this runs on Windows PowerShell 5.1.
$env:ASPNETCORE_ENVIRONMENT = 'Development'
$env:ASPNETCORE_URLS = 'https://localhost:5000'
Start-Process -FilePath 'dotnet' -ArgumentList 'run' -WorkingDirectory $Web

Write-Host ''
Write-Host 'Give it about 20 seconds, then open:' -ForegroundColor Green
Write-Host '    https://localhost:5000' -ForegroundColor White
Write-Host ''
Write-Host 'Sign in as usual. Messages and Tasks appear in the left menu.' -ForegroundColor Gray
Write-Host 'Stop everything with:  .\run-local.ps1 -Stop' -ForegroundColor Gray
