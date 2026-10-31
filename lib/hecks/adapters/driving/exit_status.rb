module Hecks
  module Adapters
    module Driving
      # The statuses a launcher exits with, which a script branches on: `CliRunner` answers them
      # beside its text, `Hecks::CLI` returns them, and every generated launcher passes them to
      # `exit`. Three suffice: the line was answered, the domain said no, or the line could not
      # be read. A crash and a domain that cannot be opened both end as `REFUSED`, because the
      # launcher distinguishes neither from a refusal.
      module ExitStatus
        # The line ran and was answered: a usage, a command's outcome, a query's rows, a stream
        # that ended, and a port operation's refusal event, which is an answer.
        ANSWERED = 0

        # The domain said no, or the run failed: a refusal, a record that is not there, a
        # `--wait` run that ended in a failure state or whose reaction was refused or crashed, a
        # question that reports a gap under `--wait`, the door refusing the caller, or a domain
        # that cannot be opened.
        REFUSED = 1

        # The line could not be read: no command named, a command or query the bluebook does not
        # declare, a word the command does not take, a value its type cannot hold, or a flag the
        # command lacks.
        USAGE = 2

        # One line a launcher's help prints, naming the three statuses.
        HELP_LINE = "exit status: #{ANSWERED} answered, #{REFUSED} refused or failed, " \
                    "#{USAGE} a line it could not read".freeze
      end
    end
  end
end
