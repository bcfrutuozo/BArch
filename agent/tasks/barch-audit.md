---
description: Monthly audit of the BArch repo (docs vs code, unused scripts, package lists)
tools: Read Grep Glob Bash(git ls-files*) Bash(git log *) Bash(git status *) Bash(pacman -Q*) Bash(bash -n *) Bash(shellcheck *) Bash(systemctl --user list-unit-files *) Bash(systemctl list-unit-files *)
notify: always
---
Audit this repository the way a fresh install would exercise it — a light, automatic version of
the VM test. context.md has the precomputed facts; read the code to confirm before reporting.

1. **Docs vs code.** README.md and CLAUDE.md: every folder, script, command, keybinding, service
   and path they mention still exists and works as described; user-visible features in the code
   (bar widgets, `barch` subcommands, keybindings in binds.lua) are documented.
2. **Unused things.** Scripts, QML files, units and generators that nothing references (no
   keybinding, no QML, no unit, no other script, no docs).
3. **Install will not break.** Commands the scripts and QML call that come from packages missing
   in packages/pacman.txt or aur.txt; enabled user services missing in packages/user-services.txt;
   stow packages missing in PACKAGES (scripts/lib.sh); system files changed in place but missing in
   SYSTEM_FILES.
4. **Script hygiene.** shellcheck findings that are real bugs (not style).

Report each finding with the file and line and the fix. Status `warn` if anything would break a
fresh install or misleads the docs, `ok` otherwise.
