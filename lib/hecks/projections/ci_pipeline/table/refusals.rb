# frozen_string_literal: true

module Hecks
  module Projections
    module CiPipeline
      class Table
        # The refusals a row earns from the chapter's closed sets and from what its job declares,
        # each naming the row and listing what is valid. Mixed into `Rows`, which holds the
        # vocabulary in `@vocabulary` and the problems in `@problems`.
        module Refusals
          private

          def refuse_event(row)
            events = @vocabulary.fetch(:trigger)
            return if events.include?(row[:event])

            problem(row, "has event #{row[:event].inspect}; an event is one of #{events.join(", ")}")
          end

          def refuse_unknown_need(row)
            names = workflow_of(row).jobs.map(&:name)
            return if names.include?(row[:needs])

            problem(row, "names job #{row[:needs].inspect}, which workflow #{row[:workflow]} does not declare; " \
                         "its jobs are #{names.join(", ")}")
          end

          # A step uses an action or runs a command, and an action is one the chapter admits.
          def refuse_uses(row)
            uses = row[:uses]
            refuse_both(row) unless uses.empty? || row[:run].empty?
            refuse_neither(row) if uses.empty? && row[:run].empty?
            refuse_action(row) unless uses.empty?
          end

          def refuse_both(row)
            problem(row, "has both uses and run; a step uses an action or runs a command, not both")
          end

          def refuse_neither(row)
            problem(row, "has neither uses nor run; a step uses an action or runs a command")
          end

          def refuse_action(row)
            actions = @vocabulary.fetch(:uses)
            return if actions.include?(row[:uses])

            problem(row, "has uses #{row[:uses].inspect}; uses is one of #{actions.join(", ")}")
          end

          def refuse_input_of_command(row)
            problem(row, "names a step that runs a command; only a step that uses an action takes inputs")
          end
        end
      end
    end
  end
end
