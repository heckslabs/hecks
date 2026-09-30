require_relative "../../../../../../runtime/registry"
require_relative "../../storage_shape"
require_relative "../../translation/audit"
require_relative "../../translation/scaffold"
require_relative "../../translation/approval_file"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # Names the source era, resolves its one outgoing translation edge, and mints the
        # next era once approval, coverage and the audited chain all check out.
        module Minter
          # Mints the next era for a drifted shape in one transaction.
          def mint!(registry, bluebook, current_text, lineage, latest, role: nil, directory: nil)
            ensure_named!(lineage, latest)
            latest = lineage.eras.last

            hash = Runtime::StorageShape.mint_hash(bluebook)
            label = hash[0, Runtime::StorageShape::LABEL_LENGTH]
            ordinal = latest[:ordinal] + 1

            edge = resolve_edge!(registry, bluebook, lineage, latest, label, ordinal, directory)
            ensure_compute_rekey_approved!(bluebook, lineage, edge, ordinal, directory: directory)
            check_coverage!(registry, bluebook, shadow(latest[:held_text]), edge)

            chain = edge_chain(registry, bluebook, lineage.eras, label)
            audit!(bluebook, lineage, chain, ordinal, edge)
            lineage.mint_era!(
              ordinal: ordinal, hash: hash, label: label, held_text: current_text,
              aggregates: bluebook.aggregates, edges: chain, role: role,
              projection: Runtime::StorageShape.project(bluebook)
            )
            ordinal
          end

          # Finds the one translation edge leaving the held era and targeting the current
          # shape's label; a second edge from the same source is a wiring mistake, not a
          # merge to resolve automatically.
          def resolve_edge!(registry, bluebook, lineage, latest, label, ordinal, directory)
            edges = registry.translations.select { |t| t.domain == bluebook.name && t.from == latest[:label] }
            refuse_toward_the_scaffold!(registry, bluebook, lineage, latest, ordinal, directory) if edges.empty?
            if edges.size > 1
              raise Runtime::WiringError,
                    "cannot boot #{bluebook.name}: #{edges.size} translation edges leave era #{latest[:ordinal]} " \
                    "(#{latest[:label]}) — eras fork mechanically; keep one edge per source shape"
            end

            edge = edges.first
            unless edge.to == label
              raise Runtime::WiringError,
                    "cannot boot #{bluebook.name}: the translation edge from #{latest[:label]} targets " \
                    "#{edge.to}, but the current shape is #{label} — the edge is stale; re-run hecks scaffold_translation"
            end
            edge
          end

          # Refuses a mint whose edge carries a compute or rekey rule without an approval.
          #
          # A compute or rekey's only verification is a human-approved audit sample. Two approvals
          # satisfy it: one recorded in the journal that matches the edge and the journal's current
          # tip, or a committed `translations/<edge>.approval` that matches the edge's digest and
          # records a passed rehearsal on a compatible host release. A committed approval that applies is written into the
          # journal, so the journal stays the single history.
          def ensure_compute_rekey_approved!(bluebook, lineage, edge, ordinal, directory: nil)
            return unless Translation::ApprovalFile.needs_rehearsal?(edge)

            approval = lineage.approval_for(from: edge.from, to: edge.to)
            digest = Translation::Audit.edge_digest(edge)
            tip = lineage.last_ordinal
            return if approval && approval[:edge_digest] == digest && approval[:reviewed_ordinal] == tip

            if Translation::ApprovalFile.applicable(directory, edge)
              lineage.record_approval!(from: edge.from, to: edge.to, edge_digest: digest)
              return
            end

            unless approval && approval[:edge_digest] == digest
              if (mismatch = Translation::ApprovalFile.host_mismatch(directory, edge))
                raise Runtime::WiringError,
                      "cannot mint era #{ordinal} of #{bluebook.name}: the committed approval does not " \
                      "apply — #{mismatch}"
              end

              raise Runtime::WiringError,
                    "cannot mint era #{ordinal} of #{bluebook.name}: this edge carries a compute or rekey " \
                    "rule, and the audit's human-approved sample is its only verification — run " \
                    "hecks audit_translation with --approve, then boot again"
            end

            raise Runtime::WiringError,
                  "cannot mint era #{ordinal} of #{bluebook.name}: the journal advanced past the approved " \
                  "review (ordinal #{approval[:reviewed_ordinal]} reviewed, #{tip} now) — the samples a " \
                  "human approved no longer cover the data; re-run hecks audit_translation with --approve"
          end

          # Refuses toward the authoring loop, or, under HECKS_SCAFFOLD=1, scaffolds the
          # missing edge first and names the file it wrote.
          def refuse_toward_the_scaffold!(registry, bluebook, lineage, latest, ordinal, directory)
            if ENV["HECKS_SCAFFOLD"] == "1" && directory
              path = scaffold!(registry, bluebook, lineage, latest, directory)
              raise Runtime::WiringError,
                    "cannot boot #{bluebook.name}: the shape changed (era #{ordinal}) — wrote #{path}; " \
                    "review it (resolve every unresolved), check it with hecks audit_translation, then boot again"
            end

            raise Runtime::WiringError,
                  "cannot boot #{bluebook.name}: the shape changed (era #{ordinal}) and no translation edge " \
                  "covers it — run hecks scaffold_translation to write the edge, " \
                  "check it with hecks audit_translation, then boot again"
          end

          # Diffs the held era against the current shape and writes the edge file —
          # confident rules inline, ambiguities as parse-refusing `unresolved` lines.
          def scaffold!(_registry, bluebook, lineage, latest, directory)
            ensure_named!(lineage, latest)
            latest = lineage.eras.last

            hash = Runtime::StorageShape.mint_hash(bluebook)
            held_bluebook = shadow(latest[:held_text])
            diffed = Translation::Scaffold.diff(held_bluebook, bluebook)
            edge = Translation::Scaffold::Edge.new(
              domain:     bluebook.name,
              from:       latest[:label],
              to:         hash[0, Runtime::StorageShape::LABEL_LENGTH],
              ordinal:    latest[:ordinal] + 1,
              label:      hash[0, Runtime::StorageShape::LABEL_LENGTH],
              aggregates: diffed[:aggregates],
              retired:    diffed[:retired]
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
        end
      end
    end
  end
end
