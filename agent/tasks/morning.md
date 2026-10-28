---
description: Morning brief (agenda, updates, system health, overnight failures)
tools: Read Grep Glob Bash(journalctl *) Bash(systemctl status *) Bash(systemctl --user status *)
notify: always
---
Write Bruno's morning brief for today from the facts in context.md: the day's agenda (and
tomorrow's first commitments), pending updates (repositories, AUR, kernel, unread Arch news),
system health (.pacnew, failed services, TPM, cleanup), service failures and agent reports from
the last 24 hours, and disk space.

Keep it short and skimmable: lead with what needs action today, then the rest in a few bullets.
If a failure or an error in the facts needs a closer look, check the journal before reporting it,
and say what you found. Do not pad: a quiet day is a one-line "nothing needs attention".
