<#
.SYNOPSIS
    Deploys the Fabric F2/F4/F8 autoscale runbook into TurnBAutomationAccount and
    moves it between log-only (dry run) and live.

.DESCRIPTION
    Idempotent. Re-running republishes Invoke-FabricAutoscale, keeps the 08:30 IST
    morning-floor schedule linked, and never touches the DryRun flag or the
    decision log unless you ask it to:

      (no switch)   publish runbook; create FabricAutoscale_Config (DryRun=true)
                    and FabricAutoscale_State if missing; migrate a pre-F4 config
      -GoLive       set DryRun=false and clear the cooldown and daily count
                    (the decision log is kept for the report)
      -DryRun       set DryRun=true again - the rollback switch
      -SmokeTest    start one job with a sample Quiet signal and print its output;
                    safe in any mode, because rule "smoke-test" is always log-only
      -ResetState   wipe FabricAutoscale_State, decision log included

    The Activator rules and the Power Automate flow that start the runbook are
    built in the Fabric and Power Automate portals - see FABRIC-AUTOSCALE.md.

    IMPORTANT - all ARM calls go through `az rest`, deliberately. The tenant
    enforces MFA for Azure resource management; a replayed bearer token gets
    401 RequestDisallowedByAzure on every write. See Deploy-FabricSchedules.ps1.

.EXAMPLE
    .\Deploy-FabricAutoscale.ps1 -WhatIfOnly
.EXAMPLE
    .\Deploy-FabricAutoscale.ps1 -SmokeTest
.EXAMPLE
    .\Deploy-FabricAutoscale.ps1 -GoLive
#>
[CmdletBinding()]
param(
    [switch]$WhatIfOnly,
    [switch]$GoLive,
    [switch]$DryRun,
    [switch]$SmokeTest,
    [switch]$ResetState
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($GoLive -and $DryRun) { throw "Choose either -GoLive or -DryRun, not both." }

# --- CONFIGURATION ---
$SubscriptionId = '0300da4d-3a63-4241-a129-42b4f8b0c5cc'
$ResourceGroup  = 'ScanB'
$AccountName    = 'TurnBAutomationAccount'
$ApiVersion     = '2023-11-01'
$Location       = 'centralus'
$CapacityName   = 'scanbf2test123456'

$RunbookName = 'Invoke-FabricAutoscale'
$RunbookFile = Join-Path $PSScriptRoot 'Invoke-FabricAutoscale.ps1'
$ConfigVar   = 'FabricAutoscale_Config'
$StateVar    = 'FabricAutoscale_State'

# Initial tuning. Only written when the variable does not exist yet (or still has
# the pre-F4 two-size shape); after that the live variable is the source of
# truth, so hand edits in the portal survive.
# Mirrors the defaults block in Invoke-FabricAutoscale.ps1.
$InitialConfig = [ordered]@{
    DryRun                        = $true
    Tiers                         = @('F2', 'F4', 'F8')
    MorningFloorSku               = 'F4'
    ProtectedWindowStartIst       = '08:30'
    ProtectedWindowEndIst         = '13:00'
    PauseTimeIst                  = '21:30'
    NoScaleDownBeforePauseMinutes = 15
    ScaleDownCooldownMinutes      = 60
    MinMinutesBetweenResizes      = 5
    MaxResizesPerDay              = 8
    UpInteractiveDelayPct         = 75
    UpBackgroundRejectionPct      = 60
    DownBackgroundRejectionPct    = 45
    DownInteractiveRejectionPct   = 45
    DownUtilisationPct            = 60
    Notify                        = $true
    Recipients                    = @()
}

# Daily schedule that raises the capacity to MorningFloorSku before the batch
# window. It never lowers the size. The capacity resumes at 07:20 at whatever
# size it paused at, so without this the 08:45-12:00 jobs could start on F2.
$FloorSchedule = 'FabricAutoscale_MorningFloor'
$FloorTimeIst  = '08:30'

$Base = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Automation/automationAccounts/$AccountName"

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
    # Windows PowerShell 5.1 turns redirected native stderr into a terminating
    # error under ErrorActionPreference=Stop, so an expected 404 would abort the
    # script. The exit code is the real signal; relax the preference for this call.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out  = & az @cmdArgs 2>&1
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $prev }
    # On success keep stdout only, so a CLI warning on stderr cannot corrupt JSON.
    if ($code -eq 0) { $out = $out | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } }
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

function Get-VariableObject {
    # An Automation variable's value is itself JSON: a string variable holding
    # JSON arrives as a quoted, escaped string literal, so it decodes twice.
    param([Parameter(Mandatory)][string]$Name)
    $r = Invoke-Arm -Method GET -Uri "$Base/variables/$Name`?api-version=$ApiVersion"
    if (-not $r.Ok) {
        if ($r.Output -match 'NotFound|404') { return $null }
        throw "Reading variable $Name failed: $($r.Output)"
    }
    $literal = ($r.Output | ConvertFrom-Json).properties.value
    if (-not $literal) { return $null }
    $text = $literal | ConvertFrom-Json
    if (-not $text) { return $null }
    return ($text | ConvertFrom-Json)
}

function Set-VariableObject {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Object,
        [string]$Description
    )
    $json    = $Object | ConvertTo-Json -Depth 8 -Compress
    $literal = ConvertTo-Json -InputObject $json -Compress
    $bodyFile = New-TempJson @{
        name       = $Name
        properties = @{ value = $literal; isEncrypted = $false; description = $Description }
    }
    try {
        $r = Invoke-Arm -Method PUT -Uri "$Base/variables/$Name`?api-version=$ApiVersion" -BodyFile $bodyFile
        if (-not $r.Ok) { throw "Writing variable $Name failed: $($r.Output)" }
    }
    finally { Remove-Item $bodyFile -ErrorAction SilentlyContinue }
}

function New-EmptyState {
    return [ordered]@{
        day = $null; resizesToday = 0; lastResizeUtc = $null
        capNoticeDay = $null; decisions = @()
    }
}

function Get-DeterministicGuid {
    # A jobSchedule id is caller-supplied. Deriving it from runbook+schedule keeps
    # re-runs idempotent instead of piling up duplicate links.
    # SHA-256 truncated to 16 bytes, not MD5: this machine runs with Windows FIPS
    # mode on, which throws on MD5. The [byte[]] cast is required in PS 5.1.
    param([string]$Text)
    $sha   = [Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
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
    Write-Host "  publish runbook $RunbookName (PowerShell72)"
    Write-Host "  create $ConfigVar with DryRun=true if missing"
    Write-Host "  create $StateVar if missing"
    Write-Host "  migrate a pre-F4 $ConfigVar to tiers F2/F4/F8 (DryRun carried over)"
    Write-Host "  create/refresh schedule $FloorSchedule ($FloorTimeIst IST daily) and link it"
    if ($GoLive)     { Write-Host "  set DryRun=false and clear cooldown and daily count" }
    if ($DryRun)     { Write-Host "  set DryRun=true" }
    if ($ResetState) { Write-Host "  wipe $StateVar including the decision log" }
    if ($SmokeTest)  { Write-Host "  start one log-only job with a sample Quiet signal" }
    Write-Host ''
    Write-Host 'No changes made.' -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------------------
# 1. Publish the runbook
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "=== 1. Runbook $RunbookName ===" -ForegroundColor Cyan
if (-not (Test-Path $RunbookFile)) { throw "Runbook source not found: $RunbookFile" }

$shellFile = New-TempJson @{
    location   = $Location
    properties = @{
        runbookType = 'PowerShell72'
        logVerbose  = $false
        logProgress = $false
        description = "Sizes $CapacityName across F2/F4/F8 when Fabric Activator reports demand. Log-only while $ConfigVar.DryRun is true."
        draft       = @{}
    }
}
try {
    $r = Invoke-Arm -Method PUT -Uri "$Base/runbooks/$RunbookName`?api-version=$ApiVersion" -BodyFile $shellFile
    if (-not $r.Ok) { throw "shell failed: $($r.Output)" }
    Write-Host '    created/updated shell' -ForegroundColor Green
}
finally { Remove-Item $shellFile -ErrorAction SilentlyContinue }

# Draft content is uploaded as raw PowerShell, not wrapped in JSON.
$r = Invoke-Arm -Method PUT -Uri "$Base/runbooks/$RunbookName/draft/content?api-version=$ApiVersion" `
                -BodyFile $RunbookFile -ContentType 'text/powershell'
if (-not $r.Ok) { throw "content upload failed: $($r.Output)" }
Write-Host '    uploaded draft content' -ForegroundColor Green

$r = Invoke-Arm -Method POST -Uri "$Base/runbooks/$RunbookName/publish?api-version=$ApiVersion"
if (-not $r.Ok) { throw "publish failed: $($r.Output)" }
Write-Host '    published' -ForegroundColor Green

# ---------------------------------------------------------------------------
# 2. Config and state variables
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== 2. Variables ===' -ForegroundColor Cyan

$config = Get-VariableObject -Name $ConfigVar
if ($null -eq $config) {
    Set-VariableObject -Name $ConfigVar -Object $InitialConfig -Description 'Tuning for Invoke-FabricAutoscale. DryRun=true means log only.'
    $config = Get-VariableObject -Name $ConfigVar
    Write-Host "    created $ConfigVar (DryRun=true)" -ForegroundColor Green
}
elseif (-not $config.PSObject.Properties['Tiers']) {
    # Pre-F4 config: threshold names changed, so rebuild it and carry DryRun over.
    $migrated = [ordered]@{}
    foreach ($k in $InitialConfig.Keys) { $migrated[$k] = $InitialConfig[$k] }
    $migrated.DryRun = [bool]$config.DryRun
    if ($config.PSObject.Properties['Recipients']) { $migrated.Recipients = @($config.Recipients) }
    Set-VariableObject -Name $ConfigVar -Object $migrated -Description 'Tuning for Invoke-FabricAutoscale. DryRun=true means log only.'
    $config = Get-VariableObject -Name $ConfigVar
    Write-Host "    migrated $ConfigVar to tiers $($config.Tiers -join '/') (DryRun=$($config.DryRun))" -ForegroundColor Green
}
else {
    Write-Host "    $ConfigVar exists (DryRun=$($config.DryRun), tiers $($config.Tiers -join '/')) - kept" -ForegroundColor Yellow
}

$state = Get-VariableObject -Name $StateVar
if ($null -eq $state -or $ResetState) {
    Set-VariableObject -Name $StateVar -Object (New-EmptyState) -Description 'Written by Invoke-FabricAutoscale: cooldown, daily count, decision log.'
    $state = Get-VariableObject -Name $StateVar
    if ($ResetState) { Write-Host "    wiped $StateVar" -ForegroundColor Green }
    else             { Write-Host "    created $StateVar" -ForegroundColor Green }
}
else {
    Write-Host "    $StateVar exists ($(@($state.decisions).Count) logged decisions) - kept" -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# 3. Morning floor schedule
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "=== 3. Schedule $FloorSchedule ===" -ForegroundColor Cyan

$r = Invoke-Arm -Method GET -Uri "$Base/schedules/$FloorSchedule`?api-version=$ApiVersion"
if (-not $r.Ok) {
    # Start at the next occurrence of the floor time in IST; Automation needs a future start.
    $ist   = [datetime]::UtcNow.AddMinutes(330)
    $first = $ist.Date + [TimeSpan]::Parse($FloorTimeIst)
    if ($first -le $ist.AddMinutes(10)) { $first = $first.AddDays(1) }
    $bodyFile = New-TempJson @{
        name       = $FloorSchedule
        properties = @{
            description = "Raises $CapacityName to at least $($config.MorningFloorSku) before the batch window. Never lowers it."
            startTime   = $first.ToString('yyyy-MM-ddTHH:mm:00') + '+05:30'
            frequency   = 'Day'
            interval    = 1
            timeZone    = 'Asia/Kolkata'
        }
    }
    try {
        $r = Invoke-Arm -Method PUT -Uri "$Base/schedules/$FloorSchedule`?api-version=$ApiVersion" -BodyFile $bodyFile
        if (-not $r.Ok) { throw "schedule create failed: $($r.Output)" }
        Write-Host "    created, first run $($first.ToString('yyyy-MM-dd HH:mm')) IST" -ForegroundColor Green
    }
    finally { Remove-Item $bodyFile -ErrorAction SilentlyContinue }
}
else {
    Write-Host '    exists - kept' -ForegroundColor Yellow
}

$floorLinkId = Get-DeterministicGuid "scanb/$RunbookName/$FloorSchedule"
$r = Invoke-Arm -Method GET -Uri "$Base/jobSchedules/$floorLinkId`?api-version=$ApiVersion"
if ($r.Ok) {
    Write-Host '    already linked' -ForegroundColor Yellow
}
else {
    $bodyFile = New-TempJson @{
        properties = @{
            schedule   = @{ name = $FloorSchedule }
            runbook    = @{ name = $RunbookName }
            parameters = @{ Signal = 'Floor'; Rule = 'morning-floor'; TargetSku = "$($config.MorningFloorSku)" }
        }
    }
    try {
        $r = Invoke-Arm -Method PUT -Uri "$Base/jobSchedules/$floorLinkId`?api-version=$ApiVersion" -BodyFile $bodyFile
        if (-not $r.Ok) { throw "schedule link failed: $($r.Output)" }
        Write-Host "    linked (Signal=Floor, TargetSku=$($config.MorningFloorSku))" -ForegroundColor Green
    }
    finally { Remove-Item $bodyFile -ErrorAction SilentlyContinue }
}

# ---------------------------------------------------------------------------
# 4. Mode switch
# ---------------------------------------------------------------------------
if ($GoLive -or $DryRun) {
    Write-Host ''
    Write-Host '=== 4. Mode ===' -ForegroundColor Cyan
    $config.DryRun = [bool]$DryRun
    Set-VariableObject -Name $ConfigVar -Object $config -Description 'Tuning for Invoke-FabricAutoscale. DryRun=true means log only.'

    if ($GoLive) {
        # Log-only resizes must not leave a cooldown or a daily count behind.
        $state.lastResizeUtc = $null
        $state.resizesToday  = 0
        Set-VariableObject -Name $StateVar -Object $state -Description 'Written by Invoke-FabricAutoscale: cooldown, daily count, decision log.'
        Write-Host '    LIVE: the next signal can resize the capacity.' -ForegroundColor Magenta
    }
    else {
        Write-Host '    DRY RUN: signals are logged, nothing is resized.' -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 5. Smoke test
# ---------------------------------------------------------------------------
if ($SmokeTest) {
    Write-Host ''
    Write-Host '=== 5. Smoke test ===' -ForegroundColor Cyan

    # Rule "smoke-test" is log-only in every mode, so this is safe while live.
    # Sample Summary-event readings from a nearly idle F8: 5% background rejection
    # is 20% on F2, well under every scale-down threshold.
    $jobId = [guid]::NewGuid().ToString()
    $bodyFile = New-TempJson @{
        properties = @{
            runbook    = @{ name = $RunbookName }
            parameters = @{
                Signal                  = 'Quiet'
                Rule                    = 'smoke-test'
                CapacitySku             = 'F8'
                BaseCapacityUnits       = '8'
                InteractiveDelayPct     = '4'
                InteractiveRejectionPct = '3'
                BackgroundRejectionPct  = '5'
                CapacityUnitMs          = '12000'
            }
        }
    }
    try {
        $r = Invoke-Arm -Method PUT -Uri "$Base/jobs/$jobId`?api-version=$ApiVersion" -BodyFile $bodyFile
        if (-not $r.Ok) { throw "job start failed: $($r.Output)" }
    }
    finally { Remove-Item $bodyFile -ErrorAction SilentlyContinue }
    Write-Host "    started job $jobId"

    $status = ''
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Seconds 10
        $j = Invoke-Arm -Method GET -Uri "$Base/jobs/$jobId`?api-version=$ApiVersion"
        if ($j.Ok) { $status = ($j.Output | ConvertFrom-Json).properties.status }
        Write-Host "    $status"
        if ($status -in 'Completed', 'Failed', 'Stopped', 'Suspended') { break }
    }
    # Job output is plain text; printing it through az crashes on this machine's
    # cp1252 console, so have az write it to a file instead.
    $outFile = [IO.Path]::GetTempFileName()
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & az rest --method get --url "$Base/jobs/$jobId/output?api-version=$ApiVersion" --output-file $outFile 2>&1 | Out-Null }
    finally { $ErrorActionPreference = $prev }
    Write-Host '--- job output ---'
    Write-Host ((Get-Content $outFile -Raw -Encoding UTF8) -replace '[^\x09\x0A\x0D\x20-\x7E]', '?')
    Write-Host '------------------'
    Remove-Item $outFile -ErrorAction SilentlyContinue
    Write-Host 'Expect action "would-resize" with to=F2 (the smoke test never resizes).' -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host '=== Verification ===' -ForegroundColor Cyan
$config = Get-VariableObject -Name $ConfigVar
$mode = 'LIVE'
if ($config.DryRun) { $mode = 'DRY RUN' }
Write-Host "  mode = $mode"

$capUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Fabric/capacities/$CapacityName`?api-version=$ApiVersion"
$r = Invoke-Arm -Method GET -Uri $capUri
if ($r.Ok) {
    $cap = $r.Output | ConvertFrom-Json
    Write-Host "  Fabric capacity $CapacityName : state=$($cap.properties.state) sku=$($cap.sku.name)"
}

Write-Host ''
Write-Host 'Done. Review test-mode decisions with .\Get-FabricAutoscaleReport.ps1' -ForegroundColor Green
