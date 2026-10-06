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
    #   hecks compact <domain> [aggregate_name ...]           # dry run
    #   hecks compact <domain> [aggregate_name ...] --force   # apply
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
        return refuse_domain(domain) if domain.nil? || !Dir.exist?(domain)

        compact_domain(domain, argv.dup, force)
      end

      # @return [Integer] 1, after printing why and how to call it
      def refuse_domain(domain)
        warn "hecks compact: no such domain #{domain.inspect}"
        warn "usage: hecks compact <domain> [aggregate_name ...] [--force]"
        1
      end

      # @return [Integer] 0
      def compact_domain(domain, wanted, force)
        found = candidates(Hecks.boot(domain).registry, wanted)
        if found.empty?
          puts "hecks compact: no Postgres/Sqlite-backed aggregate matched " \
               "#{wanted.empty? ? "(any)" : wanted.inspect} in #{domain}"
          return 0
        end

        found.each { |candidate| compact_candidate(candidate, force: force) }
        0
      end

      # @param registry [Hecks::Runtime::Registry] the booted registry
      # @param wanted [Array<String>] aggregate names, or empty for every aggregate
      # @return [Array<Hash>] each compactable aggregate and its adapter
      def candidates(registry, wanted)
        registry.bluebooks.flat_map do |domain_name, bluebook|
          bluebook.aggregates.filter_map { |aggregate| candidate_for(registry, domain_name, aggregate, wanted) }
        end
      end

      # @return [Hash, nil] the aggregate and its adapter, when it is wanted and compactable
      def candidate_for(registry, domain_name, aggregate, wanted)
        return unless wanted.empty? || wanted.include?(aggregate.hecks_name) || wanted.include?(aggregate.storage_name)

        repository = registry.repository(domain_name, aggregate)
        return unless repository.is_a?(Hecks::Ports::Persistence::AppendOnly)

        adapter = repository.adapter
        { aggregate: aggregate, adapter: adapter } if compactable?(adapter)
      end

      def compactable?(adapter)
        adapter.respond_to?(:compact_entries!) && adapter.respond_to?(:checkpoint)
      end

      # @return [void]
      def compact_candidate(candidate, force:)
        aggregate = candidate[:aggregate]
        adapter   = candidate[:adapter]
        through   = adapter.checkpoint
        if through <= adapter.compacted_through
          return puts("SKIP #{aggregate.storage_name}: nothing new to compact (already compacted through #{through})")
        end
        return puts(dry_run_message(aggregate, adapter, through)) unless force

        removed = adapter.compact_entries!(through: through)
        puts "COMPACTED #{aggregate.storage_name}: deleted #{removed} journal entries through " \
             "sequence #{through}; #{adapter.count} records preserved"
      end

      def dry_run_message(aggregate, adapter, through)
        "DRY RUN #{aggregate.storage_name}: would delete journal entries through sequence " \
          "#{through} (compacted_through is currently #{adapter.compacted_through}); current " \
          "state (#{adapter.count} records) is unaffected. Re-run with --force to apply."
      end
    end
  end
end
