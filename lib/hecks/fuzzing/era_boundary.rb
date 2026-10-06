require "hecks/ports/persistence/plugins/era"

module Hecks
  module Fuzzing
    # Checks a target's real, already-configured `PostgresEra` ledger for
    # ancestor eras still holding writes nobody has merged forward.
    module EraBoundary
      module_function

      # `kind:` on a `checked: false` result distinguishes a target with no
      # lineage to audit (`:not_applicable`) from an audit that failed to
      # run (`:error`) — `hecks quality_control query sweep.run` holds the first and surfaces the
      # second as a finding, instead of treating both as a clean audit.
      def diverged_ancestor_writes(domain_path)
        registry, directory = load_registry(domain_path)
        bluebook = registry.bluebooks.values.first
        return failed("no bluebook in #{directory}") unless bluebook

        reason = unaudited_reason(registry, bluebook)
        return not_applicable(reason) if reason

        audit(registry, bluebook, "PostgresEra")
      rescue StandardError => e
        # A refused connection or malformed `.world` settings is not the
        # same as nothing to audit, so this reports `:error`, never the
        # benign `:not_applicable` shape.
        failed("#{e.class}: #{e.message}")
      end

      # Why a bluebook has no `PostgresEra` lineage to audit, or nil when it does.
      def unaudited_reason(registry, bluebook)
        return "#{bluebook.name} declares no aggregates" unless bluebook.aggregates.first

        adapter_name = bound_adapter(registry, bluebook)
        "#{bluebook.name} is bound to #{adapter_name}, not PostgresEra" unless adapter_name == "PostgresEra"
      end

      def bound_adapter(registry, bluebook)
        Hecks::Ports::Persistence::BindingPolicy.resolve(registry, bluebook.name, bluebook.aggregates.first).adapter
      end

      # Counts the writes each ancestor era holds that were never merged forward.
      def audit(registry, bluebook, adapter_name)
        settings = registry.binding_settings(bluebook.name, Hecks::Ports::Persistence::VERB, adapter_name)
        db = Hecks::Adapters::PostgresEra.connect_for(bluebook.name, settings)
        lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, bluebook.name)
        lineage.ensure_base!
        eras = lineage.eras
        breakdown = ancestor_breakdown(lineage, eras)
        { checked: true, era_count: eras.size, breakdown: breakdown, diverged_total: breakdown.sum { |b| b[:diverged] } }
      ensure
        db&.close
      end

      def ancestor_breakdown(lineage, eras)
        return [] unless eras.size > 1

        (1...eras.last[:ordinal]).map { |ordinal| { ordinal: ordinal, diverged: lineage.diverged_count(ordinal) } }
      end

      def not_applicable(reason) = { checked: false, kind: :not_applicable, reason: reason }

      def failed(reason) = { checked: false, kind: :error, reason: reason }

      # Boots a fresh registry for the target domain, never the ledger's own
      # registry (this asks about the swept target's lineage, not
      # QualityControl's own).
      def load_registry(domain_path)
        loading = Hecks::Ports::Loading.bootstrap
        directory = loading.bluebook_directory(domain_path)
        registry = Hecks::Runtime::Registry.new(root: File.dirname(directory))
        Hecks.with_registry(registry) do
          loading.load_library
          loading.load_project(loading.shared_root(nil, directory))
          loading.load_domain(directory)
        end
        [registry, directory]
      end
    end
  end
end
