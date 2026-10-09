<#
.SYNOPSIS
    Resumes the ScanB Fabric capacity so the analytics workspaces are live.

.DESCRIPTION
    Replacement for Start-PowerBIEmbedded, which drove the retired
    powerembeddedtest101 (A1) Power BI Embedded capacity.

    Differences from the Embedded runbook, on purpose:
      * No workspace reassignment. CITYFLOWER and SB Mart both hold Fabric-native
        items (lakehouses, warehouses, notebooks, pipelines), which cannot live on
        PPU/shared capacity, so parking them off-capacity is not possible. Resuming
        the capacity is what brings both workspaces back.
      * Uses Invoke-AzRestMethod against ARM rather than a Fabric PowerShell module.
        Az.Fabric is not imported into this Automation account; Az.Accounts is.

    Runs as the Automation account's system-assigned managed identity, which holds
    Contributor at subscription scope.

.NOTES
    Paired with Stop-FabricCapacity. Scheduled via CF_START_SCHEDULE (07:20 IST daily).
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

# Fabric capacity id as Power BI sees it, for the post-resume assignment check.
$FabricCapacityId  = "52493f77-3a45-4571-917b-637ea0b355ba"

# Workspaces expected to be served by this capacity.
$WorkspaceList = @(
    @{ Id = "6d383900-b84d-4bce-afb4-b95453bee00a"; Name = "CITYFLOWER" },
    @{ Id = "2829a4af-2e07-4b43-b913-0a829a06bef4"; Name = "SB Mart"   }
)

# How long to wait for the capacity to reach Active.
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

    # ---------------------------------------------------------
    # STEP 1: RESUME THE CAPACITY
    # ---------------------------------------------------------
    Write-Output "Step 1: Checking status of Fabric capacity '$CapacityName'..."

    $currentState = Get-FabricCapacityState
    Write-Output " -> Current state: $currentState"

    if ($currentState -eq "Active") {
        Write-Output " -> [SKIP] Capacity is already Active. Nothing to resume."
    }
    else {
        Write-Output " -> Resuming..."
        $resume = Invoke-AzRestMethod -Method POST -Path "$ResourcePath/resume?api-version=$ApiVersion"

        # 200 OK or 202 Accepted are both success; resume is a long-running operation.
        if ($resume.StatusCode -notin 200, 202) {
            throw "Resume failed with HTTP $($resume.StatusCode): $($resume.Content)"
        }
        Write-Output " -> Resume accepted (HTTP $($resume.StatusCode)). Waiting for Active..."

        $polls = 0
        do {
            Start-Sleep -Seconds $PollIntervalSeconds
            $currentState = Get-FabricCapacityState
            $polls++
            Write-Output "    poll $polls/$MaxPolls -> $currentState"
        } while ($currentState -ne "Active" -and $polls -lt $MaxPolls)

        if ($currentState -ne "Active") {
            throw "Capacity did not reach Active within $($PollIntervalSeconds * $MaxPolls)s. Last state: $currentState"
        }
    }

    Write-Output " -> Capacity is Ready (State: $currentState)."

    # ---------------------------------------------------------
    # STEP 2: VERIFY WORKSPACE ASSIGNMENT (best effort)
    # ---------------------------------------------------------
    # Informational only. The capacity being Active is what matters; this block
    # surfaces drift if somebody moved a workspace off the capacity by hand. It
    # must never fail the runbook, because it depends on the managed identity
    # having Power BI workspace access, which the resume itself does not need.
    Write-Output "Step 2: Verifying workspace assignment (informational)..."
    try {
        $pbiToken = Get-AzAccessToken -ResourceUrl "https://analysis.windows.net/powerbi/api"
        $authHeader = @{
            'Content-Type'  = 'application/json'
            'Authorization' = "Bearer $($pbiToken.Token)"
        }

        foreach ($ws in $WorkspaceList) {
            try {
                $info = Invoke-RestMethod -Uri "https://api.powerbi.com/v1.0/myorg/groups/$($ws.Id)" -Method Get -Headers $authHeader
                if ($info.capacityId -eq $FabricCapacityId) {
                    Write-Output "    [OK] $($ws.Name) is on the Fabric capacity."
                }
                else {
                    Write-Warning "    [DRIFT] $($ws.Name) is on capacity '$($info.capacityId)', expected '$FabricCapacityId'. Reassign it manually."
                }
            }
            catch {
                Write-Warning "    [SKIP] Could not read workspace $($ws.Name): $_"
            }
        }
    }
    catch {
        Write-Warning " -> Skipping assignment check (no Power BI token): $_"
    }

    Write-Output "--- COMPLETED SUCCESSFULLY ---"
}
catch {
    Write-Error "CRITICAL ERROR: $_"
    throw $_
}
