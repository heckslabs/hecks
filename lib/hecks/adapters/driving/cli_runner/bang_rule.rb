module Hecks
  module Adapters
    module Driving
      module CliRunner
        # The bang rule: a line that writes says so with `!`, and a command written without it is
        # refused, naming the spelling that writes. A query is written bare, and `query` before one
        # whose name no command shares is refused, naming the bare spelling. Extended into
        # `CliRunner`.
        module BangRule
          # The word a line names as typed, before the launcher's own rewrites.
          def typed_word(argv)
            CliRunner::QUERY_WORDS.include?(argv.first) ? argv[1] : argv.first
          end

          # What a line's entry words say: `Resolution#entry_word`'s reading, the name as typed,
          # and whether the line opened with `query`.
          #
          # @param cli [Hash] the projection
          # @param argv [Array<String>] the line's words
          # @return [Hash{Symbol => Object}] `:asking`, `:word`, `:name`, `:argv` and `:queried`
          def line_words(cli, argv)
            asking, name, rest = entry_word(cli, argv)
            { asking: asking, word: typed_word(argv), name: name, argv: rest,
              queried: CliRunner::QUERY_WORDS.include?(argv.first) }
          end

          # Whether a query shares its name with a command, the one case `query` is typed.
          def shared?(scope, name, asking) = asking && scope[:cli][:names][:command].key?(name)

          # The answer a line gets before any command runs: its help, or its refusal for a
          # command written without its bang or a query written with `query` it does not need.
          def early_answer(scope, cli, line)
            return [command_help(scope, line[:name], line[:asking]), ExitStatus::ANSWERED] if line[:argv][1..].include?("--help")

            bang_less_refusal(cli, line[:asking], line[:word], line[:name], scope[:program]) ||
              query_word_refusal(cli, line, scope[:program])
          end

          # `query` before a query whose name no command shares is refused: the bare name reaches
          # it, and `query` is kept only for the name a command and a query share.
          #
          # @param line [Hash] the entry words, as `line_words` reads them
          # @return [Array(String, Integer), nil] the refusal and its usage status, or nil
          def query_word_refusal(cli, line, program)
            return nil unless line[:queried] && !cli[:names][:command].key?(line[:name])

            word = line[:word].to_s.chomp("!")
            ["#{program}: query is needed only where a command shares the name; write #{word} bare", ExitStatus::USAGE]
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
