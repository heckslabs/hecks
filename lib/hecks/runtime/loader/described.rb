module Hecks
  module Runtime
    class Loader
      # What `describe` answers: the loaded declarations and nothing bound to run them.
      #
      # The declarations load the first time `registry` is asked for, not when `describe` returns,
      # so a caller that can answer from `directory` alone (a launcher with its help already
      # remembered) never pays for the load. The directory is checked at once.
      class Described
        # @return [String] the domain directory that was described
        attr_reader :directory

        # @param directory [String] the domain directory
        # @yield loads the declarations; answers the registry
        def initialize(directory, &load)
          @directory = directory
          @load = load
        end

        # @return [Registry] the declarations, loaded on first use
        def registry
          @registry ||= @load.call
        end
      end
    end
  end
end
