require "fileutils"
require "hecks/adapters/driving/resident/paths"

module Hecks
  module Adapters
    module Driving
      module Resident
        # A resident that accepts callers and does not answer them costs every launcher the wait
        # before it boots on its own, for as long as it stands. A launcher that finds the resident
        # too busy twice in a row, within a minute, stops it, and the line after that starts a
        # new one. It stops only a process that is this user's and is this checkout's resident,
        # which it checks by asking the system, so a recycled process id is never signalled.
        #
        # It uses only the standard library: the launcher runs it before anything else loads.
        module Stuck
          # Seconds within which a second `busy` counts as following the first.
          STREAK = 60
          # What a resident's command line holds.
          SERVER = "resident/server.rb".freeze

          # Asks the system for a process's owner and command line.
          #
          # @return [Array(Integer, String), nil] the user id and the command line, nil when no
          #   such process stands
          LOOK = lambda do |pid|
            text = IO.popen(["ps", "-o", "uid=,command=", "-p", pid.to_s], err: File::NULL, &:read).to_s.strip
            uid, command = text.split(/\s+/, 2)
            uid ? [Integer(uid), command.to_s] : nil
          end
          # Sends a process the signal that asks it to end.
          STOP = ->(pid) { Process.kill("TERM", pid) }

          module_function

          # Notes how the resident answered this launcher, and stops it when it was too busy twice
          # in a row.
          #
          # @param root [String] the checkout
          # @param why [String, nil] why the resident did not serve the line, nil when it did not
          #   come to that
          # @param look [#call] answers `LOOK`; a spec stands in
          # @param stop [#call] answers `STOP`; a spec stands in
          # @return [Boolean] whether a resident was stopped
          def after(root, why, look: LOOK, stop: STOP)
            return retire(root, look: look, stop: stop) if why == "busy" && following?(root)

            why == "busy" ? note(root) : clear(root)
            false
          end

          # Forgets a `busy` that was noted, because the resident has answered.
          def clear(root) = FileUtils.rm_f(Paths.busy(root))

          # Notes that the resident was too busy to answer.
          def note(root)
            FileUtils.mkdir_p(Paths.directory, mode: 0o700)
            FileUtils.touch(Paths.busy(root))
          rescue SystemCallError
            nil
          end

          # @return [Boolean] whether a `busy` was noted within the last `STREAK` seconds
          def following?(root)
            Time.now - File.mtime(Paths.busy(root)) < STREAK
          rescue SystemCallError
            false
          end

          # Stops the checkout's resident when its process id file names a process of this user's
          # whose command line is this checkout's resident.
          #
          # @return [Boolean] whether it was stopped
          def retire(root, look:, stop:)
            pid = Integer(File.read(Paths.pid(root)).strip)
            return false unless ours?(look.call(pid), root)

            stop.call(pid)
            clear(root)
            true
          rescue SystemCallError, ArgumentError
            false
          end

          # @param found [Array(Integer, String), nil] a process's owner and command line
          # @return [Boolean] whether it is this user's, and is a resident for the checkout
          def ours?(found, root)
            return false unless found

            uid, command = found
            uid == Process.uid && command.include?(SERVER) && command.include?(root)
          end
        end
      end
    end
  end
end
