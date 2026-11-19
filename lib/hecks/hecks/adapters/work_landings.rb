# frozen_string_literal: true

require "hecks/hecks/adapters/git"
require "hecks/hecks/adapters/console_capture"
require "hecks/hecks/adapters/dispatching/work_items"

module Hecks
  module Adapters
    # The `WorkLandings` port's adapter for `Tickets::Work`: finds a landing of a work item's
    # branch that is on main.
    #
    # It reads the fact a dependency's wait reads ({Dispatching::LandingFacts#landed_commits}: the
    # commits landed `Landing` records name for the item's branch) and keeps the first one `main`
    # contains. It states the fact and judges nothing: closing the item is the Tickets bluebook's.
    # It reads and never writes.
    class WorkLandings
      # @param registry [Runtime::Registry, nil] the booted registry whose Landing records are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `root:` the checkout whose `main` is read (the working directory
      #   when absent)
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @checkout = settings[:root]
        @git = Git.new
      end

      # @param held [Hash] the Work item: `work`
      # @return [Hash{Symbol => Hash}] `landing:` the landed commit `main` contains
      # @raise [ConsoleCapture::Failure] naming the work item when no landing of it is on main
      def check_landing(**held)
        key = held[:work].is_a?(Hash) ? held[:work][:value].to_s : held[:work].to_s
        found = Dispatching::WorkItems.new(@registry).landed_commits(key).find { |sha| on_main?(sha) }
        raise ConsoleCapture::Failure, refusal(key) unless found

        { landing: { value: found } }
      end

      private

      def on_main?(sha) = @git.ancestor?(sha, "main", chdir: @checkout)

      def refusal(key)
        "#{key} has no landing on main: land its branch, or finish it with no_change.value=<why> " \
          "when it lands nothing"
      end
    end
  end
end
