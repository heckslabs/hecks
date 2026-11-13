# frozen_string_literal: true

require_relative "clone_run"

module Hecks
  module Adapters
    class GitShallowCheck
      # Says whether the specs a branch failed fail on the branch it lands on as well, by running
      # only those specs in a depth-1 clone of that branch.
      #
      # A spec red there too is not the landing branch's doing, so it does not refuse the landing.
      class OnMain
        # @param source [String] the repository to clone
        # @param onto [String] the branch the landing lands on
        # @param red [CloneRun::Red] what the landing branch's clone failed
        # @param run [Hash] what a spec changes in the clone run: `command:`
        def initialize(source, onto, red, **run)
          @onto = onto
          @red = red
          @there = red.specs.empty? ? nil : CloneRun.new(source, onto, **run, specs: red.specs).call
        end

        # @return [Boolean] whether every spec the branch failed is red where it lands too
        def excused? = @red.specs.any? && (@red.specs - shared).empty?

        # @return [String] the red, and for each failed spec whether it fails where the branch lands
        def to_s = "#{@red.text}; #{comparison}"

        private

        def shared = @there ? @red.specs & @there.specs : []

        def comparison
          return "not compared with #{@onto}" if @red.specs.empty?
          return "green in a depth-1 clone of #{@onto}, so the branch's change causes it" if shared.empty?
          return "red in a depth-1 clone of #{@onto} too, so the branch does not cause it" if excused?

          "#{shared.join(", ")} red in a depth-1 clone of #{@onto} too, the rest green there"
        end
      end
    end
  end
end
