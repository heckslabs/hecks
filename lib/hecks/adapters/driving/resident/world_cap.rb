require "hecks/hecks/adapters/machine_profiling"

module Hecks
  module Adapters
    module Driving
      module Resident
        # The resident cap the Hecks world declares, read from the world files as text so a
        # launcher can ask before it loads anything. A raised or lowered `max_residents` takes
        # effect at once, with no resident standing to remember it.
        #
        # It uses only the standard library. It reads the `resident` line of the local world
        # (`lib/hecks/hecks/hecks.local.world`, then `hecks.local.world` at the checkout's root),
        # then of the committed `lib/hecks/hecks/hecks.world`; a comment line is skipped.
        module WorldCap
          # The world files, relative to the checkout, the first that declares a cap winning.
          FILES = %w[lib/hecks/hecks/hecks.local.world hecks.local.world lib/hecks/hecks/hecks.world].freeze
          LINE = /\A\s*resident\b.*\bmax_residents:\s*(\d+)/

          module_function

          # @param root [String] the checkout
          # @return [Integer, nil] the `max_residents` the world declares, nil when none is readable
          def for(root)
            FILES.each do |file|
              cap = declared(File.join(root, file))
              return cap if cap
            end
            nil
          end

          # @return [Integer, nil] the `residents` the machine's profile derives, nil when none
          def derived = Hecks::Adapters::MachineProfiling.of("residents")

          # @return [Integer, nil] the cap a world file's `resident` line declares
          def declared(path)
            File.foreach(path) { |line| return Regexp.last_match(1).to_i if line.match(LINE) }
            nil
          rescue SystemCallError
            nil
          end
        end
      end
    end
  end
end
