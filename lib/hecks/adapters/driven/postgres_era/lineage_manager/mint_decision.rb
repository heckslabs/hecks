require_relative "../../../../ports/persistence/plugins/era/translation/implicit_edge"
require_relative "../../../../ports/persistence/plugins/era/translation/scaffold"
require_relative "../../../../ports/persistence/plugins/era/storage_shape"
require_relative "../../../../shape_ledger"

module Hecks
  module Adapters
    class PostgresEra
      module LineageManager
        # The decision a mint and a rehearsal both make: which translation edge leads the held era
        # to the current shape, and whether a mint would go ahead on it. It reads only what its
        # caller hands it and writes nothing, so the same inputs reach the same verdict on either
        # path.
        module MintDecision
          # The implicit moves the framework keeps beside its shape ledger. A bluebook the framework
          # holds, such as QualityControl, has its moves recorded here, not beside its own files.
          FRAMEWORK_MOVES = File.join(File.expand_path("../../../../hecks", __dir__),
                                      ShapeLedger::IMPLICIT_FILE).freeze

          # What a decision concludes. `verdict` is `would_mint`, `needs_edge` (the change needs
          # a rule) or `refused`; `reason` names why it is not `would_mint`; `edge` is the edge a
          # mint would use and is nil unless `would_mint`; `source` is `file` or `implicit`; `edges`
          # lists every edge that leaves the held era; `diff` is the shape diff; `watermark` is the
          # one decided at.
          Verdict = Data.define(:verdict, :reason, :edge, :edges, :source, :diff, :watermark)

          module_function

          # @param held [Array<Hash>] the held eras, oldest first; the last is the era a mint
          #   leaves.
          #   Each carries `label`, `held_text` and `declaration`, its source parsed as a bluebook
          # @param bluebook [Bluebook::Declaration] the current bluebook
          # @param edge_source [Hash] `translations`, the loaded edges, and `recorded`, the recorded
          #   implicit moves as `[from, to]` pairs (see `recorded_moves`)
          # @param watermark [Integer] the ledger watermark the decision reads
          # @param rows [Array<String>] the refusals an audit ran over the decided edge; empty when
          #   none, or when no audit has run yet
          # @return [Verdict]
          def decide(held:, bluebook:, edge_source:, watermark:, rows:)
            latest = held.last
            edges = leaving(edge_source[:translations], bluebook.name, latest[:label])
            found = if edges.empty?
                      implicit(latest, bluebook, edge_source[:recorded], watermark)
                    else
                      written(edges, latest, bluebook, watermark)
                    end
            rows.empty? ? found : audit_refusal(found)
          end

          # The implicit moves a domain has recorded: beside its own bluebooks, when a directory is
          # given, and in the framework's record. This is the only read the decision's inputs need.
          #
          # @param domain [String] the bluebook name the moves are recorded under
          # @param directory [String, nil] the domain's bluebook directory
          # @return [Array<Array(String, String)>] each recorded move as `[from, to]`
          def recorded_moves(domain, directory)
            paths = [directory && File.join(directory, ShapeLedger::IMPLICIT_FILE), FRAMEWORK_MOVES].compact
            paths.flat_map { |path| ShapeLedger.pairs_of(ShapeLedger.implicit_moves(path).fetch(domain, [])) }
          end

          # The shape label a storage shape of this bluebook carries.
          #
          # @return [String]
          def label_of(bluebook) = Runtime::StorageShape.mint_hash(bluebook)[0, Runtime::StorageShape::LABEL_LENGTH]

          # @return [Array<Object>] the edges the domain loads from `from`
          def leaving(translations, domain, from)
            translations.select { |edge| edge.domain == domain && edge.from == from }
          end

          # The implicit empty edge: the recorded moves must reach the shape from the held label,
          # and the change must qualify as additive by `Translation::ImplicitEdge.qualifies?`.
          def implicit(latest, bluebook, recorded, watermark)
            diff = diff_of(latest, bluebook)
            to = label_of(bluebook)
            return verdict_of("needs_edge", diff, watermark, reason: :unrecorded) unless reachable?(latest, to, recorded)
            return verdict_of("needs_edge", diff, watermark, reason: :non_qualifying) unless additive?(diff, latest, bluebook)

            edge = Translation::ImplicitEdge.new(domain: bluebook.name, from: latest[:label], to: to)
            verdict_of("would_mint", diff, watermark, edge: edge, edges: [], source: "implicit")
          end

          # @return [Hash] the scaffold's diff of the held era against the current bluebook
          def diff_of(latest, bluebook) = Translation::Scaffold.diff(latest[:declaration], bluebook)

          # @return [Boolean] whether the recorded moves chain from the held label to `to`
          def reachable?(latest, to, recorded) = ShapeLedger.reachable?(latest[:label], to, recorded)

          # @return [Boolean] whether the change qualifies as additive by the implicit edge's rule
          def additive?(diff, latest, bluebook) = Translation::ImplicitEdge.qualifies?(diff, latest[:declaration], bluebook)

          # A written edge leads on when it is the only one that leaves the held era and targets
          # the shape.
          def written(edges, latest, bluebook, watermark)
            diff = diff_of(latest, bluebook)
            return verdict_of("refused", diff, watermark, reason: :fork, edges: edges) if edges.size > 1

            edge = edges.first
            return stale_edge(diff, watermark, edge, edges) unless edge.to == label_of(bluebook)

            verdict_of("would_mint", diff, watermark, edge: edge, edges: edges, source: "file")
          end

          def stale_edge(diff, watermark, edge, edges)
            verdict_of("refused", diff, watermark, reason: :stale_edge, edge: edge, edges: edges)
          end

          # An audit's refusals turn a would_mint into a refusal that names the audit.
          def audit_refusal(found)
            return found unless found.verdict == "would_mint"

            verdict_of("refused", found.diff, found.watermark, reason: :audit, edges: found.edges)
          end

          # @return [Verdict] a verdict of `kind`, with the fields it carries and none it does not
          def verdict_of(kind, diff, watermark, **attributes)
            Verdict.new(verdict: kind, reason: nil, edge: nil, edges: [], source: nil, diff: diff,
                        watermark: watermark, **attributes)
          end
        end
      end
    end
  end
end
