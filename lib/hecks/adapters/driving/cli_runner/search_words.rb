module Hecks
  module Adapters
    module Driving
      module CliRunner
        # The launcher word `search`: the commands and queries a word appears in, read from the same
        # projection the help prints (ADR 0163, step 20). Extended into `CliRunner`.
        module SearchWords
          # The answer to `search <word> [--all]`: the commands and queries a word appears in, or
          # the line saying none does.
          def search_answer(scope, argv)
            return unless argv.first == "search"

            word = argv.drop(1).find { |arg| !arg.start_with?("--") }
            return { answer: ["usage: #{scope[:program]} search <word> [--all]", ExitStatus::USAGE] } unless word

            options = search_options(scope, argv.include?("--all"))
            lines = Projector::CliProjector.search_lines(scope[:bluebook], scope[:cli][:commands],
                                                         scope[:cli][:questions], options, word)
            return { answer: ["no command or query matches #{word}", ExitStatus::REFUSED] } unless lines

            { answer: [lines.join("\n"), ExitStatus::ANSWERED] }
          end

          # The listing's options for a search: the audience the help shows, or with `--all` the
          # maintainer's audience and the internal commands too.
          def search_options(scope, all)
            return scope[:shown] unless all

            scope[:options].merge(audience(scope[:runtime], scope[:launcher], maintainer: true)).merge(all: true)
          end
        end
      end
    end
  end
end
