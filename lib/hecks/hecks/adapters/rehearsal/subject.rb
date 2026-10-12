# frozen_string_literal: true

require_relative "declaration"
require_relative "environment"
require_relative "../journal_store/edge_audit"
require_relative "../journal_store/held_domain"

module Hecks
  module Adapters
    module Rehearsal
      # The domain a rehearsal is run on: loaded as the era tools load it, with nothing bound or
      # booted, so no persistence binding of the domain's own is reached.
      class Subject
        # The domain did not load: the answer a rehearsal gives is `cannot_boot`, with the reason.
        class CannotBoot < StandardError; end

        attr_reader :held, :declaration, :environment

        # @param path [String] the domain directory
        # @return [Subject] the loaded subject, with its world's declaration checked
        # @raise [CannotBoot] if the directory is absent, declares no bluebook or does not load
        # @raise [Refused] if the world's `rehearsed_by` is absent or wrong
        def self.open(path)
          environment = choose_environment(path)
          held = load(path, environment)
          new(held, Declaration.from_world(held.registry.world(held.bluebook.name), held.directory), environment)
        end

        # Whatever stops a domain from loading is a reason it cannot boot, a script error included.
        # A missing bind names the environment that was loaded and the file it came from.
        #
        # @api private
        def self.load(path, environment)
          JournalStore::HeldDomain.open(path, environment: environment.overlay)
        rescue Runtime::WiringError => e
          raise CannotBoot, "#{e.message} The rehearsal loaded #{environment}; overlays this domain " \
                            "holds: #{environment.available_words}. " \
                            "Name one with `environment \"...\"` in rehearsed_by, or HECKS_PROJECT_ENVIRONMENT."
        rescue StandardError, ScriptError => e
          raise CannotBoot, e.message
        end
        private_class_method :load

        # The overlay the world names, read before the domain loads so the load can use it.
        #
        # @api private
        def self.choose_environment(path)
          loading = Ports::Loading.bootstrap
          directory = loading.bluebook_directory(path)
          Environment.resolve(declared_environment(loading, directory), directory)
        rescue StandardError, ScriptError
          Environment.resolve(nil, path.to_s)
        end
        private_class_method :choose_environment

        # @api private
        def self.declared_environment(loading, directory)
          registry = Runtime::Registry.new(root: File.dirname(directory))
          Hecks.with_registry(registry) do
            loading.load_library
            loading.load_each(directory, %w[*.world])
          end
          registry.worlds.values.filter_map { |world| world.for_verb("rehearsed_by")[:environment] }.first
        rescue StandardError, ScriptError
          nil
        end
        private_class_method :declared_environment

        # @param held [JournalStore::HeldDomain] the loaded domain
        # @param declaration [Declaration] what its world says about the data copy
        # @param environment [Environment] the overlay the domain was loaded under
        def initialize(held, declaration, environment)
          @held = held
          @declaration = declaration
          @environment = environment
        end

        # @return [Bluebook::Chapter] the domain's bluebook as it stands
        def bluebook = held.bluebook

        # @return [String] the label the shape a mint would hold has
        def label = Runtime::StorageShape.mint_label(bluebook)

        # @return [String] the domain's bluebook directory
        def directory = held.directory

        # The edge that leads one era's label to the shape's label.
        #
        # @param from [String] the held era's label
        # @return [Bluebook::Translation, nil] the edge; nil when none is declared
        def edge_from(from)
          held.registry.translations.find { |t| t.domain == bluebook.name && t.from == from && t.to == label }
        end

        # @return [Array<String>] the persisted databases the domain's own world names, which a
        #   rehearsal must never be pointed at
        def declared_databases
          blocks = held.registry.world(bluebook.name)&.settings || {}
          blocks.select { |key, _| key.to_s.start_with?("persisted_by") }.values.filter_map { |block| block[:database] }
        end
      end
    end
  end
end
