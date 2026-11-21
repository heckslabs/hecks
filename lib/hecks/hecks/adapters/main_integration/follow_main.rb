# frozen_string_literal: true

module Hecks
  module Adapters
    class MainIntegration
      # The shell step that keeps the train copy at local main's tip. The copy holds no work, so a
      # clean detached copy whose head is not main moves to main, whether main moved forward or was
      # rewritten (a rebase of its unpushed commits leaves the copy's head off main's history). A
      # copy on a branch is left alone. A copy with a tracked change is not reset: the step says so
      # in the beat's overrun log, outside the group whose stderr is dropped. Untracked files do not
      # count as a change. The step is one line of plain POSIX shell, so it needs no zsh and runs
      # on a copy that predates any code of the domain.
      module FollowMain
        # Where a refused follow is said, beside the beat's other skipped-beat lines.
        LOG = "\"$HOME/.claude/hecks-dev/train-beat.overrun.log\""

        # What the log line says when the copy is dirty.
        REFUSAL = "train copy has a tracked change, not following main"

        # @return [String] the step, run from the copy's root; it always ends well
        def self.step
          "{ ! git symbolic-ref -q HEAD >/dev/null 2>&1 && [ \"$(git rev-parse HEAD)\" != \"$(git rev-parse main)\" ] && " \
            "if git diff --quiet HEAD; then git checkout -q --detach main; " \
            "else mkdir -p \"$(dirname #{LOG})\" && echo \"$(date -u +%FT%TZ) #{REFUSAL}\" >> #{LOG}; fi; } 2>/dev/null; true"
        end
      end
    end
  end
end
