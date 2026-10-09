# ScanB platform workspace

You are working across four independent Git repositories that ship as one
product. This folder contains no application code — it exists to give you the
whole system at once. It is its own small Git repo
(`TurnBProductDev/ScanB-Platform`), because every repo's `CLAUDE.md` imports
`SYSTEM.md` from here; the same commit and push rules apply to it.

@SYSTEM.md

## Working rules

**Repository independence is a hard constraint.** Never merge the repos, change a
remote, or add a dependency from one repo's source onto another's file path. They
integrate over HTTP and blob storage only.

**Never commit or push in any of the repos unless asked.** All four repos sit
with substantial uncommitted work (`feature/scanb-v2-ui-modernization`,
`feature/query-traces`, `cost/sales-yoy-narrated-summary`, and Messaging's empty
`main`). A copy of that work as of 2026-10-09 is pushed on each repo's
`wip/pre-migration-2026-10-09` branch, but the working tree is still the live
copy. Assume it is precious.

**Before editing, decide whether the change crosses a seam.** If it touches S1
to S5 in the system map — an endpoint, a payload field, a blob path, a DTO, the
context token, an `appsettings` key under `FastApi:`, `Dashboards:` or
`Messaging:` — then find every side before changing any side. `/impact` does
this. If it touches none of them, it is a single-repo change; just do it.

**Change the writer and the reader in the same breath.** A new field in an
`ai-content` payload is worthless until `ai_content_store.py` passes it through
and a C# DTO deserializes it. A partial cross-repo change is a broken product,
not a smaller task.

**Verify per repo, with that repo's own gate** — the table in the system map.
Run the gate for every repo you touched, not just the one you started in.

**Secrets stay put.** `.env`, `appsettings.json` and `.pbi_token_cache.json` hold
live credentials. Never print them, copy them between repos, or move a value into
a file that is tracked by Git.

## Where to start Claude Code

Start **here** for anything that spans repos or when you are not yet sure which
repo owns the problem. Start **inside a repo** when the work is clearly local to
it — each repo has its own `CLAUDE.md` that imports this same map, so you keep
full cross-repo awareness either way.
