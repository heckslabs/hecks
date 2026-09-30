# frozen_string_literal: true

require "hecks"
require_relative "../tools"

module Hecks
  module Tools
    # Compacts a Heki-backed aggregate's journal to empty; the snapshot keeps the current state.
    # Refuses any aggregate a `projected_by` binding reads, since projections replay the full
    # journal.
    #
    #   hecks compact_heki <domain> [aggregate_name ...]           # dry run
    #   hecks compact_heki <domain> [aggregate_name ...] --force   # apply
    module HekiCompaction
      module_function

      # Reports, or with `--force` applies, the compaction of each matching aggregate's journal.
      #
      # @param argv [Array<String>] the domain directory, aggregate names and `--force`
      # @param root [String] unused: the domain is read from the path given
      # @return [Integer] 0, or 1 when the domain does not exist or a projection refuses one
      def main(argv, **)
        argv = argv.dup
        force = argv.delete("--force")
        domain = argv.shift
        if domain.nil? || !Dir.exist?(domain)
          warn "hecks compact_heki: no such domain #{domain.inspect}"
          warn "usage: hecks compact_heki <domain> [aggregate_name ...] [--force]"
          return 1
        end
        wanted = argv.dup

        registry = Hecks.boot(domain).registry
        candidates = candidates(registry, wanted)
        if candidates.empty?
          puts "hecks compact_heki: no Heki-backed aggregate matched " \
               "#{wanted.empty? ? '(any)' : wanted.inspect} in #{domain}"
          return 0
        end

        refused = candidates.map { |candidate| refused_candidate?(registry, candidate, force: force) }
        refused.any? ? 1 : 0
      end

      # @param registry [Hecks::Runtime::Registry] the booted registry
      # @param wanted [Array<String>] aggregate names, or empty for every aggregate
      # @return [Array<Hash>] each compactable aggregate, its repository and adapter
      def candidates(registry, wanted)
        registry.bluebooks.each_with_object([]) do |(domain_name, bluebook), all|
          bluebook.aggregates.each do |aggregate|
            next unless wanted.empty? || wanted.include?(aggregate.hecks_name) || wanted.include?(aggregate.storage_name)

            repository = registry.repository(domain_name, aggregate)
            next unless repository.is_a?(Hecks::Ports::Persistence::AppendOnly)

            adapter = repository.adapter
            next unless adapter.respond_to?(:compact!)

            all << { domain_name: domain_name, aggregate: aggregate, repository: repository, adapter: adapter }
          end
        end
      end

      # @return [Boolean] true when a `projected_by` binding refuses the candidate
      def refused_candidate?(registry, candidate, force:)
        aggregate = candidate[:aggregate]
        adapter   = candidate[:adapter]
        bound     = Hecks::Ports::Projection.binds_for(registry, candidate[:domain_name], aggregate)

        if bound.any?
          warn "REFUSED #{aggregate.storage_name}: a projected_by binding reads its full journal " \
               "(#{bound.map(&:adapter).join(', ')}) — compacting would silently break " \
               "Projection::Worker#catch_up!/Registry#projection_current?. Not compacted."
          return true
        end

        journal_path = "#{adapter.path}.journal"
        entry_count  = adapter.entries.length
        byte_size    = File.exist?(journal_path) ? File.size(journal_path) : 0

        if entry_count.zero?
          puts "SKIP #{aggregate.storage_name}: journal already empty"
          return false
        end

        unless force
          puts "DRY RUN #{aggregate.storage_name}: would discard #{entry_count} journal " \
               "entries (#{byte_size} bytes) at #{journal_path}; current state (#{adapter.count} " \
               "records) is unaffected. Re-run with --force to apply."
          return false
        end

        adapter.compact!
        puts "COMPACTED #{aggregate.storage_name}: discarded #{entry_count} journal entries " \
             "(#{byte_size} bytes freed); #{adapter.count} records preserved at #{adapter.path}"
        false
      end
    end
  end
end
