module Hecks
  module Adapters
    module Driving
      module Resident
        # The time limit of a line: a child still running `line_seconds` after its fork is ended,
        # its whole process group with it, and its caller is told why on its standard error. The
        # limit is the Hecks world's to set (`resident "Launcher", line_seconds: ...`); a world
        # that names none has the default ({Loading::DEFAULTS}), so no line runs without one.
        module LineLimit
          private

          # @return [Float, nil] seconds a line may run, nil when the world sets no limit
          def line_seconds = @settings[:line_seconds]

          # Lets go of the caller's streams, which the child now holds, except its standard error
          # when a limit is set: the resident keeps that one to say why it ended the line.
          #
          # @return [IO, nil] the caller's standard error, nil when no limit is set
          def keep_for_limit(streams)
            said = line_seconds ? streams.last : nil
            close_streams(streams - [said])
            said
          end

          # Ends the child's group once the limit has passed. The monitor ends this when the child
          # has gone first.
          def end_when_overdue(pid, said)
            return unless line_seconds

            sleep(line_seconds)
            say_ended(pid, said)
            escalate(pid)
          rescue SystemCallError, IOError
            nil
          end

          # Tells the caller why its line is being ended; a caller that has gone is not told.
          def say_ended(pid, said)
            said.write("hecks: line #{pid} ran past the resident's limit of #{line_seconds.round} seconds " \
                       "(the Hecks world's resident line_seconds) and is being ended\n")
          rescue SystemCallError, IOError
            nil
          end
        end
      end
    end
  end
end
