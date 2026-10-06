module Hecks
  module Projector
    module Exporter
      # The registered translation edges as Hashes and JSON: the declared rules a digest hashes,
      # and the same rules with each aggregate's precompiled SQL attached.
      module Translations
        # Every registered translation, with each aggregate's precompiled SQL attached —
        # `values:` serializes as `[key, value]` pairs since a convert's keys are typed.
        #
        # @param registry [Runtime::Registry] the booted registry to export translations from
        # @return [Array<Hash>] every registered translation, as `compiled_translation_hash`
        #   builds
        def translations(registry)
          registry.translations.map { |translation| compiled_translation_hash(translation) }
        end

        # Exports one translation, its aggregates' compiled SQL included.
        #
        # @param translation [Bluebook::Translation] the translation to export
        # @return [Hash{Symbol => Object}] `:domain` (String), `:from`/`:to` (the era
        #   identifiers as declared), `:retired` (`Array<String>`), and `:aggregates`
        #   (each `compiled_translation_aggregate`'s own Hash)
        def compiled_translation_hash(translation)
          {
            domain:     translation.domain,
            from:       translation.from,
            to:         translation.to,
            retired:    translation.retired,
            aggregates: translation.aggregates.map { |aggregate| compiled_translation_aggregate(aggregate) }
          }
        end

        # Exports every registered translation as JSON.
        #
        # @param registry [Runtime::Registry] the booted registry to export translations from
        # @return [String] `translations`' output, as pretty-printed JSON
        def translations_json(registry)
          JSON.pretty_generate(translations(registry))
        end

        # The digest-relevant shape `ApprovalDigest.edge_digest` hashes — declared rules only,
        # never the compiled SQL, so a compiler-output change can't invalidate an approval.
        #
        # @param translation [Bluebook::Translation] the translation to digest
        # @return [Hash{Symbol => Object}] `:domain` (String), `:from`/`:to` (the era
        #   identifiers as declared), `:retired` (`Array<String>`), and `:aggregates`
        #   (each `translation_aggregate`'s own Hash)
        def translation_hash(translation)
          {
            domain:     translation.domain,
            from:       translation.from,
            to:         translation.to,
            retired:    translation.retired,
            aggregates: translation.aggregates.map { |aggregate| translation_aggregate(aggregate) }
          }
        end

        # Digests one aggregate's own declared translation rules.
        #
        # @param aggregate [Bluebook::TranslationAggregate] the aggregate's own
        #   translation rules to digest
        # @return [Hash{Symbol => Object}] `:name` (String), `:was` (String, nil),
        #   `:renames` (`Hash{String => String}`), `:moves`/`:converts`/`:retypes`/
        #   `:computes`/`:rekeys`/`:backfills` (each an `Array<Hash>`), `:drops`
        #   (`Array<String>`)
        def translation_aggregate(aggregate)
          structural_rules(aggregate).merge(typed_rules(aggregate)).merge(computed_rules(aggregate))
        end

        # `translation_aggregate`'s fields, plus precompiled SQL from the same
        # `Translation::RuleCompiler` mint time uses (ADR 0033 governs its fallback).
        #
        # @param aggregate [Bluebook::TranslationAggregate] the aggregate's own
        #   translation rules to compile and export
        # @return [Hash{Symbol => Object}] `translation_aggregate`'s own Hash, plus
        #   `:compiled_state_expression` (String) and `:compiled_id_expression`
        #   (String, nil) when the era persistence plugin is loaded
        def compiled_translation_aggregate(aggregate)
          return translation_aggregate(aggregate) unless Ports::Persistence.plugin?(:era)

          translation_aggregate(aggregate).merge(
            compiled_state_expression: Translation::RuleCompiler.compile_rules(aggregate),
            compiled_id_expression:    (if Translation::RuleCompiler.rekeyed?(aggregate)
                                          Translation::RuleCompiler.compile_id_expression(aggregate)
                                        end)
          )
        end

        private

        # The aggregate's name, former name, renames and moves.
        def structural_rules(aggregate)
          {
            name:    aggregate.name,
            was:     aggregate.was,
            renames: aggregate.renames.transform_keys(&:to_s).transform_values(&:to_s),
            moves:   aggregate.moves.map { |move| { from: move.from, to: move.to } }
          }
        end

        # The converts, drops and retypes of an aggregate.
        def typed_rules(aggregate)
          {
            converts: aggregate.converts.map do |convert|
              { from: convert.from, to: convert.to, values: convert.values.map { |key, value| [key, value] } }
            end,
            drops:    aggregate.drops.map(&:to_s),
            retypes:  aggregate.retypes.map { |retype| { from: retype.from, to: retype.to } }
          }
        end

        # The computes, rekeys and backfills of an aggregate.
        #
        # `rekeys`/`backfills` are digest-relevant too — a rekey with no compute
        # would otherwise collide with any other, letting its SQL change silently
        # invalidate nothing.
        def computed_rules(aggregate)
          {
            computes:  aggregate.computes.map { |compute| { from: compute.from, to: compute.to, sql: compute.sql } },
            rekeys:    aggregate.rekeys.map { |rekey| { sql: rekey.sql } },
            backfills: aggregate.backfills.map { |backfill| { name: backfill.name.to_s, default: backfill.default } }
          }
        end
      end
    end
  end
end
