# frozen_string_literal: true

require_relative "../../../hecks"
# The era subsystem does not load with core; a `PostgresEra` domain needs it (ADR 0033).
require_relative "../../ports/persistence/plugins/era"
require_relative "../../adapters/driven/heki"
require_relative "qa_postgres_migrate/copying"
require_relative "qa_postgres_migrate/reporting"

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
      include Copying
      include Reporting

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
        domain_dir = directory_argument(argv.shift, "domain directory")
        heki_dir = File.expand_path(directory_argument(argv.shift, "Heki data directory"))
        migrate(domain_dir, heki_dir, argv, force)
      rescue UsageError => e
        usage(e.message)
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

      # Raised for a wrong command line; `call` answers it with the usage line and status 1.
      class UsageError < StandardError; end

      def directory_argument(value, name)
        raise UsageError, "no #{name} given" if value.nil?
        raise UsageError, "no such #{name} #{value.inspect}" unless Dir.exist?(value)

        value
      end

      def migrate(domain_dir, heki_dir, names, force)
        registry = Hecks.boot(domain_dir).registry
        candidates = candidates_in(registry, heki_dir, names)
        return report_no_match(names, heki_dir) if candidates.empty?

        migrated, skipped, conflicts = copy(candidates, registry, heki_dir, force)
        report(force, migrated, skipped, conflicts)
        conflicts.empty? ? 0 : 1
      end

      def report_no_match(names, heki_dir)
        @out.puts "hecks quality_control migrate_ledger_from_heki: no aggregate matched " \
                  "#{names.empty? ? "(any)" : names.inspect} with a " \
                  "corresponding .heki file under #{heki_dir}"
        0
      end

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
    end
  end
end
