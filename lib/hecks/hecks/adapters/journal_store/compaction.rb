# frozen_string_literal: true

require_relative "../../../../hecks"

module Hecks
  module Adapters
    class JournalStore
      # The journals of one booted domain that can be compacted, and what compacting them does.
      #
      # `:entries` are Postgres and Sqlite journals, compacted through the aggregate's own
      # checkpoint (`compact_entries!`); `:heki` journals are compacted to empty (`compact!`),
      # the snapshot keeping the current state. The database-level guard, that the
      # `compacted_through` floor only moves forward, stays in the adapter that owns the journal.
      class Compaction
        Candidate = Struct.new(:domain_name, :aggregate, :adapter, keyword_init: true)

        KINDS = { entries: %i[compact_entries! checkpoint], heki: %i[compact!] }.freeze

        # @param path [String] the domain directory
        # @param aggregates [Array<String>] aggregate names or storage names; every one when empty
        # @param kind [Symbol] `:entries` or `:heki`
        # @raise [Runtime::NotFound] if the directory does not exist
        def initialize(path, aggregates:, kind:)
          raise Runtime::NotFound, "no such domain #{path.inspect}" unless Dir.exist?(path.to_s)

          @registry = Hecks.boot(File.expand_path(path), install_facade: false).registry
          @wanted = aggregates
          @kind = kind
        end

        # @return [Array<Candidate>] the aggregates whose journals this kind can compact
        def candidates
          @candidates ||= @registry.bluebooks.flat_map do |domain_name, bluebook|
            bluebook.aggregates.filter_map { |aggregate| candidate(domain_name, aggregate) }
          end
        end

        # The candidates a `projected_by` binding reads: their projections replay the full journal.
        #
        # @return [Array<Candidate>] the bound candidates
        def bound
          candidates.select do |candidate|
            Ports::Projection.binds_for(@registry, candidate.domain_name, candidate.aggregate).any?
          end
        end

        # What compacting would do, without doing it.
        #
        # @return [Array<String>] one line per candidate
        def preview
          candidates.map { |candidate| bound.include?(candidate) ? refusal_line(candidate) : dry_line(candidate) }
        end

        # Compacts every candidate.
        #
        # @return [Array<String>] one line per candidate
        # @raise [Runtime::WiringError] if a projection reads a journal that would be emptied, or
        #   the journal's own floor refuses the compaction
        def apply!
          raise Runtime::WiringError, preview.grep(/^REFUSED/).join("\n") if bound.any?

          candidates.map { |candidate| kind_apply(candidate) }
        end

        private

        def candidate(domain_name, aggregate)
          return unless @wanted.empty? || @wanted.include?(aggregate.hecks_name) || @wanted.include?(aggregate.storage_name)

          repository = @registry.repository(domain_name, aggregate)
          return unless repository.is_a?(Ports::Persistence::AppendOnly)

          adapter = repository.adapter
          return unless KINDS.fetch(@kind).all? { |operation| adapter.respond_to?(operation) }

          Candidate.new(domain_name: domain_name, aggregate: aggregate, adapter: adapter)
        end

        def kind_apply(candidate)
          @kind == :heki ? compact_heki(candidate) : compact_entries(candidate)
        end

        def dry_line(candidate)
          @kind == :heki ? heki_dry(candidate) : entries_dry(candidate)
        end

        def refusal_line(candidate)
          "REFUSED #{candidate.aggregate.storage_name}: a projected_by binding reads its full journal — " \
            "compacting would break its catch-up. Not compacted."
        end

        def entries_dry(candidate)
          name = candidate.aggregate.storage_name
          adapter = candidate.adapter
          through = adapter.checkpoint
          if through <= adapter.compacted_through
            return "SKIP #{name}: nothing new to compact (already compacted through #{through})"
          end

          "DRY RUN #{name}: would delete journal entries through sequence #{through} (compacted_through is " \
            "currently #{adapter.compacted_through}); current state (#{adapter.count} records) is unaffected."
        end

        def compact_entries(candidate)
          name = candidate.aggregate.storage_name
          adapter = candidate.adapter
          through = adapter.checkpoint
          if through <= adapter.compacted_through
            return "SKIP #{name}: nothing new to compact (already compacted through #{through})"
          end

          removed = adapter.compact_entries!(through: through)
          "COMPACTED #{name}: deleted #{removed} journal entries through sequence #{through}; " \
            "#{adapter.count} records preserved"
        end

        def heki_dry(candidate)
          name = candidate.aggregate.storage_name
          adapter = candidate.adapter
          return "SKIP #{name}: journal already empty" if adapter.entries.empty?

          "DRY RUN #{name}: would discard #{adapter.entries.length} journal entries (#{journal_bytes(adapter)} " \
            "bytes) at #{adapter.path}.journal; current state (#{adapter.count} records) is unaffected."
        end

        def compact_heki(candidate)
          name = candidate.aggregate.storage_name
          adapter = candidate.adapter
          entries = adapter.entries.length
          return "SKIP #{name}: journal already empty" if entries.zero?

          bytes = journal_bytes(adapter)
          adapter.compact!
          "COMPACTED #{name}: discarded #{entries} journal entries (#{bytes} bytes freed); " \
            "#{adapter.count} records preserved at #{adapter.path}"
        end

        def journal_bytes(adapter)
          path = "#{adapter.path}.journal"
          File.exist?(path) ? File.size(path) : 0
        end
      end
    end
  end
end
