require "hecks/adapters/driving/resident/paths"
require "hecks/adapters/driving/resident/baseline"

module Hecks
  module Adapters
    module Driving
      module Resident
        # A resident born under an odd environment refuses every caller that lacks it, and goes on
        # standing, since a refused caller does not count as use (ADR 0201). A launcher that sees
        # three such refusals within a minute, and finds the resident was not plain
        # ({Baseline.atypical?}), says to replace it ({Stuck}) so the line after that starts a
        # plain one. A plain resident that refuses an odd caller is working as designed and is
        # never replaced however often it refuses.
        #
        # It uses only the standard library: the client runs before anything else loads.
        module Atypical
          # Seconds within which the refusals count as one run.
          WINDOW = 60
          # How many refusals in a row, within the window, make a resident worth replacing.
          REFUSALS = 3
          # The front of a refusal on the environment, as the client words it.
          ENV_REASON = "env".freeze

          module_function

          # Notes how the resident answered this launcher, and says whether it should be replaced.
          #
          # @param root [String] the checkout
          # @param why [String, nil] why the resident did not serve the line
          # @return [Boolean] true on the third refusal on the environment within the window, from a
          #   resident that was not born plain
          def streak?(root, why)
            return note(root).size >= REFUSALS && Baseline.atypical?(root) if env?(why)

            clear(root)
            false
          end

          # @return [Boolean] whether the resident refused the line on its environment
          def env?(why) = why.to_s == ENV_REASON || why.to_s.start_with?("#{ENV_REASON}:")

          # Forgets the refusals, because the resident served or refused for another reason.
          def clear(root) = Paths.forget(Paths.envs(root))

          # Adds this refusal to the ones within the window.
          #
          # @return [Array<Float>] the times, oldest first
          def note(root)
            now = Time.now.to_f
            times = (recent(root, now) << now).last(REFUSALS)
            require "fileutils"
            FileUtils.mkdir_p(Paths.directory, mode: 0o700)
            File.write(Paths.envs(root), times.join("\n"))
            times
          rescue SystemCallError
            [now]
          end

          # @return [Array<Float>] the noted times that are still within the window
          def recent(root, now)
            noted = File.read(Paths.envs(root)).split.map { |text| Float(text) }
            noted.select { |time| now - time < WINDOW }
          rescue SystemCallError, ArgumentError
            []
          end
        end
      end
    end
  end
end
