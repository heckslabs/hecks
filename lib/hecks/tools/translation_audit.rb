# frozen_string_literal: true

require "hecks"
# The audit reads the era persistence plugin's lineage journal and its audit machinery (ADR 0033).
require "hecks/ports/persistence/plugins/era"
require "json"
require_relative "../tools"

module Hecks
  module Tools
    # Runs the translation audit's three layers standalone against a domain's latest or pending
    # edge. Read-only except `--approve`, which records the human approval in the database.
    #
    #   bin/translation_audit <domain> [--approve]
    module TranslationAudit
      module_function

      # Audits the edge and prints each aggregate's verdict and samples.
      #
      # @param argv [Array<String>] the domain directory, and `--approve` to record approval
      # @param root [String] unused: the domain is read from the path given
      # @return [Integer] 0 when the audit passes or there is no edge, 1 when it is refused
      # @raise [SystemExit] when the domain cannot be loaded or is not lineage-capable
      def main(argv, **)
        argv = argv.dup
        approve = argv.delete("--approve")
        domain_path = argv.shift or abort "usage: bin/translation_audit <domain> [--approve]"

        registry, bluebook, directory = load_domain(domain_path)
        db, lineage = open_lineage(registry, bluebook)
        audit(registry, bluebook, directory, db, lineage, approve)
      end

      # @param domain_path [String] the domain directory
      # @return [Array] the registry, its bluebook and the bluebook directory
      def load_domain(domain_path)
        loading = Hecks::Ports::Loading.bootstrap
        directory = loading.bluebook_directory(domain_path)
        registry = Hecks::Runtime::Registry.new(root: File.dirname(directory))
        begin
          Hecks.with_registry(registry) do
            loading.load_library
            loading.load_project(loading.shared_root(nil, directory))
            # Passes an environment overlay to `load_domain`, as `scaffold_translation` does.
            loading.load_domain(directory, environment: ENV.fetch("HECKS_PROJECT_ENVIRONMENT", nil))
          end
        rescue Hecks::Bluebook::DSL::Malformed => e
          abort "REFUSED at load: #{e.message}"
        end
        bluebook = registry.bluebooks.values.first or abort "no bluebook in #{directory}"
        [registry, bluebook, directory]
      end

      # @param registry [Hecks::Runtime::Registry] the loaded registry
      # @param bluebook [Object] the domain's bluebook
      # @return [Array] the open connection and its ensured lineage
      # @raise [SystemExit] when the bound adapter is not lineage-capable
      def open_lineage(registry, bluebook)
        first = bluebook.aggregates.first or abort "#{bluebook.name} declares no aggregates"
        adapter_name = Hecks::Ports::Persistence::BindingPolicy.resolve(registry, bluebook.name, first).adapter
        capable =
          begin
            adapter_class = registry.adapter_class(adapter_name)
            adapter_class.respond_to?(:lineage_capable?) && adapter_class.lineage_capable?
          rescue StandardError
            false
          end
        unless capable
          abort "the audit reads a lineage journal; #{bluebook.name} is bound to #{adapter_name}, " \
                "not PostgresEra"
        end

        settings = registry.world(bluebook.name)&.for_binding(Hecks::Ports::Persistence::VERB, adapter_name) || {}
        # The same `HECKS_SCHEMA` support as `scaffold_translation`.
        settings = settings.merge(schema: ENV["HECKS_SCHEMA"]) if ENV["HECKS_SCHEMA"]
        db = Hecks::Adapters::PostgresEra.connect_for(bluebook.name, settings)
        lineage = Hecks::Adapters::PostgresEra::Lineage.new(db, bluebook.name)
        lineage.ensure_base!
        [db, lineage]
      end

      # @return [Integer] the exit status
      def audit(registry, bluebook, directory, db, lineage, approve)
        if lineage.eras.empty?
          lineage.hold_first!(Hecks::Runtime::EraCheck.source_text_for(bluebook, directory),
                              projection: Hecks::Runtime::StorageShape.project(bluebook))
          puts "#{bluebook.name} held era 1 just now — no edge to audit."
          db.close
          return 0
        end

        era, chain = edge_chain(registry, bluebook, lineage)
        return 0 unless era

        edge = chain.last[:translation]
        failed = report(bluebook, lineage, edge, era, chain)
        conclude(db, lineage, edge, failed, approve)
      end

      # The era the edge leads to and the chain of translations ending in it, or nil when the
      # journal stands at era 1 with nothing to audit.
      #
      # @return [Array, nil] the era ordinal and the chain
      def edge_chain(registry, bluebook, lineage)
        manager = Hecks::Adapters::PostgresEra::LineageManager
        eras = lineage.eras
        latest = eras.last
        current_shape = Hecks::Runtime::StorageShape.project(bluebook)
        held_shape = Hecks::Runtime::StorageShape.project(manager.shadow(latest[:held_text]))

        if held_shape == current_shape
          era = latest[:ordinal]
          if era == 1
            puts "#{bluebook.name} stands at era 1 — no edge to audit."
            return nil
          end
          [era, manager.edge_chain(registry, bluebook, eras, latest[:label])]
        else
          # a pending edge: audit it before any mint
          manager.ensure_named!(lineage, latest)
          latest = lineage.eras.last
          to_label = Hecks::Runtime::StorageShape.mint_hash(bluebook)[0, Hecks::Runtime::StorageShape::LABEL_LENGTH]
          pending = registry.translations.find do |t|
            t.domain == bluebook.name && t.from == latest[:label] && t.to == to_label
          end
          pending or abort "no translation edge leads #{latest[:label]} to #{to_label} — " \
                           "run bin/scaffold_translation first"
          chain = begin
            manager.edge_chain(registry, bluebook, eras, latest[:label])
          rescue StandardError
            []
          end
          [latest[:ordinal] + 1, (chain || []) + [{ translation: pending }]]
        end
      end

      # Prints each aggregate's verdict.
      #
      # @return [Boolean] whether any aggregate's audit was refused
      def report(bluebook, lineage, edge, era, chain)
        failed = false
        bluebook.aggregates.each do |aggregate|
          declared = edge.for_aggregate(aggregate.name)
          after = begin
            lineage.translated_latest(aggregate, era, chain)
          rescue PG::Error => e
            abort "REFUSED: #{e.message.strip}"
          end
          before = if chain.size > 1
                     lineage.translated_latest(aggregate, era, chain[0..-2])
                   else
                     lineage.ancestor_latest(aggregate, era, chain)
                   end
          verdict = Hecks::Translation::Audit.check(aggregate: aggregate, declared: declared,
                                                    before: before, after: after)
          print_verdict(bluebook, aggregate, edge, after, verdict)
          failed ||= !verdict.ok?
        end
        failed
      end

      # @return [void]
      def print_verdict(bluebook, aggregate, edge, after, verdict)
        puts "── #{bluebook.name}::#{aggregate.name} (edge #{edge.from} → #{edge.to}, " \
             "#{after.size} record#{'s' unless after.size == 1})"
        verdict.violations.each { |violation| puts "   REFUSED: #{violation}" }
        puts "   dropped (declared data loss): #{verdict.dropped.join(', ')}" unless verdict.dropped.empty?
        puts "   unfed (no rule, no default — add default: if required): #{verdict.unfed.join(', ')}" unless verdict.unfed.empty?
        verdict.samples.each do |sample|
          puts "   ##{sample[:id]}"
          puts "     before: #{JSON.generate(sample[:before])}" if sample[:before]
          puts "     after:  #{JSON.generate(sample[:after])}" if sample[:after]
        end
      end

      # @return [Integer] the exit status
      def conclude(db, lineage, edge, failed, approve)
        if failed
          db.close
          puts "AUDIT REFUSED."
          return 1
        end

        needs_approval = edge.aggregates.any? { |declared| !declared.computes.empty? || !declared.rekeys.empty? }
        if needs_approval && approve
          # Binds to what was reviewed — this edge and the journal as it stands now — so it must
          # live in the database, not the repo.
          lineage.record_approval!(
            from: edge.from, to: edge.to,
            edge_digest: Hecks::Translation::Audit.edge_digest(edge)
          )
          db.close
          puts "AUDIT PASSED — approval recorded in the database, bound to this edge and this journal."
          puts "A journal that advances before the mint invalidates it; re-run with --approve if that happens."
        elsif needs_approval
          db.close
          puts "AUDIT PASSED — this edge carries a compute or rekey rule, and the samples above are " \
               "its ONLY verification."
          puts "If they show what you intended, run again with --approve; the mint refuses until you do."
        else
          db.close
          puts "AUDIT PASSED — review the samples above; intent is yours to approve."
        end
        0
      end
    end
  end
end
