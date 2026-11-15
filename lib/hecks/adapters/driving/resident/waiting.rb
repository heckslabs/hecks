require "hecks/adapters/driving/resident/wire"

module Hecks
  module Adapters
    module Driving
      module Resident
        # How a launcher waits for the status of a line the resident is running. A line may be
        # silent for as long as it likes (a gate is), so the wait has no time limit while the
        # resident's process stands; it ends when the socket closes, or when the process is gone
        # though a child that inherited the socket holds it open.
        #
        # It uses only the standard library: the launcher runs it before anything else loads.
        module Waiting
          # Seconds between looks at whether the resident is still there.
          SLICE = 1
          # Seconds a status line has to arrive whole once its first byte has.
          WHOLE = 3

          module_function

          # @param socket [IO] the caller's end of the resident's socket
          # @param pid [Integer, nil] the resident's process id; nil when the system does not say,
          #   and then only a closed socket ends the wait
          # @return [String, nil] the status line, nil when the resident has gone
          # @raise [Wire::Refused] when the line is malformed
          def status(socket, pid)
            loop do
              return Wire.read_line(socket, WHOLE) if socket.wait_readable(SLICE)
              return nil unless alive?(pid)
            end
          rescue EOFError, Wire::Slow
            nil
          end

          # @return [Boolean] whether the process stands. Only `ESRCH` says it is gone: a process
          #   of another user answers `EPERM`. A recycled id reads as standing, which fails safe,
          #   since the wait then goes on.
          def alive?(pid)
            return true unless pid

            Process.kill(0, pid)
            true
          rescue Errno::ESRCH
            false
          rescue SystemCallError
            true
          end
        end
      end
    end
  end
end
