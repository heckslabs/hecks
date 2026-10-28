# frozen_string_literal: true

require "json"
require "hecks"
# A domain wired to PostgresEra needs this plugin loaded explicitly, and the `:shape` projection
# reads `Runtime::StorageShape` from it (ADR 0033).
require_relative "../../ports/persistence/plugins/era"
require_relative "../../cli/stores"
require_relative "../../cli/shape"
require_relative "../../cli/history"
require_relative "../../projections/context_map_diagram"
require_relative "in_process_operations"
require_relative "in_process_access"

module Hecks
  module Adapters
    # The `DomainRuntime` port's adapter: boots a target domain in this process and answers what
    # Custodian's Introspection queries ask about it.
    #
    # Each method returns the text the matching tool prints, so the launcher shows the
    # same bytes; a projection that would have written files answers a map of file name to text
    # instead. Arguments arrive materialized, so a value object is `{ value: "x" }`. A domain or
    # bluebook that cannot be found raises `Runtime::NotFound`, which the launcher words as a
    # refusal.
    #
    # It also answers the asks of journaled commands (`InProcessOperations`): a model check, a run,
    # a projection refresh, a behaviors run, a smoke test and a bounded follow.
    class InProcessBoot
      include InProcessOperations
      include InProcessAccess

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # @param domain [Hash, String, nil] a domain directory; the nearest enclosing one when absent
      # @param translations [Boolean] only the translations, not the whole IR
      # @param meta [Boolean] the language's own IR, not a domain's
      # @return [Hash] `text:` the IR as JSON
      # @raise [Runtime::NotFound] if the domain cannot be found
      def ir(domain: nil, translations: false, meta: false)
        if meta
          require_relative "../../bluebook/meta_validator"
          return report(Projector::Exporter.json(Bluebook::MetaValidator.grammar_registry))
        end

        registry = boot(domain).registry
        report(translations ? Projector::Exporter.translations_json(registry) : Projector::Exporter.json(registry))
      end

      # @param domain [Hash, String] a bluebook file, or a directory of them
      # @return [Hash] `text:` the storage-shape projection as JSON for a file, or
      #   one `<Domain> <label>` line per domain for a directory
      # @raise [Runtime::NotFound] if the path does not exist or holds no bluebook
      def shape(domain:)
        report(CLI::Shape.render(plain(domain)))
      end

      # @param domain [Hash, String] a domain directory
      # @param aggregate [Hash, String, nil] a storage name, to read only that aggregate
      # @param record [Hash, String, nil] a record id within `aggregate`, to read only that record
      # @param flat [Hash, Boolean, nil] true unwraps the value objects to their values
      # @return [Hash] `text:` every aggregate's current records as one JSON document, or what
      #   `aggregate` and `record` narrow it to
      # @raise [Runtime::NotFound] if the domain, aggregate or record cannot be found
      def stores(domain:, aggregate: nil, record: nil, flat: nil)
        registry = boot(domain).registry
        CLI::PersistenceNotice.announce(registry, program: "hecks stores")
        report(JSON.generate(CLI::Stores.read(registry, plain(aggregate), plain(record), flat: plain(flat) == true)))
      end

      # @param domain [Hash, String] a domain directory
      # @return [Hash] `text:` every journal entry the domain's append-only adapters
      #   hold, as JSON
      # @raise [Runtime::NotFound] if the domain cannot be found
      def history(domain:)
        registry = boot(domain).registry
        CLI::PersistenceNotice.announce(registry, program: "hecks history")
        report(JSON.generate(CLI::History.document(registry)))
      end

      # @param domain [Hash, String] a domain directory
      # @param bluebook [Hash, String] the bluebook's name
      # @return [Hash] `text:` the bluebook's declared facts, one sentence a line
      # @raise [Runtime::NotFound] if the domain or bluebook cannot be found
      def statements(domain:, bluebook:)
        report(Projector.call(:statements, bluebook: bluebook_of(domain, bluebook)).join("\n"))
      end

      # @param domain [Hash, String, nil] a domain directory; the nearest enclosing one when absent
      # @param aggregate [Hash, String, nil] narrate only this aggregate
      # @return [Hash] `text:` the domain in English
      # @raise [Runtime::NotFound] if the domain or aggregate cannot be found
      def narrate(domain: nil, aggregate: nil)
        document(:narrate, domain, aggregate)
      end

      # @param domain [Hash, String] a domain directory
      # @return [Hash] `text:` one line per relationship between the contexts the domain holds
      # @raise [Runtime::NotFound] if the domain cannot be found
      def relationships(domain:)
        report(Projections::ContextRelationships.text(registry: boot(domain).registry))
      end

      # @param domain [Hash, String] a domain directory
      # @return [Hash] `text:` the declared context map drawn as Mermaid beside the wiring, with
      #   each finding of holding the wiring to the map as a comment
      # @raise [Runtime::NotFound] if the domain cannot be found
      def context_map(domain:)
        registry = boot(domain).registry
        edges = Projections::ContextRelationships.call(registry: registry)
        report(Projections::ContextMapDiagram.report(map: registry.context_maps.first, edges: edges))
      end

      # @param domain [Hash, String] a domain directory
      # @return [Hash] `text:` a starting `.world` for the adapters the domain binds
      # @raise [Runtime::NotFound] if the domain cannot be found
      def world_skeleton(domain:)
        report(Projections::WorldSkeleton.call(registry: boot(domain).registry))
      end

      # @param domain [Hash, String, nil] a domain directory; the nearest enclosing one when absent
      # @param aggregate [Hash, String, nil] document only this aggregate
      # @return [Hash] `text:` the domain's usage document
      # @raise [Runtime::NotFound] if the domain or aggregate cannot be found
      def docs(domain: nil, aggregate: nil)
        document(:docs, domain, aggregate)
      end

      # @param domain [Hash, String] a domain directory
      # @param bluebook [Hash, String] the bluebook's name
      # @return [Array<Hash{Symbol => String}>] one `name:`/`text:` row per diagram file
      # @raise [Runtime::NotFound] if the domain or bluebook cannot be found
      def project_diagrams(domain:, bluebook:)
        runtime = boot(domain)
        name    = plain(bluebook)
        options = { hecksagon: runtime.hecksagon(name) }

        projected_files(Projector.call(:diagrams, bluebook: bluebook_in(runtime, name), options: options))
      end

      # @param domain [Hash, String] a domain directory
      # @param bluebook [Hash, String] the bluebook's name
      # @return [Array<Hash{Symbol => String}>] one `name:`/`text:` row per glossary file
      # @raise [Runtime::NotFound] if the domain or bluebook cannot be found
      def glossary(domain:, bluebook:)
        runtime = boot(domain)
        name    = plain(bluebook)
        markings = runtime.pending_privacy_markings.select do |marking|
          marking[:domain].to_s.start_with?("#{name}::")
        end

        projected_files(Projector.call(:glossary, bluebook: bluebook_in(runtime, name),
                                                  options:  { markings: markings }))
      end

      # One generated, valid dispatch sequence for a domain, through the generator `hecks fuzz`
      # draws from. The fuzzing toolkit is loaded here, on the first ask, and never by a boot.
      #
      # @param domain [Hash, String] a domain directory
      # @param seed [Integer, nil] the generator's seed (1 when absent)
      # @param steps [Integer, nil] how many steps to ask for (30 when absent)
      # @param adversarial [Float, nil] the fraction of steps mutated to be refused (0.0 if none)
      # @return [Hash] `text:` a replayable script as JSON: its name, a note on how it
      #   was made, its steps
      # @raise [Runtime::NotFound] if the domain cannot be found
      def generate_sequence(domain:, seed: nil, steps: nil, adversarial: nil)
        require "hecks/fuzzing"
        target = plain(domain)
        raise Runtime::NotFound, "no such domain #{target.inspect}" unless File.exist?(target)

        seed ||= 1
        steps ||= 30
        generated = Fuzzing::SequenceGenerator.generate(target, seed: seed, steps: steps,
                                                                adversarial: adversarial || 0.0)
        report(JSON.pretty_generate(sequence_script(target, generated, seed, steps)))
      end

      private

      # The replayable script for a generated sequence: its name, how it was made, its steps.
      def sequence_script(target, generated, seed, steps)
        { name:  "#{File.basename(target)}-generated",
          note:  "generated by hecks generate_sequence: seed #{seed}, #{steps} steps " \
                 "requested (#{generated.length} produced)",
          steps: generated }
      end

      # A value object arrives as `{ value: x }`; a bare argument is already plain.
      def plain(argument)
        argument.is_a?(Hash) ? argument[:value] : argument
      end

      # Boots the domain at `domain`, or at the nearest enclosing domain directory when absent.
      def boot(domain)
        path = plain(domain) || Adapters::Folder.new.domain_root
        raise Runtime::NotFound, "no domain here, and none named" unless path
        raise Runtime::NotFound, "no such domain #{path.inspect}" unless Dir.exist?(path)

        Hecks.boot(File.expand_path(path), install_driving: false)
      end

      def bluebook_of(domain, declaration)
        bluebook_in(boot(domain), plain(declaration))
      end

      def bluebook_in(runtime, name)
        runtime.bluebook(name) or raise Runtime::NotFound, "no bluebook named #{name}"
      end

      # The domain's own bluebook, not a framework member it attached: insertion order.
      def document(projection, domain, aggregate)
        registry = boot(domain).registry
        bluebook = registry.first_bluebook or raise Runtime::NotFound, "no bluebook loaded"
        name = plain(aggregate)

        report(Projector.call(projection, bluebook: bluebook, options: name ? { aggregate: name } : {}))
      end

      # The `Document` a query returns: one document of text.
      def report(text) = { text: text }

      # The `ProjectedFile` rows a projection that would have written files answers instead.
      def projected_files(files) = files.map { |name, text| { name: name, text: text } }
    end
  end
end
