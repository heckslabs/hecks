#!/usr/bin/env bash
# PostToolUse hook: run RuboCop on the Ruby file an agent just edited.
# Offenses exit 2, which hands the report back to the agent so it fixes them
# before moving on. A broken RuboCop setup warns and never blocks an edit.
set -u

input="$(cat)"
file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')"
[ -n "$file" ] || exit 0
case "$file" in
  *.rb) ;;
  *) exit 0 ;;
esac

root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$root" || exit 0
[ -f "$file" ] || exit 0

# Pass a repo-relative path so --force-exclusion applies the Exclude globs.
case "$file" in
  "$root"/*) rel="${file#"$root"/}" ;;
  *) rel="$file" ;;
esac

out="$(bundle exec rubocop -c .rubocop.yml --force-exclusion --format emacs "$rel" 2>&1)"
status=$?

case "$status" in
  0) exit 0 ;;
  1)
    {
      echo "RuboCop found offenses in $rel. Fix them before continuing:"
      printf '%s\n' "$out"
    } >&2
    exit 2
    ;;
  *)
    {
      echo "RuboCop could not run on $rel (exit $status); edit not blocked:"
      printf '%s\n' "$out" | tail -n 20
    } >&2
    exit 0
    ;;
esac
