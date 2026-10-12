#!/bin/sh
# PreToolUse hook for Bash: refuses ad-hoc interpreters and inline shell so repo tasks go through
# exe/hecks (CLAUDE.md, "Use the hecks binary"). It matches only a command that starts with one,
# so git, jj, gh, cargo, aws, op, curl, and the launcher itself pass untouched. Exit 2 refuses
# and the stderr text reaches the agent.
CMD=$(jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$CMD" ] || exit 0
# A command position: the start of the string, or after ; & | ( or a newline.
START='(^|[;&|(]|\n)[[:space:]]*'
INTERP='(ruby|irb|python[0-9.]*|node|perl|php|lua)'
if printf '%s' "$CMD" | grep -Eq "${START}(bundle[[:space:]]+exec[[:space:]]+)?${INTERP}([[:space:]]|\$)" ||
   printf '%s' "$CMD" | grep -Eq "${START}(ba|z)?sh[[:space:]]+-c([[:space:]]|\$)"; then
  cat >&2 <<'MSG'
Refused: repo tasks run through the hecks binary, not ad-hoc interpreters or inline shell.
  exe/hecks                       lists every command and query
  exe/hecks <command> --help      says what one wants
If no command does what you need, add one to the bluebook (CLAUDE.md, "Use the hecks binary").
git, jj, gh, cargo, aws and the other tools are not affected.
MSG
  exit 2
fi
exit 0
