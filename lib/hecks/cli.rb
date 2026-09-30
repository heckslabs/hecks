module Hecks
  # The `hecks` command an installed gem puts on the path: one router over the
  # domain-operator tools, each also runnable from a checkout as `bin/<name>`.
  #
  # Every subcommand's logic lives under `cli/`, with `bin/<name>` a thin wrapper
  # over the same entry point, so the two can't drift apart.
  #
  # See `docs/decisions/0066-the-gem-ships-a-hecks-executable-and-dev-tooling-stays-in-the-repo.md`.
  module CLI
    # One subcommand: a one-line summary, its usage line, the file that holds it and the
    # call that runs it (given the argv after the name, its program name and its own name).
    Command = Struct.new(:summary, :usage, :file, :run)

    # Every subcommand, in the order the help lists them.
    COMMANDS = {
      "run"              => Command.new(
        "Dispatch a verb, or run a JSON step list, against a domain.",
        "hecks run [domain] <verb [name=value …] | script.json | - | '{\"steps\":[…]}'>",
        "cli/run",
        ->(argv, program, _name) { Run.call(argv, program: program) }
      ),
      "docs"             => Command.new(
        "Print a domain's usage document, projected from its bluebook.",
        "hecks docs [domain-path] [aggregate]",
        "cli/document",
        ->(argv, program, name) { Document.call(argv, projection: name.to_sym, program: program, root: Dir.pwd) }
      ),
      "narrate"          => Command.new(
        "Print a domain read back in English, projected from its bluebook.",
        "hecks narrate [domain-path] [aggregate]",
        "cli/document",
        ->(argv, program, name) { Document.call(argv, projection: name.to_sym, program: program, root: Dir.pwd) }
      ),
      "ir"               => Command.new(
        "Print a booted domain's IR as JSON.",
        "hecks ir <domain> [--translations] | hecks ir --meta",
        "cli/ir",
        ->(argv, program, _name) { Ir.call(argv, program: program) }
      ),
      "stores"           => Command.new(
        "Print every aggregate's current records as JSON.",
        "hecks stores <domain>",
        "cli/stores",
        ->(argv, program, _name) { Stores.call(argv, program: program) }
      ),
      "model_check"      => Command.new(
        "Statically check a domain's IR for dead states and unreachable steps.",
        "hecks model_check [--strict] [--profile client] <domain> [<domain> …]",
        "cli/model_check",
        ->(argv, program, _name) { ModelCheck.call(argv, program: program, root: checkout_root) }
      ),
      "smoke_test"       => Command.new(
        "Boot a domain and dispatch every declared command and report once.",
        "hecks smoke_test [domain]",
        "cli/smoke_test",
        ->(argv, _program, _name) { SmokeTest.call(argv, root: Dir.pwd) }
      ),
      "project_diagrams" => Command.new(
        "Write a domain's Mermaid diagrams under ./docs/generated/diagrams/ (positional form only).",
        "hecks project_diagrams <domain-path> <ChapterName>  (writes) | " \
        "hecks project_diagrams domain=<path> chapter=<Name>  (prints; writes nothing)",
        "cli/project_diagrams",
        ->(argv, program, _name) { ProjectDiagrams.call(argv, program: program, root: Dir.pwd) }
      ),
      "project_cli"      => Command.new(
        "Write a command-line launcher beside each domain, named after its bluebook.",
        "hecks project_cli [domain-path …]",
        "cli/project_cli",
        ->(argv, program, _name) { ProjectCli.call(argv, program: program, root: Dir.pwd, remove_stale_bin: false) }
      ),
      "mcp"              => Command.new(
        "Serve the MCP door over stdio (no authentication; stdio only).",
        "hecks mcp [--stdio]",
        "cli/mcp",
        ->(argv, _program, _name) { Mcp.call(argv) }
      )
    }.freeze

    HELP_FLAGS = ["--help", "-h"].freeze

    # The launcher's flags that mean the same for every subcommand here: `--wait` (a subcommand
    # exits with its own verdict, so waiting changes nothing) and `--confirm` (nothing here asks
    # for one). Each may carry a Boolean word, as at the launcher.
    GENERIC_FLAGS = ["--wait", "--confirm"].freeze

    # A launcher word: `name=value`, where the name has no path characters.
    NAME_VALUE = /\A[A-Za-z_][\w-]*=/

    # The launcher's `name=value` spellings of a subcommand's positional arguments.
    #
    # `slots` lists, in positional order, the names that fill each place (`domain` before
    # `aggregate`); `many` lets the first slot repeat and take a comma list; `exists` makes
    # the first slot's values paths that must exist; `flags` and `options` are `--name`
    # switches and `--name value` pairs; `ignored` names a launcher argument this form has no
    # use for. A subcommand absent here (`run`, whose pairs are the verb's own, `mcp`, and
    # `project_diagrams`, whose launcher form answers instead of writing) keeps its words.
    LAUNCHER_FORMS = {
      "docs"        => { slots: [%w[domain], %w[aggregate]], exists: true },
      "narrate"     => { slots: [%w[domain], %w[aggregate]], exists: true },
      "ir"          => { slots: [%w[domain]], flags: %w[translations meta], exists: true },
      "stores"      => { slots: [%w[domain]], exists: true },
      "model_check" => { slots: [%w[domains domain]], many: true, flags: %w[strict],
                         options: %w[profile], ignored: %w[run] },
      "smoke_test"  => { slots: [%w[subject domain]], ignored: %w[run] },
      "project_cli" => { slots: [%w[domain]], many: true }
    }.freeze

    # Subcommands whose words are their own: `run`'s pairs and `mcp`'s flags are not the launcher's.
    UNTOUCHED = %w[run mcp].freeze

    # Subcommands whose `name=value` form is the launcher's own question, which answers
    # differently from the positional form: `project_diagrams` writes files, the question prints.
    LAUNCHER_ANSWERS = ["project_diagrams"].freeze

    # Printed above the usage line by `overview`, on every path that reaches it
    # (a bare `hecks`, `hecks --help`, and an unknown subcommand alike).
    HERO = <<~BANNER.freeze
      #   #  #####   ####  #  #    ####
      #   #  #      #      # #    #
      #####  ####   #      ##      ###
      #   #  #      #      # #        #
      #   #  #####   ####  #  #   ####

          It's all about the specs
    BANNER

    # Exit status for a missing or unknown subcommand.
    USAGE_STATUS = 2

    module_function

    # The checkout this library is loaded from, which a corpus sweep needs; an installed gem has
    # none.
    #
    # @return [String, nil] the repository root, or nil when `hecks.gemspec` is not beside `lib/`
    def checkout_root
      root = File.expand_path("../..", __dir__)
      root if File.exist?(File.join(root, "hecks.gemspec"))
    end

    # Routes `argv` to its subcommand and runs it.
    #
    # A subcommand followed only by `--help`/`-h` prints its usage without
    # running it; other arguments still reach the verb itself.
    #
    # @param argv [Array<String>] the command line, subcommand first
    # @param out [#puts] where help goes
    # @param err [#puts] where usage errors go
    # @return [Integer] the process exit status: 2 for a bad command, 1 for a bad word, the
    #   subcommand's own Integer when it returns one, else 0; a subcommand that fails exits
    #   the process itself
    def start(argv, out: $stdout, err: $stderr)
      Encoding.default_external = Encoding::UTF_8
      Encoding.default_internal = Encoding::UTF_8
      name, *rest = argv
      if name.nil? || !COMMANDS.key?(name)
        asked = HELP_FLAGS.include?(name) || name == "help"
        err.puts "hecks: unknown command #{name.inspect}" unless asked || name.nil?
        overview(asked ? out : err)
        return asked ? 0 : USAGE_STATUS
      end

      if name != "run" && rest.any? { |word| HELP_FLAGS.include?(word) }
        help(COMMANDS.fetch(name), out)
        return 0
      end

      words, problem = launcher_words(name, rest)
      if problem
        err.puts "hecks #{name}: #{problem}"
        return 1
      end

      result = dispatch(name, words)
      result.is_a?(Integer) ? result : 0
    end

    # Whether a command line is the launcher's own form of a subcommand that answers differently
    # from its positional form, so the executable leaves it to the launcher.
    #
    # @param argv [Array<String>] the command line, subcommand first
    # @return [Boolean]
    def launcher_form?(argv)
      LAUNCHER_ANSWERS.include?(argv.first) && argv.drop(1).any? { |word| word.match?(NAME_VALUE) }
    end

    # Rewrites the launcher's spellings into the subcommand's own: drops the generic flags and
    # turns `name=value` words into the positionals and flags the subcommand reads.
    #
    # @param name [String] a key of `COMMANDS`
    # @param rest [Array<String>] the words after the subcommand
    # @return [Array(Array<String>, String)] the words to run with, and a refusal (nil when
    #   there is none)
    def launcher_words(name, rest)
      return [rest, nil] if UNTOUCHED.include?(name)

      require_relative "facade/cli_door"
      words = strip_generic(rest)
      form  = LAUNCHER_FORMS[name]
      return [words, nil] unless form && words.any? { |word| word.match?(NAME_VALUE) }

      slots = Array.new(form[:slots].length) { [] }
      extra = []
      words.grep(NAME_VALUE).each do |word|
        key, value = word.split("=", 2)
        key  = key.tr("-", "_")
        slot = form[:slots].index { |names| names.include?(key) }
        if slot
          slots[slot].concat(form[:many] ? value.split(",") : [value])
        elsif Array(form[:flags]).include?(key)
          extra << "--#{key.tr('_', '-')}" if Facade::CliDoor.boolean(value)
        elsif Array(form[:options]).include?(key)
          extra.push("--#{key}", value)
        elsif !Array(form[:ignored]).include?(key)
          known = form[:slots].flatten + Array(form[:flags]) + Array(form[:options])
          return [nil, "no argument #{key.inspect} — this verb takes #{known.sort.join(', ')}"]
        end
      end
      missing = slots.first.find { |path| !File.exist?(path) } if form[:exists]
      return [nil, "no such domain #{missing.inspect}"] if missing

      [words.grep_v(NAME_VALUE) + extra + slots.flatten, nil]
    rescue Runtime::TypeMismatch => e
      [nil, e.message]
    end

    # Takes `--wait` and `--confirm`, each with an optional Boolean word, out of `words`.
    # @api private
    def strip_generic(words)
      queue = words.dup
      kept  = []
      until queue.empty?
        word = queue.shift
        flag, value = word.split("=", 2)
        if GENERIC_FLAGS.include?(flag)
          value ||= Facade::CliDoor::BOOLEAN_WORDS.key?(queue.first.to_s.downcase) ? queue.shift : "true"
          Facade::CliDoor.boolean(value)
        else
          kept << word
        end
      end
      kept
    end

    # Runs one known subcommand with the working directory as its root.
    #
    # @param name [String] a key of `COMMANDS`
    # @param argv [Array<String>] the arguments after the subcommand
    # @return [void]
    # @raise [SystemExit] when the subcommand exits the process itself
    def dispatch(name, argv)
      command = COMMANDS.fetch(name)
      require_relative "three_zero"
      ThreeZero.route_notice(name)
      require_relative command.file
      command.run.call(argv, "hecks #{name}", name)
    end

    # @api private
    def overview(io)
      io.puts HERO
      io.puts "usage: hecks <command> [arguments]"
      io.puts ""
      width = COMMANDS.keys.map(&:length).max
      COMMANDS.each { |name, command| io.puts "  #{name.ljust(width)}  #{command.summary}" }
      io.puts ""
      io.puts "Run `hecks <command> --help` for one command's usage."
    end

    # @api private
    def help(command, io)
      io.puts "usage: #{command.usage}"
      io.puts ""
      io.puts command.summary
    end
  end
end
