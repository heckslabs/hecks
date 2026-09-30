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
        ->(argv, program, _name) { ModelCheck.call(argv, program: program) }
      ),
      "smoke_test"       => Command.new(
        "Boot a domain and dispatch every declared command and report once.",
        "hecks smoke_test [domain]",
        "cli/smoke_test",
        ->(argv, _program, _name) { SmokeTest.call(argv, root: Dir.pwd) }
      ),
      "project_diagrams" => Command.new(
        "Write a domain's Mermaid diagrams under ./docs/generated/diagrams/.",
        "hecks project_diagrams <domain-path> <ChapterName>",
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

    # Routes `argv` to its subcommand and runs it.
    #
    # A subcommand followed only by `--help`/`-h` prints its usage without
    # running it; other arguments still reach the verb itself.
    #
    # @param argv [Array<String>] the command line, subcommand first
    # @param out [#puts] where help goes
    # @param err [#puts] where usage errors go
    # @return [Integer] the process exit status for a subcommand that returns; a
    #   subcommand that fails exits the process itself
    def start(argv, out: $stdout, err: $stderr)
      name, *rest = argv
      if name.nil? || !COMMANDS.key?(name)
        asked = HELP_FLAGS.include?(name) || name == "help"
        err.puts "hecks: unknown command #{name.inspect}" unless asked || name.nil?
        overview(asked ? out : err)
        return asked ? 0 : USAGE_STATUS
      end

      if rest.length == 1 && HELP_FLAGS.include?(rest.first)
        help(COMMANDS.fetch(name), out)
      else
        dispatch(name, rest)
      end
      0
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
