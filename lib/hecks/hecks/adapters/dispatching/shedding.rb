# frozen_string_literal: true

require_relative "shed_survey"

module Hecks
  module Adapters
    class Dispatching
      # The question a rise of the load puts to the queue: which started work item could be asked
      # to yield. It reads the same work items and settings as the rest of {Dispatching}, which
      # includes this module, and answers facts; the Delegate bluebook's `Shed` policies decide.
      module Shedding
        # Surveys the started work items for the one to shed. It starts, stops and asks nothing.
        #
        # @param _held [Hash] the `Shed` record: `reading`, the reading that heard the load rise
        # @return [Hash{Symbol => Object}] `coders:`, `shedding:` and `candidate:` (see
        #   {ShedSurvey#to_h}), with the Tickets world's `min_coders:` and `at_once:`
        def survey(**_held)
          gauge = machine
          ShedSurvey.new(work_items, red: WorkItems.method(:red?)).to_h
                    .merge(min_coders: gauge.shed_min_coders, at_once: gauge.shed_at_once)
        end
      end
    end
  end
end
