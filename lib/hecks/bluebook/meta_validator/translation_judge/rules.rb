module Hecks
  module Bluebook
    module MetaValidator
      class TranslationJudge
        # Offers each rule collection of one translated aggregate: renames, moves, converts,
        # drops, retypes, derives, rekeys and backfills.
        module Rules
          private

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

          def judge_derives(aggregate, name)
            Array(aggregate.derives).each do |derive|
              fields = { to: v(derive.to), expression: v(derive.expression) }
              send_to("Translation::TranslationAggregate.AddDerive", name, to: name, with: fields)
            end
          end

          def judge_rekeys(aggregate, name)
            aggregate.rekeys.each do |rekey|
              send_to("Translation::TranslationAggregate.AddRekeyTo", name, to: name, with: { to: v(rekey.to) })
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
end
