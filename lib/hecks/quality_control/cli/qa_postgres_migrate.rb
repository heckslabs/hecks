# frozen_string_literal: true

require_relative "../../../hecks"
# The era subsystem does not load with core; a `PostgresEra` domain needs it (ADR 0033).
require_relative "../../ports/persistence/plugins/era"
require_relative "../../adapters/driven/heki"

module Hecks
  module QualityControlCli
    # The command behind `hecks quality_control sweep.migrate_ledger_from_heki`: copies each
    # aggregate's current state from a Heki data directory into the repository that the domain's
    # `.hecksagon`/`.world` files bind today (for example `PostgresEra`). It is domain-agnostic.
    #
    #   migrate_ledger_from_heki <domain_dir> <heki_data_dir> [aggregate_name ...]         # dry run
    #   migrate_ledger_from_heki <domain_dir> <heki_data_dir> [aggregate_name ...] --force # apply
    #
    # One `save` per id from `Heki#all`, not a journal replay: state is kept byte-for-byte, the
    # per-append history is not. The Heki side is only read. An id the destination holds under a
    # different state is always refused, so a second run is idempotent. Only aggregates with a
    # `<storage_name>.heki` file in the Heki directory are considered; trailing names (`hecks_name`
    # or `storage_name`) narrow further.
    class QaPostgresMigrate
      USAGE = "usage: hecks quality_control migrate_ledger_from_heki <domain_dir> <heki_data_dir> " \
              "[aggregate_name ...] [--force]"

      # Migrates, or reports what a migration would do.
      #
      # @param argv [Array<String>] the domain directory, the Heki directory, aggregate names, and
      #   `--force` to apply
      # @param out [IO] where the report goes
      # @param err [IO] where a refusal goes
      # @return [Integer] 0 when nothing conflicts, 1 for a usage error or a conflict
      def self.call(argv, out: $stdout, err: $stderr)
        new(out: out, err: err).call(argv)
      end

      # @param out [IO] where the report goes
      # @param err [IO] where a refusal goes
      def initialize(out: $stdout, err: $stderr)
        @out = out
        @err = err
      end

      # @param argv [Array<String>] the domain directory, the Heki directory, aggregate names, and
      #   `--force` to apply
      # @return [Integer] 0 when nothing conflicts, 1 for a usage error or a conflict
      def call(argv)
        argv = argv.dup
        force = argv.delete("--force")
        domain_dir = argv.shift
        return usage("no domain directory given") if domain_dir.nil?
        return usage("no such domain directory #{domain_dir.inspect}") unless Dir.exist?(domain_dir)

        heki_dir = argv.shift
        return usage("no Heki data directory given") if heki_dir.nil?
        return usage("no such Heki data directory #{heki_dir.inspect}") unless Dir.exist?(heki_dir)

        heki_dir = File.expand_path(heki_dir)
        registry = Hecks.boot(domain_dir).registry
        candidates = candidates_in(registry, heki_dir, argv)
        if candidates.empty?
          @out.puts "hecks quality_control migrate_ledger_from_heki: no aggregate matched " \
                    "#{argv.empty? ? "(any)" : argv.inspect} with a " \
                    "corresponding .heki file under #{heki_dir}"
          return 0
        end

        migrated, skipped, conflicts = copy(candidates, registry, heki_dir, force)
        report(force, migrated, skipped, conflicts)
        conflicts.empty? ? 0 : 1
      end

      # Deep comparison independent of key type and hash order; only array order is meaningful.
      # `spec/qa_postgres_migration_spec.rb` pins this for conflict detection.
      #
      # @param value [Object] a state, or any part of one
      # @return [Object] the same with every hash keyed by string and sorted
      def self.canonical(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), h| h[k.to_s] = canonical(v) }.sort.to_h
        when Array
          value.map { |v| canonical(v) }
        else
          value
        end
      end

      private

      def usage(message)
        @err.puts "hecks quality_control migrate_ledger_from_heki: #{message}"
        @err.puts USAGE
        1
      end

      # A candidate is an aggregate whose own `.heki` file exists, whatever it is bound to now.
      def candidates_in(registry, heki_dir, wanted)
        registry.bluebooks.each_with_object([]) do |(domain_name, bluebook), all|
          bluebook.aggregates.each do |aggregate|
            next unless wanted.empty? || wanted.include?(aggregate.hecks_name) || wanted.include?(aggregate.storage_name)

            heki_path = File.join(heki_dir, "#{aggregate.storage_name}.heki")
            next unless File.exist?(heki_path)

            all << { domain_name: domain_name, aggregate: aggregate, heki_path: heki_path }
          end
        end
      end

      def copy(candidates, registry, heki_dir, force)
        migrated = []
        skipped = []
        conflicts = []
        candidates.each do |candidate|
          aggregate = candidate[:aggregate]
          # Guarded like a factory-built repository so a Heki store decodes through the state codec.
          source = Hecks::Ports::Persistence::CodecBoundary.guard!(
            Hecks::Adapters::Heki.new(aggregate: aggregate, settings: { dir: heki_dir }, root: nil)
          )
          dest = registry.repository(candidate[:domain_name], aggregate)
          source.all.each do |instance|
            name = "#{aggregate.storage_name}/#{instance.id}"
            existing = dest.find(instance.id)
            if existing.nil?
              dest.save(instance) if force
              migrated << name
            elsif self.class.canonical(existing.state) == self.class.canonical(instance.state)
              skipped << name
            else
              conflicts << name
            end
          end
        end
        [migrated, skipped, conflicts]
      end

      def report(force, migrated, skipped, conflicts)
        label = force ? "MIGRATED" : "WOULD MIGRATE"
        migrated.each { |id| @out.puts "#{label} #{id}" }
        skipped.each { |id| @out.puts "SKIP #{id}: destination already holds the identical state" }
        conflicts.each do |id|
          @err.puts "REFUSED #{id}: the destination already holds a DIFFERENT state for this id — " \
                    "not overwritten, --force or not. Resolve by hand (compare the two states, decide " \
                    "which is authoritative) before migrating this id again."
        end
        @out.puts "" unless migrated.empty? && skipped.empty? && conflicts.empty?
        @out.puts "#{force ? "migrated" : "would migrate"} #{migrated.size}, skipped #{skipped.size} " \
                  "(already caught up), refused #{conflicts.size} (conflicting data)"
        @out.puts "re-run with --force to apply" unless force || migrated.empty?
      end
    end
  end
end
