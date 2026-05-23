# i720 — GitTool / GitHubTool phase-2 exec substrate

GitTool and GitHubTool (shipped in tonight's commit) are contract-only. The bluebook
is valid and the behaviors are green, but no `:git` / `:gh` exec adapter exists yet.
Dispatching any GitTool or GitHubTool command falls through to the no-op runtime arm.

## What phase-2 needs

**For GitTool** — a `:git` arm of the exec dispatcher :

1. Map command name → git subcommand (`Status` → `git status`, `Diff` → `git diff`,
   `Add` → `git add <files...>`, `Commit` → `git commit -m <message> <files...>`,
   `Log` → `git log`, `Mv` → `git mv <from> <to>`, `Push` → `git push <remote>
   <branch>`).
2. Run with `cwd = repo` (the `repo` attribute is the working directory — no shell
   `cd`; pass it as `std::process::Command::current_dir`).
3. Capture stdout + exit code ; chain through `result_into: Cascade.RecordResult`.

**For GitHubTool** — a `:gh` arm :

1. Map command name → gh subcommand (`RepoView` → `gh repo view <repo_slug>`,
   `RepoRename` → `gh repo rename <new_name> --repo <repo_slug>`, `PrCreate` → `gh
   pr create --title <title> --body <body>`, `PrView` → `gh pr view <pr_ref>`).
2. `PrCreate` / `PrView` run with `cwd = repo` ; `RepoView` / `RepoRename` are
   stateless (no cwd required).
3. Capture stdout + exit code ; chain through `result_into: Cascade.RecordResult`.

## Placement

The exec dispatcher lives alongside `claude_tool_dispatcher` and
`web_tool_dispatcher` in the runtime kernel. Extend or add a `git_dispatcher` and
`gh_dispatcher` there.
