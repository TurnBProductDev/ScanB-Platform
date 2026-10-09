---
description: Build and test all three ScanB repositories, with a git status summary
argument-hint: "[web|bot|insight]  (default: all three)"
---

Run the cross-repository gate.

```
powershell -ExecutionPolicy Bypass -File "C:/Users/TURNRETAIL/OneDrive - turnb.com (1)/ScanB-Platform/scripts/check.ps1" $ARGUMENTS
```

Then summarise: which repos passed, which failed, and for any failure the
specific error and the file it points at. If a repo was not selected, say it was
skipped rather than implying it passed.
