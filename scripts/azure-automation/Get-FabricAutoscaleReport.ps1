<#
.SYNOPSIS
    Summarises what Invoke-FabricAutoscale decided - the go-live evidence for the
    test week.

.DESCRIPTION
    Read-only. Pulls FabricAutoscale_State from TurnBAutomationAccount and prints:

      * every decision in the window (IST), newest last
      * per day: signals, switches, blocks, flaps, and the time the capacity
        would have spent on F2 vs F8 between resume and pause, as CU-hours
        against the 113.3 CU-h of a full F8 day
      * a go-live checklist

    A "flap" is a switch to F2 followed by a switch back to F8 within 60 minutes:
    it means the Quiet rule fired while load was about to return.

    Smoke-test decisions (rule "smoke-test") are ignored.

.EXAMPLE
    .\Get-FabricAutoscaleReport.ps1
.EXAMPLE
    .\Get-FabricAutoscaleReport.ps1 -Days 3 -Summary
#>
[CmdletBinding()]
param(
    [int]$Days = 7,
    # Per-day summary and checklist only, without the decision list.
    [switch]$Summary
)

$ErrorActionPreference = 'Stop'

$SubscriptionId = '0300da4d-3a63-4241-a129-42b4f8b0c5cc'
$Base = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/ScanB/providers/Microsoft.Automation/automationAccounts/TurnBAutomationAccount"
$ApiVersion = '2023-11-01'

# Must match CF_START_SCHEDULE / CF_STOP_SCHEDULE.
$ResumeIst = [TimeSpan]::Parse('07:20')
$PauseIst  = [TimeSpan]::Parse('21:30')
$FlapMinutes = 60
$CuBySku = @{ F2 = 2; F4 = 4; F8 = 8 }
$IstOffset = [TimeSpan]::FromMinutes(330)

function Get-VariableObject {
    param([string]$Name)
    # 5.1 would turn az's stderr into a terminating error under Stop; use the exit code.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = az rest --method get --url "$Base/variables/$Name`?api-version=$ApiVersion" -o json 2>&1 }
    finally { $ErrorActionPreference = $prev }
    if ($LASTEXITCODE -ne 0) { throw "Could not read $Name. Is it deployed, and are you logged in? $out" }
    $literal = (($out | Out-String) | ConvertFrom-Json).properties.value
    return (($literal | ConvertFrom-Json) | ConvertFrom-Json)
}

function ConvertTo-Ist {
    param($Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() + $IstOffset }
    $utc = [datetime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal')
    return $utc + $IstOffset
}

$config = Get-VariableObject 'FabricAutoscale_Config'
$state  = Get-VariableObject 'FabricAutoscale_State'

$nowIst = [datetime]::UtcNow + $IstOffset
$fromDay = $nowIst.Date.AddDays(-($Days - 1))

$rows = @(
    @($state.decisions) | Where-Object { $_ -and $_.rule -ne 'smoke-test' } | ForEach-Object {
        $ist = ConvertTo-Ist $_.t
        [pscustomobject]@{
            Ist    = $ist
            Day    = $ist.Date
            Signal = $_.signal
            Rule   = $_.rule
            From   = $_.from
            To     = $_.to
            Action = $_.action
            Reason = $_.reason
        }
    } | Where-Object { $_.Day -ge $fromDay } | Sort-Object Ist
)

$mode = 'LIVE'
if ($config.DryRun) { $mode = 'DRY RUN (test mode)' }
Write-Host ''
Write-Host "Fabric autoscale report - mode: $mode - last $Days day(s), $($rows.Count) decision(s)" -ForegroundColor Cyan

if ($rows.Count -eq 0) {
    Write-Host 'No decisions yet. Check the Activator rules are started and the flow ran (Automation account > Jobs).' -ForegroundColor Yellow
    exit 0
}

if (-not $Summary) {
    Write-Host ''
    $rows | Format-Table -AutoSize -Wrap `
        @{ n = 'IST'; e = { $_.Ist.ToString('ddd dd MMM HH:mm') } },
        Signal, Rule,
        @{ n = 'Switch'; e = { if ($_.To) { "$($_.From)->$($_.To)" } else { '' } } },
        Action,
        @{ n = 'Reason'; e = { if ($_.Reason.Length -gt 80) { $_.Reason.Substring(0, 77) + '...' } else { $_.Reason } } }
}

# --- per-day simulation ------------------------------------------------------
$switchActions = @('would-resize', 'resized')
$days = @()
foreach ($g in ($rows | Group-Object { $_.Day.ToString('yyyy-MM-dd') } | Sort-Object Name)) {
    $dayRows  = @($g.Group)
    $switches = @($dayRows | Where-Object { $_.Action -in $switchActions })
    $dayStart = $dayRows[0].Day

    # A flap is a step down followed by a step back up within the flap window.
    $flaps = 0
    for ($i = 1; $i -lt $switches.Count; $i++) {
        $prev = $switches[$i - 1]; $curr = $switches[$i]
        if ($CuBySku[$prev.To] -lt $CuBySku[$prev.From] -and $CuBySku[$curr.To] -gt $CuBySku[$curr.From] -and
            ($curr.Ist - $prev.Ist).TotalMinutes -le $FlapMinutes) { $flaps++ }
    }

    # Walk the active window from resume to pause (or now, for today), starting at
    # the size the first decision saw.
    $windowStart = $dayStart + $ResumeIst
    $windowEnd   = $dayStart + $PauseIst
    if ($nowIst -lt $windowEnd) { $windowEnd = $nowIst }
    $minutes = @{ F2 = 0.0; F4 = 0.0; F8 = 0.0 }
    $sku    = 'F8'
    $firstKnown = @($dayRows | Where-Object { $CuBySku.ContainsKey("$($_.From)") } | Select-Object -First 1)
    if ($firstKnown.Count -gt 0) { $sku = $firstKnown[0].From }
    $cursor = $windowStart
    foreach ($s in $switches) {
        $at = $s.Ist
        if ($at -lt $windowStart) { $at = $windowStart }
        if ($at -gt $windowEnd)   { $at = $windowEnd }
        if ($at -gt $cursor) { $minutes[$sku] += ($at - $cursor).TotalMinutes; $cursor = $at }
        $sku = $s.To
    }
    if ($windowEnd -gt $cursor) { $minutes[$sku] += ($windowEnd - $cursor).TotalMinutes }

    $activeHours = ($minutes.F2 + $minutes.F4 + $minutes.F8) / 60
    $cuh = ($minutes.F2 * $CuBySku.F2 + $minutes.F4 * $CuBySku.F4 + $minutes.F8 * $CuBySku.F8) / 60
    $fullF8 = $activeHours * $CuBySku.F8

    $days += [pscustomobject]@{
        Day        = $dayStart.ToString('ddd dd MMM')
        Busy       = @($dayRows | Where-Object { $_.Signal -in 'Busy', 'Overloaded' }).Count
        Quiet      = @($dayRows | Where-Object { $_.Signal -eq 'Quiet' }).Count
        Switches   = $switches.Count
        Blocked    = @($dayRows | Where-Object { $_.Action -eq 'blocked' }).Count
        Rejected   = @($dayRows | Where-Object { $_.Action -eq 'rejected' }).Count
        Flaps      = $flaps
        CapHit     = [bool]@($dayRows | Where-Object { $_.Reason -like 'daily cap*' }).Count
        HoursF2    = [math]::Round($minutes.F2 / 60, 1)
        HoursF4    = [math]::Round($minutes.F4 / 60, 1)
        HoursF8    = [math]::Round($minutes.F8 / 60, 1)
        CuHours    = [math]::Round($cuh, 1)
        SavingPct  = if ($fullF8 -gt 0) { [math]::Round((1 - $cuh / $fullF8) * 100) } else { 0 }
        Failed     = @($dayRows | Where-Object { $_.Action -eq 'failed' }).Count
    }
}

Write-Host ''
Write-Host 'Per day (active window 07:20-21:30 IST; a full F8 day is 113.3 CU-h)' -ForegroundColor Cyan
$days | Format-Table -AutoSize Day, Busy, Quiet, Switches, Blocked, Rejected, Flaps, CapHit, HoursF2, HoursF4, HoursF8, CuHours,
    @{ n = 'Saving'; e = { "$($_.SavingPct)%" } }

# --- health checks -----------------------------------------------------------
$checks = @(
    [pscustomobject]@{ Check = 'No more than 1 flap on any day';        Pass = -not @($days | Where-Object { $_.Flaps -gt 1 }).Count }
    [pscustomobject]@{ Check = 'Daily cap never reached';               Pass = -not @($days | Where-Object { $_.CapHit }).Count }
    [pscustomobject]@{ Check = 'Some time below F8 on most days';       Pass = @($days | Where-Object { $_.HoursF2 + $_.HoursF4 -ge 1 }).Count -ge [math]::Ceiling($days.Count / 2) }
    [pscustomobject]@{ Check = 'No failed jobs';                        Pass = -not @($days | Where-Object { $_.Failed -gt 0 }).Count }
)
Write-Host 'Health checks' -ForegroundColor Cyan
foreach ($c in $checks) {
    if ($c.Pass) { Write-Host "  [PASS] $($c.Check)" -ForegroundColor Green }
    else         { Write-Host "  [FAIL] $($c.Check)" -ForegroundColor Red }
}
Write-Host ''
Write-Host 'Also look by eye: does any switch to F2 sit shortly before a known job (12:00 refreshes, 21:00 notebook)?'
if ($config.DryRun) {
    Write-Host 'When every check passes: .\Deploy-FabricAutoscale.ps1 -GoLive' -ForegroundColor Yellow
}
