module Hecks
  module Adapters
    module Driving
      module Resident
        # How a launcher line met the checkout's resident, in one word the usage log keeps. The
        # client notes it in the environment before the launcher boots, and a resident's forked
        # child notes `served` itself, so whichever process runs the line can say what happened.
        #
        # It uses only the standard library: the client runs before anything else loads.
        module Outcome
          # The variable the outcome travels in.
          VARIABLE = "HECKS_RESIDENT_OUTCOME".freeze
          # The line ran in a forked child of a resident.
          SERVED = "served".freeze
          # No resident was standing; the launcher booted on its own.
          NONE = "none".freeze
          # The launcher booted on its own and started a resident for the next line.
          STARTED = "started".freeze
          # The line is one the launcher always runs itself, or the resident is switched off.
          BYPASS = "bypass".freeze
          # The cache root changes from one launcher to the next, so no resident can be found.
          UNSTABLE = "unstable".freeze
          # The front of a refusal: the resident was asked, or could have been, and did not serve.
          REFUSED = "refused:".freeze

          module_function

          # Notes the outcome for the process that goes on to run the line.
          #
          # @param value [String] one of the words above, or a {refused} word
          # @return [String] the value
          def note(value) = (ENV[VARIABLE] = value)

          # @param reason [String] why the resident did not serve: `stale`, `env`, `changed`,
          #   `script`, `busy`, `dropped`, `unsafe`, `path`, `crowded` or `protocol` (a resident
          #   of another protocol stands for the checkout, and is not asked)
          # @return [String] the outcome word for it
          def refused(reason) = "#{REFUSED}#{reason}"

          # @return [String, nil] the outcome this process was told, nil when no client ran
          def current
            value = ENV.fetch(VARIABLE, "")
            value.empty? ? nil : value[0, 64]
          end
        end
      end
    end
  end
end
