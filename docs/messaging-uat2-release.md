# Release brief: ScanB Messaging to UAT2

**For a fresh session.** Everything below was established by inspection on
2026-09-17 (git, the UAT2 VM, the Azure subscription and the local database).
Take it as ground truth and do not re-derive it.

**Goal.** Get Messages and Tasks working on UAT2 for a small pilot, so two real
people can hold a conversation about an insight and assign a task.

**Done means:** two pilot users sign in at
`https://scanb-uat2.centralindia.cloudapp.azure.com`, press **Ask Team** on an
insight, the recipient sees it in **Messages** and in the bell, a task can be
assigned and moved through its statuses, and the attached insight is pinned to
a specific **report** (`anchor.resolution == "report"`), not to the whole
company.

---

## 1. Ground truth

### Repositories (four, independent; never merge or cross-reference file paths)

| Repo | Path | Role here |
|---|---|---|
| Web App | `TurnB_ScanB_WebApplication_latest/TurnB_ScanB_WebApplication` | The UI, and the owner of users/roles/entitlements |
| Messaging | `ScanB-Messaging` | The new service being deployed (no git remote, no commits) |
| AI Bot | `ScanB-AI-Bot` | Untouched. Read `.claude/skills/deploy-bot-uat/SKILL.md` — the deployment conventions there are the model to copy |
| Auto-Insight | `Auto-Insight-Generation` | Untouched |

Read `ScanB-Platform/SYSTEM.md` first (seams S1–S5) and each repo's `CLAUDE.md`.

### UAT2 as it stands today

| | |
|---|---|
| VM | `turnRetailVM-UAT2`, resource group **`SCANB-UAT`**, centralindia, **running**, private IP `10.0.0.5` |
| IIS site | `scanb-webapp` -> `C:\ReleaseUAT\webApp` (also `scanb-mobileapis`, `scanb-ai-proxy`) |
| Deployed build | `TurnRetailWebApp.dll` built **2026-09-15 16:14**. No `TurnRetailWebApp.Views.dll` (views are compiled into the main assembly, so a `.cshtml` change needs a rebuild) |
| Database | server `repair-turnRet`, database **`TurnRetail`** |
| Storage | `turnbtestblobstorage` (resource group `ScanB-UAT`) |
| Container env | `scanb-ai-agent-container-env`, **internal**, vnet `turnRetailVM-UAT-vnet` / subnet `ScanBAIAgent-subnet`, domain `lemonbush-2bb8da08.centralindia.azurecontainerapps.io` |
| Existing container app | `scanb-ai-agent`, image `ghcr.io/turnbproductdev/scanb-ai-agent:<tag>`, port 8000, min 1 / max 1, public GHCR image so **no registry credentials on the app** |
| How the web app reaches the bot | directly: `FastApi:BaseUrl = https://scanb-ai-agent.lemonbush-2bb8da08.centralindia.azurecontainerapps.io/`. Messaging will use the same style of URL |
| Entra tenant | `315642c5-e14a-4c12-bf77-41ee070def79` |
| Web App app registration | client id `1804e8e0-32f9-452b-bd3b-2f8843370801` |
| AI Bot API app id | `bec46185-971d-4878-ad8d-76874ca57b7a` (scope `api://bec46185-.../access_as_user`) |

### What is already deployed (do not re-ship it)

A file-by-file comparison on 2026-09-17 found **70 of 74** deployed static files
byte-identical to the local tree. UAT2 already has the AI workspace, the admin
redesign, recent activity, HTML dashboards, the KPI tile schema and the whole
ScanB 2.0 UI. The only differences are messaging:

* **3 modified**: `wwwroot/js/KpiDetail.js`, `wwwroot/js/notify.js`, `wwwroot/js/ReportSummary.js`
* **6 new**: `wwwroot/js/messaging/*.js` (5), `wwwroot/css/Messages.css`
* **15 C#/Razor files** changed since that build — all messaging, plus three
  files messaging edits (`Program.cs`, `Views/Shared/_Layout.cshtml`,
  `Views/Shared/_AiSummaryOverlay.cshtml`)

**Re-confirm this before deploying** (step 8). If anything else differs, stop
and ask: the working tree is deployed-but-uncommitted, so an unrelated edit
would ship silently.

### UAT2 config gaps (relevant here)

`C:\ReleaseUAT\webApp\appsettings.json` has `AzureAD`, `FastApi` and
`Dashboards`, but **no `Insights`, `AiSummary`, `Features` or `Messaging`
sections**. Two matter:

* `Insights:ReportAliases` is missing -> step 4 fixes it.
* `Messaging` is missing -> step 5 adds it.

Note the quirk: on UAT the client secret is a **flat root key**
`"AzureAD:ClientSecret"`, not nested. Do not "tidy" it.

---

## 2. Rules

* **Never commit or push** in any repo unless explicitly asked. Every repo has
  substantial uncommitted work that is already deployed.
* **Secrets stay put.** `appsettings.json` and `.env` hold live credentials.
  Never print them, never copy a value into a tracked file, never paste one
  into a commit or a doc.
* **Confirm before changing UAT.** The database script, the app registrations,
  the container app and the web app release each change a live environment.
  Say what you are about to do and get a yes.
* **Gates before shipping:**
  * `ScanB-Messaging`: `.venv/Scripts/python -m pytest -q` (104 pass, ~3s) and,
    for storage changes, `MSG_TEST_STORE=azure .venv/Scripts/python -m pytest -q`
    with Azurite running (`docker start scanb-azurite`).
  * Web App: `dotnet msbuild TurnRetailWebApp.csproj -t:Compile -v:minimal -nologo`.
* **Production guards are deliberate.** The messaging service refuses to start
  with `MSG_DEV_MODE`, a connection string, a static directory or a dev key when
  `MSG_ENVIRONMENT=production`. Do not weaken them to make a deploy easier.

---

## 3. Step 1 — Entra ID (do this first; everything else waits on it)

Two registrations. A tenant admin is needed. The portal is often easier than the
CLI for the scope JSON; both are fine.

**a. The Messaging API** (so a signed-in user's token can reach the service)

1. New app registration, e.g. `ScanB Messaging API`.
2. Expose an API: Application ID URI `api://<messaging-app-id>`, scope
   **`access_as_user`** (admin + user consent).
3. Under *Expose an API -> Authorized client applications*, pre-authorize the
   Web App (`1804e8e0-32f9-452b-bd3b-2f8843370801`) for that scope, so users are
   not prompted to consent.

**b. The directory call-back** (so the service can ask the Web App who people are)

1. On the **Web App** registration (`1804e8e0-...`), add an **App role**:
   * Display name: `Messaging directory`
   * Value: **`Messaging.Directory`**
   * Allowed member types: **Applications**
2. Give the container app a **system-assigned managed identity** (step 6) and
   assign that app role to its service principal. App-role assignment to a
   managed identity is a Graph write:

```bash
# ids
WEBAPP_SP=$(az ad sp list --filter "appId eq '1804e8e0-32f9-452b-bd3b-2f8843370801'" --query "[0].id" -o tsv)
ROLE_ID=$(az ad sp show --id "$WEBAPP_SP" --query "appRoles[?value=='Messaging.Directory'].id | [0]" -o tsv)
MSI_SP=$(az containerapp identity show -g ScanB-UAT -n scanb-messaging --query principalId -o tsv)

az rest --method POST \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$MSI_SP/appRoleAssignments" \
  --headers "Content-Type=application/json" \
  --body "{\"principalId\":\"$MSI_SP\",\"resourceId\":\"$WEBAPP_SP\",\"appRoleId\":\"$ROLE_ID\"}"
```

**No redirect URI changes are needed.** Nothing new signs users in.

**Verify:** `az ad sp show --id $MSI_SP --query appRoleAssignments` lists the role,
and the Web App registration shows the app role as assigned.

---

## 4. Step 2 — Database

On `repair-turnRet` / **`TurnRetail`**, run:

```
TurnB_ScanB_WebApplication/docs/sql/2026-09-15_MessagingPermissions.sql
```

It creates `dbo.MessagingUserPermission` (five columns), is guarded, safe to
re-run, and carries its own rollback. Nothing else in the release touches the
database.

**First check the table naming.** Local is mixed (`Users` plural, but `Customer`,
`Role`, `Report`, `Dashboard`, `Module` singular). Confirm on UAT before writing
any query of your own:

```sql
SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME;
```

The script itself only creates a new table, so naming does not affect it.

**Optional:** grant the team-task view to a pilot lead, or do it from the UI
afterwards (*Tasks -> Team access*, customer admins only).

---

## 5. Step 3 — Pick the pilot customer

Messaging is enabled per customer via `Messaging:EnabledCustomerIds`.

```sql
SELECT c.id, c.name, c.isActive, COUNT(u.id) AS activeUsers
FROM Customer c LEFT JOIN Users u ON u.customerId = c.id AND ISNULL(u.isActive,1)=1
GROUP BY c.id, c.name, c.isActive ORDER BY activeUsers DESC;
```

Pick one with at least two active users who can actually sign in. On UAT, SB Mart
is customer **1036** (per `docs/sql/2026-09-15_SbMartAiContainer.sql`) — note this
differs from the local database, where SB Mart is 1029. Do not assume ids match.

Leaving `EnabledCustomerIds` empty enables **every** customer. For a pilot, list
one id.

---

## 6. Step 4 — The `Insights:ReportAliases` fix

**Why this matters.** An insight card names its source report only with the
pipeline's own slug (`target_tracker`). The app routes by numeric module and
report ids and has never heard of that slug. `Insights:ReportAliases` is the one
place the two vocabularies meet. It is **absent on UAT2**.

Without it, `MessagingContextBuilder.ResolveInsightReportAsync` cannot pin a card
to a report row, so the anchor falls back to `module` or `tenant-only`. That
still works, but the permission check becomes "anyone in the company" instead of
"people entitled to this report" — a weaker guarantee than the design intends.

**Build the map for UAT (do not copy the local one blindly).**

1. **Get the slugs actually in the UAT feed.** They come from `reportId` on each
   card. Read the tenant's published feed from blob:

```bash
az storage blob download --account-name turnbtestblobstorage --auth-mode login \
  -c <client-container> -n ai-content/kpi/client/insights.json -f insights.json
python -c "import json;d=json.load(open('insights.json'));p=d.get('payload',d);print(sorted({c.get('reportId') for c in p if c.get('reportId')}))"
```

   `<client-container>` is the customer's AI container (e.g. `sb-mart`). Also
   check `ai-content/kpi/client/alerts.json`, which holds the seven-day feed.

2. **Get the report names on UAT** for the pilot customer:

```sql
SELECT r.id, d.name AS reportName, m.name AS moduleName
FROM Report r
JOIN Dashboard d ON d.id = r.dashboardId
LEFT JOIN Module m ON m.id = r.moduleId
WHERE r.customerId = <pilotCustomerId> AND ISNULL(r.isActive,1) = 1
ORDER BY d.name;
```

3. **Map each slug to the report name it means.** Matching is case- and
   punctuation-insensitive (both sides are reduced to letters and digits), so the
   value only has to *name* the report, not spell it exactly.

The local map, as a starting point only — the UAT catalogue may differ:

```jsonc
"Insights": {
  "ReportAliases": {
    "sales_yoy":               "Sales Performance",
    "daily_sales":             "Daily Sales Performance",
    "inventory_stock_health":  "Inventory Management",
    "sku_overview":            "SKU Overview",
    "target_tracker":          "Target Tracker",
    "stock_age_analysis":      "Stock Age Analysis"
  }
}
```

4. Add that `Insights` section to UAT2's `appsettings.json` in step 5.

**Two things to know about the resolver** (`MessagingContextBuilder.ResolveInsightReportAsync`):

* It matches against **every active report in the customer**, not the sender's
  own entitlements — deliberately, so a sender who is not entitled cannot make
  the anchor weaker by failing to match.
* An **ambiguous** match (two reports with the same name) is left unresolved on
  purpose. If a slug will not pin, check for duplicate dashboard names first.

**Verify after deploying:** start a conversation from an insight and check the
response from `POST /Messages/api/context/insight`. It must return
`anchor.resolution: "report"` with a numeric `anchor.reportRowId`. If it says
`module` or `tenant-only`, the alias is missing or ambiguous.

---

## 7. Step 5 — UAT2 web app configuration

Add to `C:\ReleaseUAT\webApp\appsettings.json` (keep a backup of the file first):

```jsonc
"Messaging": {
  "Enabled": true,
  "BaseUrl": "https://scanb-messaging.lemonbush-2bb8da08.centralindia.azurecontainerapps.io",
  "Scopes": "api://<messaging-app-id>/access_as_user",
  "TimeoutSeconds": 10,
  "ContextSigningKeys": "<base64, 32+ bytes - SAME value as the service>",
  "ContextLifetimeSeconds": 300,
  "EnabledCustomerIds": "<pilot customer id>",
  "InternalApi": {
    "Enabled": true,
    "TenantId": "315642c5-e14a-4c12-bf77-41ee070def79",
    "Audiences": "api://1804e8e0-32f9-452b-bd3b-2f8843370801,1804e8e0-32f9-452b-bd3b-2f8843370801",
    "AllowedClientIds": "<the container app managed identity's CLIENT id>",
    "RequiredRole": "Messaging.Directory"
  }
}
```

Plus the `Insights` section from step 4.

Generate the signing key once and use the same value on both sides:

```bash
python -c "import os,base64;print(base64.b64encode(os.urandom(32)).decode())"
```

Notes:

* `AllowedClientIds` is the managed identity's **client (application) id**, which
  is what arrives in the token's `azp`/`appid` claim — **not** its principal id.
  `az containerapp identity show` returns the *principal* id, so translate it:

  ```bash
  MSI=$(az containerapp identity show -g ScanB-UAT -n scanb-messaging --query principalId -o tsv)
  az ad sp show --id "$MSI" --query appId -o tsv      # <- this is AllowedClientIds
  ```
* `DevAuth`, `AllowSampleContext` and `InternalApi:DevKey` are **development
  only** — `MessagingSetup` throws at startup if any is set outside Development.
  Do not add them here.
* **Corrected 2026-09-17.** `Messaging:Scopes` must NOT be added to the sign-in
  scopes. The build released that morning did, and sign-in failed for every UAT2
  user with `AADSTS28000` (the sign-in code redemption named a third resource).
  `Program.cs` no longer adds it; the Web App is pre-authorized on the Messaging
  API, so the Messaging client acquires its token silently on first use. If it
  cannot, messaging pages show "your session needs to be refreshed".
* The Messaging API registration needs `requestedAccessTokenVersion: 2` —
  `fastapi_azure_auth` rejects v1 tokens.

Full reference: `TurnB_ScanB_WebApplication/docs/messaging-setup.md`.

---

## 8. Step 6 — Build, push and run the messaging service

Follow the conventions in `ScanB-AI-Bot/.claude/skills/deploy-bot-uat/SKILL.md`:
tag format `<yyyymmdd><letter>-<label>`, check the image for stray data before
pushing, keep the previous tag for rollback.

```bash
cd ScanB-Messaging
docker build -t ghcr.io/turnbproductdev/scanb-messaging:20260917a-phase1 .
# sanity: no .env, no test data, image ~300MB
docker run --rm ghcr.io/turnbproductdev/scanb-messaging:20260917a-phase1 ls -la /app
docker push ghcr.io/turnbproductdev/scanb-messaging:20260917a-phase1
```

The GHCR package must be **public**, like the bot's, so the container app needs
no registry credentials.

```bash
az containerapp create -g ScanB-UAT -n scanb-messaging \
  --environment scanb-ai-agent-container-env \
  --image ghcr.io/turnbproductdev/scanb-messaging:20260917a-phase1 \
  --target-port 8010 --ingress external \
  --min-replicas 1 --max-replicas 1 --cpu 0.5 --memory 1Gi \
  --system-assigned
```

`--ingress external` is right: the **environment** is internal, so this is
reachable only inside the vnet — exactly how `scanb-ai-agent` is set up.

Storage access for the identity:

```bash
MSI=$(az containerapp identity show -g ScanB-UAT -n scanb-messaging --query principalId -o tsv)
SA=$(az storage account show -g ScanB-UAT -n turnbtestblobstorage --query id -o tsv)
az role assignment create --assignee "$MSI" --role "Storage Blob Data Contributor" --scope "$SA"
az role assignment create --assignee "$MSI" --role "Storage Table Data Contributor" --scope "$SA"
```

Environment variables (the signing key as a secret, not plain text):

```bash
az containerapp secret set -g ScanB-UAT -n scanb-messaging \
  --secrets context-key="<the same base64 key as the web app>"

az containerapp update -g ScanB-UAT -n scanb-messaging --set-env-vars \
  MSG_ENVIRONMENT=production \
  MSG_AZURE_TENANT_ID=315642c5-e14a-4c12-bf77-41ee070def79 \
  MSG_AZURE_API_CLIENT_ID=<messaging-app-id> \
  MSG_AZURE_API_SCOPE_NAME=access_as_user \
  MSG_STORE=azure \
  MSG_STORAGE_BLOB_URL=https://turnbtestblobstorage.blob.core.windows.net \
  MSG_STORAGE_TABLE_URL=https://turnbtestblobstorage.table.core.windows.net \
  MSG_DIRECTORY=webapp \
  MSG_WEBAPP_BASE_URL=https://scanb-uat2.centralindia.cloudapp.azure.com \
  MSG_WEBAPP_API_SCOPE=api://1804e8e0-32f9-452b-bd3b-2f8843370801/.default \
  MSG_REALTIME=poll \
  MSG_CONTEXT_SIGNING_KEYS=secretref:context-key
```

`MSG_ENVIRONMENT=production` is intentional on UAT: that value only switches on
the safety guards (no dev mode, no connection strings, no static directory), which
is what you want here.

**Verify from the UAT2 VM** (it is in the same vnet):

```powershell
Invoke-WebRequest -UseBasicParsing https://scanb-messaging.lemonbush-2bb8da08.centralindia.azurecontainerapps.io/health/ready
# expect: {"status":"ok","store":"azure","directory":"webapp","realtime":"poll"}
```

If DNS does not resolve from the VM, compare with how `FastApi:BaseUrl` reaches
`scanb-ai-agent` — the same private DNS zone serves both.

### The reminder worker

Task reminders (due soon, overdue, no update, blocked escalation, approval chase)
run separately. A scheduled job is the cheapest form:

```bash
az containerapp job create -g ScanB-UAT -n scanb-messaging-reminders \
  --environment scanb-ai-agent-container-env \
  --image ghcr.io/turnbproductdev/scanb-messaging:20260917a-phase1 \
  --trigger-type Schedule --cron-expression "*/10 * * * *" \
  --replica-timeout 600 --replica-retry-limit 1 \
  --command python --args "-m","messaging.worker","--once" \
  --system-assigned
```

It needs the **same storage and directory environment variables and the same
storage role assignments** as the app. Without the worker, messaging still
works; only reminders stop.

---

## 9. Step 7 — Release the web app

1. **Re-confirm only messaging differs.** Hash the deployed `wwwroot` and compare
   with local (the method used on 2026-09-17: `Get-FileHash` over
   `C:\ReleaseUAT\webApp\wwwroot` via `az vm run-command`, excluding `lib\` and
   `images\`, then compare with the local tree). Expect exactly the 3 modified +
   6 new messaging files. **Anything else: stop and ask.**
2. **Back up** `C:\ReleaseUAT\webApp` (copy to `C:\ReleaseUAT\webApp.bak-<date>`).
   This is the rollback.
3. `dotnet publish -c Release` and copy the output over the site, preserving
   `appsettings.json` (it holds UAT secrets and is not in git).
4. Restart the IIS site `scanb-webapp` (or recycle its app pool).
5. Watch the first requests in the site log for startup errors.

`az vm run-command` is the access route. It serialises: if a second invocation
errors with a conflict, wait and retry rather than running two at once.

---

## 10. Step 8 — Verify end to end

1. `https://scanb-uat2.centralindia.cloudapp.azure.com` — sign in as pilot user A.
   **Messages** and **Tasks** appear in the left rail.
2. Open an insight -> **Ask Team**. The insight attaches. Colleagues who cannot
   see that report are listed as unavailable with a reason.
3. Confirm `anchor.resolution` is `"report"` (step 4). This is the whole point of
   the alias fix.
4. Send to pilot user B. B signs in: the bell shows it; opening the conversation
   clears it; a reply reaches A within 30 seconds (polling).
5. **Ask Team -> Assign a task** with a due date. Check the **Tasks** page: list
   and board, status changes, a note required for Blocked.
6. *Tasks -> Team access* (customer admin) grants the My team view.
7. Storage: a container `msg-c<customerId>` and tables `MsgC<customerId>` exist in
   `turnbtestblobstorage`, and `audit/<yyyy>/<mm>/<dd>/` has entries.
8. Leave the worker for one cycle and confirm it logs a pass.

---

## 11. Rollback

| Change | Undo |
|---|---|
| Web app | Restore `webApp.bak-<date>`, restart the site |
| Messaging config only | Set `Messaging:Enabled` to `false` — rail entries, routes and the bell revert; no redeploy needed |
| Container app | `az containerapp delete -g ScanB-UAT -n scanb-messaging` (nothing else depends on it) |
| Worker | `az containerapp job delete -g ScanB-UAT -n scanb-messaging-reminders` |
| Database | Rollback block at the end of `2026-09-15_MessagingPermissions.sql` |
| Entra | Remove the app role assignment and the Messaging API registration |
| Data | Conversations live in `msg-c<customerId>`; deleting the container destroys them. Leave it unless asked |

Turning `Messaging:Enabled` off is the fastest safe move if anything misbehaves
during the pilot.

---

## 12. Gotchas already paid for

* **`Customer.aiContainer`** — the EF model expects it; if a database has not had
  `docs/sql/2026-09-15_AiAccessSync.sql` run, *every* query touching Customer
  fails with "Invalid column name" and the home page 500s on a null. Confirm the
  column exists on `TurnRetail` before blaming messaging.
* **Sign-in only works on registered redirect URIs.** `localhost:7214` is not
  registered; `https://localhost:5000/signin-oidc` is. UAT2's own URL is already
  registered.
* **Container startup takes ~10s.** A health check at 6 seconds returns nothing
  and looks like a crash.
* **`az vm run-command` and quoting.** Pass a script file (`--scripts @file.ps1`);
  inline scripts with nested quotes silently produce empty output.
* **`$host` is reserved in PowerShell.** Using it as a variable in a run-command
  script yields no output and no error.
* **The service's own tests are the fastest check.** 104 unit tests in ~3s, and
  `MSG_TEST_STORE=azure` replays all of them against Azurite.
* **Ports on this laptop**: web app 5000 (registered redirect URI), messaging
  8010. `ScanB-Platform/scripts/run-local.ps1` starts both.

---

## 13. Confidence: what is proven and what is not

**Proven:** the messaging service's rules (104 tests, plus the full suite replayed
on Azurite); the C#/Razor compiles; the container image builds and serves; the
whole chain works locally over HTTP with the real UAT-shaped database — the
service resolved a real user, listed their real colleagues, created a
conversation and a task; and the Web App's C# signer produces a token the Python
verifier accepts (a committed test fixture guards that seam).

**Not proven:** nobody has looked at the Messages or Tasks **screens in a
browser**. Rendering, layout and the drag-and-drop board are unverified. Expect to
fix small UI issues during the pilot — that is the main thing this release is for.

Also unproven: the Entra setup, the container app deployment, and the worker job
in Azure. Web PubSub is not used; live updates fall back to 30-second polling,
which is the intended starting point.
