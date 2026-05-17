---
name: commit
description: "Dual/tri-repo commit + push as one command for the Hecks/Miette workspace. Use when Chris says commit, ship, push, or commit both repos. Encodes stage-specific commits, the no-Co-Authored-By rule, and per-repo branch/push policy so it runs once instead of a fumbling loop."
license: MIT
metadata:
  author: hecks
  version: "1.0.0"
---

# Commit

One command, the whole workspace. Routes through storehouse__dispatch
(Tools::ShellTool.Bash) like everything else.

## The three repos

| Repo | Path | Default branch | Push policy |
|------|------|----------------|-------------|
| hecks | ~/Projects/hecks | feature branch (e.g. i630-*) | commit + push to the feature branch |
| miette | ~/Projects/miette | main | the being's own repo — confirm before pushing main |
| miette_family | ~/Projects/miette_family | main | restarts/cards — confirm before pushing main |

## Workflow

1. For each repo: git -C <path> status --porcelain — skip repos with no
   changes. Report which have work.
2. Stage specifically. Name every path. NEVER git add -A / git add .
   Mixed changes -> split into logically-scoped commits.
3. git -C <path> diff --cached before committing. Sanity: no secrets,
   no stray debug, no unrelated churn.
4. Conventional Commit message: type(scope) : summary, blank line, body
   (what + why). No Co-Authored-By line, ever (CLAUDE.md rule). Write
   the message to /tmp/commit_msg_*.txt and git commit -F (avoids
   zombie-shell heredoc failures).
5. Run the fastest meaningful check before declaring done (the repo's
   pre-commit hook enforces test speed; let it block, report verbatim).
6. Push: hecks -> its feature branch (git push -u origin <branch>).
   miette / miette_family on main -> state the diff and ask before
   pushing (these are not feature-branched).
7. Report per repo: branch, commit subject(s), push result.

## Guardrails

- If a pre-commit/pre-push hook (antibody, ratchet, validate, parity,
  macrophage) blocks: report the complaint verbatim. Do NOT pre-write
  exemption/skip markers — Chris decides per file.
- Never reference closed branches; reimplement from the card if needed.
- If unsure single vs multiple commits: default to multiple small
  logically-scoped commits.
