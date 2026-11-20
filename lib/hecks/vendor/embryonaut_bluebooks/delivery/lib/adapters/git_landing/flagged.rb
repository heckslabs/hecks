# frozen_string_literal: true

require_relative "bound_holds"
require_relative "gate_marker"

module Hecks
  module Adapters
    class GitLanding
      # What landing on main asks beyond any other landing: a base that is not behind origin, and
      # no flag the project's `Holds` port raises for the branch. A landing on main is recorded
      # with main's new commit, so what stands above delivery may act on it. The including class
      # answers `common_git_dir`, `@git`, `@registry` and `refuse_stale_base`.
      module Flagged
        include GateMarker::Gating

        private

        # @return [Object] what the block answers, run only after main's checks pass
        def on_main(branch, onto)
          return yield unless onto == "main"

          refuse_stale_base(branch)
          git_dir = common_git_dir
          holds = BoundHolds.new(@registry)
          holds.flag(branch, git_dir)
          yield.tap { holds.record_landing(branch, tip(git_dir), git_dir) }
        end

        # Main's commit, read against the git directory: the worktree a finish lands from is gone
        # by now.
        def tip(git_dir) = @git.capture("--git-dir=#{git_dir}", "rev-parse", "main").out.strip
      end
    end
  end
end
