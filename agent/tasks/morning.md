---
description: Morning brief (agenda, updates, system health, overnight failures)
tools: Read Grep Glob Bash(journalctl *) Bash(systemctl status *) Bash(systemctl --user status *) Bash(coredumpctl list *) Bash(coredumpctl info *) Bash(jq *) Bash(grep *) Bash(head *) Bash(tail *) Bash(sort *) Bash(uniq *) Bash(wc *) Bash(cut *)
notify: always
---
Write Bruno's morning brief for today from the facts in context.md: the day's agenda (and
tomorrow's first commitments), pending updates (repositories, AUR, kernel, unread Arch news),
system health (.pacnew, failed services, TPM, cleanup), service failures and agent reports from
the last 24 hours, and disk space.

Keep it short and skimmable: lead with what needs action today, then the rest in a few bullets.
If a failure or an error in the facts needs a closer look, check the journal before reporting it,
and say what you found. Do not pad: a quiet day is a one-line "nothing needs attention".

The facts already carry the head of every failure log of the day (unit, result, last journal
lines); the full logs are in ~/.local/state/barch/failures/ (Read them when the head is not
enough). A `hyprland-*.log` there is a compositor crash: the services listed in it as casualties
only lost their compositor and restarted, so report the crash, not each of them. Pipes of the
allowed read-only commands work (journalctl ... | grep ...).
