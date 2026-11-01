require "tempfile"

require_relative "lineage_manager/era_resolver"
require_relative "lineage_manager/minter"
require_relative "lineage_manager/merge_coordinator"
require_relative "lineage_manager/coverage_check"
require_relative "../../../ports/persistence/plugins/era/era_guard"
require_relative "../../../runtime/registry"

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
        # @param bluebook [Bluebook::Declaration] the domain; only edges for its name count
        # @param eras [Array<Hash>] the ancestor eras in order, as `Lineage#eras` returns them
        # @param current_label [String] the shape label the last step must lead to
        # @param target [Hash, nil] the era record the last step reaches when it is not in `eras`
        #   (the held era of a settled chain, or the era a mint is about to write)
        # @return [Array<Hash>] one `{ translation: edge }` per step, in mint order
        # @raise [Runtime::WiringError] if no loaded translation or journal record leads a label
        #   to the next one
        def edge_chain(registry, bluebook, eras, current_label, target: nil)
          labels = eras.map { |era| era[:label] } + [current_label]
          labels.each_cons(2).with_index.map do |(from, to), index|
            step = edge_between(registry, bluebook, from, to) ||
                   recorded_edge(bluebook, from, to, eras[index + 1] || target)
            refuse_broken_chain!(bluebook, index, from, to) unless step
            { translation: step }
          end
        end

        # The implicit edge a journal record names for the step that reached its era, or nil.
        #
        # @param bluebook [Bluebook::Declaration] the domain the edge belongs to
        # @param from [String] the shape label the step leaves
        # @param to [String] the shape label the step reaches
        # @param record [Hash, nil] the era record the step reaches
        # @return [Translation::ImplicitEdge, nil]
        def recorded_edge(bluebook, from, to, record)
          return unless record && record[:label] == to && record[:edge] == Translation::ImplicitEdge::RECORD

          Translation::ImplicitEdge.new(domain: bluebook.name, from: from, to: to)
        end

        # Finds the loaded translation that leads one shape label to the next.
        #
        # @param registry [Runtime::Registry] the registry whose `translations` are searched
        # @param bluebook [Bluebook::Declaration] the domain; only edges for its name count
        # @param from [String] the shape label the edge leaves
        # @param to [String] the shape label the edge reaches
        # @return [Bluebook::Translation, nil] the edge, or nil when none is loaded
        def edge_between(registry, bluebook, from, to)
          registry.translations.find { |t| t.domain == bluebook.name && t.from == from && t.to == to }
        end

        # Refuses a boot whose edge chain has a gap.
        #
        # @param bluebook [Bluebook::Declaration] the domain, named in the message
        # @param index [Integer] the zero-based step with no translation
        # @param from [String] the shape label the missing edge would leave
        # @param to [String] the shape label the missing edge would reach
        # @raise [Runtime::WiringError] always
        def refuse_broken_chain!(bluebook, index, from, to)
          raise Runtime::WiringError,
                "cannot boot #{bluebook.name}: the edge chain is broken at era #{index + 1} — no translation " \
                "leads #{from} to #{to}; restore bluebook/translations/"
        end

        # Parses a held era's bluebook text into a throwaway registry, not the live one.
        #
        # The predicate extractor reads source from disk, so the text goes through a scratch file.
        #
        # @param source [String] bluebook source text from `hecks_eras.held_text`
        # @return [Bluebook::Declaration, nil] the first bluebook the text declares
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
