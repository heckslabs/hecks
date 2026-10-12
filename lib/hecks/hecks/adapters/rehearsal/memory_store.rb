# frozen_string_literal: true

require "json"
require_relative "rows"

module Hecks
  module Adapters
    module Rehearsal
      # The data copy as a JSON document the world names (`rows`): the eras held and the records
      # stored under the latest, in that era's shape. Nothing is created or dropped, so specs and
      # fixtures rehearse without a database.
      #
      # The document is `{"eras": [{"ordinal": 1, "held_text": "<bluebook text>"}], "records":
      # {"Aggregate": {"id": {"field": ...}}}}`.
      class MemoryStore
        # @param declaration [Declaration] a `memory` declaration
        def initialize(declaration)
          path = declaration.rows
          @document = path ? JSON.parse(File.read(path)) : {}
        end

        # @return [void]
        def prepare! = nil

        # @return [void] there is nothing to drop
        def drop! = nil

        # @param _subject [Subject] unused: the document holds its own eras
        # @return [Array<Hash>] the eras, `ordinal` and `held_text`
        def eras(_subject)
          Array(@document["eras"]).map { |era| { ordinal: era["ordinal"], held_text: era["held_text"] } }
        end

        # Runs the mint's audit over the stored records, translated through the edge in process.
        #
        # @param subject [Subject] the loaded domain
        # @param edge [Bluebook::Translation] the edge leading to the shape
        # @return [Array(Array<String>, Hash)] the audit's refusals, and the translated records
        #   by aggregate name and id
        def audit(subject, edge)
          refusals = []
          after = subject.bluebook.aggregates.to_h do |aggregate|
            declared = edge.for_aggregate(aggregate.name)
            before = records(declared&.was || aggregate.name)
            translated = translate(aggregate, declared, before)
            refusals.concat(Translation::Audit.check(aggregate: aggregate, declared: declared, before: before,
                                                     after: translated).violations)
            [aggregate.name, translated]
          end
          [refusals, after]
        end

        # @param edge [Bluebook::Translation] the edge
        # @return [Array<Hash>] what memory cannot apply, as report limits
        def limits(edge)
          return [] unless edge && Translation::ApprovalFile.needs_rehearsal?(edge)

          [{ what: "the edge's compute and rekey rules",
             why:  "they are SQL, which only a postgres copy runs; memory leaves those fields as stored" }]
        end

        private

        def records(name) = @document.dig("records", name.to_s) || {}

        def translate(aggregate, declared, before)
          lineage = Ports::Persistence::Lineage.from_declared(declared, aggregate.name)
          return before unless lineage

          before.to_h { |id, state| [id, lineage.translate(entry(id, state)).state] }
        end

        def entry(id, state)
          Ports::Persistence::Entry.new(operation: "save", id: id, state: symbolise(state), mirrors: {})
        end

        def symbolise(state) = JSON.parse(JSON.generate(state), symbolize_names: true)
      end
    end
  end
end
