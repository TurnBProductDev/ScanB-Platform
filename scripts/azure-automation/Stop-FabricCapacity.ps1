<#
.SYNOPSIS
    Suspends the ScanB Fabric capacity to stop billing outside working hours.

.DESCRIPTION
    Replacement for StopPowerBIEmbedded, which drove the retired
    powerembeddedtest101 (A1) Power BI Embedded capacity.

    Differences from the Embedded runbook, on purpose:
      * No workspace reassignment to PPU before suspending. CITYFLOWER and SB Mart
        both hold Fabric-native items (lakehouses, warehouses, notebooks,
        pipelines), which cannot be hosted on PPU/shared capacity, so the
        move-to-Pro step the Embedded runbook used is not available here.
        CONSEQUENCE: both workspaces are fully unavailable while the capacity is
        suspended. That is expected, not a fault.
      * Uses Invoke-AzRestMethod against ARM rather than a Fabric PowerShell module.
        Az.Fabric is not imported into this Automation account; Az.Accounts is.

    Runs as the Automation account's system-assigned managed identity, which holds
    Contributor at subscription scope.

.NOTES
    Paired with Start-FabricCapacity. Scheduled via CF_STOP_SCHEDULE (21:30 IST daily).
#>

# Ensures you do not inherit an AzContext in your runbook
Disable-AzContextAutosave -Scope Process | Out-Null

# Connect to Azure with the managed identity
Connect-AzAccount -Identity | Out-Null

# --- CONFIGURATION ---
$CapacityName      = "scanbf2test123456"
$ResourceGroupName = "ScanB"
$SubscriptionId    = "0300da4d-3a63-4241-a129-42b4f8b0c5cc"
$ApiVersion        = "2023-11-01"

# How long to wait for the capacity to reach Paused.
$PollIntervalSeconds = 20
$MaxPolls            = 30

$ResourcePath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Fabric/capacities/$CapacityName"

function Get-FabricCapacityState {
    $resp = Invoke-AzRestMethod -Method GET -Path "$($ResourcePath)?api-version=$ApiVersion"
    if ($resp.StatusCode -ne 200) {
        throw "GET capacity failed with HTTP $($resp.StatusCode): $($resp.Content)"
    }
    return ($resp.Content | ConvertFrom-Json).properties.state
}

try {
    Set-AzContext -Subscription $SubscriptionId | Out-Null

    Write-Output "Step 1: Checking status of Fabric capacity '$CapacityName'..."

    $currentState = Get-FabricCapacityState
    Write-Output " -> Current state: $currentState"

    if ($currentState -eq "Paused") {
        Write-Output " -> [SKIP] Capacity is already Paused. Nothing to suspend."
        Write-Output "--- COMPLETED SUCCESSFULLY ---"
        return
    }

    Write-Output "Step 2: Suspending capacity..."
    $suspend = Invoke-AzRestMethod -Method POST -Path "$ResourcePath/suspend?api-version=$ApiVersion"

    # 200 OK or 202 Accepted are both success; suspend is a long-running operation.
    if ($suspend.StatusCode -notin 200, 202) {
        throw "Suspend failed with HTTP $($suspend.StatusCode): $($suspend.Content)"
    }
    Write-Output " -> Suspend accepted (HTTP $($suspend.StatusCode)). Waiting for Paused..."

    $polls = 0
    do {
        Start-Sleep -Seconds $PollIntervalSeconds
        $currentState = Get-FabricCapacityState
        $polls++
        Write-Output "    poll $polls/$MaxPolls -> $currentState"
    } while ($currentState -ne "Paused" -and $polls -lt $MaxPolls)

    if ($currentState -ne "Paused") {
        throw "Capacity did not reach Paused within $($PollIntervalSeconds * $MaxPolls)s. Last state: $currentState"
    }

    Write-Output "Success: Capacity suspended. Billing stopped."
    Write-Output "--- COMPLETED SUCCESSFULLY ---"
}
catch {
    Write-Error "CRITICAL ERROR: $_"
    throw $_
}
