# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      module InForce
        # The state and the plain words for each setting that another switch can silence. A rule
        # takes the reading and answers `[state, why]`; a setting with no rule is in force.
        module Rules
          IN_FORCE = "in_force"
          STANDING_BY = "standing_by"
          WITHOUT = "without_effect"
          SIGNAL = "Signalbox's pressure signal is current, so Signalbox's mark governs"
          ADMITTED = "admission.signalbox is on, so Signalbox admits by headroom"
          UNVERIFIED = "main_verification.verifies is off, so no verification runs on this machine"

          module_function

          # @param setting [String] a setting name
          # @param reading [Hash] {InForce.reading}
          # @return [Hash] `state` (in_force, standing_by or without_effect) and `why`
          def for(setting, reading)
            rule = RULES[setting]
            state, why = rule&.call(reading)
            { state: state || IN_FORCE, why: why || Switches.word(setting, reading) || "Read at every start." }
          end

          def on?(reading, verb, key) = reading[:row].call(verb)[key] == true

          def admitted?(reading) = on?(reading, "admission", :signalbox)

          def unverified?(reading) = reading[:row].call("main_verification")[:verifies].to_s == "off"

          def load_line(reading)
            return [WITHOUT, "#{SIGNAL} (its short mark)."] if reading[:signal]

            [IN_FORCE, "A start waits above this load. #{Switches.dark(reading)}"]
          end

          def cap_line(reading)
            return [WITHOUT, "#{ADMITTED}."] if admitted?(reading)
            return [WITHOUT, "The moving cap stands (#{reading[:moving][:current]}), so this cap is unused."] if reading[:moving]

            [IN_FORCE, "The most Work items started at once."]
          end

          def bound_line(reading)
            return [WITHOUT, "#{ADMITTED}."] if admitted?(reading)
            return [STANDING_BY, "Stands by for work_cap.moves; the cap is fixed now."] unless reading[:moving]

            [IN_FORCE, "A bound on the moving cap."]
          end

          def reserve_line(reading)
            admitted?(reading) ? [WITHOUT, "#{ADMITTED}."] : [IN_FORCE, "Red items may start past a full cap."]
          end

          def shed_line(reading)
            return [IN_FORCE, "Still drives shedding. The fill pause it sets is discarded: #{SIGNAL}."] if reading[:signal]

            [IN_FORCE, "Drives shedding and the fill pause."]
          end

          def heavy_line(reading)
            return [IN_FORCE, "Only an upper bound: #{SIGNAL}, and the places follow the gates it fits."] if reading[:signal]

            [IN_FORCE, "The heavy jobs at once."]
          end

          def verify_line(reading)
            unverified?(reading) ? [WITHOUT, "#{UNVERIFIED}."] : [IN_FORCE, "Set on each verification run."]
          end

          RULES = {
            "dispatch_max_load.limit" => method(:load_line), "work_limit.cap" => method(:cap_line),
            "work_cap.least" => method(:bound_line), "work_cap.most" => method(:bound_line),
            "work_limit.urgent_reserve" => method(:reserve_line),
            "machine_marks.load_high" => method(:shed_line), "machine_marks.load_low" => method(:shed_line),
            "heavy_jobs.cap" => method(:heavy_line),
            "main_verification.workers" => method(:verify_line), "main_verification.nice" => method(:verify_line)
          }.freeze
        end
      end
    end
  end
end
