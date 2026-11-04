# frozen_string_literal: true

require "json"
require_relative "shell"
require "time"
require_relative "console_capture"
require_relative "claude_transcript"
require_relative "claude_jobs"
require_relative "claude_agent_list"
require_relative "dispatching/settings"

module Hecks
  module Adapters
    # The `Agents` port's adapter for `AgentRun`: finds the directory a session will work in and the
    # agents `claude` lists there, starts a background Claude session with the `claude` command,
    # and reads the state its job is in.
    #
    # It decides nothing. Whether a brief is enough, whether an agent is listed and which states
    # are new or mean a session has ended are the bluebook's; this only looks, starts and reads. The
    # command is an argument list, never a string for a shell, and a `--` keeps a brief from being
    # taken for a flag.
    class ClaudeAgents
      # The command that starts and lists sessions.
      COMMAND = "claude"

      # A background start prints `backgrounded · <id>` first, then how to attach to the session.
      SESSION_ID = /\Abackgrounded\W+([0-9A-Za-z][0-9A-Za-z_-]{5,})/

      # How long a just-started session is given to fail before its job is read, in seconds.
      SETTLE_SECONDS = 3

      # Keeps the command to run, so a spec can point it at a stand-in.
      #
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `command:` the program that starts sessions (default `claude`),
      #   `jobs:` the jobs directory, `settle:` the seconds a new session is given to fail
      # @param root [String, nil] unused
      # @param registry [Runtime::Registry, nil] whose Tickets world names the session environment
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil)
        @command = settings[:command] || COMMAND
        @session = Dispatching::Settings.new(registry)
        @shell = Shell.new
        @transcript = ClaudeTranscript.new(**settings.slice(:projects))
        @jobs = ClaudeJobs.new(directory: settings[:jobs])
        @agents = ClaudeAgentList.new(@command, shell: @shell)
        @settle = settings.fetch(:settle, SETTLE_SECONDS)
      end

      # Says the directory a session would work in is there, and whether the `claude` there lists
      # the named agent. With no agent named the session runs `claude`'s default, so nothing is
      # asked.
      #
      # @param held [Hash] the `AgentRun` record: `repo`, and `agent` when one is named
      # @return [Hash{Symbol => Object}] `report:` that the directory is there, `listed:` whether
      #   the agent is listed, and `note:` that in words, naming the agents that are
      # @raise [ConsoleCapture::Failure] when it is not a directory, or `claude` names no agents
      def locate(**held)
        repo = plain(held[:repo])
        raise ConsoleCapture::Failure, "#{repo} is not a directory" unless File.directory?(repo.to_s)

        { report: { value: "#{repo} is a directory" }, **agent_listing(repo, plain(held[:agent])) }
      end

      # Starts a background session in the directory, with the brief as its first prompt.
      #
      # @param held [Hash] the `AgentRun` record: `repo`, `brief`, and `agent` when one is named
      # @return [Hash{Symbol => Hash}] `session:` the id the session is known by
      # @raise [ConsoleCapture::Failure] when the command fails or names no session
      def start(**held)
        result = @shell.capture(*start_arguments(held), env: @session.session_environment, chdir: plain(held[:repo]))
        raise ConsoleCapture::Failure, "#{@command} did not start a session: #{result.err.strip}" unless result.ok?

        id = result.out[SESSION_ID, 1]
        raise ConsoleCapture::Failure, "#{@command} named no session: #{result.out.strip}" unless id

        { session: { value: id } }
      end

      # Reads the state a started session's job is in, beside the state the run last recorded.
      #
      # @param held [Hash] the `AgentRun` record: `session`, `repo`, and the `condition` it holds
      # @return [Hash{Symbol => String}] `state:` and `detail:` from the job, `previous:` the held
      #   condition (empty when none), and `checkout:` the run's directory with its trailing slash
      # @raise [ConsoleCapture::Failure] when the job's state cannot be read
      def read_job(**held)
        job = @jobs.state(plain(held[:session]))
        { state: job["state"].to_s, detail: job["detail"].to_s, previous: plain(held[:condition]).to_s,
          checkout: File.join(plain(held[:repo]).to_s, "") }
      end

      # Waits the settling time, then reads the job as {#read_job} does: a session that dies at
      # once has reported it by then.
      #
      # @param held [Hash] the `AgentRun` record, as for {#read_job}
      # @return [Hash{Symbol => String}] what {#read_job} answers
      # @raise [ConsoleCapture::Failure] when the job's state cannot be read
      def await_job(**held)
        sleep(@settle) if @settle.positive?
        read_job(**held)
      end

      # Says whether a person replied in a session after its brief.
      #
      # @param held [Hash] the `AgentRun` record: `session`
      # @return [Hash{Symbol => Object}] `taken_over:` true when a person replied or the transcript
      #   cannot be read, and `note:` that fact in words
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed or this one is not among
      #   them
      def review(**held)
        full = listed(plain(held[:session]))["sessionId"]
        taken = @transcript.taken_over?(full)
        { taken_over: taken, note: taken ? "a person replied, or the transcript cannot be read" : "nobody replied" }
      end

      # Removes a session with `claude rm`.
      #
      # @param held [Hash] the `AgentRun` record: `session`
      # @return [Hash{Symbol => Object}] `removed_at:` when it was removed, as an ISO 8601 string
      # @raise [ConsoleCapture::Failure] when the command refuses
      def remove(**held)
        id = plain(held[:session])
        result = @shell.capture(@command, "rm", id)
        raise ConsoleCapture::Failure, "#{@command} rm #{id} refused: #{result.err.strip}" unless result.ok?

        { removed_at: { value: Time.now.utc.iso8601 } }
      end

      # Answers a blocked session by resuming it in the run's directory, with the answer as its prompt.
      #
      # @param held [Hash] the `AgentRun` record: `session`, `repo`, and `answer`
      # @return [Hash{Symbol => Hash}] `resumed_at:` when the resume was started, as an ISO 8601 string
      # @raise [ConsoleCapture::Failure] when the command refuses
      def resume(**held)
        id = plain(held[:session])
        result = @shell.capture(*niceness, @command, "--bg", "--resume", id, "--", plain(held[:answer]),
                                env: @session.session_environment, chdir: plain(held[:repo]))
        raise ConsoleCapture::Failure, "#{@command} resume #{id} refused: #{result.err.strip}" unless result.ok?

        { resumed_at: { value: Time.now.utc.iso8601 } }
      end

      private

      def agent_listing(repo, agent)
        return { listed: true, note: "no agent named: the session runs the default agent" } unless agent

        names = @agents.names(repo)
        { listed: names.include?(agent), note: "agent #{agent} is not available in #{repo}; available: #{names.join(", ")}" }
      end

      def listed(id)
        listing = @shell.capture(@command, "agents", "--json", "--all")
        raise ConsoleCapture::Failure, "#{@command} could not list sessions: #{listing.err.strip}" unless listing.ok?

        found = JSON.parse(listing.out).find { |entry| [entry["id"], entry["sessionId"]].include?(id) }
        found || raise(ConsoleCapture::Failure, "no session #{id} is listed")
      end

      def start_arguments(held)
        agent = plain(held[:agent])
        [*niceness, @command, *(agent ? ["--agent", agent] : []), "--bg", "--", plain(held[:brief])]
      end

      def niceness = @session.nice ? ["nice", "-n", @session.nice.to_s] : []

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
