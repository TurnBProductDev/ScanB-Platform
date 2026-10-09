<#
.SYNOPSIS
    Sizes the ScanB Fabric capacity across F2, F4 and F8 on demand.

.DESCRIPTION
    Started by Fabric Activator (through a Power Automate "Create job" action or
    an Automation webhook) when a rule over the capacity overview events fires,
    and by the daily morning-floor schedule. Activator reports what it saw; this
    runbook owns every decision.

    Signals
      Busy       the current size is running hot         -> smallest larger size that is comfortable
      Overloaded a State event reported throttling       -> largest size
      Quiet      a smaller size could carry the load     -> smallest smaller size that is comfortable
      Floor      schedule: raise to at least -TargetSku  -> never lowers

    Why readings are re-expressed per size
      Event percentages are relative to the SKU the capacity ran at when the event
      was emitted. Background work is smoothed over 24 hours, so committed CU
      survives a resize while the budget changes: 15% of F8 is 30% of F4 and 60%
      of F2. Every reading is projected onto a candidate size with
      (pct * baseCapacityUnits / candidateCU) before it is compared.

      "Comfortable" on a size means, projected onto that size:
        background rejection  < DownBackgroundRejectionPct
        interactive rejection < DownInteractiveRejectionPct
        30-second utilisation < DownUtilisationPct
      "Running hot" on the current size means:
        interactive delay >= UpInteractiveDelayPct, or
        background rejection >= UpBackgroundRejectionPct
      The gap between the two is what stops a resize from immediately
      qualifying for the opposite resize.

    Hard guards
      * never resumes a paused capacity (Start-/Stop-FabricCapacity own that)
      * inside the protected batch window, never below MorningFloorSku
      * no scale-down just before the nightly pause
      * cooldown after any resize before scaling down again
      * a daily cap, after which only scale-up is allowed
      * the rule name "smoke-test" is always log-only, in any mode
      * jobs run one at a time, so rules firing together cannot race

    DryRun=true in FabricAutoscale_Config makes every decision log-only.

    Runs as the Automation account's system-assigned managed identity.

.NOTES
    Runtime: PowerShell 7.2 (uses -SkipHttpErrorCheck).
    Parameters are strings on purpose: Automation passes them as JSON values and
    Power Automate sends everything as text.
#>

param(
    [object] $WebhookData,
    [string] $Signal,
    [string] $Rule,
    [string] $TargetSku,
    [string] $CapacitySku,
    [string] $BaseCapacityUnits,
    [string] $InteractiveDelayPct,
    [string] $InteractiveRejectionPct,
    [string] $BackgroundRejectionPct,
    [string] $CapacityUnitMs
)

$ErrorActionPreference = 'Stop'

# An unattended runbook that dies with a bare .NET message is hard to debug from
# the job history, so always surface the line and the source text.
trap {
    $ii = $_.InvocationInfo
    Write-Output "RUNBOOK FAILURE line $($ii.ScriptLineNumber): $($_.Exception.Message)"
    Write-Output "  source: $($ii.Line.Trim())"
    break
}

# --- CONFIGURATION ---
$CapacityName      = "scanbf2test123456"
$ResourceGroupName = "ScanB"
$SubscriptionId    = "0300da4d-3a63-4241-a129-42b4f8b0c5cc"
$ApiVersion        = "2023-11-01"
$AutomationAccount = "TurnBAutomationAccount"
$RunbookName       = "Invoke-FabricAutoscale"

$ConfigVar     = "FabricAutoscale_Config"
$StateVar      = "FabricAutoscale_State"
$MailerVar     = "CostMonitor_MailerUrl"   # shared Logic App mailer
$CostConfigVar = "CostMonitor_Config"      # recipients fall back to the cost monitor's list

$CuBySku   = @{ F2 = 2; F4 = 4; F8 = 8; F16 = 16; F32 = 32; F64 = 64 }
$WindowMs  = 30000                          # Summary events cover 30-second windows
$MaxLoggedDecisions = 400
$IstOffset = [TimeSpan]::FromMinutes(330)   # IST has no daylight saving

# Tuning defaults. Anything present in FabricAutoscale_Config overrides these;
# a missing config variable means dry run, never live.
$Defaults = [ordered]@{
    DryRun                        = $true
    Tiers                         = @("F2", "F4", "F8")
    MorningFloorSku               = "F4"
    ProtectedWindowStartIst       = "08:30"
    ProtectedWindowEndIst         = "13:00"
    PauseTimeIst                  = "21:30"
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

$ResourcePath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Fabric/capacities/$CapacityName"

# ---------------------------------------------------------------- helpers ---

function ConvertTo-Number {
    param([string] $Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $n = 0.0
    $ok = [double]::TryParse($Text.Trim(), [Globalization.NumberStyles]::Float,
                             [Globalization.CultureInfo]::InvariantCulture, [ref]$n)
    if ($ok) { return $n }
    return $null
}

function ConvertTo-UtcDate {
    # PowerShell 7 ConvertFrom-Json already turns ISO strings into DateTime.
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    return [datetime]::Parse("$Value", [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]'AssumeUniversal, AdjustToUniversal')
}

function Get-Projection {
    # The event's readings re-expressed as percentages of a candidate size.
    param([string] $Sku)
    $cuOfSku = [double]$CuBySku[$Sku]
    $scale = if ($null -ne $base) { $base / $cuOfSku } else { $null }
    $p = [ordered]@{ sku = $Sku; interactiveDelay = $null; interactiveRejection = $null; backgroundRejection = $null; utilisation = $null }
    if ($null -ne $scale) {
        if ($null -ne $idelay) { $p.interactiveDelay     = [math]::Round($idelay * $scale, 1) }
        if ($null -ne $irej)   { $p.interactiveRejection = [math]::Round($irej   * $scale, 1) }
        if ($null -ne $bgrej)  { $p.backgroundRejection  = [math]::Round($bgrej  * $scale, 1) }
    }
    if ($null -ne $cu) { $p.utilisation = [math]::Round($cu / ($cuOfSku * $WindowMs) * 100, 1) }
    return [pscustomobject]$p
}

function Test-Comfortable {
    param($P)
    return ($null -ne $P.backgroundRejection -and $null -ne $P.interactiveRejection -and $null -ne $P.utilisation -and
            $P.backgroundRejection  -lt [double]$cfg.DownBackgroundRejectionPct -and
            $P.interactiveRejection -lt [double]$cfg.DownInteractiveRejectionPct -and
            $P.utilisation          -lt [double]$cfg.DownUtilisationPct)
}

function Test-RunningHot {
    param($P)
    return (($null -ne $P.interactiveDelay    -and $P.interactiveDelay    -ge [double]$cfg.UpInteractiveDelayPct) -or
            ($null -ne $P.backgroundRejection -and $P.backgroundRejection -ge [double]$cfg.UpBackgroundRejectionPct))
}

function Format-Projection {
    param($P)
    return "$($P.sku): background $($P.backgroundRejection)%, interactive $($P.interactiveRejection)%, delay $($P.interactiveDelay)%, utilisation $($P.utilisation)%"
}

function Get-Capacity {
    $resp = Invoke-AzRestMethod -Method GET -Path "$($ResourcePath)?api-version=$ApiVersion"
    if ($resp.StatusCode -ne 200) {
        throw "GET capacity failed with HTTP $($resp.StatusCode): $($resp.Content)"
    }
    return ($resp.Content | ConvertFrom-Json)
}

function Set-CapacitySku {
    param([string] $Sku)
    $payload = @{ sku = @{ name = $Sku; tier = "Fabric" } } | ConvertTo-Json -Compress
    $resp = Invoke-AzRestMethod -Method PATCH -Path "$($ResourcePath)?api-version=$ApiVersion" -Payload $payload

    # 200 OK or 202 Accepted are both success; a resize is a long-running operation.
    if ($resp.StatusCode -notin 200, 202) {
        throw "Resize to $Sku failed with HTTP $($resp.StatusCode): $($resp.Content)"
    }
    for ($i = 1; $i -le 20; $i++) {
        Start-Sleep -Seconds 15
        $c = Get-Capacity
        Write-Output "    poll $i/20 -> sku=$($c.sku.name) provisioning=$($c.properties.provisioningState)"
        if ($c.sku.name -eq $Sku -and $c.properties.provisioningState -eq 'Succeeded') { return }
    }
    throw "Capacity did not settle on $Sku within 300s."
}

function Wait-ForTurn {
    # Two rules can fire within seconds of each other. Jobs queue behind any
    # earlier job of this runbook so state reads and writes never interleave.
    try {
        $me = "$($PSPrivateMetadata.JobId)"
        if (-not $me) { return $true }
        $mine = Get-AzAutomationJob -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccount -Id $me
        for ($i = 0; $i -lt 18; $i++) {
            $ahead = Get-AzAutomationJob -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccount `
                                         -RunbookName $RunbookName -StartTime ([DateTimeOffset]::UtcNow.AddMinutes(-30)) |
                     Where-Object {
                         "$($_.JobId)" -ne $me -and
                         $_.Status -in 'New', 'Activating', 'Running', 'Resuming' -and
                         $_.CreationTime -lt $mine.CreationTime
                     }
            if (-not $ahead) { return $true }
            Start-Sleep -Seconds 10
        }
        return $false
    }
    catch {
        Write-Warning "Could not check for concurrent jobs, continuing: $($_.Exception.Message)"
        return $true
    }
}

function Send-Notice {
    param([string] $Subject, [string] $Html)
    if (-not $cfg.Notify) { return }
    try {
        $recipients = @($cfg.Recipients | Where-Object { $_ })
        if ($recipients.Count -eq 0) {
            $costCfg = Get-AutomationVariable -Name $CostConfigVar -ErrorAction Stop | ConvertFrom-Json
            $recipients = @($costCfg.recipients | Where-Object { $_ })
        }
        if ($recipients.Count -eq 0) { Write-Warning "No recipients configured; notice not sent."; return }

        $url = Get-AutomationVariable -Name $MailerVar -ErrorAction Stop
        $payload = @{
            to         = ($recipients -join ';')
            subject    = $Subject
            html       = $Html
            importance = 'normal'
        } | ConvertTo-Json -Depth 4
        $r = Invoke-WebRequest -Method Post -Uri $url -ContentType 'application/json' `
                               -Body $payload -UseBasicParsing -SkipHttpErrorCheck
        if ($r.StatusCode -ge 300) { Write-Warning "Mailer returned HTTP $($r.StatusCode)." }
    }
    catch {
        Write-Warning "Notice not sent: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------ input ---

$InputNames = 'Signal', 'Rule', 'TargetSku', 'CapacitySku', 'BaseCapacityUnits', 'InteractiveDelayPct',
              'InteractiveRejectionPct', 'BackgroundRejectionPct', 'CapacityUnitMs'

if ($WebhookData) {
    # Allow testing with WebhookData pasted as a JSON string.
    if (-not $WebhookData.RequestBody) { $WebhookData = $WebhookData | ConvertFrom-Json }
    $body = $WebhookData.RequestBody | ConvertFrom-Json
    foreach ($name in $InputNames) {
        if ($null -ne $body.$name -and "$($body.$name)" -ne '') {
            Set-Variable -Name $name -Value ([string]$body.$name)
        }
    }
}

# Activator wraps every inserted property token in a zero-width space (U+200B)
# plus padding, e.g. "​ 13.30425  ". Trim() does not remove U+200B, so
# strip Unicode format characters from every input before using it.
foreach ($name in $InputNames) {
    $raw = Get-Variable -Name $name -ValueOnly
    Set-Variable -Name $name -Value (("$raw" -replace '\p{Cf}', '').Trim())
}

$Signal = @('Busy', 'Overloaded', 'Quiet', 'Floor') | Where-Object { $_ -eq $Signal } | Select-Object -First 1
if (-not $Signal) { throw "Signal must be Busy, Overloaded, Quiet or Floor." }
if (-not $Rule) { $Rule = "(unnamed)" }
$isSmokeTest = $Rule -eq 'smoke-test'

$eventSku  = $CapacitySku.ToUpper()
$TargetSku = $TargetSku.ToUpper()
$base = ConvertTo-Number $BaseCapacityUnits
if ($null -eq $base -and $CuBySku.ContainsKey($eventSku)) { $base = [double]$CuBySku[$eventSku] }
$idelay = ConvertTo-Number $InteractiveDelayPct
$irej   = ConvertTo-Number $InteractiveRejectionPct
$bgrej  = ConvertTo-Number $BackgroundRejectionPct
$cu     = ConvertTo-Number $CapacityUnitMs

# ------------------------------------------------------------------- main ---

Disable-AzContextAutosave -Scope Process | Out-Null
Connect-AzAccount -Identity | Out-Null
Set-AzContext -Subscription $SubscriptionId | Out-Null

$cfg = [pscustomobject]$Defaults
$rawCfg = Get-AutomationVariable -Name $ConfigVar -ErrorAction SilentlyContinue
if ($rawCfg) {
    $stored = $rawCfg | ConvertFrom-Json
    foreach ($p in $stored.PSObject.Properties) {
        if ($cfg.PSObject.Properties[$p.Name]) { $cfg.($p.Name) = $p.Value }
    }
}
else {
    Write-Warning "$ConfigVar is missing; running on defaults (dry run)."
}
$tiers = @($cfg.Tiers | ForEach-Object { "$_".ToUpper() } | Where-Object { $CuBySku.ContainsKey($_) } |
           Sort-Object { $CuBySku[$_] })
if ($tiers.Count -lt 2) { throw "Config Tiers must list at least two known SKUs." }
$floorSku = "$($cfg.MorningFloorSku)".ToUpper()

$logOnly = [bool]$cfg.DryRun -or $isSmokeTest
$mode = if ($cfg.DryRun) { "DRY RUN" } elseif ($isSmokeTest) { "LIVE, smoke test is log-only" } else { "LIVE" }
Write-Output "Invoke-FabricAutoscale [$mode] signal=$Signal rule=$Rule eventSku=$eventSku tiers=$($tiers -join '/')"

if (-not (Wait-ForTurn)) {
    Write-Output "Another autoscale job is still running after 3 minutes; skipping this signal."
    return
}

$nowUtc   = [datetime]::UtcNow
$nowIst   = $nowUtc + $IstOffset
$todayIst = $nowIst.ToString('yyyy-MM-dd')

$state = [ordered]@{
    day           = $todayIst
    resizesToday  = 0
    lastResizeUtc = $null
    capNoticeDay  = $null
    decisions     = @()
}
$rawState = Get-AutomationVariable -Name $StateVar -ErrorAction SilentlyContinue
if ($rawState) {
    try {
        $s = $rawState | ConvertFrom-Json
        foreach ($k in @($state.Keys)) { if ($null -ne $s.$k) { $state[$k] = $s.$k } }
    }
    catch { Write-Warning "State unreadable, starting fresh: $($_.Exception.Message)" }
}
if ("$($state.day)" -ne $todayIst) {
    $state.day          = $todayIst
    $state.resizesToday = 0
}

$cap        = Get-Capacity
$currentSku = $cap.sku.name
$capState   = $cap.properties.state
$currentIdx = [array]::IndexOf($tiers, $currentSku)
$topSku     = $tiers[-1]

$tod         = $nowIst.TimeOfDay
$inProtected = $tod -ge [TimeSpan]::Parse($cfg.ProtectedWindowStartIst) -and $tod -lt [TimeSpan]::Parse($cfg.ProtectedWindowEndIst)
$pauseAt     = [TimeSpan]::Parse($cfg.PauseTimeIst)
$nearPause   = $tod -ge $pauseAt.Subtract([TimeSpan]::FromMinutes([double]$cfg.NoScaleDownBeforePauseMinutes)) -and $tod -lt $pauseAt

$lastResize = ConvertTo-UtcDate $state.lastResizeUtc
$minsSinceResize = if ($lastResize) { ($nowUtc - $lastResize).TotalMinutes } else { [double]::MaxValue }

$onCurrent = if ($currentIdx -ge 0) { Get-Projection $currentSku } else { $null }
$target = $null
$action = 'none'
$reason = ''

if ($capState -ne 'Active') {
    $action = 'skip'
    $reason = "capacity is $capState; this runbook never resumes it"
}
elseif ($currentIdx -lt 0) {
    $action = 'skip'
    $reason = "capacity is $currentSku, outside the managed tiers $($tiers -join '/'); leaving it alone"
}
elseif ($Signal -eq 'Floor') {
    $floorIdx = [array]::IndexOf($tiers, $TargetSku)
    if ($floorIdx -lt 0) {
        $action = 'rejected'
        $reason = "Floor signal needs -TargetSku from $($tiers -join '/'); got '$TargetSku'"
    }
    elseif ($currentIdx -ge $floorIdx) {
        $reason = "already at or above the $TargetSku floor"
    }
    else {
        $target = $TargetSku
        $action = 'resize'
        $reason = "morning floor: at least $TargetSku for the batch window"
    }
}
elseif ($Signal -eq 'Overloaded') {
    if ($currentSku -eq $topSku) {
        $reason = "already $topSku"
        if (-not $logOnly) {
            Send-Notice "Fabric capacity $CapacityName is overloaded at $topSku" `
                "<p>Activator rule <b>$Rule</b> reported throttling while the capacity is already $topSku, the autoscale ceiling. Check the Capacity Metrics app for the operations responsible.</p>"
        }
    }
    elseif ($minsSinceResize -lt [double]$cfg.MinMinutesBetweenResizes) {
        $action = 'deferred'
        $reason = "last resize was $([math]::Round($minsSinceResize, 1)) min ago"
    }
    else {
        $target = $topSku
        $action = 'resize'
        $reason = "capacity reported throttling"
    }
}
elseif ($Signal -eq 'Busy') {
    if (-not (Test-RunningHot $onCurrent)) {
        $action = 'rejected'
        $reason = "Busy signal, but $currentSku is not running hot ($(Format-Projection $onCurrent))"
    }
    elseif ($currentSku -eq $topSku) {
        $reason = "already $topSku ($(Format-Projection $onCurrent))"
    }
    elseif ($minsSinceResize -lt [double]$cfg.MinMinutesBetweenResizes) {
        $action = 'deferred'
        $reason = "last resize was $([math]::Round($minsSinceResize, 1)) min ago"
    }
    else {
        # Smallest larger size that carries the load comfortably, else the largest.
        $target = $topSku
        for ($i = $currentIdx + 1; $i -lt $tiers.Count; $i++) {
            if (Test-Comfortable (Get-Projection $tiers[$i])) { $target = $tiers[$i]; break }
        }
        $action = 'resize'
        $reason = "$currentSku running hot ($(Format-Projection $onCurrent)); $(Format-Projection (Get-Projection $target))"
    }
}
else {
    # Quiet: smallest smaller size that carries the load comfortably.
    for ($i = 0; $i -lt $currentIdx; $i++) {
        if (Test-Comfortable (Get-Projection $tiers[$i])) { $target = $tiers[$i]; break }
    }

    $missing = @(@{ 'interactive rejection' = $irej; 'background rejection' = $bgrej; 'utilisation' = $cu; 'base capacity units' = $base }.GetEnumerator() |
                 Where-Object { $null -eq $_.Value } | ForEach-Object { $_.Key })

    if ($currentIdx -eq 0) {
        $reason = "already $currentSku, the smallest size"
    }
    elseif ($missing.Count -gt 0) {
        $action = 'rejected'
        $target = $null
        $reason = "Quiet signal is missing readings: $($missing -join ', ')"
    }
    elseif (-not $target) {
        $action = 'rejected'
        $below  = $tiers[$currentIdx - 1]
        $reason = "no smaller size fits: $(Format-Projection (Get-Projection $below))"
    }
    else {
        # Inside the batch window, never go below the floor.
        if ($inProtected -and [array]::IndexOf($tiers, $floorSku) -gt [array]::IndexOf($tiers, $target)) {
            $target = $floorSku
        }
        if ([array]::IndexOf($tiers, $target) -ge $currentIdx) {
            $action = 'blocked'
            $reason = "inside protected window $($cfg.ProtectedWindowStartIst)-$($cfg.ProtectedWindowEndIst) IST; not going below $floorSku"
            $target = $null
        }
        elseif ($nearPause) {
            $action = 'blocked'
            $reason = "within $($cfg.NoScaleDownBeforePauseMinutes) min of the $($cfg.PauseTimeIst) IST pause"
        }
        elseif ($minsSinceResize -lt [double]$cfg.ScaleDownCooldownMinutes) {
            $action = 'blocked'
            $reason = "cooldown: last resize $([math]::Round($minsSinceResize)) min ago"
        }
        elseif ([int]$state.resizesToday -ge [int]$cfg.MaxResizesPerDay) {
            $action = 'blocked'
            $reason = "daily cap of $($cfg.MaxResizesPerDay) resizes reached; holding $currentSku"
            if (-not $logOnly -and "$($state.capNoticeDay)" -ne $todayIst) {
                $state.capNoticeDay = $todayIst
                Send-Notice "Fabric autoscale hit its daily cap" `
                    "<p>$CapacityName has been resized $($state.resizesToday) times today, so autoscale will not scale it down again until tomorrow. Frequent switching usually means the thresholds need widening.</p>"
            }
        }
        else {
            $action = 'resize'
            $reason = "$(Format-Projection (Get-Projection $target))"
        }
    }
}

$failure = $null
if ($action -eq 'resize') {
    if ($logOnly) {
        $action = 'would-resize'
    }
    else {
        Write-Output "Resizing $CapacityName $currentSku -> $target ($reason)..."
        try {
            Set-CapacitySku -Sku $target
            $action = 'resized'
            $state.lastResizeUtc = $nowUtc.ToString('o')
            $state.resizesToday  = [int]$state.resizesToday + 1
            Send-Notice "Fabric capacity switched $currentSku to $target" `
                "<p>$CapacityName moved from $currentSku to <b>$target</b> at $($nowIst.ToString('HH:mm')) IST.</p><p>Signal: $Signal (rule $Rule)<br>$reason</p>"
        }
        catch {
            $action  = 'failed'
            $failure = $_.Exception.Message
            $reason  = "$reason | resize failed: $failure"
            Send-Notice "Fabric autoscale failed to switch to $target" "<p>$failure</p>"
        }
    }
}

$entry = [pscustomobject][ordered]@{
    t         = $nowUtc.ToString('o')
    signal    = $Signal
    rule      = $Rule
    eventSku  = $eventSku
    from      = $currentSku
    to        = $target
    action    = $action
    reason    = $reason
    dryRun    = [bool]$cfg.DryRun
    onCurrent = $onCurrent
}
$state.decisions = @(@($state.decisions) + @($entry) | Select-Object -Last $MaxLoggedDecisions)

try {
    Set-AutomationVariable -Name $StateVar -Value ($state | ConvertTo-Json -Depth 6 -Compress) -ErrorAction Stop
}
catch {
    Write-Warning "Could not persist $StateVar (run Deploy-FabricAutoscale.ps1 to create it): $($_.Exception.Message)"
}

Write-Output ("DECISION " + ($entry | ConvertTo-Json -Compress -Depth 4))
if ($failure) { throw "Resize failed: $failure" }
Write-Output "--- COMPLETED ---"
