#!/bin/sh
# PostToolUse hook for Edit/Write: runs rubocop on the edited .rb file and, on an offense,
# prints it to stderr and exits 2 so the agent sees it in the same turn.
FILE=$(ruby -rjson -e 'puts(JSON.parse($stdin.read).dig("tool_input", "file_path").to_s)' 2>/dev/null)
case "$FILE" in
  *.rb) ;;
  *) exit 0 ;;
esac
[ -f "$FILE" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
OUT=$(bundle exec rubocop -c .rubocop.yml --force-exclusion "$FILE" 2>&1) && exit 0
printf 'rubocop found offenses in %s; fix them before moving on:\n%s\n' "$FILE" "$OUT" >&2
exit 2
