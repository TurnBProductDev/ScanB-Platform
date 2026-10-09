<#
.SYNOPSIS
    Deploys the Fabric capacity start/stop automation into TurnBAutomationAccount
    and retires the superseded Power BI Embedded schedule wiring.

.DESCRIPTION
    Idempotent. Re-running is safe: runbooks are overwritten and republished,
    schedule links are keyed on a deterministic GUID, and already-correct state
    is reported rather than duplicated.

    IMPORTANT - all ARM calls go through `az rest`, deliberately.

    The tenant enforces MFA for Azure resource management. A token pulled out
    with `az account get-access-token` and replayed by curl / Invoke-WebRequest
    carries amr=["pwd"] and every write comes back 401 RequestDisallowedByAzure,
    even though the account has Authenticator push registered. Letting the CLI
    own the request means it also owns the token step-up, and the same writes
    succeed. Do not "simplify" this back to Invoke-WebRequest with a bearer token.

.EXAMPLE
    # Show what would change, without writing:
    .\Deploy-FabricSchedules.ps1 -WhatIfOnly

.EXAMPLE
    .\Deploy-FabricSchedules.ps1
#>
[CmdletBinding()]
param(
    [switch]$WhatIfOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- CONFIGURATION ---
$SubscriptionId = '0300da4d-3a63-4241-a129-42b4f8b0c5cc'
$ResourceGroup  = 'ScanB'
$AccountName    = 'TurnBAutomationAccount'
$ApiVersion     = '2023-11-01'
$Location       = 'centralus'
$CapacityName   = 'scanbf2test123456'

$Base = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$AccountName"

# Runbook -> schedule wiring. CF_START_SCHEDULE fires 07:20 IST daily and
# CF_STOP_SCHEDULE 21:30 IST daily; both already drive Start-VM / Stop-VM.
# One schedule can fan out to many runbooks, so these are shared, not duplicated.
$Links = @(
    @{ Runbook = 'Start-FabricCapacity'; Schedule = 'CF_START_SCHEDULE' }
    @{ Runbook = 'Stop-FabricCapacity';  Schedule = 'CF_STOP_SCHEDULE'  }
)

# Orphaned Power BI Embedded schedules to disable.
# Deliberately NOT touching:
#   CF_START_SCHEDULE / CF_STOP_SCHEDULE - now drive the Fabric runbooks
#   CityFlowerPBIStartSchedule / ...Stop - left enabled pending a decision on the window
#   cm-daily, Start-VM_time, Stop-VM_time - unrelated to Power BI
#   the expired one-time test schedules   - already inert
$SchedulesToDisable = @(
    'PowerBIEmbedded_Start_time'
    'PowerBIEmbedded_Suspend_time'
    'CF_START_SCHEDULE_PBI'
    'PBI_Start_Schedule_5AM'
    'PBI_Stop_Schedule_7AM'
)

$RetiredRunbooks = @('Start-PowerBIEmbedded', 'StopPowerBIEmbedded')

$Runbooks = @(
    @{
        Name = 'Start-FabricCapacity'
        File = Join-Path $PSScriptRoot 'Start-FabricCapacity.ps1'
        Desc = "Resumes the $CapacityName Fabric F8 capacity (serves CITYFLOWER and SB Mart). Replaces Start-PowerBIEmbedded."
    }
    @{
        Name = 'Stop-FabricCapacity'
        File = Join-Path $PSScriptRoot 'Stop-FabricCapacity.ps1'
        Desc = "Suspends the $CapacityName Fabric F8 capacity to stop billing. Replaces StopPowerBIEmbedded."
    }
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Invoke-Arm {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Uri,
        [string]$BodyFile,
        [string]$ContentType = 'application/json'
    )
    $cmdArgs = @('rest', '--method', $Method, '--url', $Uri)
    if ($BodyFile) {
        $cmdArgs += @('--headers', "Content-Type=$ContentType", '--body', "@$BodyFile")
    }
    $out  = & az @cmdArgs 2>&1
    $code = $LASTEXITCODE
    return [pscustomobject]@{
        Ok     = ($code -eq 0)
        Output = ($out | Out-String).Trim()
    }
}

function New-TempJson {
    param([Parameter(Mandatory)]$Object)
    $f = [IO.Path]::GetTempFileName()
    ($Object | ConvertTo-Json -Depth 8 -Compress) | Set-Content -Path $f -Encoding utf8 -NoNewline
    return $f
}

function Get-DeterministicGuid {
    # A jobSchedule id is caller-supplied. Deriving it from runbook+schedule keeps
    # re-runs idempotent instead of piling up duplicate links.
    # SHA-256 truncated to 16 bytes, not MD5: this machine runs with Windows FIPS
    # mode on, which throws on MD5. Only stability matters here, not the algorithm.
    param([string]$Text)
    $sha   = [Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
    # The [byte[]] cast is required: a range index yields Object[] in PS 5.1,
    # which binds the Guid(string) overload and throws.
    return ([guid]::new([byte[]]($bytes[0..15]))).ToString()
}

# ---------------------------------------------------------------------------
# Context
# ---------------------------------------------------------------------------
Write-Host '=== Azure context ===' -ForegroundColor Cyan
$acct = az account show -o json 2>&1
if ($LASTEXITCODE -ne 0) { throw "Not logged in. Run: az login --tenant 315642c5-e14a-4c12-bf77-41ee070def79" }
$acctObj = $acct | ConvertFrom-Json
Write-Host "  user         = $($acctObj.user.name)"
Write-Host "  subscription = $($acctObj.name) ($($acctObj.id))"
if ($acctObj.id -ne $SubscriptionId) {
    throw "Active subscription is $($acctObj.id), expected $SubscriptionId. Run: az account set --subscription $SubscriptionId"
}

if ($WhatIfOnly) {
    Write-Host ''
    Write-Host '=== WhatIf: planned changes ===' -ForegroundColor Cyan
    foreach ($rb in $Runbooks) { Write-Host "  publish runbook $($rb.Name) (PowerShell72)" }
    foreach ($l  in $Links)    { Write-Host "  link $($l.Runbook) <- $($l.Schedule)" }
    Write-Host "  unlink all job schedules from: $($RetiredRunbooks -join ', ')"
    foreach ($s in $SchedulesToDisable) { Write-Host "  disable schedule $s" }
    Write-Host ''
    Write-Host 'No changes made.' -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# 1. Create and publish the Fabric runbooks
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 1. Fabric runbooks ===' -ForegroundColor Cyan

foreach ($rb in $Runbooks) {
    Write-Host "--- $($rb.Name)"
    if (-not (Test-Path $rb.File)) { throw "Runbook source not found: $($rb.File)" }

    $shellFile = New-TempJson @{
        location   = $Location
        properties = @{
            runbookType = 'PowerShell72'
            logVerbose  = $false
            logProgress = $false
            description = $rb.Desc
            draft       = @{}
        }
    }
    try {
        $r = Invoke-Arm -Method PUT -Uri "$Base/runbooks/$($rb.Name)?api-version=$ApiVersion" -BodyFile $shellFile
        if (-not $r.Ok) { Write-Error "    shell failed: $($r.Output)"; continue }
        Write-Host '    created/updated shell' -ForegroundColor Green
    }
    finally { Remove-Item $shellFile -ErrorAction SilentlyContinue }

    # Draft content is uploaded as raw PowerShell, not wrapped in JSON.
    $r = Invoke-Arm -Method PUT -Uri "$Base/runbooks/$($rb.Name)/draft/content?api-version=$ApiVersion" `
                    -BodyFile $rb.File -ContentType 'text/powershell'
    if (-not $r.Ok) { Write-Error "    content upload failed: $($r.Output)"; continue }
    Write-Host '    uploaded draft content' -ForegroundColor Green

    $r = Invoke-Arm -Method POST -Uri "$Base/runbooks/$($rb.Name)/publish?api-version=$ApiVersion"
    if (-not $r.Ok) { Write-Error "    publish failed: $($r.Output)"; continue }
    Write-Host '    published' -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 2. Link runbooks to the live daily schedules
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 2. Schedule links ===' -ForegroundColor Cyan

foreach ($l in $Links) {
    $jsId = Get-DeterministicGuid "scanb/$($l.Runbook)/$($l.Schedule)"
    Write-Host "--- $($l.Runbook) <- $($l.Schedule)"

    $bodyFile = New-TempJson @{
        properties = @{
            schedule = @{ name = $l.Schedule }
            runbook  = @{ name = $l.Runbook }
        }
    }
    try {
        $r = Invoke-Arm -Method PUT -Uri "$Base/jobSchedules/$jsId`?api-version=$ApiVersion" -BodyFile $bodyFile
        if ($r.Ok) { Write-Host '    linked' -ForegroundColor Green }
        elseif ($r.Output -match 'already exists|Conflict') { Write-Host '    already linked' -ForegroundColor Yellow }
        else { Write-Error "    link failed: $($r.Output)" }
    }
    finally { Remove-Item $bodyFile -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# 3. Retire the Power BI Embedded automation
# ---------------------------------------------------------------------------
# The A1 capacity powerembeddedtest101 is suspended and no production workspace
# is assigned to it. Unlink its dead schedule bindings and disable the orphaned
# PBI schedules. Runbook code and the capacity resource are left in place.
Write-Host ''
Write-Host '=== 3. Retire Power BI Embedded wiring ===' -ForegroundColor Cyan

$r = Invoke-Arm -Method GET -Uri "$Base/jobSchedules?api-version=$ApiVersion"
if ($r.Ok) {
    $dead = ($r.Output | ConvertFrom-Json).value |
            Where-Object { $RetiredRunbooks -contains $_.properties.runbook.name }
    if (-not $dead) { Write-Host '    no Embedded job schedules left to unlink' -ForegroundColor Yellow }
    foreach ($js in $dead) {
        $jsId  = $js.properties.jobScheduleId
        $sched = $js.properties.schedule.name
        $d = Invoke-Arm -Method DELETE -Uri "$Base/jobSchedules/$jsId`?api-version=$ApiVersion"
        if ($d.Ok) { Write-Host "    unlinked $($js.properties.runbook.name) <- $sched" -ForegroundColor Green }
        else       { Write-Warning "    unlink $sched failed: $($d.Output)" }
    }
}
else { Write-Warning "    could not list job schedules: $($r.Output)" }

foreach ($s in $SchedulesToDisable) {
    $bodyFile = New-TempJson @{ name = $s; properties = @{ isEnabled = $false } }
    try {
        $r = Invoke-Arm -Method PATCH -Uri "$Base/schedules/$s`?api-version=$ApiVersion" -BodyFile $bodyFile
        if ($r.Ok) { Write-Host "    disabled $s" -ForegroundColor Green }
        else       { Write-Host "    could not disable $s (likely already expired/inert)" -ForegroundColor Yellow }
    }
    finally { Remove-Item $bodyFile -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# 4. Verification
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 4. Verification ===' -ForegroundColor Cyan

$r = Invoke-Arm -Method GET -Uri "$Base/jobSchedules?api-version=$ApiVersion"
if ($r.Ok) {
    Write-Host 'Active runbook -> schedule links:'
    ($r.Output | ConvertFrom-Json).value |
        Sort-Object { $_.properties.runbook.name } |
        ForEach-Object { Write-Host ('  {0,-24} <- {1}' -f $_.properties.runbook.name, $_.properties.schedule.name) }
}

$capUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Fabric/capacities/$CapacityName`?api-version=$ApiVersion"
$r = Invoke-Arm -Method GET -Uri $capUri
if ($r.Ok) {
    $cap = $r.Output | ConvertFrom-Json
    Write-Host "Fabric capacity $CapacityName : state=$($cap.properties.state) sku=$($cap.sku.name)"
}

Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
