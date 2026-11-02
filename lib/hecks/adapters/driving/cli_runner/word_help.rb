module Hecks
  module Adapters
    module Driving
      module CliRunner
        # Help for the launcher words that read their own arguments (`tour`, `search`, `completion`,
        # `resume`). A line that asks for help after the word answers the word's one-line usage
        # before the word's handler runs, so `hecks tour --help` never writes a directory named
        # `--help`. Extended into `CliRunner`.
        module WordHelp
          # The usage line of each word, declared by the word's own module.
          #
          # @return [Hash{String => String}] the word and its usage
          def word_usages
            { "tour" => TourWords::USAGE, "search" => SearchWords::USAGE,
              "completion" => CompletionWords::USAGE, "resume" => ResumeWords::USAGE }
          end

          # The answer to a line that opens with one of these words: its usage when it asks for help,
          # else the word's own handler; nil when the line opens with another word.
          def word_answer(scope, argv)
            word_help(scope, argv) || search_answer(scope, argv) || completion_answer(scope, argv) ||
              tour_answer(scope, argv) || resume(scope, argv)
          end

          # The answer to `<word> --help`, `<word> -h` or `<word> help`, or nil when the line asks
          # for no help or its first word is not one of these.
          #
          # @return [Hash, nil] `{answer: [text, status]}`
          def word_help(scope, argv)
            usage = word_usages[argv.first]
            return unless usage && argv.drop(1).intersect?(Resolution::HELP_WORDS)

            { answer: ["usage: #{scope[:program]} #{usage}", ExitStatus::ANSWERED] }
          end
        end
      end
    end
  end
end
