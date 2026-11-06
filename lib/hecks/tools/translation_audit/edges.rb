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
        # @param directory [String, nil] the domain's bluebook directory, holding its implicit moves
        # @return [Array, nil] the era ordinal and the chain
        def edge_chain(registry, bluebook, lineage, directory = nil)
          eras = lineage.eras
          current_shape = Hecks::Runtime::StorageShape.project(bluebook)
          held_shape = lineage_manager.held_shape(eras.last)

          if held_shape == current_shape
            standing_chain(registry, bluebook, eras)
          else
            pending_chain(registry, bluebook, lineage, eras, directory)
          end
        end

        private

        def lineage_manager
          Hecks::Adapters::PostgresRevisions::LineageManager
        end

        # The chain when the held journal already matches the bluebook.
        def standing_chain(registry, bluebook, eras)
          latest = eras.last
          era = latest[:ordinal]
          if era == 1
            puts "#{bluebook.name} stands at era 1 — no edge to audit."
            return nil
          end
          [era, lineage_manager.edge_chain(registry, bluebook, eras, latest[:label], target: latest)]
        end

        # The chain when the bluebook has moved past the held journal: audit the pending edge
        # before any mint.
        def pending_chain(registry, bluebook, lineage, eras, directory)
          lineage_manager.ensure_named!(lineage, eras.last)
          latest = lineage.eras.last
          pending = pending_translation(registry, bluebook, latest, lineage, directory)
          chain = begin
            lineage_manager.edge_chain(registry, bluebook, eras, latest[:label], target: latest)
          rescue StandardError
            []
          end
          [latest[:ordinal] + 1, (chain || []) + [{ translation: pending }]]
        end

        # The edge the shared decision leads `latest` by, as a mint takes it.
        #
        # @return [Object] the edge leading from `latest` to the bluebook
        # @raise [SystemExit] when the decision names no edge
        def pending_translation(registry, bluebook, latest, lineage, directory)
          verdict = lineage_manager::MintDecision.decide_latest(
            latest, bluebook: bluebook, translations: registry.translations, directory: directory,
            watermark: lineage.last_ordinal
          )
          return verdict.edge if verdict.verdict == "would_mint"

          abort "no translation edge leads #{latest[:label]} to the current shape (the decision is " \
                "#{verdict.verdict}) — run hecks scaffold_translation first"
        end
      end
    end
  end
end
