require_relative "../../../../../../runtime/registry"
require_relative "../../storage_shape"
require_relative "../../translation/audit"
require_relative "../../translation/scaffold"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # The mint path: name the source era, find the one edge that
        # leaves it, hold the compute approval to what was actually
        # reviewed, check coverage, audit the live chain, and mint — or
        # refuse toward the authoring loop by name.
        module Minter
          def mint!(registry, bluebook, current_text, lineage, latest, role: nil, directory: nil)
            ensure_named!(lineage, latest)
            latest = lineage.eras.last

            hash = Runtime::StorageShape.mint_hash(bluebook)
            label = hash[0, Runtime::StorageShape::LABEL_LENGTH]
            ordinal = latest[:ordinal] + 1

            edges = registry.translations.select { |t| t.domain == bluebook.name && t.from == latest[:label] }
            if edges.empty?
              refuse_toward_the_scaffold!(registry, bluebook, lineage, latest, ordinal, directory)
            end
            if edges.size > 1
              raise Runtime::WiringError,
                    "cannot boot #{bluebook.name}: #{edges.size} translation edges leave era #{latest[:ordinal]} " \
                    "(#{latest[:label]}) — eras fork mechanically; keep one edge per source shape"
            end

            edge = edges.first
            unless edge.to == label
              raise Runtime::WiringError,
                    "cannot boot #{bluebook.name}: the translation edge from #{latest[:label]} targets " \
                    "#{edge.to}, but the current shape is #{label} — the edge is stale; re-run bin/scaffold_translation"
            end

            # A compute's (and, the same way, a rekey's) only verification
            # is the audit's human-approved sample — mint stays
            # non-interactive by requiring the approval to already exist,
            # recorded IN THIS DATABASE by `bin/translation_audit …
            # --approve` and bound to what was actually reviewed: this
            # edge's parsed content, and the journal as it stood when the
            # samples were read. A journal that has advanced past the
            # review invalidates it — the approved samples no longer cover
            # the data.
            if edge.aggregates.any? { |declared| !declared.computes.empty? || !declared.rekeys.empty? }
              approval = lineage.approval_for(from: edge.from, to: edge.to)
              unless approval && approval[:edge_digest] == Translation::Audit.edge_digest(edge)
                raise Runtime::WiringError,
                      "cannot mint era #{ordinal} of #{bluebook.name}: this edge carries a compute or rekey " \
                      "rule, and the audit's human-approved sample is its only verification — run " \
                      "bin/translation_audit with --approve, then boot again"
              end
              tip = lineage.last_ordinal
              if approval[:reviewed_ordinal] != tip
                raise Runtime::WiringError,
                      "cannot mint era #{ordinal} of #{bluebook.name}: the journal advanced past the approved " \
                      "review (ordinal #{approval[:reviewed_ordinal]} reviewed, #{tip} now) — the samples a " \
                      "human approved no longer cover the data; re-run bin/translation_audit with --approve"
              end
            end

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

          # No edge yet: the boot refuses toward the authoring loop —
          # naming both tools and the era ordinal. With HECKS_SCAFFOLD=1
          # the boot RUNS the scaffold first (an explicit flag, never a
          # silent side-effect) and the refusal names the file it wrote.
          def refuse_toward_the_scaffold!(registry, bluebook, lineage, latest, ordinal, directory)
            if ENV["HECKS_SCAFFOLD"] == "1" && directory
              path = scaffold!(registry, bluebook, lineage, latest, directory)
              raise Runtime::WiringError,
                    "cannot boot #{bluebook.name}: the shape changed (era #{ordinal}) — wrote #{path}; " \
                    "review it (resolve every unresolved), check it with bin/translation_audit, then boot again"
            end

            raise Runtime::WiringError,
                  "cannot boot #{bluebook.name}: the shape changed (era #{ordinal}) and no translation edge " \
                  "covers it — run bin/scaffold_translation to write the edge, " \
                  "check it with bin/translation_audit, then boot again"
          end

          # Diff the held era against the current shape and write the edge
          # file — confident rules inline, ambiguities as parse-refusing
          # `unresolved` lines. Returns the file path.
          def scaffold!(registry, bluebook, lineage, latest, directory)
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

          # Era names are minted once. An era held before any drift was
          # seen has no name yet; it gets one the moment an edge needs to
          # leave it.
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
