require "socket"

module Hecks
  # Startup gate for the stdio MCP servers `hecks mcp` runs: refuses network sockets, extra
  # flags and unknown `HECKS_MCP_*` variables. It is not authentication (ADR 0062).
  module McpStdioGuard
    ACCEPTED_ARGS = %w[--stdio].freeze
    ENV_PREFIX    = "HECKS_MCP_".freeze
    ACCEPTED_ENV  = { "HECKS_MCP_TRANSPORT" => "stdio" }.freeze
    EXIT_STATUS   = 2

    # The lines every stdio server prints, ahead of its own notes.
    COMMON_NOTES = [
      "stdio only. This server has no authentication and must not be exposed over a network.",
      "Whoever can write to this process's stdin can make every call it accepts."
    ].freeze

    module_function

    # Lists every reason this process should not start as a stdio server.
    #
    # @param argv [Array<String>] the command-line arguments
    # @param env [Hash{String => String}] the process environment
    # @param stdin [IO] the stream requests arrive on
    # @param stdout [IO] the stream responses leave on
    # @return [Array<String>] one message per violation; empty when the process is
    #   set up for stdio
    def violations(argv: ARGV, env: ENV, stdin: $stdin, stdout: $stdout)
      argument_violations(argv) + environment_violations(env) + descriptor_violations(stdin, stdout)
    end

    # Builds the warning printed at startup.
    #
    # @param server [String] the server's name, used as the line prefix
    # @param notes [Array<String>] server-specific lines added after `COMMON_NOTES`
    # @return [Array<String>] the banner lines, each prefixed with `server`
    def banner(server:, notes: [])
      (COMMON_NOTES + notes).map { |line| "#{server}: #{line}" }
    end

    # Refuses to continue on a non-stdio setup. Everything goes to `stderr`: stdout
    # carries the MCP protocol, and a stray line there corrupts the client's framing.
    #
    # @param server [String] the server's name, used as the line prefix
    # @param argv [Array<String>] the command-line arguments
    # @param env [Hash{String => String}] the process environment
    # @param stdin [IO] the stream requests arrive on
    # @param stdout [IO] the stream responses leave on
    # @param stderr [IO] where the refusal is written
    # @return [void]
    # @raise [SystemExit] with status `EXIT_STATUS` when `violations` is not empty
    def enforce_stdio!(server:, argv: ARGV, env: ENV, stdin: $stdin, stdout: $stdout, stderr: $stderr)
      found = violations(argv: argv, env: env, stdin: stdin, stdout: stdout)
      refuse!(server, found, stderr) unless found.empty?
    end

    # Prints the startup warning to `stderr`, never to stdout.
    #
    # @param server [String] the server's name, used as the line prefix
    # @param notes [Array<String>] server-specific warning lines
    # @param stderr [IO] where the warning is written
    # @return [void]
    def warn!(server:, notes: [], stderr: $stderr)
      banner(server: server, notes: notes).each { |line| stderr.puts(line) }
    end

    # Enforces stdio, then prints the warning.
    #
    # @param server [String] the server's name, used as the line prefix
    # @param notes [Array<String>] server-specific warning lines
    # @param stderr [IO] where the refusal or the warning is written
    # @param checks [Hash{Symbol => Object}] `argv:`, `env:`, `stdin:` and `stdout:`, as
    #   for `enforce_stdio!`
    # @return [void]
    # @raise [SystemExit] with status `EXIT_STATUS` when the setup is not stdio
    def start!(server:, notes: [], stderr: $stderr, **checks)
      enforce_stdio!(server: server, stderr: stderr, **checks)
      warn!(server: server, notes: notes, stderr: stderr)
    end

    # @api private
    def refuse!(server, found, stderr)
      found.each { |message| stderr.puts("#{server}: refusing to start: #{message}") }
      stderr.puts("#{server}: this server speaks MCP over stdio only.")
      exit(EXIT_STATUS)
    end

    # @api private
    def argument_violations(argv)
      (argv - ACCEPTED_ARGS).map do |arg|
        "argument #{arg.inspect} is not accepted (only #{ACCEPTED_ARGS.join(', ')}); network options are refused, not ignored"
      end
    end

    # @api private
    def environment_violations(env)
      env.select { |name, value| name.start_with?(ENV_PREFIX) && ACCEPTED_ENV[name] != value }.map do |name, value|
        "environment #{name}=#{value.inspect} is not accepted; the servers take no #{ENV_PREFIX}* options " \
          "except #{ACCEPTED_ENV.map { |k, v| "#{k}=#{v}" }.join(', ')}"
      end
    end

    # @api private
    def descriptor_violations(stdin, stdout)
      { "stdin" => stdin, "stdout" => stdout }.select { |_, io| ip_socket?(io) }.map do |label, _|
        "#{label} is a network (IP) socket, so this process is being served over a network"
      end
    end

    # A socket whose address cannot be read is refused: it cannot be shown to be local.
    #
    # @api private
    def ip_socket?(io)
      return false unless io.stat.socket?

      socket = Socket.for_fd(io.fileno)
      socket.autoclose = false # the descriptor belongs to `io`
      socket.local_address.ip?
    rescue SystemCallError, IOError
      true
    end
  end
end
