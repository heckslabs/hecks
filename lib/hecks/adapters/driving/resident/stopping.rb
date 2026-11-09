module Hecks
  module Adapters
    module Driving
      module Resident
        # How a resident stops the child of a line whose caller has gone, and what it stops: the
        # whole process group the child leads, so a build or a gate the line started goes with it.
        module Stopping
          # Seconds to wait before each signal to a child that does not leave: `INT` at once, then
          # `TERM` after 5 seconds and `KILL` after 10 more.
          ESCALATION = [[0, "INT"], [5, "TERM"], [10, "KILL"]].freeze

          private

          # Stops the child's whole group when the caller's end of the socket closes before the
          # line is done. The monitor ends this when the child has gone.
          def stop_when_gone(client, pid)
            client.read(1)
            ESCALATION.each do |wait, signal|
              sleep(wait)
              signal_group(signal, pid)
            end
          rescue SystemCallError, IOError
            nil
          end

          # Signals the group the child leads, else the child alone when the group is not yet made.
          def signal_group(signal, pid)
            Process.kill(signal, -pid)
          rescue Errno::ESRCH
            Process.kill(signal, pid)
          end

          # Puts a process in a group. The child does it for itself right after the fork and the
          # resident does it for the child, so the group stands whichever runs first.
          def into_group(pid, group)
            Process.setpgid(pid, group)
          rescue SystemCallError
            nil
          end
        end
      end
    end
  end
end
