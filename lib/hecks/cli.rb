module Hecks
  # The `hecks` command an installed gem puts on the path: one router over the
  # domain-operator tools, each also runnable from a checkout as `bin/<name>`.
  #
  # Every subcommand's logic lives under `cli/`, with `bin/<name>` a thin wrapper
  # over the same entry point, so the two can't drift apart.
  #
  # See `docs/decisions/0066-the-gem-ships-a-hecks-executable-and-dev-tooling-stays-in-the-repo.md`.
  module CLI
    # One subcommand's help: a one-line summary and its usage line.
    Command = Struct.new(:summary, :usage)

    # Every subcommand, in the order the help lists them.
    COMMANDS = {
      "run"              => Command.new(
        "Dispatch a verb, or run a JSON step list, against a domain.",
        "hecks run [domain] <verb [name=value …] | script.json | - | '{\"steps\":[…]}'>"
      ),
      "docs"             => Command.new(
        "Print a domain's usage document, projected from its bluebook.",
        "hecks docs [domain-path] [aggregate]"
      ),
      "narrate"          => Command.new(
        "Print a domain read back in English, projected from its bluebook.",
        "hecks narrate [domain-path] [aggregate]"
      ),
      "ir"               => Command.new(
        "Print a booted domain's IR as JSON.",
        "hecks ir <domain> [--translations] | hecks ir --meta"
      ),
      "stores"           => Command.new(
        "Print every aggregate's current records as JSON.",
        "hecks stores <domain>"
      ),
      "model_check"      => Command.new(
        "Statically check a domain's IR for dead states and unreachable steps.",
        "hecks model_check [--strict] [--profile client] <domain> [<domain> …]"
      ),
      "smoke_test"       => Command.new(
        "Boot a domain and dispatch every declared command and report once.",
        "hecks smoke_test [domain]"
      ),
      "project_diagrams" => Command.new(
        "Write a domain's Mermaid diagrams under ./docs/generated/diagrams/.",
        "hecks project_diagrams <domain-path> <ChapterName>"
      ),
      "project_cli"      => Command.new(
        "Write a command-line launcher beside each domain, named after its bluebook.",
        "hecks project_cli [domain-path …]"
      ),
      "mcp"              => Command.new(
        "Serve the MCP door over stdio (no authentication; stdio only).",
        "hecks mcp [--stdio]"
      )
    }.freeze

    HELP_FLAGS = ["--help", "-h"].freeze

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
      program = "hecks #{name}"
      case name
      when "run"
        require_relative "cli/run"
        Run.call(argv, program: program)
      when "docs", "narrate"
        require_relative "cli/document"
        Document.call(argv, projection: name.to_sym, program: program, root: Dir.pwd)
      when "ir"
        require_relative "cli/ir"
        Ir.call(argv, program: program)
      when "stores"
        require_relative "cli/stores"
        Stores.call(argv, program: program)
      when "model_check"
        require_relative "cli/model_check"
        ModelCheck.call(argv, program: program)
      when "smoke_test"
        require_relative "cli/smoke_test"
        SmokeTest.call(argv, root: Dir.pwd)
      when "project_diagrams"
        require_relative "cli/project_diagrams"
        ProjectDiagrams.call(argv, program: program, root: Dir.pwd)
      when "project_cli"
        require_relative "cli/project_cli"
        ProjectCli.call(argv, program: program, root: Dir.pwd, remove_stale_bin: false)
      when "mcp"
        require_relative "cli/mcp"
        Mcp.call(argv)
      end
    end

    # @api private
    def overview(io)
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
