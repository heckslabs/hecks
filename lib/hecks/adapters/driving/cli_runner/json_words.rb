module Hecks
  module Adapters
    module Driving
      module CliRunner
        # The launcher's `--json` flag (ADR 0163, plan step 9): `hecks --json` and
        # `hecks <module> --json` print the listing's entries as JSON, from the same projection the
        # help prints. Extended into `CliRunner`.
        module JsonWords
          JSON_FLAG = "--json".freeze

          # The answer to a line that asks for the listing as JSON, or nil when it does not.
          #
          # @param scope [Hash] the runner's scope for the line: the bluebook, its projection, the
          #   launcher and the options the help is shown with
          # @param argv [Array<String>] the words of the line
          # @return [Hash, nil] the answer, or nil when the line does not carry the flag
          def json_answer(scope, argv)
            return unless argv.include?(JSON_FLAG)

            words = argv.reject { |word| word == JSON_FLAG }
            module_word = words.find { |word| !word.start_with?("--") }
            return { answer: [json_text(scope, module_word, words), ExitStatus::ANSWERED] } if known_or_none?(scope, module_word)

            { answer: ["usage: #{scope[:program]} [<module>] --json", ExitStatus::USAGE] }
          end

          # The JSON text for the listing, limited to the module named, if any.
          def json_text(scope, module_word, words)
            name = module_word && Projector::CliProjector.module_named(scope[:bluebook], module_word)
            options = json_options(scope, words).merge(module: name)
            Projector::CliProjector.json_listing(scope[:bluebook], scope[:cli][:commands], scope[:cli][:questions], options)
          end

          # The listing's options for JSON: the audience the help shows, or with `--all` the
          # maintainer's audience and the internal entries too.
          def json_options(scope, words)
            return scope[:shown] unless words.include?("--all")

            search_options(scope, true)
          end

          # Whether a line names no module, or a module the bluebook declares.
          def known_or_none?(scope, word)
            word.nil? || known_module?(scope, word)
          end

          # Whether a word names a module of the bluebook.
          def known_module?(scope, word)
            !Projector::CliProjector.module_named(scope[:bluebook], word).nil?
          end
        end
      end
    end
  end
end
