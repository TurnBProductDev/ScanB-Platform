# ScanB platform — the system map

Four separate Git repositories that ship as one product. This file is the only
place the cross-repository facts are written down; each repo's `CLAUDE.md`
imports it. Keep it about **seams and ownership** — never copy code, schemas or
payload shapes in here, point at the file that owns them instead.

## The repositories

| # | Repo | Path (this machine) | Stack | Owns |
|---|---|---|---|---|
| 1 | **Web App** | `TurnB_ScanB_WebApplication_latest/TurnB_ScanB_WebApplication` | ASP.NET Core 8 MVC, EF Core, SQL Server, Azure AD, Power BI Embedded | Everything the customer sees. Sign-in, entitlements, report catalogue, dashboards, KPI hub, AI chat UI |
| 2 | **AI Bot** | `ScanB-AI-Bot` | Python, FastAPI, LangGraph, Kuzu graph + DuckDB + vector index | The answer engine. Natural-language `/analyze`, RBAC enforcement, and the read API that serves stored AI content |
| 3 | **Auto-Insight** | `Auto-Insight-Generation` | Python, LangGraph over Power BI semantic models | The generator. Produces daily KPI insights and per-report AI summaries, and publishes them to blob |
| 4 | **Messaging** | `ScanB-Messaging` | Python, FastAPI, Azure Blob + Table, Web PubSub | Conversations and tasks. Direct messages, groups, conversations about an insight or report, task assignment with reminders |

Remotes are independent and must stay that way:
`aarti1205/TurnB_ScanB_WebApplication` (+ `scanbprod`, `scanbweb`) ·
`TurnBProductDev/ScanB-AI-Agent` ·
`TurnBProductDev/Auto-Insight-Generation---Semantic-Model` ·
`TurnBProductDev/ScanB-Messaging` (remote added 2026-10-09; its only commit so
far is the `wip/pre-migration-2026-10-09` snapshot, local `main` is still empty).
This workspace folder is `TurnBProductDev/ScanB-Platform`; it must sit beside the
four repos, since their `CLAUDE.md` files import this file by relative path.

**Why Messaging is its own service and not part of the AI Bot.** The bot has sat
unreachable for days at a time, and messaging must not go down with the answer
engine; the two also scale differently (long-lived connections against heavy
compute). It copies the bot's blob patterns but imports nothing from it.

## How the data flows

```
Power BI semantic model
        |
        v
[3] Auto-Insight  --writes-->  Azure Blob (turnbtestblobstorage)
                               |
                               +-- {client}/ai-content/...  --read-->  [2] AI Bot :8001
                               |                                            |
                               +-- sb-mart/html-dashboards/ --------+       | HTTP + Azure AD
                                                                    v       v
                                                              [1] Web App (.NET)
                                                                    |     ^
                                              S4 user token (HTTP)  v     | S5 app token: who is this
                                                              [4] Messaging   person, what may they see
                                                                    |
                                                                    +--> msg-c{customerId} blob + tables
```

**Auto-Insight and the Web App never call each other.** All coupling between
them is indirect: through a blob contract that the AI Bot relays, or through the
dashboard blob the Web App reads directly. Remember this when tracing impact —
a change in [3] reaches [1] only via [2] or via blob layout.

**Messaging never talks to the AI Bot or Auto-Insight.** It asks the Web App
about people and permissions and stores its own data. An insight reaches a
conversation as a snapshot the Web App fetched and signed, never by Messaging
reading the AI content itself.

## The seams

A change is only cross-repository if it touches one of these. Everything else is
local to its repo.

### S1 — HTTP: Web App -> AI Bot

* **Transport:** REST over `FastApi:BaseUrl` (dev `http://localhost:8001`), Azure AD
  bearer token, scope `api://bec46185-971d-4878-ad8d-76874ca57b7a/access_as_user`.
* **Routes are configuration, not code** — `FastApi:KpiInsightsPath`,
  `KpiAlertsPath`, `ReportSummaryPath` in `appsettings.json`. A backend path can
  move without a C# change.
* **Contract owners:** `Service/impl/FastApiService.cs` + `DTO/*.cs` (caller side)
  <-> `main.py` route handlers and their Pydantic response models (server side).
* **Endpoints in use:** `/analyze`, `/analyze/cancel`, `/transcribe`,
  `/kpi/insights`, `/kpi/alerts`, `/report/summary`, `/report/summary/history`,
  `/sessions/*`, `/feedback`, `/auth/validate`.
* **Home Ver 4 (added 2026-10-01):** `/kpi/brief` (the AI Executive Summary, an
  object) and `/kpi/highlights` (Top Insights, an array), stored blobs on the 8s
  client. Off in the Web App until `FastApi:KpiBriefPath` / `KpiHighlightsPath`
  are set (no default route); unset or 404, Home keeps its fallbacks. The Web App
  (`HomeController.ExecutiveBrief` / `TopInsights`) drops every line or item that
  names a Power BI report the user cannot open, so both payloads must carry
  `reportIds`. Contract: `docs/home-v4/PLAN.md` §5. Producers (Auto-Insight, both
  off by default): `highlights.json` from the Daily Sales, Target Tracker and Sales
  YoY publishers (`ai_content_highlights`); `brief.json` from its own job
  (`AGENT_RUNNER=executive_brief`, `ai_content_executive_brief`), run after the
  report jobs.
* **Three HTTP clients on purpose:** `FastApi` (8s) for cheap reads,
  `FastApiAnalyze` (120s) for inference, `FastApiTranscribe` (30s) for a voice
  upload plus two model calls. Don't collapse them — see the comment in
  `Program.cs`.
* **Voice input is the one S1 call that is not JSON.** The browser posts a
  recording to `Controllers/AIAssistantController.Transcribe`, which streams the
  raw body to `/transcribe`; the audio is stored by nobody. The reply carries
  both the transcript and its English translation, and **the English is what
  `/analyze` must be given** — the entity index is English-only, so a Hindi
  question halts the pipeline. Owners: `speech.py` (bot) <-> `voice.js` +
  `_ChatSurface.cshtml` (Web App). Off until `FastApi:TranscribePath` is set,
  which is also what decides whether a mic is rendered.
* **404 is a normal answer.** A missing summary/insight is a 404 and the Web App
  falls back to bundled sample content. Never turn one into a 500.
* **AI access admin — the one S1 path with a different identity.** `/admin/ai-users/*`
  and `/admin/ai-containers/*` take the Web App's **app** token (client credentials,
  scope `api://bec46185-…/.default`, role `AI.Admin`), never a user's. Caller:
  `Service/impl/AiAccessSyncServiceImpl.cs` + `DTO/AiAccessDto.cs`, over the
  `FastApiAdmin` / `FastApiAdminBulk` clients, which deliberately lack the user-token
  handler. Server: `admin_api.py` over `access_admin.py`, the only writer of
  `agent-config/client_mapping.json` and `{container}/User_Security.parquet`.
  Off on both sides until switched on: `FastApi:AiAccessSyncEnabled` (Web App) and
  `AI_ADMIN_CLIENT_IDS` (bot). The Web App's SQL (`Customer.aiContainer`,
  `UserOdsMapping`) is the source of truth; a customer with no `aiContainer` is not
  managed from here.

### S2 — Blob: Auto-Insight -> AI Bot (the `ai-content/` contract)

* **Writer:** `Auto-Insight-Generation/powerbi-summary-agent/src/tools/ai_content_publisher.py`
* **Reader:** `ScanB-AI-Bot/ai_content_store.py` — read-only by design; its module
  docstring is the authoritative description of the blob layout.
* **Spec:** `TurnB_ScanB_WebApplication_latest/docs/ai-content-publish-spec.md`
  (envelope, resolution order, tenant rules).
* **The shape in one line:** every JSON blob is an envelope; the API returns
  **only its `payload`**, and that payload is the Web App's UI contract.
* **Resolution order:** `users/{user_hash}/...` -> `client/...` -> 404.
* Changing the payload shape is a **three-repo change**: publisher, store, and the
  C# DTO that deserializes it.

### S3 — Blob: dashboards -> Web App

* `Service/Dashboards/DashboardBlobOptions.cs`, container `sb-mart`, prefix
  `html-dashboards`, configured under `Dashboards:Blob` in `appsettings.json`.
* Served only through `PowerBi/HtmlDashboardFrame` so sign-in and entitlement
  both apply. Dashboard assets are deliberately **outside `wwwroot`** — see the
  comment in `TurnRetailWebApp.csproj`.

### S4 — HTTP: Web App -> Messaging

* **Transport:** REST over `Messaging:BaseUrl`, Azure AD bearer token, delegated
  scope `api://<messaging-api-id>/access_as_user`. The browser never holds a
  Messaging token: `Controllers/MessagesController.cs` proxies an ALLOW-LIST of
  routes (not a forwarder) and shape-checks every id.
* **Contract owners:** `Service/Messaging/*.cs` (caller) <->
  `ScanB-Messaging/messaging/api/routes.py` (server). Written down in
  `ScanB-Messaging/docs/web-app-contract.md`.
* **Verified context.** The item a conversation is about is fetched by the Web
  App, signed (HMAC) and sent as a token; Messaging accepts context no other
  way, so a browser cannot invent an "insight". Signer:
  `Service/Messaging/MessagingContextSigner.cs`. Verifier:
  `ScanB-Messaging/messaging/context.py`. **Change both together**, and keep
  `Messaging:ContextSigningKeys` equal to `MSG_CONTEXT_SIGNING_KEYS`.
* **Off by default.** No `Messaging` section in `appsettings.json` means no
  routes, no rail entries, no scopes. See `docs/messaging-setup.md`.

### S5 — HTTP: Messaging -> Web App (the internal directory API)

* `/internal/messaging/v1/*`, served by `Service/Messaging/MessagingInternalApi.cs`,
  called by `ScanB-Messaging/messaging/directory.py`.
* **Application token only** (no `scp` claim), app role `Messaging.Directory`,
  allow-listed client id. A signed-in person's token is refused.
* The Web App stays the only source of truth for users, roles and report
  entitlements. Messaging caches answers for 60 seconds and **fails closed**.
* Same identity pattern as S1's AI access admin path, in the other direction.

Messaging's own store (`msg-c{customerId}` container + `MsgC{customerId}` tables)
is not a seam: nothing else reads it.

## Tenancy — the rule that spans all four

**One customer = one blob container.** The AI Bot maps a signed-in user's email to
a container via `client_mapping.json`, and hashes the email (16-hex SHA-256) for
per-user paths. Per-tenant query schemas live in `ScanB-AI-Bot/schemas/`
(`scanb.py`, `cityflower.py`, `sb_mart.py`).

Messaging follows the same rule with its own containers, `msg-c{customerId}`,
keyed by the Web App's numeric customer id rather than the AI container name:
messaging must work for customers that have no ScanB AI.

Anything that resolves a container, a `user_hash` or a report id is a tenant
boundary. Treat a bug there as a data-leak risk, not a display bug.

## Visual design — owned by the Web App

What customers see is designed in one place:
- **Rules:** the Web App's `CLAUDE.md`, section *Frontend Design System*.
- **Reasoning and the parts list:** its `design/` folder.
- **Every value:** `wwwroot/css/theme.css`.

Read them before changing anything a customer sees, in any repo.

For UI work, start Claude Code inside the Web App repo. That is where these
skills are registered:
- `ui-build` (`.claude/skills/ui-build/SKILL.md`), the workflow and entry
  point for any UI task;
- `ui-design`, the method it uses to design;
- `ui-review`, how it judges the rendered result.

From anywhere else, read the files directly. The state of the UI setup work, and its
next step, are in the Web App's `docs/claude-ui-handoff.md` and
`docs/claude-ui-session-checkpoint.md`.

Two other repos draw customer-facing visuals and are held to the same rules:
- the AI Bot's chat charts (`blob_viz_handler.py`, Plotly HTML shown in an
  iframe);
- Auto-Insight's HTML dashboards and summaries
  (`powerbi-summary-agent/src/domains/*/*_html.py`).

Copy values into them; never import across repos. The chart palette to copy
is `--sb-chart-*` in `theme.css`: both themes, validated for colour-blind
readers, and explained in the Web App's `design/tokens.md`. A change to how
they look is local to that repo, unless it needs something from the Web App
(such as the active theme). Then it crosses a seam.

Visual QA, in any repo, happens in a real browser through the Playwright MCP
server (user scope on this machine), never from the code alone. The procedure
is in the Web App's `docs/visual-qa.md`.

## Build and test — verified working

| Repo | Command | Notes |
|---|---|---|
| Web App | `dotnet msbuild TurnRetailWebApp.csproj -t:Compile -v:minimal -nologo` | net8.0; NU1902/NU1701 warnings are known and expected. UI changes also run `npm run test:visual` in `ui/` (visual regression, ~10s, no credentials; `ui/README.md`) |
| AI Bot | `.venv/Scripts/python -m pytest -m unit -q` | ~15s. Markers: `unit`, `integration`, `e2e`, `eval` — only `unit` needs no credentials |
| Auto-Insight | `python scripts/replay_all.py` (from `powerbi-summary-agent/`) | the offline commit gate, ~40s. Second half is `python scripts/golden_master.py` |
| Messaging | `.venv/Scripts/python -m pytest -q` | ~3s, no credentials. `MSG_TEST_STORE=azure` replays the whole suite against Azurite (`docker start scanb-azurite`), ~25s |

`ScanB-Platform/scripts/check.ps1` runs all four plus a git status summary.

## Facts that are easy to get wrong

* The Web App's Git repo is the **inner** `TurnB_ScanB_WebApplication` folder. The
  `_latest` wrapper above it is untracked scratch space that also holds the
  cross-repo spec and a UI prototype.
* The Web App **gitignores `appsettings.json` and `TurnRetailWebApp.csproj`**. A
  fresh clone will not build without them. Never assume they are in the repo.
* UAT's config database is called `TurnRetail`, not `TurnretailVMConfigDB`, and
  its table names are singular. See the `deploy-uat` skill.
* Messaging is **off in every environment** until `Messaging:Enabled` is set and
  a customer is listed in `Messaging:EnabledCustomerIds`. Its one SQL table
  (`dbo.MessagingUserPermission`) is created by
  `TurnB_ScanB_WebApplication/docs/sql/2026-09-15_MessagingPermissions.sql`.
* `Auto-Insight-Generation/CLAUDE.md` and `AGENTS.md` must stay byte-identical.
* Auto-Insight's `outputs*/` folders are generated artifacts, not source.
* **All three repos live inside OneDrive.** OneDrive resolves a sync clash by
  leaving a second copy next to the original with the machine name appended
  (`response_formatter-LAPTOP-DMROBM24.py`) or a `_conflict_backup_*` folder.
  Those are not source. Never edit one, and never treat one as the live file.
