# frozen_string_literal: true

require_relative "headroom"
require_relative "headroom_reads"
require_relative "admission_reads"
require_relative "protection_reads"
require_relative "shared_sections"

module Hecks
  module Adapters
    class Dispatching
      # Starts the chosen work items of a confirmed filling and says how each one ended. It reads
      # the work items, machine and launcher of the {Dispatching} that includes it.
      module Launching
        include HeadroomReads
        include AdmissionReads
        include ProtectionReads

        private

        # A confirmed filling starts work, so it says why when the owner has stopped new work.
        def refuse_stopped!
          raise ConsoleCapture::Failure, "new work is stopped: dispatch_roll_forward is off" unless machine.switch_on?
        end

        # The header, the line of each launch and each wait of a confirmed filling; a filling that
        # started nothing says why in the header.
        def confirmed_lines(plan, held)
          report = FillReport.new(launch(plan, held))
          PlannedCache.clear!
          [header(plan, report.tally(plan.chosen.size) + stop_clause(plan, held))] + report.lines + waiting(plan)
        end

        # The area warnings, then each work item left waiting.
        def waiting(plan) = area_warnings(plan) + plan.skipped.map { |skip| skipped_line(skip) }

        # Why nothing started, when nothing did: a roll leaves out the planned items no one marked.
        def stop_clause(plan, held)
          unmarked = plain(held[:rolling]) == true ? work_items.planned.size - work_items.rollable.size : 0
          StopReason.new(skipped: plan.skipped, unmarked: unmarked, chosen: plan.chosen.size).clause
        end

        def launch(plan, held)
          launcher = launcher_for(held)
          minutes = plain(held[:budget_minutes]) || Settings::BUDGET_MINUTES
          plan.chosen.each_with_index.map do |item, index|
            waiting = waiting_outcome(item)
            next waiting if waiting

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
          item = plan.chosen[index]
          others = (work_items.started + plan.chosen.first(index)).reject { |other| other.area.empty? }
          others.map { |other| held_line(item, other) }
        end

        # The other work item's line, ending in a notice of each bluebook it shares by sections.
        def held_line(item, other)
          "#{other.key}: #{other.title} (#{other.area.join(", ")})#{SharedSections.notice(item.area, other.area)}"
        end
      end
    end
  end
end
