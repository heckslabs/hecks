# frozen_string_literal: true

require "hecks/hecks/adapters/started_work"

module Hecks
  module Adapters
    class RecordIndex
      # The records the index covers, read from the booted Tickets store and never written: each
      # work item, finding and decision as its kind, its id and the text a search looks in.
      class Records
        # Kind, aggregate, key field and the fields whose text is searched.
        SOURCES = [
          ["work", "Work", :work, %i[title detail]],
          ["finding", "Finding", :finding, %i[title body]],
          ["decision", "Adr", :adr, %i[title]]
        ].freeze

        # @param registry [Runtime::Registry, nil] the booted registry; nil reads nothing
        def initialize(registry)
          @registry = registry
        end

        # @return [Array<Array(String, String, String)>] each record as kind, id and text
        def all
          SOURCES.flat_map { |kind, name, key, fields| of(kind, name, key, fields) }
        end

        private

        def of(kind, name, key, fields)
          aggregate = find(name)
          return [] unless aggregate

          @registry.repository("Tickets", aggregate).all.map do |record|
            [kind, read(record, key), fields.map { |field| read(record, field) }.reject(&:empty?).join(" ")]
          end
        end

        def find(name)
          bluebook = @registry&.bluebook("Tickets")
          bluebook&.aggregates&.find { |candidate| candidate.hecks_name == name }
        end

        def read(record, field) = StartedWork.value(record, field).to_s
      end
    end
  end
end
