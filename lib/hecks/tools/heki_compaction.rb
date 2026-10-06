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
      # A journal file's location, how many entries it holds and how many bytes it takes.
      Journal = Struct.new(:path, :entry_count, :byte_size)

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
        return refuse_domain(domain) if domain.nil? || !Dir.exist?(domain)

        compact_domain(domain, argv.dup, force)
      end

      # @return [Integer] 1, after printing why and how to call it
      def refuse_domain(domain)
        warn "hecks compact_heki: no such domain #{domain.inspect}"
        warn "usage: hecks compact_heki <domain> [aggregate_name ...] [--force]"
        1
      end

      # @return [Integer] 0, or 1 when a projection refuses a candidate
      def compact_domain(domain, wanted, force)
        registry = Hecks.boot(domain).registry
        found = candidates(registry, wanted)
        if found.empty?
          puts "hecks compact_heki: no Heki-backed aggregate matched " \
               "#{wanted.empty? ? "(any)" : wanted.inspect} in #{domain}"
          return 0
        end

        refused = found.map { |candidate| refused_candidate?(registry, candidate, force: force) }
        refused.any? ? 1 : 0
      end

      # @param registry [Hecks::Runtime::Registry] the booted registry
      # @param wanted [Array<String>] aggregate names, or empty for every aggregate
      # @return [Array<Hash>] each compactable aggregate, its repository and adapter
      def candidates(registry, wanted)
        registry.bluebooks.flat_map do |domain_name, bluebook|
          bluebook.aggregates.filter_map { |aggregate| candidate_for(registry, domain_name, aggregate, wanted) }
        end
      end

      # @return [Hash, nil] the aggregate, its repository and adapter, when it is wanted and
      #   compactable
      def candidate_for(registry, domain_name, aggregate, wanted)
        return unless wanted.empty? || wanted.include?(aggregate.hecks_name) || wanted.include?(aggregate.storage_name)

        repository = registry.repository(domain_name, aggregate)
        return unless repository.is_a?(Hecks::Ports::Persistence::AppendOnly)

        adapter = repository.adapter
        return unless adapter.respond_to?(:compact!)

        { domain_name: domain_name, aggregate: aggregate, repository: repository, adapter: adapter }
      end

      # @return [Boolean] true when a `projected_by` binding refuses the candidate
      def refused_candidate?(registry, candidate, force:)
        aggregate = candidate[:aggregate]
        bound = Hecks::Ports::Projection.binds_for(registry, candidate[:domain_name], aggregate)
        if bound.any?
          warn_refused(aggregate, bound)
          return true
        end

        compact_journal(candidate[:adapter], aggregate, force)
        false
      end

      def warn_refused(aggregate, bound)
        warn "REFUSED #{aggregate.storage_name}: a projected_by binding reads its full journal " \
             "(#{bound.map(&:adapter).join(", ")}) — compacting would silently break " \
             "Projection::Worker#catch_up!/Registry#projection_current?. Not compacted."
      end

      # Prints what compacting would do, or does it when `force` is set.
      def compact_journal(adapter, aggregate, force)
        journal = journal_of(adapter)
        return puts("SKIP #{aggregate.storage_name}: journal already empty") if journal.entry_count.zero?
        return puts(dry_run_message(aggregate, adapter, journal)) unless force

        adapter.compact!
        puts "COMPACTED #{aggregate.storage_name}: discarded #{journal.entry_count} journal entries " \
             "(#{journal.byte_size} bytes freed); #{adapter.count} records preserved at #{adapter.path}"
      end

      # @return [Journal] the adapter's journal file, as it stands
      def journal_of(adapter)
        path = "#{adapter.path}.journal"
        Journal.new(path, adapter.entries.length, File.exist?(path) ? File.size(path) : 0)
      end

      def dry_run_message(aggregate, adapter, journal)
        "DRY RUN #{aggregate.storage_name}: would discard #{journal.entry_count} journal " \
          "entries (#{journal.byte_size} bytes) at #{journal.path}; current state (#{adapter.count} " \
          "records) is unaffected. Re-run with --force to apply."
      end
    end
  end
end
