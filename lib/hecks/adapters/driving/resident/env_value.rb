module Hecks
  module Adapters
    module Driving
      module Resident
        # What a variable's value comes to for the comparison of a line's environment with the one
        # the resident loaded under. Nearly all values count as they are. The exception is the
        # library path (`RUBYLIB`): the rbenv shim puts its own gem-rehash hook directory on it for
        # every Ruby it starts, so every launcher carries it and a resident started without the
        # shim does not. That entry says nothing about what the code loads, so it is left out; a
        # path of the caller's own still counts.
        #
        # It uses only the standard library: the client runs before anything else loads.
        module EnvValue
          # The variable whose value is cleaned.
          LIBRARY_PATH = "RUBYLIB".freeze
          # The entries a Ruby version manager adds for its own hooks.
          MANAGER = %r{/rbenv\.d/}

          module_function

          # @param name [String] the variable
          # @param value [String, nil] its value, nil when it is not set
          # @return [String, nil] the value to compare: the library path without the manager's
          #   entries (nil when nothing else is on it), any other value as it is
          def of(name, value)
            return value unless name == LIBRARY_PATH && value

            kept = value.split(":").reject { |entry| entry.empty? || entry.match?(MANAGER) }
            kept.empty? ? nil : kept.join(":")
          end
        end
      end
    end
  end
end
