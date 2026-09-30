# frozen_string_literal: true

require "hecks"
require_relative "../tools"

module Hecks
  module Tools
    # Compacts a Postgres- or Sqlite-backed aggregate's journal: deletes entries already projected
    # into its own aggregate table (its own `checkpoint`), so a `:refresh` projection rebuild never
    # needs them. A `:strict` projection catch-up refuses loudly on its own if it is ever behind
    # what this deletes (see `Ports::Projection::Worker#catch_up!`).
    #
    #   bin/compact <domain> [aggregate_name ...]           # dry run
    #   bin/compact <domain> [aggregate_name ...] --force   # apply
    module JournalCompaction
      module_function

      # Reports, or with `--force` applies, the compaction of each matching aggregate's journal.
      #
      # @param argv [Array<String>] the domain directory, aggregate names and `--force`
      # @param root [String] unused: the domain is read from the path given
      # @return [Integer] 0, or 1 when the domain directory does not exist
      def main(argv, **)
        argv = argv.dup
        force = argv.delete("--force")
        domain = argv.shift
        if domain.nil? || !Dir.exist?(domain)
          warn "bin/compact: no such domain #{domain.inspect}"
          warn "usage: bin/compact <domain> [aggregate_name ...] [--force]"
          return 1
        end
        wanted = argv.dup

        registry = Hecks.boot(domain).registry
        candidates = candidates(registry, wanted)
        if candidates.empty?
          puts "bin/compact: no Postgres/Sqlite-backed aggregate matched " \
               "#{wanted.empty? ? '(any)' : wanted.inspect} in #{domain}"
          return 0
        end

        candidates.each { |candidate| compact_candidate(candidate, force: force) }
        0
      end

      # @param registry [Hecks::Runtime::Registry] the booted registry
      # @param wanted [Array<String>] aggregate names, or empty for every aggregate
      # @return [Array<Hash>] each compactable aggregate and its adapter
      def candidates(registry, wanted)
        registry.bluebooks.each_with_object([]) do |(domain_name, bluebook), all|
          bluebook.aggregates.each do |aggregate|
            next unless wanted.empty? || wanted.include?(aggregate.hecks_name) || wanted.include?(aggregate.storage_name)

            repository = registry.repository(domain_name, aggregate)
            next unless repository.is_a?(Hecks::Ports::Persistence::AppendOnly)

            adapter = repository.adapter
            next unless adapter.respond_to?(:compact_entries!) && adapter.respond_to?(:checkpoint)

            all << { aggregate: aggregate, adapter: adapter }
          end
        end
      end

      # @return [void]
      def compact_candidate(candidate, force:)
        aggregate = candidate[:aggregate]
        adapter   = candidate[:adapter]
        through   = adapter.checkpoint

        if through <= adapter.compacted_through
          puts "SKIP #{aggregate.storage_name}: nothing new to compact (already compacted through #{through})"
          return
        end

        unless force
          puts "DRY RUN #{aggregate.storage_name}: would delete journal entries through sequence " \
               "#{through} (compacted_through is currently #{adapter.compacted_through}); current " \
               "state (#{adapter.count} records) is unaffected. Re-run with --force to apply."
          return
        end

        removed = adapter.compact_entries!(through: through)
        puts "COMPACTED #{aggregate.storage_name}: deleted #{removed} journal entries through " \
             "sequence #{through}; #{adapter.count} records preserved"
      end
    end
  end
end
