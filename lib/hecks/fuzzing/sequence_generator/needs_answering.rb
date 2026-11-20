# frozen_string_literal: true

require_relative "seeded_clock"

module Hecks
  module Fuzzing
    class SequenceGenerator
      # Answers each fact a command or query `needs` that a step's drawn arguments leave out, from
      # the sequence's {SeededClock}, in the shape `Runtime::Needs.value` gives it: a bare Integer
      # for an Integer attribute, else the one-field value object. It draws nothing from `@random`.
      module NeedsAnswering
        private

        def answer_needs!(args, declaring)
          declaring.needs.map(&:to_s).each do |fact|
            next if args.key?(fact)

            args[fact] = needs_answer(declaring, fact)
          end
          args
        end

        def needs_answer(declaring, fact)
          reading = @clock.answer(fact)
          attribute = declaring.attributes.find { |held| held.name.to_s == fact }
          attribute&.type.to_s == "Integer" ? reading : { "value" => reading }
        end
      end
    end
  end
end
