module Hecks
  module Adapters
    module Driving
      module Resident
        # The scheduling a resident runs under on macOS. A launchd beat (`ProcessType Background`)
        # puts its launcher in Darwin's background band, which confines a process to the efficiency
        # cores and throttles its disk, and a resident that launcher starts inherits the band. Every
        # line of the checkout is served by the resident, so it leaves the band when it starts,
        # whoever started it, and the line children it forks inherit the default band from it.
        #
        # It cannot lower its `nice`: an unprivileged process may only raise it, so a resident
        # keeps its starter's increment. It uses only the standard library.
        module Foreground
          # `PRIO_DARWIN_PROCESS` from `<sys/resource.h>`: the `which` that reads and sets the
          # background band of a whole process. Ruby does not define the constant on every build.
          DARWIN_PROCESS = 4
          # The value of the band that is not background.
          DEFAULT = 0

          module_function

          # Takes this process out of Darwin's background band; anywhere else it does nothing.
          #
          # @param platform [String] the platform Ruby runs on; a spec stands in for another
          # @return [Boolean] whether the band was set
          def apply(platform: RUBY_PLATFORM)
            return false unless platform.include?("darwin")

            Process.setpriority(DARWIN_PROCESS, 0, DEFAULT)
            true
          rescue SystemCallError
            false
          end

          # @param platform [String] the platform Ruby runs on; a spec stands in for another
          # @return [Boolean] whether this process is in Darwin's background band
          def background?(platform: RUBY_PLATFORM)
            return false unless platform.include?("darwin")

            Process.getpriority(DARWIN_PROCESS, 0) != DEFAULT
          rescue SystemCallError
            false
          end
        end
      end
    end
  end
end
