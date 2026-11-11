# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # Starts the chosen work items of a confirmed filling and says how each one ended. It reads
      # the work items, machine and launcher of the {Dispatching} that includes it.
      module Launching
        private

        def launch(plan, held)
          launcher = launcher_for(held)
          minutes = plain(held[:budget_minutes]) || Settings::BUDGET_MINUTES
          plan.chosen.each_with_index.map do |item, index|
            launched(launcher, item) do
              outcome(*launcher.attempt(item, held: holding(plan, index), minutes: minutes,
                                              limit: machine.spec_files_limit, **asked_of(item)))
            end
          end
        end

        def outcome(kind, line) = FillReport::Outcome.new(kind, line)

        # One work item's outcome. An error the launcher did not expect yields that work item
        # with the error's class and message, so the next chosen work item still launches and the
        # report still says why; a yield that fails too is named on the line.
        def launched(launcher, item)
          yield
        rescue StandardError => e
          reason = "#{e.class}: #{e.message}"
          begin
            outcome(:yielded, launcher.yield_back(item, reason))
          rescue StandardError => failure
            outcome(:stuck, "#{item.key} could not be started or yielded: #{reason} " \
                            "(yield failed: #{failure.class}: #{failure.message})")
          end
        end

        # What a brief says beyond the work item: the frozen areas, a line for each known trap its
        # area meets, and the section its architect's rethinks write.
        def asked_of(item)
          { frozen: machine.frozen, traps: LessonTraps.new(work_items.lessons).for(item.area),
            rethinks: rethinks(machine.rethink_limit).section(item.key) }
        end

        # The architect's rethinks on every work item: the PlanReview rows, or the `reviews:` a
        # stand-in names.
        def rethinks(limit)
          Rethinks.new(@standins[:reviews] || WorkItems.new(@registry).reviews, limit: limit)
        end

        # A line for each other work item, started or chosen before this one, that holds an area.
        def holding(plan, index)
          (work_items.started + plan.chosen.first(index)).reject { |other| other.area.empty? }.map { |other| held_line(other) }
        end

        def held_line(item) = "#{item.key}: #{item.title} (#{item.area.join(", ")})"
      end
    end
  end
end
