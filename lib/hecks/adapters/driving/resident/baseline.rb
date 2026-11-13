require "hecks/adapters/driving/resident/paths"
require "hecks/adapters/driving/resident/env_value"

module Hecks
  module Adapters
    module Driving
      module Resident
        # What a resident was born under, kept beside its socket so a launcher can tell a resident
        # that is plain from one that is not. A plain one holds only the variables every caller
        # shares; one started with others in its environment (an older resident, whose spawner's
        # environment became its own) refuses callers that lack them, and a launcher that meets
        # such a refusal over and over can replace it ({Atypical}).
        #
        # It uses only the standard library: the client runs before anything else loads.
        module Baseline
          # The variables a plain resident has set among the ones it matches a line on: where the
          # cache is, and the spec runner's switch that keeps a spec's resident writing where it
          # stands (`SpawnEnv::KEEP`).
          PLAIN = %w[HOME XDG_CACHE_HOME HECKS_CACHE_DIR HECKS_WRITES_LOCAL].freeze

          module_function

          # @param environment [Hash{String => String}] the variables the resident matches a line
          #   on, as it holds them
          # @return [Array<String>] the names set beyond what a plain resident has
          def odd(environment)
            set = environment.reject { |name, value| PLAIN.include?(name) || EnvValue.of(name, value).nil? }
            set.keys
          end

          # Writes the names, through a temp file renamed into place, so a launcher never reads
          # half a list. An empty list is a plain resident.
          #
          # @return [void]
          def write(root, names)
            file = Paths.baseline(root)
            temp = "#{file}.#{Process.pid}.tmp"
            File.write(temp, names.join(" "))
            File.rename(temp, file)
          rescue SystemCallError
            nil
          end

          # @return [Boolean] whether the checkout's resident was born under more than a plain
          #   resident has, or has not said what it was born under (an older resident)
          def atypical?(root)
            !File.read(Paths.baseline(root)).strip.empty?
          rescue SystemCallError
            true
          end
        end
      end
    end
  end
end
