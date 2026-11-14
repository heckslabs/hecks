# frozen_string_literal: true

require_relative "swap"
require "hecks/hecks/adapters/console_capture"

module Hecks
  module Adapters
    class GitLanding
      # A landing with no line: each try reads the target, builds on it and moves the target by a
      # compare-and-swap; a try that finds the target moved is made again from the new commit.
      #
      # Every try runs its own checks again (unsaved work, rivals, a stale base, a red flag), so a
      # flag raised between two tries stops the landing. Nothing waits for another landing: two
      # that start together both land, the second after one more try. A gated landing pays for a
      # lost try with another rebase and another gate run.
      module Swapping
        # How many tries a landing makes before it is refused because the target keeps moving.
        TRIES = 5

        private

        # Runs the block, a whole try, until its swap wins.
        #
        # @param branch [String] the branch being landed
        # @param onto [String] the branch it lands on
        # @yieldreturn [Hash] the landing answer of a try that moved the target
        # @return [Hash] that answer, saying how many tries were lost on the way
        # @raise [ConsoleCapture::Failure] when every try was lost; a landing job runs it again
        def swapped(branch, onto)
          lost = 0
          begin
            again(yield, onto, lost)
          rescue Swap::Lost
            retry if (lost += 1) < TRIES
            raise ConsoleCapture::Failure, "queue busy: #{onto} moved #{TRIES} times while #{branch} was landing; " \
                                           "nothing changed; land again"
          end
        end

        def again(said, onto, lost)
          return said if lost.zero?

          note = "#{onto} moved #{lost} time#{"s" unless lost == 1} meanwhile, so the landing was built again"
          said.merge(report: { value: "#{said[:report][:value]}; #{note}" })
        end
      end
    end
  end
end
