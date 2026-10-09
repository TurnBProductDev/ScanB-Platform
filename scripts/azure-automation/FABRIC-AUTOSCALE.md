# Fabric F2/F4/F8 autoscale

Sizes `scanbf2test123456` across **F2, F4 and F8** based on load. It sits on top
of the daily resume at 07:20 IST and pause at 21:30 IST
(`Start-/Stop-FabricCapacity`), which it never touches.

```
Fabric capacity ──30s events──> Eventstream ──> Activator rules
                                                     │  rule fires
                                                     v
                                  Power Automate flow "Fabric autoscale"
                                                     │  Create job
                                                     v
                         Azure Automation: Invoke-FabricAutoscale
                         (decides, applies guards, logs, resizes, emails)
                                                     ^
                   08:30 IST schedule FabricAutoscale_MorningFloor (Floor → F4)
```

Why it works this way: Fabric capacities send no metrics to Azure Monitor, so
the old Embedded pattern of alert, then webhook, then runbook has nothing to
trigger on. The load signal comes from Fabric's Real-Time hub instead.

## Files

| File | Runs where | Purpose |
|---|---|---|
| `Invoke-FabricAutoscale.ps1` | Automation (PowerShell 7.2) | Receives a signal, decides, resizes, logs |
| `Deploy-FabricAutoscale.ps1` | Your machine | Publishes the runbook, sets up its variables and the morning-floor schedule, switches between live and log-only, smoke test |
| `Get-FabricAutoscaleReport.ps1` | Your machine | Read-only report: decisions, hours per size, CU-hours, health checks |

Runtime settings are stored in two Automation variables:

- `FabricAutoscale_Config`: size list, thresholds, time windows and the
  `DryRun` flag. Edit it in the portal under Automation account > Variables.
  Redeploying keeps your edits.
- `FabricAutoscale_State`: cooldown, the day's resize count and the last 400
  decisions.

## How decisions are made

| Signal | Sent by | What the runbook does |
|---|---|---|
| `Busy` | `busy-*` rules | If the current size is running hot, moves to the **smallest larger size that is comfortable** (F2→F4, or straight to F8 if F4 wouldn't be comfortable either) |
| `Quiet` | `quiet-*` rules | Moves to the **smallest smaller size that is comfortable** (F8→F4, or straight to F2) |
| `Overloaded` | `overloaded` rule (optional) | Fabric reported throttling, so it moves straight to F8 |
| `Floor` | 08:30 IST schedule | Raises the capacity to at least F4 before the batch window. It never lowers it |

Fabric reports each percentage relative to the size running at that moment,
and background work keeps counting for 24 hours. So 15% of F8 is 30% of F4
and 60% of F2. The runbook converts every reading to each candidate size
(`pct × baseCapacityUnits ÷ sizeCU`) before it compares.

| Measured on a size | Running hot (scale up) | Comfortable (OK to scale down to) |
|---|---|---|
| Interactive delay (next 10 min) | ≥ 75% | — |
| Background rejection (next 24 h) | ≥ 60% | < 45% |
| Interactive rejection (next 1 h) | — | < 45% |
| 30-second utilisation | — | < 60% |

The gap between the two columns stops a resize from immediately qualifying
for the opposite resize.

**Guards:**

- It never resumes a paused capacity.
- During the batch window, 08:30–13:00 IST, it never goes below F4.
- It never scales down within 15 minutes of the 21:30 pause.
- It won't scale down within 60 minutes of any resize.
- After 8 resizes in a day, it only scales up.
- It waits at least 5 minutes between resizes.
- A rule named `smoke-test` never resizes, in any mode.

**Emails:** every real resize, a resize that fails, and hitting the daily cap
each send an email through the cost-monitor mailer, to the recipients in
`CostMonitor_Config`. To use different recipients, set `Recipients` in the
config.

---

## Going live

From `ScanB-Platform/scripts/azure-automation/`, signed in with `az login`:

```powershell
.\Deploy-FabricAutoscale.ps1 -WhatIfOnly          # preview
.\Deploy-FabricAutoscale.ps1 -GoLive -SmokeTest   # publish, migrate config, schedule, go live, test
```

The smoke test should end with a `DECISION` line showing `would-resize`. That
means the logic worked; the smoke test itself never resizes.

## Power Automate flow checks

Open the flow **Fabric autoscale** in edit mode, then the **Create job**
action. Every runbook parameter must be an **fx token**, exactly like this:

```
Signal                   triggerBody()?['customProperties/Signal']
Rule                     triggerBody()?['customProperties/Rule']
CapacitySku              triggerBody()?['customProperties/CapacitySku']
BaseCapacityUnits        triggerBody()?['customProperties/BaseCapacityUnits']
InteractiveDelayPct      triggerBody()?['customProperties/InteractiveDelayPct']
InteractiveRejectionPct  triggerBody()?['customProperties/InteractiveRejectionPct']
BackgroundRejectionPct   triggerBody()?['customProperties/BackgroundRejectionPct']
CapacityUnitMs           triggerBody()?['customProperties/CapacityUnitMs']
```

Pasted as plain text, a formula is sent literally instead of being evaluated.
Also make sure there is no trailing space or line break after a token.

## Activator rules

> **Superseded on 15 Sep 2026.** Rules on object properties never fired: they
> only activate when the condition *changes*, and ours were already true when
> they started. The live setup now uses **event rules** on
> `es-fabric-capacity-stream`, with the same conditions and without
> summarisation. An event rule fires on every matching event (every 30 s), so
> a blocked signal is naturally retried. Power Automate throttles the volume
> with this trigger condition on "When an activator rule is triggered", which
> lets Busy through at most once a minute and Quiet at most once every
> 5 minutes:
>
> ```
> @or(and(equals(triggerBody()?['customProperties/Signal'],'Busy'),less(int(formatDateTime(utcNow(),'ss')),30)),and(equals(mod(int(formatDateTime(utcNow(),'mm')),5),0),less(int(formatDateTime(utcNow(),'ss')),30)))
> ```
>
> | Rule | Conditions (all on `data.` fields) | `Signal` |
> |---|---|---|
> | `quiet-f8` | backgroundRejection < 22 AND capacitySku = F8 AND interactiveRejection < 22 | Quiet |
> | `quiet-f4` | backgroundRejection < 22 AND capacitySku = F4 AND interactiveRejection < 22 | Quiet |
> | `busy-f2-interactive` | interactiveDelay > 75 AND capacitySku = F2 | Busy |
> | `busy-f2-background` | backgroundRejection > 60 AND capacitySku = F2 | Busy |
> | `busy-f4-interactive` | interactiveDelay > 75 AND capacitySku = F4 | Busy |
> | `busy-f4-background` | backgroundRejection > 60 AND capacitySku = F4 | Busy |
>
> The first live resize ran on 15 Sep 2026 at 10:11 IST: F8 → F4, triggered
> by `quiet-f8`. The object/summarisation description below is kept for
> history only.

The rules below were originally built on an **object**, not on the raw stream.

**The object:**

- Object `Capacity` is keyed on `data.capacityId`.
- Its properties are `data.capacitySku`, `data.baseCapacityUnits`,
  `data.capacityUnitMs`, `data.interactiveDelayThresholdPercentage`,
  `data.interactiveRejectionThresholdPercentage` and
  `data.backgroundRejectionThresholdPercentage`.

**Every rule shares these settings:**

- **Action:** custom action `autoscale-smoke-test` (that is its name; it calls
  the runbook).
- **Inputs:**
  - `Signal` and `Rule` are plain text.
  - The other six inputs are the object properties with the same names.

Activator summaries only offer fixed windows (10 s, 30 s, 1, 5 and 10 min,
1 h…), so there is no 30-minute option.

| Rule (= `Rule` input) | Monitor (summary, window / step) | Condition | Property filters (AND) | `Signal` |
|---|---|---|---|---|
| `quiet-f8` | **Max** of background rejection, 10 min / 5 min | < 22 | capacitySku = F8; interactive rejection < 22 | `Quiet` |
| `quiet-f4` | **Max** of background rejection, 10 min / 5 min | < 22 | capacitySku = F4; interactive rejection < 22 | `Quiet` |
| `busy-f2-interactive` | **Average** of interactive delay, 5 min / 1 min | > 75 | capacitySku = F2 | `Busy` |
| `busy-f2-background` | **Average** of background rejection, 5 min / 1 min | > 60 | capacitySku = F2 | `Busy` |
| `busy-f4-interactive` | **Average** of interactive delay, 5 min / 1 min | > 75 | capacitySku = F4 | `Busy` |
| `busy-f4-background` | **Average** of background rejection, 5 min / 1 min | > 60 | capacitySku = F4 | `Busy` |
| `overloaded` *(optional, later)* | State event `stateChangeReason` | not a pause, resume or not-overloaded value | — | `Overloaded` |

`quiet-f8` was built in the UI. The other five were cloned from it through
the Fabric REST API: Get Item Definition, edit the copy, then Update Item
Definition. To change a threshold, edit it in the UI and keep the matching
`Down*`/`Up*` value in `FabricAutoscale_Config` consistent.

Where the numbers come from:

- **Busy rules are split per size.** Their percentages are relative to the
  current size, so "75% delay" means running hot on F2 or F4. There are no
  busy rules for F8, because it is the largest size.
- **Quiet rules** ask whether the next size down would be comfortable.
  Stepping down one size doubles every percentage, so 22% becomes 44%, just
  under the 45% limit.
- **Activator allows only three conditions**, so there is no utilisation
  filter. The runbook checks utilisation on the target size before resizing.
- **The action sends the latest raw values**, not the summarised ones, and
  the runbook re-checks them. If a latest value doesn't qualify, the runbook
  logs `rejected` and the rule tries again at its next step.
- **Jumping two sizes:** `quiet-f8` can take the capacity straight to F2 when
  F2 is also comfortable. The runbook decides.
- **Background load after the morning batch:** that load keeps counting for
  24 hours, so in the afternoon `quiet-f8` usually leads to F4, not F2.
- **The `overloaded` rule waits** until you have seen the nightly pause and
  morning resume State events. Those must be excluded, or every 07:20 resume
  would push the capacity to F8.

## Watching it

```powershell
.\Get-FabricAutoscaleReport.ps1 -Summary     # per day: switches, hours on F2/F4/F8, CU-h, saving
.\Get-FabricAutoscaleReport.ps1              # plus every decision
```

A full F8 day, 07:20–21:30, is 113.3 CU-h.

**Flaps** are a step down followed by a step back up within 60 minutes.
Several a day means the Quiet thresholds are too eager. Lower the `22`s in the
quiet rules, and `Down*` in the config to match.

**Also check the monitoring cost:** in the Capacity Metrics app, see what the
eventstream and Activator consume. On F2 that overhead matters.

## Known risk

Notebooks are about 80% of this capacity's load. F2 has 4 Spark cores and F4
has 8 (each can burst ×3). Scheduled notebooks that start on a small size
**queue** rather than fail, and background load only shows up in the readings
after they start. The 08:30 IST F4 floor covers the morning batch. For the
21:00 notebook, check the report the next day.

## Rollback

```powershell
.\Deploy-FabricAutoscale.ps1 -DryRun     # stop resizing immediately; logging continues
```

Then put the capacity back on F8 if needed. Use a body file, because the CLI's
cmd shim mangles inline JSON:

```powershell
$f = Join-Path $env:TEMP 'f8.json'
'{"sku":{"name":"F8","tier":"Fabric"}}' | Set-Content $f -Encoding ascii -NoNewline
az rest --method patch --body "@$f" --headers "Content-Type=application/json" `
  --url "https://management.azure.com/subscriptions/0300da4d-3a63-4241-a129-42b4f8b0c5cc/resourceGroups/ScanB/providers/Microsoft.Fabric/capacities/scanbf2test123456?api-version=2023-11-01"
```

To remove autoscale entirely, stop the Activator rules and disable the
`FabricAutoscale_MorningFloor` schedule.
