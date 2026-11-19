# frozen_string_literal: true

require "hecks/hecks/adapters/started_work"
require "hecks/hecks/adapters/branch_work_names"

module Hecks
  module Adapters
    class DoneOffMain
      # The done work items no landed `Landing` names and that record neither a landing nor a
      # reason they land nothing: work marked done whose code may be on no branch at all.
      #
      # A landing names an item as {BranchWorkNames} reads its branch, the same fact a dependency's
      # wait reads. It reads the registry once and never writes.
      class Unlanded
        # @param registry [Runtime::Registry, nil] the booted registry whose Work items and Landing
        #   records are read
        def initialize(registry)
          @registry = registry
        end

        # @param done [Array<Object>] the done Work records
        # @param keys [Array<String>] every Work item's key
        # @return [Array<String>] the keys of the done items with no landing, in their order
        def keys(done, keys)
          landed = landed_keys(keys)
          done.reject { |record| vouched?(record) }.map { |record| value(record, :work) }.reject { |key| landed.include?(key) }
        end

        private

        def vouched?(record) = !value(record, :landing).empty? || !value(record, :no_change).empty?

        def landed_keys(keys)
          landings.select { |landing| value(landing, :status) == "landed" }
                  .flat_map { |landing| BranchWorkNames.of(value(landing, :branch), keys) }.to_set
        end

        def landings
          aggregate = landing_aggregate
          aggregate ? @registry.repository("Hecks", aggregate).all : []
        end

        def landing_aggregate
          bluebook = @registry&.bluebook("Delivery")
          bluebook&.aggregates&.find { |found| found.hecks_name == "Landing" }
        end

        def value(record, name) = StartedWork.value(record, name).to_s
      end
    end
  end
end
