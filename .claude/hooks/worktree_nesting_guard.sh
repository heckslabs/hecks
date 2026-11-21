#!/usr/bin/env bash
# PreToolUse hook for EnterWorktree: refuses it when the session already stands in a linked
# worktree, because the Claude Code harness puts the new worktree under the current directory's
# .claude/worktrees, and a worktree inside another worktree vanishes from sight when the outer one is
# retired. The refusal exits 2 and hands the fix back to the session.
#
# The check is one comparison of `git rev-parse --git-dir` with `--git-common-dir`, so it holds no
# domain rule: the hecks verbs that open a worktree resolve their target from the primary checkout
# themselves (GitWorktreeAdd). It runs for every session, with or without a role, so the owner's is
# covered too. When git cannot answer (not a repository, git missing) the call is let through: it
# guards a rare mistake, and a wrong refusal would stop honest work.
set -u

input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"
[ "$tool" = "EnterWorktree" ] || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
[ -n "$cwd" ] || cwd="$(pwd)"
git_dir="$(git -C "$cwd" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || exit 0
common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
[ "$git_dir" != "$common" ] || exit 0

primary="$(dirname "$common")"
echo "worktree_nesting_guard: $cwd is already a linked worktree, and EnterWorktree would open the new" \
  "one inside it. Keep working in this worktree, or create the new one under the primary checkout:" \
  "git -C $primary worktree add $primary/.claude/worktrees/<name> -b <branch>" >&2
exit 2
