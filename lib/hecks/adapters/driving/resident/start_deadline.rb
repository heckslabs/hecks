module Hecks
  module Adapters
    module Driving
      module Resident
        # The first moments of a forked child. A child tells the resident it has begun (`S` on its
        # notes pipe) once it holds the caller's streams, directory and environment, and before it
        # loads the launcher, so a child that never says so never ran a line: it is ended, and its
        # caller boots cold instead of waiting on it. The note is written before the line starts,
        # and a child ended at the deadline is read once more after it is reaped ({started_late?}),
        # so a note written as the deadline passed still counts and no line runs twice.
        module StartDeadline
          # Seconds a child has to say it has begun, on a loaded machine too.
          START_SECONDS = 10
          # What a child writes to say it has begun.
          STARTED = "S\n".freeze
          # What the caller is told when its child never began.
          UNSTARTED = "unstarted".freeze

          private

          # Waits for the child's note and consumes it. A child that closed its pipe without one
          # has died before it began; one that is silent past the deadline is ended.
          #
          # @return [Boolean] whether the child began
          def await_start(pid, reader, seconds = START_SECONDS)
            note = begun?(reader, seconds)
            signal_group("KILL", pid) if note.nil?
            note == true
          rescue SystemCallError, IOError
            false
          end

          # Reads the pipe once more after the child is reaped, when its end is closed and nothing
          # can be written to it: a note that was written is there.
          #
          # @return [Boolean] whether the child began after all
          def started_late?(reader)
            reader.read_nonblock(STARTED.bytesize, exception: false).is_a?(String)
          rescue SystemCallError, IOError
            false
          end

          # Looks once more after the wait, so a note written as the deadline passed counts.
          #
          # @return [Boolean, nil] whether a note came; nil when the child was silent to the end
          def begun?(reader, seconds)
            return nil unless reader.wait_readable(seconds) || reader.wait_readable(0)

            reader.read_nonblock(STARTED.bytesize, exception: false).is_a?(String)
          end
        end
      end
    end
  end
end
