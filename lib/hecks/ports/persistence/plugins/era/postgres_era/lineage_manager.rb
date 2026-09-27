require "tempfile"

require_relative "lineage_manager/era_resolver"
require_relative "lineage_manager/minter"
require_relative "lineage_manager/merge_coordinator"
require_relative "lineage_manager/coverage_check"
require_relative "../era_guard"
require_relative "../../../../../runtime/registry"

module Hecks
  module Adapters
    class PostgresEra
      # PostgresEra's era gate: mints the next era when an edge covers the drift, else refuses.
      # Era names are hashed once at mint time and stored in hecks_eras, never reconstructed.
      module LineageManager
        extend EraResolver
        extend Minter
        extend MergeCoordinator
        extend CoverageCheck

        module_function

        # Collects the translation edge for every step from era 1 to the current shape.
        # Each mint required its own edge, so a gap in the chain means a deleted file.
        #
        # @param registry [Runtime::Registry] the registry whose loaded `translations` are searched
        # @param bluebook [Bluebook::Chapter] the domain; only edges for its name count
        # @param eras [Array<Hash>] the ancestor eras in order, as `Lineage#eras` returns them
        # @param current_label [String] the shape label the last step must lead to
        # @return [Array<Hash>] one `{ translation: edge }` per step, in mint order
        # @raise [Runtime::WiringError] if no loaded translation leads one label to the next
        def edge_chain(registry, bluebook, eras, current_label)
          labels = eras.map { |era| era[:label] } + [current_label]
          (0...(labels.size - 1)).map do |index|
            step = registry.translations.find do |t|
              t.domain == bluebook.name && t.from == labels[index] && t.to == labels[index + 1]
            end
            unless step
              raise Runtime::WiringError,
                    "cannot boot #{bluebook.name}: the edge chain is broken at era #{index + 1} — no translation " \
                    "leads #{labels[index]} to #{labels[index + 1]}; restore bluebook/translations/"
            end
            { translation: step }
          end
        end

        # Parses a held era's bluebook text into a throwaway registry, not the live one.
        #
        # The predicate extractor reads source from disk, so the text goes through a scratch file.
        #
        # @param source [String] bluebook source text from `hecks_eras.held_text`
        # @return [Bluebook::Chapter, nil] the first bluebook the text declares
        # @raise [Bluebook::DSL::Malformed] if the text parses under neither grammar
        def shadow(source)
          file = Tempfile.new(["hecks-era-", ".bluebook"])
          file.write(source)
          file.flush
          Runtime::EraGuard.shadow_parse(source, file.path)
        ensure
          file&.close!
        end
      end
    end
  end
end
