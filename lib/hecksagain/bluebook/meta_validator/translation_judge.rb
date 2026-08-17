module Hecksagain
  module Bluebook
    module MetaValidator
      # Offers a built translation (a `translations/*.bluebook` edge,
      # `Hecks.data_translation`'s own real, established file convention —
      # there is no separate `.translation` extension) to the language
      # that describes translations.
      #
      # A sibling of a bluebook again, the same shape PortJudge/
      # AdapterJudge already are — its own file, its own door, judged
      # through its own self-hosted language (translation.bluebook)
      # rather than left as plain Ruby structs nothing checks. Walks the
      # WHOLE built translation in one pass — the top-level Declare/
      # Retire commands, then every nested aggregate's own Declare plus
      # one Add* command per rule it carries — the same "one judge, every
      # nested record" shape WorldJudge already gives Wiring. Field names
      # throughout read lib/hecksagain/bluebook/translation.rb's own real
      # struct/class definitions directly, not the DSL builder's own
      # local parameter names (`move(old_path, to:)`'s `old_path` reads
      # back as the struct's own `from`). Whole-project table-
      # unification survey, item #13's remaining builders.
      class TranslationJudge
        attr_reader :refusals

        def initialize(translation)
          @translation = translation
          @refusals    = []
          @runtime     = MetaValidator.fresh_runtime
          judge!
        end

        private

        def v(text) = text.nil? ? nil : { value: text.to_s }

        def args(pairs) = pairs.compact

        # `Runtime::AlreadyExists` is rescued HERE but not by World/Port/
        # Adapter's own sibling judges — found live, not by inspection.
        # Those three each judge a SINGLE aggregate per build (Port/Adapter)
        # or a Hash keyed by verb (World's own settings, deduped by
        # construction), so a duplicate-identity Declare can never reach
        # their own runtime. `TranslationBuilder#aggregate` appends every
        # block to a plain Array (`@aggregates << builder.build`) with no
        # dedup — two `aggregate "Account" do ... end` blocks in the same
        # translation are syntactically legal and reach here for real. Left
        # unrescued, the second Declare's `AlreadyExists` crashed straight
        # through `call_translation` instead of becoming a clean refusal —
        # confirmed via direct dispatch before this fix.
        def offer(label)
          yield
        rescue Runtime::GivenNotMet, Runtime::InvariantViolation, Runtime::TypeMismatch,
               Runtime::NotFound, Runtime::AlreadyExists => e
          @refusals << "#{label}: #{e.message}"
        rescue Runtime::UnknownVerb
          nil
        end

        def send_to(verb, label, **payload)
          offer(label) { @runtime.dispatch(verb, **args(payload)) }
        end

        def judge!
          t = @translation
          send_to("Translation::Translation.Declare", t.domain, domain: v(t.domain), from: v(t.from), to: v(t.to))

          # `id:`, computed the SAME way — `Naming.identity([domain, from,
          # to])` — Translation's own identity is COMPOSITE
          # (`identified_by :domain, :from, :to`), the same reason
          # `Wiring.Set`'s own self-reference dispatch (world.bluebook,
          # `WorldJudge#judge_wiring`) needs a computed `id:` rather than
          # a bare field value — a single-field identity (TranslationAggregate's
          # own `name`) is the ONE case where the bare value itself IS the
          # id, confirmed live via direct dispatch testing, not assumed.
          translation_id = Naming.identity([t.domain, t.from, t.to])
          Array(t.retired).each do |name|
            send_to("Translation::Translation.Retire", t.domain, id: translation_id, value: v(name))
          end

          Array(t.aggregates).each { |aggregate| judge_aggregate(aggregate) }
        end

        def judge_aggregate(aggregate)
          name = aggregate.name
          send_to("Translation::TranslationAggregate.Declare", name, name: v(name), was: v(aggregate.was))

          Hash(aggregate.renames).each do |from, to|
            send_to("Translation::TranslationAggregate.AddRename", name, name: name, from: v(from), to: v(to))
          end

          Array(aggregate.moves).each do |move|
            send_to("Translation::TranslationAggregate.AddMove", name, name: name, from: v(move.from), to: v(move.to))
          end

          Array(aggregate.converts).each do |convert|
            send_to("Translation::TranslationAggregate.AddConvert", name, name: name, from: v(convert.from),
                    to: v(convert.to), values: v(convert.values.inspect))
          end

          Array(aggregate.drops).each do |dropped|
            send_to("Translation::TranslationAggregate.AddDrop", name, name: name, value: v(dropped))
          end

          Array(aggregate.retypes).each do |retype|
            send_to("Translation::TranslationAggregate.AddRetype", name, name: name, from: v(retype.from), to: v(retype.to))
          end

          Array(aggregate.computes).each do |compute|
            send_to("Translation::TranslationAggregate.AddCompute", name, name: name, from: v(compute.from),
                    to: v(compute.to), sql: v(compute.sql))
          end

          Array(aggregate.rekeys).each do |rekey|
            send_to("Translation::TranslationAggregate.AddRekey", name, name: name, sql: v(rekey.sql))
          end

          Array(aggregate.backfills).each do |backfill|
            send_to("Translation::TranslationAggregate.AddBackfill", name, aggregate: name, name: v(backfill.name),
                    default: v(backfill.default.inspect))
          end
        end
      end
    end
  end
end
