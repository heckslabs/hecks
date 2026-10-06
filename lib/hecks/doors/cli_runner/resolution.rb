module Hecks
  module Doors
    module CliRunner
      # Parses a command line against the projection: either the answer it gives without running
      # anything, or the command it would run.
      module Resolution
        # What one command line is parsed against: its chapter, launcher setting, projection
        # options, the projection itself and the program name.
        Line = Struct.new(:bluebook, :launcher, :options, :cli, :program)

        module_function

        # @return [Hash] `{answer: [text, status]}`, or `{spec:, name:, rest:, asking:, program:,
        #   bluebook:, launcher:}` for a command to dispatch
        def call(runtime, argv, program)
          bluebook, argv, program = chapter_for(runtime, argv, program)
          launcher = LauncherOptions.settings(runtime, bluebook.name)
          options  = LauncherOptions.projection(launcher, program)
          cli      = Projector.call(:cli, bluebook: bluebook, options: options)
          command_or_answer(Line.new(bluebook, launcher, options, cli, program), argv)
        end

        # The answer the line gives, or the command it names.
        def command_or_answer(line, argv)
          usage = usage_answer(line, argv.first)
          return { answer: usage } if usage

          asking, name, argv = entry_word(line.cli, argv)
          return { answer: [line.cli[:usage], 1] } if name.nil?

          named_command(line, asking, name, argv[1..])
        end

        # The answer for a named command or question that is unknown or asks for help, else the
        # command to dispatch.
        def named_command(line, asking, name, rest)
          spec = spec_for(line.cli, asking, name)
          return { answer: [Suggestions.unknown(line.cli, name, asking, line.program), 1] } unless spec
          return { answer: [help_for(line, name, asking), 0] } if rest.include?("--help")

          { spec: spec, name: name, rest: rest, asking: asking, program: line.program,
            bluebook: line.bluebook, launcher: line.launcher }
        end

        # The usage text a line asks for with no command, `--help` or `--all`, else nil.
        def usage_answer(line, word)
          return [line.cli[:usage], 0] if word.nil? || %w[--help -h help].include?(word)

          [all_usage(line.bluebook, line.options), 0] if word == "--all"
        end

        # The projected spec the name stands for. The alias map lets `create_pizza` and
        # `order.create_pizza` reach the same command.
        def spec_for(cli, asking, name)
          pool = asking ? cli[:questions] : cli[:commands]
          pool[cli[:names][asking ? :question : :command][name]]
        end

        # The `--help` text of one command or question.
        def help_for(line, name, asking)
          Projector.call(:cli, bluebook: line.bluebook,
                               options:  line.options.merge(command: name, ask: asking))[:usage]
        end

        # The usage with the internal commands and queries listed too, which `--all` asks for.
        def all_usage(bluebook, options)
          Projector.call(:cli, bluebook: bluebook, options: options.merge(all: true))[:usage]
        end

        # Reads the entry words of a line: whether it asks a query, the bare name, and the words
        # from the name on.
        #
        # `query` gives queries their own namespace (`ask` is its older spelling); a chapter may
        # declare a command and a query of one name. A trailing `!` says the word is a command and
        # is not part of the name. A query answers to its bare name too; `query` is needed only when
        # a command shares it.
        #
        # @return [Array(Boolean, String, Array<String>)] `asking`, `name` (nil when absent), `argv`
        def entry_word(cli, argv)
          asking = QUERY_WORDS.include?(argv.first)
          argv   = argv[1..] if asking
          name   = argv.first
          return [asking, nil, argv] if name.nil?

          bang = name.end_with?("!")
          asking ||= !bang && question_only?(cli, name.chomp("!"))
          [asking, name.chomp("!"), argv]
        end

        # Whether the name belongs to a question and to no command.
        def question_only?(cli, name)
          !cli[:names][:command].key?(name) && cli[:names][:question].key?(name)
        end

        # The chapter a command line speaks to: the booted domain's own, or, when the first word
        # names a chapter its hecksagon attaches or uses as a framework member (`deploy`,
        # `governance`), that chapter, with the word dropped and added to the program name.
        def chapter_for(runtime, argv, program)
          own      = runtime.registry.bluebooks.values.first
          attached = Array(runtime.registry.hecksagon(own.name)&.member_chapters)
          target   = attached.find { |name| Naming.snake(name) == argv.first }
          return [own, argv, program] unless target

          [runtime.registry.bluebook(target), argv[1..], "#{program} #{argv.first}"]
        end
      end
    end
  end
end
