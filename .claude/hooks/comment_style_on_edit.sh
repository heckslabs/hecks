#!/bin/sh
# PostToolUse hook for Edit/Write: checks the comments of the edited .rb file against
# docs/COMMENT_STYLE_GUIDE.md and, on a violation, prints it to stderr and exits 2 so the agent
# sees it in the same turn instead of at the push gate.
FILE=$(ruby -rjson -e 'puts(JSON.parse($stdin.read).dig("tool_input", "file_path").to_s)' 2>/dev/null)
case "$FILE" in
  *.rb) ;;
  *) exit 0 ;;
esac
[ -f "$FILE" ] || exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
OUT=$(HECKS_ENVIRONMENT=memory exe/hecks style_run.check_comments "paths=$FILE" --wait 2>&1)
printf '%s' "$OUT" | grep -q StyleCompleted && exit 0
VIOLATIONS=$(printf '%s' "$OUT" | grep -oE '[^ "]+:[0-9]+: \[[a-z_]+\][^"\\]*' | sort -u)
[ -n "$VIOLATIONS" ] || exit 0
printf 'comment style found violations in %s (docs/COMMENT_STYLE_GUIDE.md); fix them before moving on:\n%s\n' \
  "$FILE" "$VIOLATIONS" >&2
exit 2
