require_relative "cli/command_table"
require_relative "cli/launcher_words"

module Hecks
  # The `hecks` command an installed gem puts on the path: one router over the
  # domain-operator tools, each also runnable from a checkout as `exe/hecks <name>`.
  #
  # Every subcommand's logic lives under `cli/`, and `exe/hecks` routes to it.
  #
  # See `docs/decisions/0066-the-gem-ships-a-hecks-executable-and-dev-tooling-stays-in-the-repo.md`.
  module CLI
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

    include LauncherWords
    extend LauncherWords

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
      return refuse_command(name, out, err) unless COMMANDS.key?(name)
      return command_help(name, out) if help_asked?(name, rest)

      words, problem = launcher_words(name, rest)
      return refuse_words(name, problem, err) if problem

      result = dispatch(name, words)
      result.is_a?(Integer) ? result : 0
    end

    # Answers an absent or unknown subcommand with the overview.
    # @api private
    # @return [Integer] 0 when help was asked for, else the usage status
    def refuse_command(name, out, err)
      asked = HELP_FLAGS.include?(name) || name == "help"
      err.puts "hecks: unknown command #{name.inspect}" unless asked || name.nil?
      overview(asked ? out : err)
      asked ? 0 : USAGE_STATUS
    end

    # Prints one subcommand's usage.
    # @api private
    # @return [Integer] 0
    def command_help(name, out)
      help(COMMANDS.fetch(name), out)
      0
    end

    # Says why a subcommand's words were refused.
    # @api private
    # @return [Integer] 1
    def refuse_words(name, problem, err)
      err.puts "hecks #{name}: #{problem}"
      1
    end

    # Whether the words ask for a subcommand's usage: a lone flag for `run`, whose other words are
    # the verb's own, and the flag anywhere for the rest.
    # @api private
    def help_asked?(name, rest)
      return rest.length == 1 && HELP_FLAGS.include?(rest.first) if name == "run"

      rest.any? { |word| HELP_FLAGS.include?(word) }
    end

    # Runs one known subcommand with the working directory as its root.
    #
    # @param name [String] a key of `COMMANDS`
    # @param argv [Array<String>] the arguments after the subcommand
    # @return [void]
    # @raise [SystemExit] when the subcommand exits the process itself
    def dispatch(name, argv)
      command = COMMANDS.fetch(name)
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
