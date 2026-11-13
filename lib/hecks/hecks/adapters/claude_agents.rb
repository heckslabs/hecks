# frozen_string_literal: true

require "json"
require_relative "shell"
require "time"
require_relative "console_capture"
require_relative "claude_transcript"
require_relative "reviewer_judgment"
require_relative "claude_jobs"
require_relative "claude_resumption"
require_relative "architect_verdict"
require_relative "architect_findings"
require_relative "claude_closing_message"
require_relative "coder_job_facts"
require_relative "claude_agent_list"
require_relative "claude_session_listing"
require_relative "session_caller"
require_relative "dispatching/settings"
require_relative "session_lookup"
require_relative "session_line"
require_relative "session_hooks"
require_relative "main_launcher"
require_relative "session_reaping"
require_relative "claude_agents/removal"

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
      include Removal

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
      #   `jobs:` the jobs directory, `settle:` the seconds a new session is given to fail,
      #   `wake_patience:` the seconds a woken session is given to stop reading `stopped`,
      #   `launcher:` the `exe/hecks` its hooks run (default the main checkout's), `projects:` the
      #   directory of the per-project transcript folders
      # @param root [String, nil] unused
      # @param registry [Runtime::Registry, nil] whose Tickets world names the session environment
      def initialize(aggregate: nil, settings: {}, root: nil, registry: nil)
        @command = settings[:command] || COMMAND
        @session = Dispatching::Settings.new(registry)
        @shell = Shell.new
        transcripts(settings.slice(:projects))
        @jobs = ClaudeJobs.from(settings)
        @agents = ClaudeAgentList.new(@command, shell: @shell)
        @lookup = session_lookup(settings[:now])
        @settle = settings.fetch(:settle, SETTLE_SECONDS)
        @hooks = SessionHooks.new(launcher: settings.fetch(:launcher) { MainLauncher.path })
        @reaping = SessionReaping.new(registry: registry)
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
        result = @shell.capture(*session_line.arguments(held, caller_only(held)), env: named(held), chdir: plain(held[:repo]))
        { session: { value: session_id(result) }, started_at: { value: @clock.call.iso8601 } }
      end

      # Reads the state a started session's job is in, beside the state the run last recorded.
      #
      # @param held [Hash] the `AgentRun` record: `session`, `repo`, and the `condition` it holds
      # @return [Hash{Symbol => String}] `state:` and `detail:` from the job, `previous:` the held
      #   condition (empty when none), `checkout:` the run's directory with its trailing slash, and
      #   the {CoderJobFacts}: `agent:`, `report:`, and a done coder's `branch:`, `sha:`, `clean:`;
      #   and `listed:` the status and `live:` the state `claude agents` lists the session with.
      #   A job that reads ended (`done`, `stopped`) is read against a fresh listing, so `live:`
      #   is not stale news; the state itself stays the job's own
      # @raise [ConsoleCapture::Failure] when the job's state cannot be read
      def read_job(**held)
        job = @jobs.state(plain(held[:session]))
        { state: job["state"].to_s, detail: job["detail"].to_s }
          .merge(architect_facts(job, held), reviewer_facts(job, held), run_facts(held), session_facts(job, held))
      end

      # @return [Hash{Symbol => Object}] what {CoderJobFacts} reads of the job and its checkout, and
      #   the listing's `listed:` and `live:`, read afresh when the job reads ended (only freshness:
      #   whether it ended is the bluebook's)
      def session_facts(job, held)
        CoderJobFacts.new.call(agent: plain(held[:agent]), state: job["state"], report: last_words(job, held),
                               checkout: plain(held[:repo]))
                     .merge(@listing.facts(plain(held[:session]), fresh: %w[done stopped].include?(job["state"])))
      end

      # The session's last words: its timeline's tail, else the job's result, else its summary; the
      # first that says something, never the three joined, so the last word is the session's own.
      #
      # @return [String] the first of the three that says something, or empty
      def last_words(job, held)
        [@jobs.closing(plain(held[:session])), job.dig("output", "result"), job["detail"]].map(&:to_s).find do |text|
          !text.strip.empty?
        end.to_s
      end

      # @return [Hash{Symbol => String}] the architect's `verdict` and its `findings`, both read
      #   from one text: its closing message whole from the transcript, else {#last_words}. The
      #   findings keep that text's head and tail ({ArchitectFindings.clip}); both are empty for
      #   any other agent
      def architect_facts(job, held)
        return { verdict: "", findings: "" } unless plain(held[:agent]).to_s == "architect"

        text = ArchitectFindings.pick(@closing.of(plain(held[:session])), last_words(job, held))
        { verdict: ArchitectVerdict.of(text), findings: ArchitectFindings.clip(text) }
      end

      # @return [Hash{Symbol => String}] the reviewer's `judgment` ({ReviewerJudgment}), empty for
      #   any other agent or a text that names none
      def reviewer_facts(job, held)
        return { judgment: "" } unless plain(held[:agent]).to_s == "reviewer"

        { judgment: ReviewerJudgment.of([job.dig("output", "result"), job["detail"]].compact.join(" ")) }
      end

      # @return [Hash{Symbol => String}] the run the job belongs to: its key, the Work item it
      #   serves (empty for a run that serves none), its last known condition, whether an answer
      #   is on its way to it (`resuming`), whether a plan review it asked for is open
      #   (`reviewing`), and its directory with a trailing slash
      def run_facts(held)
        { previous: plain(held[:condition]).to_s, checkout: File.join(plain(held[:repo]).to_s, ""),
          run: plain(held[:run]).to_s, work: plain(held[:work]).to_s, **waiting_facts(held) }
      end

      # @return [Hash{Symbol => Boolean}] `resuming:` and `reviewing:`, each true only when the run
      #   holds it so
      def waiting_facts(held) = %i[resuming reviewing].to_h { |name| [name, plain(held[name]) == true] }

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

      # Answers a session by waking it in place under its own id (see {ClaudeResumption}). The run
      # holds the short id `claude agents` shows; `--resume` takes only the full session id.
      #
      # @param held [Hash] the `AgentRun` record: `session`, `repo` and `answer`, `step` when the
      #   answer comes with the session's next step (it leads the prompt), and `agent` when the run
      #   has a role, which the resume passes as `--agent` so the role's MCP server narrows itself
      #   again
      # @return [Hash{Symbol => Object}] `resumed_at:` when the resume was started, as an ISO 8601
      #   string; `session:` the id the run follows, its own unless the CLI started a copy; and
      #   `note:` what the CLI said of that copy, when it did. It answers once the woken session's
      #   job reads a state other than `stopped` ({ClaudeJobs#woken})
      # @raise [ConsoleCapture::Failure] when the session is not listed or the command refuses
      def resume(**held)
        id = plain(held[:session])
        @jobs.woken(ClaudeResumption.new(@command, @shell, nice: niceness)
                                    .call(id, listed(id), prompt(held), env: named(held), chdir: plain(held[:repo]),
                                                                        agent: plain(held[:agent])))
      end

      # Says whether `claude agents` still lists the run's session. A session `claude rm` deleted is
      # not listed; whether a run whose session is gone may be retired is the bluebook's.
      #
      # @param held [Hash] the `AgentRun` record: `session`
      # @return [Hash{Symbol => Object}] `listed:` whether the session is listed, `state:` its state
      #   there (empty when it is not), and `note:` that in words
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
      def look_for(**held) = @lookup.call(held)

      private

      # The readers of the sessions' transcripts: whether a person replied, and the closing message.
      def transcripts(projects)
        @transcript = ClaudeTranscript.new(**projects)
        @closing = ClaudeClosingMessage.new(**projects)
      end

      # The answer a session is woken with: the step, when the answer has one, then the answer.
      def prompt(held) = [plain(held[:step]), plain(held[:answer])].map(&:to_s).reject(&:empty?).join("\n\n")

      # @return [Hash{String => String}] the session environment, with the run's name as the caller
      def named(held) = SessionCaller.environment(@session.session_environment, held)

      # @return [Hash{String => String}] only the caller name, which the session reads through its
      #   settings; the rest of the session environment is not forwarded there
      def caller_only(held) = SessionCaller.environment({}, held)

      def agent_listing(repo, agent)
        return { listed: true, note: "no agent named: the session runs the default agent" } unless agent

        names = @agents.names(repo)
        { listed: names.include?(agent), note: "agent #{agent} is not available in #{repo}; available: #{names.join(", ")}" }
      end

      def listed(id) = @listing.find(id) || raise(ConsoleCapture::Failure, "no session #{id} is listed")

      def session_line = SessionLine.new(command: @command, nice: niceness, hooks: @hooks)

      # The id a start printed, or why there is none.
      def session_id(result)
        raise ConsoleCapture::Failure, "#{@command} did not start a session: #{result.err.strip}" unless result.ok?

        result.out[SESSION_ID, 1] || raise(ConsoleCapture::Failure, "#{@command} named no session: #{result.out.strip}")
      end

      def niceness = @session.nice ? ["nice", "-n", @session.nice.to_s] : []

      # The look-up of whether a run's session is still listed, over the listing it shares. `now`
      # stands in for the clock, which also dates a session's start.
      def session_lookup(now)
        @clock = now || -> { Time.now.utc }
        @listing = ClaudeSessionListing.new(@command, shell: @shell, now: @clock)
        SessionLookup.new(@listing, grace: -> { @session.session_grace }, now: @clock)
      end

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
