# frozen_string_literal: true

require_relative "declaration"
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

        attr_reader :held, :declaration

        # @param path [String] the domain directory
        # @return [Subject] the loaded subject, with its world's declaration checked
        # @raise [CannotBoot] if the directory is absent, declares no bluebook or does not load
        # @raise [Refused] if the world's `rehearsed_by` is absent or wrong
        def self.open(path)
          held = load(path)
          new(held, Declaration.from_world(held.registry.world(held.bluebook.name), held.directory))
        end

        # Whatever stops a domain from loading is a reason it cannot boot, a script error included.
        #
        # @api private
        def self.load(path)
          JournalStore::HeldDomain.open(path)
        rescue StandardError, ScriptError => e
          raise CannotBoot, e.message
        end
        private_class_method :load

        # @param held [JournalStore::HeldDomain] the loaded domain
        # @param declaration [Declaration] what its world says about the data copy
        def initialize(held, declaration)
          @held = held
          @declaration = declaration
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
