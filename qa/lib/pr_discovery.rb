# frozen_string_literal: true

module Hecks
  module QA
    # THE ONE FILTER THAT DECIDES WHAT COUNTS AS "OURS" — pulled out of
    # bin/qa_pr_check itself, into a real, namespaced, `require_relative`-
    # able module rather than a top-level method the script used to
    # define, so spec/bin_qa_pr_check_spec.rb can exercise it directly
    # without `load`ing the whole script (which would define its own
    # top-level methods and constants — `field`, `q`, `gh`, `ROOT` among
    # them — as PRIVATE METHODS AND CONSTANTS ON `Object` ITSELF, visible
    # to every other spec file in the same process for the rest of the
    # run. Confirmed live, not assumed: an earlier version of this file
    # did exactly that, and the full suite's own example count went
    # flaky — 2560, then 1646, then 133, then 49, run to run, depending
    # on file-load order and which examples elsewhere happened to shadow
    # or collide with a same-named private method. Moving here fixes it
    # at the root: nothing this module defines escapes the `Hecks::QA`
    # namespace.
    #
    # THIS IS THE EXACT PIECE THAT WAS WRONG. An earlier version of
    # bin/qa_pr_check asked `gh pr list --search "head:loop-parity"` —
    # branch name only — which is how PR #534 (title "qa: fix
    # quality_control.world's dropdb guidance; pin dotted-hop shadow-parse
    # behavior", genuinely open, red CI, DRAFT) went completely invisible:
    # its branch is `worktree-agent-<hash>` (opened from an agent
    # worktree, never renamed to `loop-parity/<slug>` per
    # .claude/skills/hecks_qa/SKILL.md's own convention). Confirmed live,
    # not assumed, against the real repo: `gh pr list --search
    # "head:loop-parity" --state open` was empty while `gh pr list --state
    # open` showed exactly that one PR. Separately confirmed live: `gh pr
    # list` does NOT exclude drafts by default, with or without
    # `--search` — #534 (isDraft: true) showed up in a bare listing, in
    # `--search "qa:"`, and even in `--search "is:draft"`. A real
    # draft-exclusion bug here would have hidden 100% of what this script
    # exists to watch (every `hecks_qa`-originated PR is kept draft
    # forever, per SKILL.md: "Never auto-merge. Draft, always"), so it was
    # worth checking for real — it just turned out not to be the actual
    # defect.
    #
    # A PR counts if EITHER its title starts with this repository's own
    # `qa:` convention (every hecks_qa commit and PR — the durable signal,
    # true regardless of how the branch got named) OR its branch still
    # follows the `loop-parity/<slug>` convention. Neither is a strict
    # superset of the other in practice — real history has `loop-parity/*`
    # PRs titled `heki:`/`BUG#N:`/`rust:` (not `qa:`), so branch-only
    # discovery is kept alongside title discovery rather than replaced by
    # it. Says nothing about draft state — a draft is exactly as
    # candidate as a ready-for-review PR.
    module PrDiscovery
      QA_TITLE_PREFIX = "qa:"
      LOOP_PARITY_BRANCH_PREFIX = "loop-parity/"

      def self.candidate?(pull_request)
        title  = pull_request[:title].to_s
        branch = pull_request[:headRefName].to_s

        title.start_with?(QA_TITLE_PREFIX) || branch.start_with?(LOOP_PARITY_BRANCH_PREFIX)
      end
    end
  end
end
