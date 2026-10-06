require_relative "../../../../../../runtime/registry"
require_relative "../../storage_shape"
require_relative "../../translation/audit"
require_relative "../../translation/scaffold"
require_relative "../../translation/approval_file"
require_relative "context"
require_relative "refusals"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # Names the source era, resolves its one outgoing translation edge, and mints the
        # next era once approval, coverage and the audited chain all check out.
        module Minter
          include Refusals

          # Mints the next era for a drifted shape in one transaction.
          #
          # @param context [Context] the era check so far; `latest` is the latest held era, named
          #   here if it has no name yet
          # @return [Integer] the ordinal of the era minted
          # @raise [Runtime::WiringError] if the edge, its approval, its coverage or its audit
          #   refuses
          def mint!(context)
            ensure_named!(context.lineage, context.latest)
            context = context.with(latest: context.lineage.eras.last)
            edge = verified_edge!(context)
            chain = audited_chain!(context, edge)
            commit_era!(context, chain)
          end

          # Finds the one translation edge leaving the held era and targeting the current
          # shape's label; a second edge from the same source is a wiring mistake, not a
          # merge to resolve automatically.
          def resolve_edge!(context)
            edges = edges_leaving(context)
            refuse_toward_the_scaffold!(context) if edges.empty?
            refuse_forked_eras!(context, edges) if edges.size > 1
            refuse_stale_edge!(context, edges.first)
            edges.first
          end

          # Refuses a mint whose edge carries a compute or rekey rule without an approval.
          #
          # A compute or rekey's only verification is a human-approved audit sample. Two approvals
          # satisfy it: one recorded in the journal that matches the edge and the journal's current
          # tip, or a committed `translations/<edge>.approval` that matches the edge's digest and
          # records a passed rehearsal on a compatible host release. A committed approval that
          # applies is written into the journal, so the journal stays the single history.
          def ensure_compute_rekey_approved!(context, edge)
            return unless Translation::ApprovalFile.needs_rehearsal?(edge)

            approval = context.lineage.approval_for(from: edge.from, to: edge.to)
            digest = Translation::Audit.edge_digest(edge)
            tip = context.lineage.last_ordinal
            return if approved_at_tip?(approval, digest, tip)

            if Translation::ApprovalFile.applicable(context.directory, edge)
              context.lineage.record_approval!(from: edge.from, to: edge.to, edge_digest: digest)
              return
            end

            refuse_unapproved!(context, edge, approval, tip)
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

          def edges_leaving(context)
            context.registry.translations.select do |t|
              t.domain == context.bluebook.name && t.from == context.latest[:label]
            end
          end

          # The edge chain to the current shape, after its audit passes.
          def audited_chain!(context, edge)
            chain = edge_chain(context.registry, context.bluebook, context.lineage.eras, context.label)
            audit!(context.bluebook, context.lineage, chain, context.ordinal, edge)
            chain
          end

          # The edge leaving the held era, once resolved, approved and found to cover the diff.
          def verified_edge!(context)
            edge = resolve_edge!(context)
            ensure_compute_rekey_approved!(context, edge)
            check_coverage!(context.registry, context.bluebook, shadow(context.latest[:held_text]), edge)
            edge
          end

          def commit_era!(context, chain)
            hash = context.shape_hash
            context.lineage.mint_era!(
              ordinal: context.ordinal, hash: hash, label: hash[0, Runtime::StorageShape::LABEL_LENGTH],
              held_text: context.current_text, aggregates: context.bluebook.aggregates, edges: chain,
              role: context.role, projection: Runtime::StorageShape.project(context.bluebook)
            )
            context.ordinal
          end
        end
      end
    end
  end
end
