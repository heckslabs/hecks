# frozen_string_literal: true

require_relative "../../tools"

module Hecks
  module Tools
    module TranslationAudit
      # Finds the edge to audit: the translations leading from the journal's latest era to the
      # bluebook as it stands.
      module Edges
        # The era the edge leads to and the chain of translations ending in it, or nil when the
        # journal stands at era 1 with nothing to audit.
        #
        # @return [Array, nil] the era ordinal and the chain
        def edge_chain(registry, bluebook, lineage)
          eras = lineage.eras
          current_shape = Hecks::Runtime::StorageShape.project(bluebook)
          held_shape = Hecks::Runtime::StorageShape.project(lineage_manager.shadow(eras.last[:held_text]))

          if held_shape == current_shape
            standing_chain(registry, bluebook, eras)
          else
            pending_chain(registry, bluebook, lineage, eras)
          end
        end

        private

        def lineage_manager
          Hecks::Adapters::PostgresEra::LineageManager
        end

        # The chain when the held journal already matches the bluebook.
        def standing_chain(registry, bluebook, eras)
          latest = eras.last
          era = latest[:ordinal]
          if era == 1
            puts "#{bluebook.name} stands at era 1 — no edge to audit."
            return nil
          end
          [era, lineage_manager.edge_chain(registry, bluebook, eras, latest[:label])]
        end

        # The chain when the bluebook has moved past the held journal: audit the pending edge
        # before any mint.
        def pending_chain(registry, bluebook, lineage, eras)
          lineage_manager.ensure_named!(lineage, eras.last)
          latest = lineage.eras.last
          pending = pending_translation(registry, bluebook, latest)
          chain = begin
            lineage_manager.edge_chain(registry, bluebook, eras, latest[:label])
          rescue StandardError
            []
          end
          [latest[:ordinal] + 1, (chain || []) + [{ translation: pending }]]
        end

        # @return [Object] the translation leading from `latest` to the bluebook
        # @raise [SystemExit] when none is declared
        def pending_translation(registry, bluebook, latest)
          to_label = Hecks::Runtime::StorageShape.mint_hash(bluebook)[0, Hecks::Runtime::StorageShape::LABEL_LENGTH]
          pending = registry.translations.find do |t|
            t.domain == bluebook.name && t.from == latest[:label] && t.to == to_label
          end
          pending or abort "no translation edge leads #{latest[:label]} to #{to_label} — " \
                           "run hecks scaffold_translation first"
        end
      end
    end
  end
end
