---
description: Trace the cross-repository blast radius of a change before writing any code
argument-hint: <the change you are considering>
---

Work out the full blast radius of this change across the three ScanB
repositories, then stop and report. **Do not modify any code in this command.**

Change under consideration: $ARGUMENTS

Do this:

1. **Classify it.** Using the system map, decide which seams it touches — S1
   (Web App <-> AI Bot HTTP), S2 (`ai-content/` blob), S3 (dashboard blob), or
   none. Say so explicitly. If it touches no seam, say "single-repo change" and
   name the repo; that is a complete answer and you are done.

2. **Find every side.** For each seam involved, locate the real code on both
   sides — writer and reader, caller and handler, payload producer and the DTO
   that deserializes it. Search; do not assume from this map. Cite
   `file.ext:line` for each.

3. **Check the tenancy angle.** Does the change go anywhere near container
   resolution, `user_hash`, report ids or per-tenant schemas? If yes, call it out
   as a data-boundary concern.

4. **Report** in this shape:

   - **Verdict:** single-repo, or crosses seams <list>
   - **Files to change, grouped by repository**, each with a one-line reason
   - **Order of change** — which repo has to move first for the system to stay
     working in between, and whether an intermediate state is deployable
   - **Gates to run** — the specific build/test command for each repo touched
   - **Risks** — anything that fails silently: a 404 that turns into fallback
     sample content, an envelope field consumed by name, a config key that must
     change alongside code

Be concrete and short. No code changes, no speculative refactors.
