# frozen_string_literal: true

require "json"
require "hecks/hecks/adapters/started_work"
require_relative "work_show/overlaps"

module Hecks
  module Adapters
    # The `WorkShow` port's adapter for `Tickets::Work`: answers one work item as JSON, with the
    # started work items whose claimed area meets its own.
    #
    # `overlap` reads claimed areas only, by {AreaOverlap}; it does not read the files a branch
    # changes, so a fill that judges by those may skip an item this shows no overlap for. It judges
    # nothing and writes nothing.
    class WorkShow
      # @param registry [Runtime::Registry, nil] the booted registry whose Work items are read
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
      end

      # @param held [Hash] the query's `work`, the key of the work item
      # @return [Hash{Symbol => String}] `text:` the work item as JSON, ending in a newline
      # @raise [ConsoleCapture::Failure] when no work item has that key
      def show(**held)
        key = held[:work].is_a?(Hash) ? held[:work][:value] : held[:work]
        record = records.find { |entry| fact(entry, :work).to_s == key.to_s }
        raise ConsoleCapture::Failure, "no work item #{key}" unless record

        { text: "#{JSON.pretty_generate(describe(record))}\n" }
      end

      private

      def describe(record)
        area = StartedWork.words(fact(record, :area))
        { work: fact(record, :work).to_s, title: fact(record, :title).to_s, status: fact(record, :status).to_s,
          claimed_by: fact(record, :claimed_by).to_s, area: area,
          overlap: Overlaps.new(StartedWork.items(@registry)).of(fact(record, :work).to_s, area) }
      end

      def fact(record, name) = StartedWork.value(record, name)

      def records
        aggregate = StartedWork.work_aggregate(@registry)
        aggregate ? @registry.repository("Tickets", aggregate).all : []
      end
    end
  end
end
