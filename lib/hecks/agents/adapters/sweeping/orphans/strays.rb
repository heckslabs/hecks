# frozen_string_literal: true

module Hecks
  module Adapters
    class Sweeping
      class Orphans
        # The processes of three named shapes that run past a time limit bound to no held run: a
        # ticker's `tick` fork, a resident fork of a worktree, and a mock-up `serve.rb`. A positive
        # list: a board, the push train, a wait on an event and every other launcher the {Rules}
        # keep are never read here, however old.
        #
        # A process is bound to a held run when its command names a held branch; a live tick that
        # names none is stopped after the age. Never a pid of 1 or below. The primary
        # checkout's resident is bound by being the primary: only a resident of a worktree under
        # `.claude/worktrees` can be a stray. The age and binding judgment is the adapter's, as the
        # launcher rules are; the bluebook says only that a stray is stopped.
        class Strays
          # How long a process of these shapes may run unbound before it is a stray, in seconds.
          AGE = 3600
          # The three shapes, anchored to the program: a tick fork, a worktree's resident fork, a
          # mock-up server. An editor or a `grep` that only names `serve.rb` is not one.
          SHAPE = %r{\A(?:ruby\s+-e\s.*Ticking::Chain|
                   (?:\S*/)?exe/hecks\s+Ticker\.tick!|
                   hecks\s+resident\s.*/\.claude/worktrees/|ruby\s+(?:-\S+\s+)*\S*serve\.rb(?:\s|\z))}x

          # @param entries [Array<ProcessTable::Entry>] the process table
          # @param held [Array<String>] the branches an open item or a live run holds
          def initialize(entries:, held:)
            @entries = entries
            @held = held
          end

          # @return [Array<ProcessTable::Entry>] the strays, each to be stopped by its own pid
          def found = @entries.select { |entry| stray?(entry) }

          private

          def stray?(entry) = entry.pid > 1 && entry.age > AGE && entry.command.match?(SHAPE) && !bound?(entry)

          def bound?(entry) = @held.any? { |branch| entry.command.include?(branch) }
        end
      end
    end
  end
end
