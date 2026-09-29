# frozen_string_literal: true

require "json"
require_relative "../../../hecks"
# A domain wired to PostgresEra needs this plugin loaded explicitly, and the `:shape` projection
# reads `Runtime::StorageShape` from it (ADR 0033).
require_relative "../../ports/persistence/plugins/era"
require_relative "../../cli/stores"
require_relative "in_process_operations"

module Hecks
  module Adapters
    # The `DomainRuntime` port's adapter: boots a target domain in this process and answers what
    # Custodian's Introspection queries ask about it.
    #
    # Each method returns the text the matching `bin/` script prints, so the launcher shows the
    # same bytes; a projection that would have written files answers a map of file name to text
    # instead. Arguments arrive materialized, so a value object is `{ value: "x" }`. A domain or
    # chapter that cannot be found raises `Runtime::NotFound`, which the launcher words as a
    # refusal.
    #
    # It also answers the asks of journaled commands (`InProcessOperations`): a model check, a run,
    # a projection refresh, a behaviors run, a smoke test and a bounded follow.
    class InProcessBoot
      include InProcessOperations

      # Accepts the arguments every driven adapter is built with and keeps none of them.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] unused
      # @param root [String, nil] unused
      def initialize(aggregate: nil, settings: {}, root: nil); end

      # @param domain [Hash, String, nil] a domain directory; the nearest enclosing one when absent
      # @param translations [Boolean] only the translations, not the whole IR
      # @param meta [Boolean] the language's own IR, not a domain's
      # @return [String] the IR as JSON
      # @raise [Runtime::NotFound] if the domain cannot be found
      def ir(domain: nil, translations: false, meta: false)
        if meta
          require_relative "../../bluebook/meta_validator"
          return Projector::Exporter.json(Bluebook::MetaValidator.grammar_registry)
        end

        registry = boot(domain).registry
        translations ? Projector::Exporter.translations_json(registry) : Projector::Exporter.json(registry)
      end

      # @param domain [Hash, String] a bluebook file, or a directory of them
      # @return [String] the storage-shape projection as JSON for a file, or one
      #   `<Domain> <label>` line per domain for a directory
      # @raise [Runtime::NotFound] if the path does not exist or holds no bluebook
      def shape(domain:)
        target = plain(domain)
        raise Runtime::NotFound, "#{target} does not exist" unless File.exist?(target)

        directory = File.directory?(target)
        files = directory ? Dir[File.join(target, "*.bluebook")] : [target]
        raise Runtime::NotFound, "no *.bluebook files in #{target}" if files.empty?

        registry = load_files(files)
        return shape_labels(registry) if directory

        bluebook = registry.bluebooks.values.first or raise Runtime::NotFound, "#{target} declares no bluebook"
        JSON.pretty_generate(Projector.call(:shape, bluebook: bluebook))
      end

      # @param domain [Hash, String] a domain directory
      # @return [String] every aggregate's current records as one JSON document
      # @raise [Runtime::NotFound] if the domain cannot be found
      def stores(domain:)
        registry = boot(domain).registry
        stores = registry.bluebooks.each_with_object({}) do |(name, bluebook), all|
          bluebook.aggregates.each do |aggregate|
            all[aggregate.storage_name] = CLI::Stores.data_for(registry.repository(name, aggregate))
          end
        end

        JSON.generate(stores)
      end

      # @param domain [Hash, String] a domain directory
      # @return [String] every journal entry the domain's append-only adapters hold, as JSON
      # @raise [Runtime::NotFound] if the domain cannot be found
      def history(domain:)
        registry = boot(domain).registry
        history = registry.bluebooks.each_with_object({}) do |(name, bluebook), all|
          bluebook.aggregates.each do |aggregate|
            all[aggregate.storage_name] = entries(registry.repository(name, aggregate))
          end
        end

        JSON.generate(history)
      end

      # @param domain [Hash, String] a domain directory
      # @param chapter [Hash, String] the chapter's name
      # @return [String] the chapter's declared facts, one sentence a line
      # @raise [Runtime::NotFound] if the domain or chapter cannot be found
      def statements(domain:, chapter:)
        Projector.call(:statements, bluebook: chapter_of(domain, chapter)).join("\n")
      end

      # @param domain [Hash, String, nil] a domain directory; the nearest enclosing one when absent
      # @param aggregate [Hash, String, nil] narrate only this aggregate
      # @return [String] the domain in English
      # @raise [Runtime::NotFound] if the domain or aggregate cannot be found
      def narrate(domain: nil, aggregate: nil)
        document(:narrate, domain, aggregate)
      end

      # @param domain [Hash, String, nil] a domain directory; the nearest enclosing one when absent
      # @param aggregate [Hash, String, nil] document only this aggregate
      # @return [String] the domain's usage document
      # @raise [Runtime::NotFound] if the domain or aggregate cannot be found
      def docs(domain: nil, aggregate: nil)
        document(:docs, domain, aggregate)
      end

      # @param domain [Hash, String] a domain directory
      # @param chapter [Hash, String] the chapter's name
      # @return [Hash{Symbol => Hash{String => String}}] `files:` the diagrams by file name
      # @raise [Runtime::NotFound] if the domain or chapter cannot be found
      def project_diagrams(domain:, chapter:)
        runtime = boot(domain)
        name    = plain(chapter)
        options = { hecksagon: runtime.registry.hecksagon(name) }

        { files: Projector.call(:diagrams, bluebook: chapter_in(runtime, name), options: options) }
      end

      # @param domain [Hash, String] a domain directory
      # @param chapter [Hash, String] the chapter's name
      # @return [Hash{Symbol => Hash{String => String}}] `files:` the glossary by file name
      # @raise [Runtime::NotFound] if the domain or chapter cannot be found
      def glossary(domain:, chapter:)
        runtime = boot(domain)
        name    = plain(chapter)
        markings = runtime.registry.pending_privacy_markings.select do |marking|
          marking[:domain].to_s.start_with?("#{name}::")
        end

        { files: Projector.call(:glossary, bluebook: chapter_in(runtime, name), options: { markings: markings }) }
      end

      # One generated, valid dispatch sequence for a domain, through the generator `hecks fuzz`
      # draws from. The fuzzing toolkit is loaded here, on the first ask, and never by a boot.
      #
      # @param domain [Hash, String] a domain directory
      # @param seed [Integer, nil] the generator's seed (1 when absent)
      # @param steps [Integer, nil] how many steps to ask for (30 when absent)
      # @param adversarial [Float, nil] the fraction of steps mutated to be refused (0.0 if none)
      # @return [String] a replayable script as JSON: its name, a note on how it was made, its steps
      # @raise [Runtime::NotFound] if the domain cannot be found
      def generate_sequence(domain:, seed: nil, steps: nil, adversarial: nil)
        require_relative "../../fuzzing"
        target = plain(domain)
        raise Runtime::NotFound, "no such domain #{target.inspect}" unless File.exist?(target)

        seed ||= 1
        steps ||= 30
        generated = Fuzzing::SequenceGenerator.generate(target, seed: seed, steps: steps,
                                                                adversarial: adversarial || 0.0)
        JSON.pretty_generate(name: "#{File.basename(target)}-generated",
                             note: "generated by hecks generate_sequence: seed #{seed}, #{steps} steps " \
                                   "requested (#{generated.length} produced)",
                             steps: generated)
      end

      private

      # A value object arrives as `{ value: x }`; a bare argument is already plain.
      def plain(argument)
        argument.is_a?(Hash) ? argument[:value] : argument
      end

      # Boots the domain at `domain`, or at the nearest enclosing domain directory when absent.
      def boot(domain)
        path = plain(domain) || Adapters::Folder.new.domain_root
        raise Runtime::NotFound, "no domain here, and none named" unless path
        raise Runtime::NotFound, "no such domain #{path.inspect}" unless Dir.exist?(path)

        Hecks.boot(File.expand_path(path), install_facade: false)
      end

      def chapter_of(domain, chapter)
        chapter_in(boot(domain), plain(chapter))
      end

      def chapter_in(runtime, name)
        runtime.registry.bluebook(name) or raise Runtime::NotFound, "no chapter named #{name}"
      end

      # The domain's own chapter, not a framework member it attached: insertion order.
      def document(projection, domain, aggregate)
        bluebook = boot(domain).registry.bluebooks.values.first or raise Runtime::NotFound, "no bluebook loaded"
        name = plain(aggregate)

        Projector.call(projection, bluebook: bluebook, options: name ? { aggregate: name } : {})
      end

      def entries(repository)
        return [] unless repository.is_a?(Ports::Persistence::AppendOnly)

        repository.entries.map { |entry| { "operation" => entry.operation, "id" => entry.id, "state" => entry.state } }
      end

      def load_files(files)
        registry = Runtime::Registry.new
        loading  = Ports::Loading.bootstrap
        Hecks.with_registry(registry) do
          loading.load_library
          files.each { |file| Kernel.eval(File.read(file), TOPLEVEL_BINDING, File.expand_path(file), 1) }
        end
        registry
      end

      def shape_labels(registry)
        registry.bluebooks.sort_by { |name, _| name.to_s }
                .map { |name, bluebook| "#{name} #{Runtime::StorageShape.mint_label(bluebook)}" }
                .join("\n")
      end
    end
  end
end
