require "json"
require "hecks/release/runner"

# Test doubles for the release specs.
module ReleaseSpecSupport
  # Records every command and answers from a script; the default script is a
  # release that is ready to go: clean main equal to origin/main, no tag, nothing
  # published.
  class RecordingCommands
    Call = Struct.new(:kind, :argv, :env, :chdir, keyword_init: true)

    # @return [Array<Call>] every command started, in order
    attr_reader :calls

    # @param sha [String] the commit `HEAD` and `origin/main` both resolve to
    # @param version [String] the version whose tag does not exist yet
    def initialize(sha:, version:)
      @calls = []
      @answers = []
      @failures = []
      @hooks = []
      script_defaults(sha, version)
    end

    # Scripts the answer to captured commands starting with a prefix; the newest
    # answer for the longest matching prefix wins.
    #
    # @param prefix [Array<String>] the leading arguments to match
    # @param stdout [String] what the command prints
    # @param stderr [String] what the command prints to standard error
    # @param success [Boolean] whether it exits zero
    # @return [void]
    def answer(*prefix, stdout: "", stderr: "", success: true)
      result = Hecks::Release::Runner::Commands::Result.new(stdout: stdout, stderr: stderr, success: success)
      @answers.unshift([prefix, result])
    end

    # Makes `run!` raise for commands starting with a prefix.
    #
    # @param prefix [Array<String>] the leading arguments to match
    # @return [void]
    def fail_run(*prefix)
      @failures << prefix
    end

    # Calls a block, with the argument list, as a matching `run!` starts.
    #
    # @param prefix [Array<String>] the leading arguments to match
    # @yieldparam argv [Array<String>] the full argument list
    # @return [void]
    def on_run(*prefix, &block)
      @hooks << [prefix, block]
    end

    # Records the command and returns its scripted answer, or success with no output.
    #
    # @param argv [Array<String>] the command and its arguments
    # @param env [Hash] the environment it was given
    # @param chdir [String, nil] the directory it was given
    # @return [Hecks::Release::Runner::Commands::Result] the scripted answer
    def capture(*argv, env: {}, chdir: nil)
      @calls << Call.new(kind: :capture, argv: argv, env: env, chdir: chdir)
      match = @answers.select { |prefix, _| argv.first(prefix.size) == prefix }.max_by { |prefix, _| prefix.size }
      match ? match.last : Hecks::Release::Runner::Commands::Result.new(stdout: "", stderr: "", success: true)
    end

    # Records the command, runs any hook for it, and raises when it was told to fail.
    #
    # @param argv [Array<String>] the command and its arguments
    # @param env [Hash] the environment it was given
    # @param chdir [String, nil] the directory it was given
    # @return [void]
    # @raise [Hecks::Release::Runner::CommandFailed] if the command was scripted to fail
    def run!(*argv, env: {}, chdir: nil)
      @calls << Call.new(kind: :run, argv: argv, env: env, chdir: chdir)
      @hooks.each { |prefix, block| block.call(argv) if argv.first(prefix.size) == prefix }
      return unless @failures.any? { |prefix| argv.first(prefix.size) == prefix }

      raise Hecks::Release::Runner::CommandFailed, "`#{argv.first(2).join(' ')}` failed"
    end

    # Lists the commands that changed something.
    #
    # @return [Array<Call>] the `run!` calls, in order
    def runs
      @calls.select { |call| call.kind == :run }
    end

    # Lists every argument list started.
    #
    # @return [Array<Array<String>>] the argument lists, in order
    def argvs
      @calls.map(&:argv)
    end

    # Says whether a command starting with a prefix was run with `run!`.
    #
    # @param prefix [Array<String>] the leading arguments to match
    # @return [Boolean] true when one was
    def ran?(*prefix)
      runs.any? { |call| call.argv.first(prefix.size) == prefix }
    end

    private

    def script_defaults(sha, version)
      answer("git", "rev-parse", "--abbrev-ref", "HEAD", stdout: "main\n")
      answer("git", "rev-parse", "HEAD", stdout: "#{sha}\n")
      answer("git", "rev-parse", "origin/main", stdout: "#{sha}\n")
      answer("git", "status", "--porcelain", stdout: "")
      answer("git", "rev-parse", "-q", "--verify", "refs/tags/v#{version}^{commit}", success: false)
      answer("git", "ls-remote", stdout: "")
      answer("curl", "-fsS", stdout: JSON.generate([{ "number" => "0.0.1" }]))
      answer("npm", "view", stderr: "npm error code E404\n", success: false)
    end
  end
end
