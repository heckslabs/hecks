# frozen_string_literal: true

module Hecks
  module Adapters
    class MainIntegration
      # The shell step that keeps the train copy at local main's tip. The copy holds no work, so a
      # clean detached copy whose head is not main moves to main, whether main moved forward or was
      # rewritten (a rebase of its unpushed commits leaves the copy's head off main's history). The
      # move is a detached checkout, never a reset. Every case where the copy stays put says why in
      # one stamped line of the beat's overrun log, outside the group whose stderr is dropped, and a
      # line the log already ends with is not said again. The reasons: a copy on a branch, a copy
      # with no main, a tracked change (untracked files do not count), a Ticker or advance running
      # from the copy, and a move that fails. The step is plain POSIX shell, so it needs no zsh and
      # runs on a copy that predates any code of the domain.
      module FollowMain
        # Where a refused follow is said, beside the beat's other skipped-beat lines.
        LOG = "\"$HOME/.claude/hecks-dev/train-beat.overrun.log\""

        # What the log line says when the copy is dirty.
        REFUSAL = "train copy has a tracked change, not following main"

        # What the log line says when the move to main fails, an untracked file in the way for one.
        STUCK = "train copy could not move to main (an untracked file in the way?)"

        # What the log line says when the copy is on a branch, which is not the beat's to move.
        BRANCH = "train copy is on a branch, not following main"

        # What the log line says when the copy's repository has no main.
        NO_MAIN = "train copy has no main to follow"

        # What the log line says when a train process (a ticker or an advance) runs from the copy.
        BUSY = "a train process runs from the train copy, not following main"

        # @return [String] the step, run from the copy's root; it always ends well
        def self.step
          "{ if git symbolic-ref -q HEAD >/dev/null; then #{say(BRANCH)}; " \
            "elif ! git rev-parse -q --verify main >/dev/null; then #{say(NO_MAIN)}; " \
            "elif [ \"$(git rev-parse HEAD)\" = \"$(git rev-parse main)\" ]; then :; " \
            "elif ! git diff --quiet HEAD; then #{say(REFUSAL)}; " \
            "elif #{busy}; then #{say(BUSY)}; " \
            "else git checkout -q --detach main || #{say(STUCK)}; fi; } 2>/dev/null; true"
        end

        # A process whose command names a Ticker or an advance and whose working directory is the
        # copy. The patterns are bracketed so the step's own shell never matches them; with no
        # `lsof` or `pgrep` nothing is found.
        #
        # @return [String] a shell condition, true when one runs from the copy
        def self.busy
          "{ command -v lsof >/dev/null && command -v pgrep >/dev/null && found= && " \
            "for p in $(pgrep -f '[T]icker|[a]dvance'); do [ \"$p\" != \"$$\" ] && " \
            "lsof -a -d cwd -p \"$p\" -Fn | grep -qx \"n$(pwd -P)\" && found=1; done; [ -n \"$found\" ]; }"
        end

        # @param text [String] the line to append to the overrun log
        # @return [String] shell that appends the line, stamped, unless the log already ends with it
        def self.say(text)
          "{ mkdir -p \"$(dirname #{LOG})\" && " \
            "[ \"$(tail -n 1 #{LOG} | cut -d' ' -f2-)\" = \"#{text}\" ] || " \
            "echo \"$(date -u +%FT%TZ) #{text}\" >> #{LOG}; }"
        end
      end
    end
  end
end
