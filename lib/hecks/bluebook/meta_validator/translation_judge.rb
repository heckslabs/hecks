module Hecks
  module Bluebook
    module MetaValidator
      # Offers a built translation (a `translations/*.bluebook` edge) to the language that
      # describes translations. Field names follow the `Translation` structs, not the DSL builder.
      class TranslationJudge
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
          t = @translation
          send_to("Translation::Translation.Declare", t.domain,
                  with: { domain: v(t.domain), from: v(t.from), to: v(t.to) })

          # Translation's identity is composite, so `id:` must be computed, not a bare field.
          translation_id = Naming.identity([t.domain, t.from, t.to])
          Array(t.retired).each do |name|
            send_to("Translation::Translation.Retire", t.domain, to:   translation_id,
                                                                 with: { value: v(name) })
          end

          Array(t.aggregates).each { |aggregate| judge_aggregate(t, aggregate) }
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

        def judge_renames(aggregate, name)
          Hash(aggregate.renames).each do |from, to|
            send_to("Translation::TranslationAggregate.AddRename", name, to:   name,
                                                                         with: { from: v(from), to: v(to) })
          end
        end

        def judge_moves(aggregate, name)
          Array(aggregate.moves).each do |move|
            send_to("Translation::TranslationAggregate.AddMove", name, to:   name,
                                                                       with: { from: v(move.from), to: v(move.to) })
          end
        end

        def judge_converts(aggregate, name)
          Array(aggregate.converts).each do |convert|
            send_to("Translation::TranslationAggregate.AddConvert", name, to:   name,
                                                                          with: { from:   v(convert.from),
                                                                                  to:     v(convert.to),
                                                                                  values: v(convert.values.inspect) })
          end
        end

        def judge_drops(aggregate, name)
          Array(aggregate.drops).each do |dropped|
            send_to("Translation::TranslationAggregate.AddDrop", name, to:   name,
                                                                       with: { value: v(dropped) })
          end
        end

        def judge_retypes(aggregate, name)
          Array(aggregate.retypes).each do |retype|
            send_to("Translation::TranslationAggregate.AddRetype", name, to:   name,
                                                                         with: { from: v(retype.from), to: v(retype.to) })
          end
        end

        def judge_computes(aggregate, name)
          Array(aggregate.computes).each do |compute|
            send_to("Translation::TranslationAggregate.AddCompute", name, to:   name,
                                                                          with: { from: v(compute.from),
                                                                                  to:   v(compute.to),
                                                                                  sql:  v(compute.sql) })
          end
        end

        def judge_rekeys(aggregate, name)
          Array(aggregate.rekeys).each do |rekey|
            send_to("Translation::TranslationAggregate.AddRekey", name, to:   name,
                                                                        with: { sql: v(rekey.sql) })
          end
        end

        def judge_backfills(aggregate, name)
          Array(aggregate.backfills).each do |backfill|
            send_to("Translation::TranslationAggregate.AddBackfill", name, to:   name,
                                                                           with: { name:    v(backfill.name),
                                                                                   default: v(backfill.default.inspect) })
          end
        end
      end
    end
  end
end
