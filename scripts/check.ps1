<#
.SYNOPSIS
  Build and test the four ScanB repositories, plus a git status summary.

.DESCRIPTION
  One gate over the whole platform. Each repo keeps its own real gate; this
  only calls them, so there is nothing here to keep in sync with a build.

  All four are offline and need no credentials. Messaging can additionally be
  replayed against Azurite (docker start scanb-azurite, then
  MSG_TEST_STORE=azure), which this script does not do.

.EXAMPLE
  .\check.ps1              # all four
  .\check.ps1 bot          # just the AI bot
  .\check.ps1 web insight  # web app and Auto-Insight
  .\check.ps1 messaging    # just messaging
#>
param([string[]]$Only)

$ErrorActionPreference = 'Continue'

$Root    = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$Base    = Split-Path -Parent $Root
$Web     = Join-Path $Base 'TurnB_ScanB_WebApplication_latest\TurnB_ScanB_WebApplication'
$Bot     = Join-Path $Base 'ScanB-AI-Bot'
$Insight = Join-Path $Base 'Auto-Insight-Generation'
$Msg     = Join-Path $Base 'ScanB-Messaging'

function Want([string]$name) {
    if (-not $Only -or $Only.Count -eq 0) { return $true }
    return ($Only -contains $name)
}

function Head([string]$text) {
    Write-Host ''
    Write-Host ('=' * 68) -ForegroundColor DarkGray
    Write-Host $text -ForegroundColor Cyan
    Write-Host ('=' * 68) -ForegroundColor DarkGray
}

# ---------------------------------------------------------------- git status
Head 'Repository status'
foreach ($pair in @(@('Web App', $Web), @('AI Bot', $Bot), @('Auto-Insight', $Insight), @('Messaging', $Msg))) {
    $label = $pair[0]; $path = $pair[1]
    if (-not (Test-Path $path)) {
        Write-Host ("  {0,-14} MISSING at {1}" -f $label, $path) -ForegroundColor Red
        continue
    }
    Push-Location $path
    $branch = (git branch --show-current 2>$null)
    $dirty  = @(git status --porcelain 2>$null).Count
    Pop-Location
    Write-Host ("  {0,-14} {1,-42} {2} uncommitted" -f $label, $branch, $dirty)
}

$results = @{}

function Run([string]$key, [string]$label, [string]$dir, [scriptblock]$body) {
    if (-not (Want $key)) { $results[$label] = 'skipped'; return }
    Head $label
    if (-not (Test-Path $dir)) {
        Write-Host "  directory not found: $dir" -ForegroundColor Red
        $results[$label] = 'FAIL'
        return
    }
    Push-Location $dir
    & $body
    $code = $LASTEXITCODE
    Pop-Location
    if ($code -eq 0) {
        $results[$label] = 'pass'
        Write-Host "  -> pass" -ForegroundColor Green
    } else {
        $results[$label] = 'FAIL'
        Write-Host "  -> FAIL (exit $code)" -ForegroundColor Red
    }
}

Run 'web' 'Web App - compile' $Web {
    dotnet msbuild TurnRetailWebApp.csproj -t:Compile -v:minimal -nologo
}

Run 'bot' 'AI Bot - unit tests' $Bot {
    $py = Join-Path $PWD '.venv\Scripts\python.exe'
    if (-not (Test-Path $py)) { $py = 'python' }
    & $py -m pytest -m unit -q
}

Run 'insight' 'Auto-Insight - replay gate' (Join-Path $Insight 'powerbi-summary-agent') {
    python scripts/replay_all.py
}

Run 'messaging' 'Messaging - unit tests' $Msg {
    $py = Join-Path $PWD '.venv\Scripts\python.exe'
    if (-not (Test-Path $py)) { $py = 'python' }
    & $py -m pytest -q
}

# -------------------------------------------------------------------- summary
Head 'Summary'
$failed = 0
foreach ($k in $results.Keys | Sort-Object) {
    $v = $results[$k]
    $colour = 'Green'
    if ($v -eq 'FAIL')    { $colour = 'Red';      $failed = $failed + 1 }
    if ($v -eq 'skipped') { $colour = 'DarkGray' }
    Write-Host ("  {0,-30} {1}" -f $k, $v) -ForegroundColor $colour
}
Write-Host ''
if ($failed -gt 0) {
    Write-Host "$failed gate(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All selected gates green.' -ForegroundColor Green
exit 0
