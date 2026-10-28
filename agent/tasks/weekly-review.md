---
description: Weekly review (journal errors, failures, snapshots, disk, unsaved BArch changes)
tools: Read Grep Glob Bash(journalctl *) Bash(systemctl status *) Bash(systemctl --user status *) Bash(git status *) Bash(git diff *) Bash(git log *)
notify: always
---
Review the past week of this machine from the facts in context.md:

- Recurring errors in the journal: group them, tell noise from real problems, and for each real
  one say what it means and what to do. Check the journal for details when the sample is unclear.
- Service failures of the week and whether they are still happening.
- Agent safety snapshots taken this week and disk usage.
- `.pacnew` files, orphans and cache size (from the health facts).
- Changes in ~/BArch that were never saved with `./scripts/sync.sh`, and how old they are.

End with a short "to do this week" list (empty is fine).
