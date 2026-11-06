# frozen_string_literal: true

require "json"
require_relative "rows"
require_relative "census"

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

        # The document's eras as a lineage stores them, each with the storage shape a mint records:
        # the document's own `projection` when it gives one, else the shape of its `held_text`,
        # which a document holds whole, since it is written as the domain's source.
        #
        # @param _subject [Subject] unused: the document holds its own eras
        # @return [Array<Hash>] the eras, `ordinal`, `held_text` and `projection`
        def eras(_subject)
          Array(@document["eras"]).map do |era|
            { ordinal: era["ordinal"], held_text: era["held_text"], projection: era["projection"] || shape_of(era["held_text"]) }
          end
        end

        # @return [Hash, nil] the storage shape a held text declares; nil for no text
        def shape_of(text)
          text && Runtime::StorageShape.project(PostgresRevisions::LineageManager.shadow(text))
        end

        # A document holds no ledger, so its watermark is zero and never moves.
        #
        # @param _subject [Subject] unused
        # @return [Integer] the ledger watermark
        def watermark(_subject) = 0

        # What the document holds: it keeps the latest state of each record only, so the head and
        # the journal counts are the same number.
        #
        # @param subject [Subject] the loaded domain
        # @return [Census] the counts
        def census(subject)
          counts = subject.aggregates.map do |aggregate|
            held = records(aggregate.name).size
            Census::Count.new(aggregate: aggregate.name, head: held, journal: held)
          end
          Census.new(schema: "(memory document)", source: "memory", present: true, eras: eras(subject).size,
                     journal_entries: counts.sum(&:journal), counts: counts)
        end

        # Runs the mint's audit over the stored records, translated through the edge in process.
        #
        # @param subject [Subject] the loaded domain
        # @param edge [Bluebook::Translation] the edge leading to the shape
        # @return [Array(Array<String>, Hash)] the audit's refusals, and the translated records
        #   by aggregate name and id
        def audit(subject, edge)
          refusals = []
          after = subject.aggregates.to_h do |aggregate|
            declared = edge.for_aggregate(aggregate.name)
            before = split_before(edge, aggregate) || records(declared&.was || aggregate.name)
            translated = translate(aggregate, declared, before)
            refusals.concat(Translation::Audit.check(aggregate: aggregate, declared: declared, before: before,
                                                     after: translated).violations)
            [aggregate.name, translated]
          end
          [refusals, after]
        end

        private

        # A split target's "before": its source's held records, fanned out one per key the split
        # names,
        # carrying the split's fields (ADR 0166). Nil when the aggregate is not a split target.
        def split_before(edge, aggregate)
          source, split = split_source_for(edge, aggregate)
          source && fan_out(records(source.was || source.name), split)
        end

        # The source aggregate and the split that feeds `aggregate`, or nil.
        def split_source_for(edge, aggregate)
          edge.aggregates.each do |source|
            split = source.splits.find { |candidate| candidate.into == aggregate.name }
            return [source, split] if split
          end
          []
        end

        # One target record per source record that carries the split's key, holding the split's
        # fields.
        def fanned_out(held, split)
          fields = split.fields.map(&:to_s)
          held.filter_map do |_id, state|
            key = split_key(state, split)
            [key.to_s, state.slice(*fields)] if key
          end.to_h
        end

        # A value object key is identified by its `value` member.
        def split_key(state, split)
          key = state[split.keyed_by.to_s]
          key.is_a?(Hash) ? key["value"] : key
        end

        def fan_out(held, split)
          fields = split.fields.map(&:to_s)
          held.filter_map { |_id, state| fanned_row(state, split.keyed_by.to_s, fields) }.to_h
        end

        # One target row keyed by the held record's key, a value object's `value` member when it has
        # one.
        def fanned_row(state, key, fields)
          value = state[key]
          value = value["value"] if value.is_a?(Hash)
          [value.to_s, state.slice(*fields)] if value
        end

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
