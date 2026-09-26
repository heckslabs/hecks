require "socket"

module Hecks
  # The startup gate for the stdio MCP servers in `bin/` (`hecks_mcp_door`,
  # `hecks_query_ir_mcp`): it refuses to run when the process was set up to
  # speak to anything but a local parent, and it says on stderr what the
  # process does and does not protect.
  #
  # ## Why a gate and not a comment
  #
  # Both servers have no authentication. What keeps a stranger away from
  # them is that only a process that can spawn them can write to their
  # stdin. That holds until someone wraps one in `socat TCP-LISTEN:... EXEC:`
  # or an `inetd`-style listener, which hands the process a network socket
  # as stdin/stdout without changing a line of the server. The gate turns
  # that setup into a refusal at startup instead of an exposure nobody
  # noticed.
  #
  # ## What it checks
  #
  # - **Arguments** — none, except `--stdio`. A `--port` or `--http` flag is
  #   refused rather than ignored, so a caller that believes it started a
  #   network server finds out immediately.
  # - **Environment** — no `HECKS_MCP_*` variable except
  #   `HECKS_MCP_TRANSPORT=stdio`. The servers take no configuration, so an
  #   unknown option in that namespace fails closed.
  # - **Descriptors** — stdin and stdout must not be internet-protocol sockets
  #   (`AF_INET` or `AF_INET6`). A pipe, a file, a terminal and a Unix-domain socket all pass;
  #   the last matters because some MCP clients spawn servers over a
  #   `socketpair`, which is local to the machine.
  #
  # ## What it does not do
  #
  # It does not authenticate anyone and it cannot see a proxy that copies
  # bytes from a network socket into an ordinary pipe. It closes the
  # configurations that announce themselves; the ADR on MCP authentication
  # (`docs/decisions/0061-mcp-servers-need-real-authentication-before-any-network-transport.md`)
  # covers what a network transport would need.
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

    # Refuses to continue on a non-stdio setup.
    #
    # A server calls this before it requires anything heavy, so a misconfigured start
    # fails in milliseconds and before any protocol byte is answered. Everything goes
    # to `stderr`: stdout carries the MCP protocol, and one stray line there corrupts
    # the client's framing.
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
