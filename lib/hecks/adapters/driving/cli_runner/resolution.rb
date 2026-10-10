module Hecks
  module Adapters
    module Driving
      module CliRunner
        # Parses a command line against the projection. Extended into `CliRunner`.
        module Resolution
          # The words that ask for the usage.
          HELP_WORDS = ["--help", "-h", "help"].freeze

          # Parses a command line against the projection: either the answer it gives without
          # running anything, or the command it would run.
          #
          # @return [Hash] `{answer: [text, status]}`, or `{spec:, name:, rest:, asking:, program:,
          #   bluebook:, launcher:}` for a command to dispatch
          def resolve(runtime, argv, program)
            bluebook, argv, program = chapter_for(runtime, argv, program)
            launcher = LauncherOptions.settings(runtime, bluebook.name)
            options  = LauncherOptions.projection(launcher, program)
            cli = Projector.call(:cli, bluebook: bluebook, options: options.merge(audience(runtime, launcher)))
            scope = { runtime: runtime, bluebook: bluebook, launcher: launcher, options: options,
                      cli: cli, program: program }
            usage_answer(scope, argv.first) || command_plan(scope, argv)
          end

          # The answer to a line that is only a request for usage, or nil.
          def usage_answer(scope, name)
            return { answer: [scope[:cli][:usage], 0] } if name.nil? || HELP_WORDS.include?(name)
            return { answer: [all_usage(*scope.values_at(:runtime, :bluebook, :launcher, :options)), 0] } if name == "--all"
            return unless name == "--maintainer"

            { answer: [maintainer_usage(*scope.values_at(:runtime, :bluebook, :launcher, :options)), 0] }
          end

          # The command a line names, or the answer when it names none or asks for its help.
          def command_plan(scope, argv)
            cli = scope[:cli]
            asking, name, argv = entry_word(cli, argv)
            return { answer: [cli[:usage], 1] } if name.nil?

            spec = find_spec(cli, asking, name)
            return { answer: [unknown(cli, name, asking, scope[:program]), 1] } unless spec

            rest = argv[1..]
            return { answer: [command_help(scope, name, asking), 0] } if rest.include?("--help")

            { spec: spec, name: name, rest: rest, asking: asking, program: scope[:program],
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
          # aggregates only in a hecks checkout, and the chapters the chapter's launcher names, each
          # with the first sentence of what it is for.
          #
          # @return [Hash{Symbol => Object}] `:hide` and `:chapters` (pairs of word and summary)
          def audience(runtime, launcher, maintainer: LauncherOptions.maintainer?)
            shown = LauncherOptions.audience(launcher, maintainer)
            return shown unless shown[:chapters]

            shown.merge(chapters: chapter_summaries(runtime, shown[:chapters]))
          end

          # Each named chapter the domain attaches, as its word and the first sentence of its
          # vision.
          def chapter_summaries(runtime, names)
            known = attached_chapters(runtime)
            names.filter_map do |name|
              next unless known.include?(name)

              [Naming.snake(name), Projector::CliProjector.first_sentence(runtime.registry.bluebook(name).vision)]
            end
          end

          # Names who the help is for, so the help remembered for one is not given to the other.
          def audience_key
            LauncherOptions.maintainer? ? "maintainer" : "project"
          end

          # Reads the entry words of a line: whether it asks a query, the bare name, and the words
          # from the name on.
          #
          # `query` gives queries their own namespace (`ask` is its older spelling); a chapter may
          # declare a command and a query of one name. A trailing `!` says the word is a command and
          # is not part of the name. A query answers to its bare name too; `query` is needed only
          # when
          # a command shares it.
          #
          # @return [Array(Boolean, String, Array<String>)] `asking`, `name` (nil when absent),
          #   `argv`
          def entry_word(cli, argv)
            asking = CliRunner::QUERY_WORDS.include?(argv.first)
            argv   = argv[1..] if asking
            name   = argv.first
            return [asking, nil, argv] if name.nil?

            bang = name.end_with?("!")
            name = name.chomp("!")
            [asking || (!bang && query_only?(cli, name)), name, argv]
          end

          # Whether the name belongs to a query and to no command.
          def query_only?(cli, name)
            !cli[:names][:command].key?(name) && cli[:names][:question].key?(name)
          end

          # The chapter a command line speaks to: the booted domain's own, or, when the first word
          # names a chapter its hecksagon attaches or uses as a framework member (`deploy`,
          # `governance`), that chapter, with the word dropped and added to the program name.
          def chapter_for(runtime, argv, program)
            own    = runtime.registry.bluebooks.values.first
            target = attached_chapters(runtime).find { |name| Naming.snake(name) == argv.first }
            return [own, argv, program] unless target

            [runtime.registry.bluebook(target), argv[1..], "#{program} #{argv.first}"]
          end

          # The chapters the booted domain's hecksagon attaches or uses as framework members.
          def attached_chapters(runtime)
            own = runtime.registry.bluebooks.values.first
            Array(runtime.registry.hecksagon(own.name)&.member_chapters)
          end
        end
      end
    end
  end
end
