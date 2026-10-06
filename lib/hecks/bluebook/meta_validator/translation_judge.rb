require_relative "translation_judge/rules"

module Hecks
  module Bluebook
    module MetaValidator
      # Offers a built translation (a `translations/*.bluebook` edge) to the language that
      # describes translations. Field names follow the `Translation` structs, not the DSL builder.
      class TranslationJudge
        include Rules

        attr_reader :refusals

        # @param translation [Bluebook::Translation] the built translation to judge
        def initialize(translation)
          @translation = translation
          @refusals    = []
          @runtime     = MetaValidator.fresh_runtime
          judge!
        end

        private

        def v(text) = text.nil? ? nil : { value: text.to_s }

        def args(pairs) = pairs.compact

        # Rescues `AlreadyExists` too: `TranslationBuilder#aggregate` does not dedup, so two
        # same-named aggregate blocks reach here and must become a refusal, not a crash.
        def offer(label)
          yield
        rescue Runtime::GivenNotMet, Runtime::InvariantViolation, Runtime::TypeMismatch,
               Runtime::NotFound, Runtime::AlreadyExists => e
          @refusals << "#{label}: #{e.message}"
        rescue Runtime::UnknownVerb
          nil
        end

        def send_to(verb, label, to: nil, with: {})
          offer(label) { @runtime.dispatch(verb, to: to, with: args(with)) }
        end

        def judge!
          declare_translation
          retire_aggregates

          Array(@translation.aggregates).each { |aggregate| judge_aggregate(@translation, aggregate) }
        end

        def declare_translation
          t = @translation
          send_to("Translation::Translation.Declare", t.domain,
                  with: { domain: v(t.domain), from: v(t.from), to: v(t.to) })
        end

        def retire_aggregates
          t = @translation
          # Translation's identity is composite, so `id:` must be computed, not a bare field.
          translation_id = Naming.identity([t.domain, t.from, t.to])
          Array(t.retired).each do |name|
            send_to("Translation::Translation.Retire", t.domain, to: translation_id, with: { value: v(name) })
          end
        end

        # Declares the aggregate, then adds each rule collection. Only Declare-before-Add is
        # order-sensitive.
        def judge_aggregate(translation, aggregate)
          name = aggregate.name
          declare_aggregate(translation, aggregate, name)

          judge_renames(aggregate, name)
          judge_moves(aggregate, name)
          judge_converts(aggregate, name)
          judge_drops(aggregate, name)
          judge_retypes(aggregate, name)
          judge_computes(aggregate, name)
          judge_rekeys(aggregate, name)
          judge_backfills(aggregate, name)
        end

        def declare_aggregate(translation, aggregate, name)
          parent = {
            domain: v(translation.domain),
            from:   v(translation.from),
            to:     v(translation.to)
          }
          send_to("Translation::TranslationAggregate.Declare", name,
                  with: { translation_ref: parent, name: v(name), was: v(aggregate.was) })
        end
      end
    end
  end
end
