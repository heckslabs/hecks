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
          # lists the edges that lead the held era to the current shape; `diff` is the shape diff;
          # `watermark` is the one decided at.
          Verdict = Data.define(:verdict, :reason, :edge, :edges, :source, :diff, :watermark)

          module_function

          # @param held [Array<Hash>] the held eras, oldest first; the last is the era a mint
          #   leaves.
          #   Each carries `label` and `declaration`, the storage shape it holds as a bluebook view
          #   (see `held_for_decision`)
          # @param bluebook [Bluebook::Declaration] the current bluebook
          # @param edge_source [Hash] `translations`, the loaded edges, and `recorded`, the recorded
          #   implicit moves as `[from, to]` pairs (see `recorded_moves`)
          # @param watermark [Integer] the ledger watermark the decision reads
          # @param rows [Array<String>] the refusals an audit ran over the decided edge; empty when
          #   none, or when no audit has run yet
          # @return [Verdict]
          def decide(held:, bluebook:, edge_source:, watermark:, rows:)
            latest = held.last
            edges = leading(edge_source[:translations], bluebook, latest[:label])
            found = if edges.empty?
                      implicit(latest, bluebook, edge_source[:recorded], watermark)
                    else
                      written(edges, latest, bluebook, watermark)
                    end
            rows.empty? ? found : audit_refusal(found)
          end

          # The decision for the era a mint would leave, reading the held era's stored shape here,
          # so a caller holding only the era's record reaches the same verdict as a mint does.
          #
          # @param latest [Hash] the held era, as `Lineage#eras` answers it
          # @param bluebook [Bluebook::Declaration] the current bluebook
          # @param translations [Array<Object>] the edges the registry loaded
          # @param directory [String, nil] the domain's bluebook directory
          # @param watermark [Integer] the ledger watermark the decision reads
          # @return [Verdict]
          def decide_latest(latest, bluebook:, translations:, directory:, watermark:)
            decide(held: [held_for_decision(latest)], bluebook: bluebook, watermark: watermark, rows: [],
                   edge_source: { translations: translations, recorded: recorded_moves(bluebook.name, directory) })
          end

          # A held era as the decision reads it: with `declaration`, the storage shape it holds as a
          # bluebook view (LineageManager::HeldEra). Its held text is not read.
          #
          # @param era [Hash] an era as `Lineage#eras` answers it
          # @return [Hash] the era with `declaration`, a `Runtime::ProjectedBluebook`
          # @raise [Runtime::WiringError] naming the era, when its shape cannot be known
          def held_for_decision(era) = era.merge(declaration: LineageManager.held_bluebook(era))

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

          # Whether the move from the held era is breaking and nothing covers it: the decision needs
          # an edge, and the change is not provably additive. A move a mint would go ahead on, or a
          # decision already refused for another reason, is not this. An edge from the held shape
          # covers it even when the held era has not been named yet.
          #
          # @return [Boolean]
          def breaking?(latest, bluebook, verdict, translations)
            return false unless verdict.verdict == "needs_edge"
            return false unless leading(translations, bluebook, held_label_of(latest)).empty?

            !additive?(verdict.diff, held_for_decision(latest), bluebook)
          end

          # @return [String] the stored label of a held era, or the one its shape would be named
          def held_label_of(era)
            era[:label] || LineageManager.held_hash(era)[0, Runtime::StorageShape::LABEL_LENGTH]
          end

          # The shape label a storage shape of this bluebook carries.
          #
          # @return [String]
          def label_of(bluebook) = Runtime::StorageShape.mint_hash(bluebook)[0, Runtime::StorageShape::LABEL_LENGTH]

          # The edges the domain loads that lead the held era straight to the current shape. An edge
          # from the held era to any other shape plays no part: the translation is from the held
          # shape to the current one, so other edges neither fork the decision nor make it stale.
          #
          # @return [Array<Object>] the edges from `from` to the bluebook's current label
          def leading(translations, bluebook, from)
            to = label_of(bluebook)
            translations.select { |edge| edge.domain == bluebook.name && edge.from == from && edge.to == to }
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

          # A written edge from the held shape to the current one leads on. Two files declaring that
          # same pair disagree about one translation, so neither is taken.
          def written(edges, latest, bluebook, watermark)
            diff = diff_of(latest, bluebook)
            return verdict_of("refused", diff, watermark, reason: :duplicate_edge, edges: edges) if edges.size > 1

            verdict_of("would_mint", diff, watermark, edge: edges.first, edges: edges, source: "file")
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
