module Hecks
  module Adapters
    module Driving
      module CliRunner
        # The launcher word `completion <shell>` (ADR 0163, plan step 7): the script that completes
        # the launcher's words in that shell, written from the same listing the help prints.
        module CompletionWords
          USAGE = "completion <bash|zsh|fish>  print the script that completes the launcher in a shell".freeze

          # The answer to `completion <shell>`: the script on stdout, or the usage line when the
          # shell is missing or not one this projection writes.
          def completion_answer(scope, argv)
            return unless argv.first == "completion"

            shell = argv[1]
            script = script_for(scope, shell)
            return { answer: ["usage: #{scope[:program]} completion <#{shells_word}>", ExitStatus::USAGE] } unless script

            { answer: [script, ExitStatus::ANSWERED] }
          end

          # The script for one shell, or nil when the projection writes none for it.
          def script_for(scope, shell)
            return unless Projector::CliProjector::Completion::SHELLS.include?(shell)

            words = Projector::CliProjector.completion_words(scope[:bluebook], scope[:cli], scope[:shown])
            Projector::CliProjector.completion_script(shell, scope[:program], words)
          end

          # The shells named in the usage line.
          def shells_word
            Projector::CliProjector::Completion::SHELLS.join("|")
          end
        end
      end
    end
  end
end
