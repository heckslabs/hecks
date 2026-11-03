# frozen_string_literal: true

require_relative "../red_flag_guard"

module Hecks
  module Adapters
    class GitLanding
      # What landing on main asks beyond any other landing: a base that is not behind origin, and
      # no standing red flag unless the branch is a red Work item's fix. A fix that lands records
      # its tip
      # on the flag so the push train may board it. The including class answers `common_git_dir`,
      # `@git` and `refuse_stale_base`.
      module Flagged
        private

        # @return [Object] what the block answers, run only after main's checks pass
        def on_main(branch, onto)
          return yield unless onto == "main"

          refuse_stale_base(branch)
          git_dir = common_git_dir
          guard = RedFlagGuard.new(git_dir)
          guard.landing!(branch)
          yield.tap { guard.landed(branch, tip(git_dir)) }
        end

        # Main's commit, read against the git directory: the worktree a finish lands from is gone
        # by now.
        def tip(git_dir) = @git.capture("--git-dir=#{git_dir}", "rev-parse", "main").out.strip
      end
    end
  end
end
