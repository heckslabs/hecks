# frozen_string_literal: true

require_relative "bound_gate"
require "hecks/hecks/adapters/git_worktrees"

module Hecks
  module Adapters
    class GitLanding
      # A merge train: the holder of the front place lands every branch whose ticket declared it
      # ready,
      # in ticket order, without giving the place up between them.
      #
      # Each branch is rebased onto the moving `onto`, run through the quick gate, then landed by
      # the
      # same steps a single landing takes. A branch that conflicts, fails the gate or overlaps
      # another
      # started row's area is skipped with its reason; the verdict goes into its ticket, so the
      # waiting
      # `land!` of that branch returns the answer or the refusal, and the others go on.
      class Train
        include GitWorktrees

        # What the train works with.
        #
        # @!attribute [r] line
        #   @return [Line] the line
        # @!attribute [r] ticket
        #   @return [Ticket] the train's own ticket, at the front
        # @!attribute [r] land
        #   @return [#call] `(checkout, branch, onto)` lands one branch, answering the landing hash
        # @!attribute [r] gate
        #   @return [#call] `(directory)` answers nil when the quick gate is green, else why it is
        # not
        Crew = Struct.new(:line, :ticket, :land, :gate)

        # The gate of a train run with no booted project: none is bound, so it refuses.
        QUICK_GATE = BoundGate.new(nil).method(:refusal)

        # @param text [String] some output
        # @param count [Integer] how many lines
        # @return [String] the last lines of it
        def self.tail(text, count)
          lines = text.lines.last(count)
          lines.map(&:strip).join(" ")
        end

        # @param git [Git] the adapter every git call goes through
        # @param checkout [String] the repository's top level
        # @param crew [Crew] the line, the ticket and the steps
        # @param onto [String] the branch the train lands on
        def initialize(git, checkout, crew, onto:)
          @git = git
          @checkout = checkout
          @crew = crew
          @onto = ref(onto)
        end

        # @return [String] a sentence saying which branches landed and which were skipped, and why
        def run
          settled = []
          while (ticket = @crew.line.next_ready(@crew.ticket))
            settled << carry(ticket)
          end
          settled.empty? ? "no branch was waiting in the line" : settled.join("; ")
        end

        private

        def carry(ticket)
          held = ticket.data
          ticket.update(handled: true)
          answer = lands(held)
          ticket.deliver(landed: answer)
          "landed #{held[:branch]}"
        rescue ConsoleCapture::Failure => e
          ticket.deliver(refused: e.message)
          "skipped #{held[:branch]}: #{e.message}"
        end

        def lands(held)
          rebase(held[:branch])
          why = @crew.gate.call(worktree_on(held[:branch])&.path || @checkout)
          raise ConsoleCapture::Failure, why if why

          @crew.land.call(held[:checkout], held[:branch], @onto)
        end

        def rebase(branch)
          tree = worktree_on(branch)
          return unless tree

          result = @git.capture("rebase", @onto, chdir: tree.path)
          return if result.ok?

          @git.capture("rebase", "--abort", chdir: tree.path)
          raise ConsoleCapture::Failure, "#{branch} does not rebase onto #{@onto}: #{Train.tail(result.out, 2)}"
        end
      end
    end
  end
end
