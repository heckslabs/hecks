# frozen_string_literal: true

module Hecks
  module Adapters
    module PipelineBoard
      # Signalbox's marks as its world declares them, read only: each with its present value, the
      # group of the page it sits in and, where one exists, the Tickets setting that means the
      # same idea, so two numbers for one idea are seen side by side.
      module SignalboxMarks
        PUSHED = "How hard the machine is pushed"
        WORK = "How much work runs"

        # Each Signalbox mark that has a twin among the Tickets settings, and that twin.
        BESIDE = {
          "load_short_percent" => "dispatch_max_load.limit", "target_mb" => "machine_marks.free_gb_recovered",
          "floor_mb" => "machine_marks.free_gb_low", "shedding_min_coders" => "load_shed.min_coders"
        }.freeze

        # The verbs of the Signalbox world the page lists, with the group each sits in.
        VERBS = {
          "pressure" => PUSHED, "draws" => WORK, "fuses" => WORK, "ramp" => WORK, "helper_share" => WORK,
          "seats" => WORK, "breakers" => WORK, "reaping" => WORK
        }.freeze

        module_function

        # @param registry [Runtime::Registry, nil] whose Signalbox world is read
        # @param cores [Integer, nil] the performance cores the posted signal was read against
        # @return [Array<Hash>] each mark: `group`, `verb`, `name`, `value`, `unit`, and `beside`
        #   (the Tickets `setting` and, for a load mark, the load it stands for) or nil
        def of(registry, cores: nil)
          world = registry&.world("Signalbox")
          VERBS.flat_map do |verb, group|
            row(world, verb).map { |name, value| mark(group, verb, name.to_s, value, cores) }
          end
        end

        def row(world, verb)
          found = world&.for_verb(verb)
          found.is_a?(Hash) ? found : {}
        end

        def mark(group, verb, name, value, cores)
          setting = BESIDE[name]
          { group: group, verb: verb, name: name, value: value, unit: unit(name),
            beside: setting && { setting: setting, load: load_of(name, value, cores) } }
        end

        def unit(name) = name.split("_").last.then { |tail| %w[mb percent minutes seconds].include?(tail) ? tail : nil }

        # A load mark is percent of the performance cores: 342 percent of 6 is a load of 20.52.
        def load_of(name, value, cores)
          return unless name.start_with?("load_") && cores.to_i.positive?

          (value.to_f * cores.to_i / 100).round(2)
        end
      end
    end
  end
end
