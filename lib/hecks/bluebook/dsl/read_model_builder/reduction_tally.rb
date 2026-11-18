module Hecks
  module Bluebook
    module DSL
      class ReadModelBuilder
        # The record of every reduction word a read model's body declared, in order, with the
        # field each named. The reductions reach the builder through `WordGate#method_missing`
        # and land in one instance variable apiece, so a second `sum` would replace the first
        # unseen; the tally keeps both, and the seal refuses the repeat by name.
        module ReductionTally
          # The words of `Behaviour::ReadModel::REDUCTION_FIELDS`, as a read model's body
          # writes them.
          REDUCTION_WORDS = Behaviour::ReadModel::REDUCTION_FIELDS.values.freeze

          private

          def method_missing(word, *args, **, &)
            tally_reduction(word.to_s, args.first) if REDUCTION_WORDS.include?(word.to_s)
            super
          end

          def respond_to_missing?(word, include_private = false) = super

          def tally_reduction(word, field)
            @reduction_words ||= []
            @reduction_words << [word, field]
          end

          # Refuses a reduction word declared more than once: a read model reports one
          # reduction, and the later declaration would replace the earlier one silently.
          def refuse_repeated_reductions!
            tally = Array(@reduction_words)
            word, = tally.find { |(name, _)| tally.count { |(other, _)| other == name } > 1 }
            return unless word

            raise Malformed,
                  "#{@name} declares #{word} twice (#{repeated_declarations(tally, word)}) — " \
                  "a read model reports one reduction; declare it once"
          end

          def repeated_declarations(tally, word)
            tally.select { |(name, _)| name == word }
                 .map { |(name, field)| field ? "#{name} #{field.inspect}" : name }
                 .join(", then ")
          end
        end
      end
    end
  end
end
