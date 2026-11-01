require_relative "../../../../runtime/registry"
require_relative "../../../../ports/persistence/plugins/era/storage_shape"
require_relative "../../../../ports/persistence/plugins/era/translation/audit"
require_relative "../../../../ports/persistence/plugins/era/translation/scaffold"
require_relative "context"
require_relative "refusals"
require_relative "mint_decision"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # Names the source era, resolves its one outgoing translation edge, and mints the
        # next era once coverage and the audited chain check out.
        module Minter
          include Refusals

          # Mints the next era for a drifted shape in one transaction.
          #
          # @param context [Context] the era check so far; `latest` is the latest held era, named
          #   here if it has no name yet
          # @return [Integer] the ordinal of the era minted
          # @raise [Runtime::WiringError] if the edge, its coverage or its audit refuses
          def mint!(context)
            refuse_unrehearsed_mint!(context)
            ensure_named!(context.lineage, context.latest)
            context = context.with(latest: context.held_eras.last)
            decided_at = context.watermark
            edge = verified_edge!(context)
            refuse_unpermitted_mint!(context) unless context.mint_permitted
            chain = audited_chain!(context, edge)
            refuse_moved_watermark!(context, decided_at)
            commit_era!(context, chain, edge)
          end

          # The edge a mint leaves the held era by, as `MintDecision` decides it. A refusal the
          # decision names is raised by name; a change that needs a rule refuses toward the
          # scaffold.
          def resolve_edge!(context)
            verdict = decide!(context)
            return verdict.edge if verdict.verdict == "would_mint"
            return refuse_toward_the_scaffold!(context) if verdict.verdict == "needs_edge"

            refuse_refused_verdict!(context, verdict)
          end

          # Diffs the held era against the current shape and writes the edge file —
          # confident rules inline, ambiguities as parse-refusing `unresolved` lines.
          def scaffold!(_registry, bluebook, lineage, latest, directory)
            ensure_named!(lineage, latest)
            latest = lineage.eras.last
            label = Runtime::StorageShape.mint_hash(bluebook)[0, Runtime::StorageShape::LABEL_LENGTH]
            diffed = Translation::Scaffold.diff(shadow(latest[:held_text]), bluebook)
            edge = Translation::Scaffold::Edge.new(
              domain: bluebook.name, from: latest[:label], to: label, ordinal: latest[:ordinal] + 1,
              label: label, aggregates: diffed[:aggregates], retired: diffed[:retired]
            )
            Translation::Scaffold.write!(directory, edge)
          end

          # Mints a name for an era that has none yet, leaving an already-named era untouched.
          #
          # Era names are minted once, the moment an edge first needs to leave that era.
          def ensure_named!(lineage, era)
            return if era[:hash]

            held_bluebook = shadow(era[:held_text])
            hash = Runtime::StorageShape.mint_hash(held_bluebook)
            lineage.mint_name!(era[:ordinal], hash, hash[0, Runtime::StorageShape::LABEL_LENGTH])
          end

          private

          # The verdict `MintDecision` reaches for the held era the mint leaves, read at the
          # watermark the context holds now.
          def decide!(context)
            held = context.latest.merge(declaration: shadow(context.latest[:held_text]))
            MintDecision.decide(held: [held], bluebook: context.bluebook, edge_source: edge_source_of(context),
                                watermark: context.watermark, rows: [])
          end

          def edge_source_of(context)
            registry = context.registry
            { translations: registry.translations,
              recorded:     MintDecision.recorded_moves(context.domain_name, context.directory) }
          end

          # The refusal a decided edge stands for: a fork or a stale edge, each named.
          def refuse_refused_verdict!(context, verdict)
            return refuse_forked_eras!(context, verdict.edges) if verdict.reason == :fork

            refuse_stale_edge!(context, verdict.edge)
          end

          # The edge chain to the current shape, after its audit passes.
          def audited_chain!(context, edge)
            chain = edge_chain(context.registry, context.bluebook, context.held_eras, context.label,
                               target: minted_record(edge))
            audit!(context.bluebook, context.lineage, chain, context.ordinal, edge)
            chain
          end

          # The edge leaving the held era, once resolved and found to cover the diff.
          def verified_edge!(context)
            edge = resolve_edge!(context)
            check_coverage!(context.registry, context.bluebook, shadow(context.latest[:held_text]), edge)
            edge
          end

          # The journal record of the era a mint reaches, when the edge is implicit; nil when a
          # written edge file leads there.
          #
          # @return [Hash, nil] the era record `edge_chain` reads as its last step
          def minted_record(edge)
            edge.is_a?(Translation::ImplicitEdge) ? edge.record : nil
          end

          # @return [Hash, nil] the `edge` column of the minted era: the implicit marker, or nil
          def implicit_record(edge)
            edge.is_a?(Translation::ImplicitEdge) ? Translation::ImplicitEdge::RECORD : nil
          end

          def commit_era!(context, chain, edge)
            hash = context.shape_hash
            bluebook = context.bluebook
            context.lineage.mint_era!(
              ordinal: context.ordinal, hash: hash, label: hash[0, Runtime::StorageShape::LABEL_LENGTH],
              held_text: context.current_text, aggregates: bluebook.aggregates, edges: chain,
              role: context.role, projection: Runtime::StorageShape.project(context.bluebook),
              edge: implicit_record(edge)
            )
            context.ordinal
          end
        end
      end
    end
  end
end
