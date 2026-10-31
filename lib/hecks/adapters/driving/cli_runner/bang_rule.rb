module Hecks
  module Adapters
    module Driving
      module CliRunner
        # The bang rule: a line that writes says so with `!`, and a command written without it is
        # refused, naming the spelling that writes. Extended into `CliRunner`.
        module BangRule
          # The word a line names as typed, before the launcher's own rewrites.
          def typed_word(argv)
            CliRunner::QUERY_WORDS.include?(argv.first) ? argv[1] : argv.first
          end

          # The answer a line gets before any command runs: its help, or its refusal for a
          # command written without its bang.
          def early_answer(scope, cli, line)
            return [command_help(scope, line[:name], line[:asking]), ExitStatus::ANSWERED] if line[:argv][1..].include?("--help")

            bang_less_refusal(cli, line[:asking], line[:word], line[:name], scope[:program])
          end

          # A command written without its `!` is refused. A query, and a name that is not a
          # command, pass.
          #
          # @return [Array(String, Integer), nil] the refusal and its usage status, or nil
          def bang_less_refusal(cli, asking, word, name, program)
            return nil if asking || word.nil? || word.end_with?("!")
            return nil unless cli[:names][:command].key?(name)

            ["#{program}: #{word} is a command and writes; write it as #{word}!", ExitStatus::USAGE]
          end
        end
      end
    end
  end
end
