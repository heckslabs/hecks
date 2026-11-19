# frozen_string_literal: true

require_relative "conflict_settling"

module Hecks
  module Adapters
    module Landing
      # A rebase carried through its conflicts by {ConflictSettling}: each commit that stops in
      # conflict is settled and the rebase continued, until it ends, a conflict is refused, or
      # `LIMIT` commits have stopped. It never aborts the rebase; the caller does, as before.
      class RebaseSettling
        # The most stopped commits one rebase is carried through.
        LIMIT = 50

        # @param git [Hecks::Adapters::Git] the adapter every git call goes through
        # @param dir [String] the tree being rebased
        # @param identity [Array<String>] git's `-c` words naming who replays the commits
        def initialize(git, dir, identity = [])
          @git = git
          @dir = dir
          @identity = identity
        end

        # @param result [Hecks::Adapters::Shell::Result] the rebase's first answer
        # @return [Array(Hecks::Adapters::Shell::Result, String)] the rebase's last answer, and why
        #   it was not carried through (nil when it ended or stopped for no conflict)
        def settle(result)
          LIMIT.times do
            settling = ConflictSettling.new(@git, @dir)
            return [result, nil] if result.ok? || settling.conflicted.empty?

            why = settling.refusal
            return [result, why] if why

            result = @git.capture(*@identity, "-c", "core.editor=true", "rebase", "--continue", chdir: @dir)
          end
          [result, "more than #{LIMIT} commits stopped in conflict"]
        end
      end
    end
  end
end
