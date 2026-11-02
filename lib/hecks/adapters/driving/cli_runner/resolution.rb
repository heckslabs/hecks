require_relative "bang_rule"

module Hecks
  module Adapters
    module Driving
      module CliRunner
        # Parses a command line against the projection. Extended into `CliRunner`.
        module Resolution
          include BangRule

          # The words that ask for the usage.
          HELP_WORDS = ["--help", "-h", "help"].freeze

          # Parses a command line against the projection: either the answer it gives without
          # running anything, or the command it would run.
          #
          # @return [Hash] `{answer: [text, status]}`, or `{spec:, name:, rest:, asking:, program:,
          #   bluebook:, launcher:}` for a command to dispatch
          def resolve(runtime, argv, program)
            refused = Admission.refusal(runtime.registry, "Cli")
            return { answer: [refused, ExitStatus::REFUSED] } if refused

            bluebook, argv, program = bluebook_for(runtime, argv, program)
            launcher = LauncherOptions.settings(runtime, bluebook.name)
            options  = LauncherOptions.projection(launcher, program)
            shown = options.merge(audience(runtime, launcher))
            cli = Projector.call(:cli, bluebook: bluebook, options: shown)
            scope = { runtime: runtime, bluebook: bluebook, launcher: launcher, options: options,
                      shown: shown, cli: cli, program: program }
            answer_for(scope, argv) || command_plan(scope, argv)
          end

          # The answer a line gets without naming a command, or nil when it names one.
          def answer_for(scope, argv)
            json_answer(scope, argv) || usage_answer(scope, argv.first) || module_answer(scope, argv.first) ||
              word_help(scope, argv) ||
              search_answer(scope, argv) || completion_answer(scope, argv) || tour_answer(scope, argv) || resume(scope, argv)
          end

          # The answer to a line that is only a request for usage, or nil.
          def usage_answer(scope, name)
            return { answer: [scope[:cli][:usage], ExitStatus::ANSWERED] } if name.nil? || HELP_WORDS.include?(name)
            return unless %w[--all --maintainer].include?(name)

            shown = scope.values_at(:runtime, :bluebook, :launcher, :options)
            { answer: [name == "--all" ? all_usage(*shown) : maintainer_usage(*shown), ExitStatus::ANSWERED] }
          end

          # The help of the module a line is only the word of, or nil. A module groups aggregates of
          # one bluebook (ADR 0163), so `hecks deliver` lists what `deliver` holds.
          def module_answer(scope, word)
            name = Projector::CliProjector.module_named(scope[:bluebook], word)
            return unless name

            shown = scope[:shown].merge(module: name, program: scope[:program])
            { answer: [Projector.call(:cli, bluebook: scope[:bluebook], options: shown)[:usage], ExitStatus::ANSWERED] }
          end

          # The command a line names, or the answer when it names none or asks for its help. A
          # line that names nothing, or something the bluebook does not declare, could not be read.
          def command_plan(scope, argv)
            cli = scope[:cli]
            word = typed_word(argv)
            asking, name, argv = entry_word(cli, argv)
            return { answer: [cli[:usage], ExitStatus::USAGE] } if name.nil?

            spec = find_spec(cli, asking, name)
            return { answer: [unknown(cli, name, asking, scope[:program]), ExitStatus::USAGE] } unless spec

            answer = early_answer(scope, cli, { asking: asking, word: word, name: name, argv: argv })
            return { answer: answer } if answer

            { spec: spec, name: name, rest: argv[1..], asking: asking, program: scope[:program],
              bluebook: scope[:bluebook], launcher: scope[:launcher] }
          end

          # The spec a name reaches; the alias map lets `create_pizza` and `order.create_pizza`
          # reach the same command.
          def find_spec(cli, asking, name)
            pool = asking ? cli[:questions] : cli[:commands]
            pool[cli[:names][asking ? :question : :command][name]]
          end

          # The usage of one command or question, which its `--help` asks for.
          def command_help(scope, name, asking)
            options = scope[:options].merge(command: name, ask: asking)
            Projector.call(:cli, bluebook: scope[:bluebook], options: options)[:usage]
          end

          # The usage with the internal commands and queries listed too, which `--all` asks for, and
          # with the maintainer's too.
          def all_usage(runtime, bluebook, launcher, options)
            shown = options.merge(audience(runtime, launcher, maintainer: true))
            Projector.call(:cli, bluebook: bluebook, options: shown.merge(all: true))[:usage]
          end

          # The usage a maintainer of the hecks checkout sees, which `--maintainer` asks for
          # anywhere.
          def maintainer_usage(runtime, bluebook, launcher, options)
            shown = options.merge(audience(runtime, launcher, maintainer: true))
            Projector.call(:cli, bluebook: bluebook, options: shown)[:usage]
          end

          # What the help leaves out and points at for whoever typed the line: the maintainer's
          # aggregates only in a hecks checkout, and the bluebooks the bluebook's launcher names,
          # each
          # with the first sentence of what it is for.
          #
          # @return [Hash{Symbol => Object}] `:hide` and `:bluebooks` (pairs of word and summary)
          def audience(runtime, launcher, maintainer: LauncherOptions.maintainer?,
                       newcomer: !maintainer && Newcomer.applies?)
            shown = (newcomer && Newcomer.audience(launcher)) || LauncherOptions.audience(launcher, maintainer)
            return shown unless shown[:declarations]

            shown.merge(declarations: bluebook_summaries(runtime, shown[:declarations]))
          end

          # Each named bluebook the domain attaches, as its word and the first sentence of its
          # vision.
          def bluebook_summaries(runtime, names)
            known = attached_bluebooks(runtime)
            names.filter_map do |name|
              next unless known.include?(name)

              [Naming.snake(name), Projector::CliProjector.first_sentence(runtime.bluebook(name).vision)]
            end
          end

          # Names who the help is for, so the help remembered for one is not given to the other.
          def audience_key
            return "maintainer" if LauncherOptions.maintainer?

            Newcomer.applies? ? "newcomer" : "project"
          end

          # Reads the entry words of a line: whether it asks a query, the bare name, and the words
          # from the name on.
          #
          # `query` gives queries their own namespace (`ask` is its older spelling); a bluebook may
          # declare a command and a query of one name. A trailing `!` says the word is a command and
          # is not part of the name. A query answers to its bare name too; `query` is needed only
          # when a command shares it. The name may be written in the bluebook's verb form
          # (`Hecks::SendTrain.board!`), which reaches the same command (see `VerbNames`).
          #
          # @return [Array(Boolean, String, Array<String>)] `asking`, `name` (nil when absent),
          #   `argv`
          def entry_word(cli, argv)
            asking = CliRunner::QUERY_WORDS.include?(argv.first)
            argv   = argv[1..] if asking
            name   = argv.first
            return [asking, nil, argv] if name.nil?

            bang  = name.end_with?("!")
            typed = name.chomp("!")
            name  = canonical_name(cli, typed)
            note_former_name(cli, typed, name)
            argv = renamed_line(cli, typed, name, argv)
            [asking || (!bang && query_only?(cli, name)), name, argv]
          end

          # Whether the name belongs to a query and to no command.
          def query_only?(cli, name)
            !cli[:names][:command].key?(name) && cli[:names][:question].key?(name)
          end

          # The bluebook a command line speaks to: the booted domain's own, or, when the first word
          # names a bluebook its hecksagon attaches or uses as a framework member (`deploy`,
          # `governance`), that bluebook, with the word dropped and added to the program name.
          def bluebook_for(runtime, argv, program)
            own    = runtime.first_bluebook
            target = attached_bluebooks(runtime).find { |name| Naming.snake(name) == argv.first }
            return [own, argv, program] unless target

            [runtime.bluebook(target), argv[1..], "#{program} #{argv.first}"]
          end

          # The bluebooks the booted domain's hecksagon attaches or uses as framework members.
          def attached_bluebooks(runtime)
            own = runtime.first_bluebook
            Array(runtime.hecksagon(own.name)&.member_bluebooks)
          end
        end
      end
    end
  end
end
