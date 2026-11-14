# frozen_string_literal: true

require_relative "pipeline_stages"
require_relative "pipeline_wiring"
require_relative "pipeline_web/actions"
require_relative "pipeline_web/ended_run"
require_relative "pipeline_web/server"
require_relative "pipeline_web/stream"
require_relative "pipeline_web/pushed"
require_relative "pipeline_web/plan_page"
require_relative "pipeline_web/snapshot"

module Hecks
  module Adapters
    # The `Web` port's adapter: opens the board on 127.0.0.1 and answers `GET /`, `GET /api/state`
    # and the `GET /api/events` stream until it is stopped. Every answer is read from
    # {PipelineStages}; the one write is `POST /api/act`, which runs one step from {Actions} through
    # the launcher and nothing else.
    class PipelineWeb
      PAGE = File.expand_path("pipeline_web/page.html", __dir__)
      WIRING_PAGE = File.expand_path("pipeline_web/wiring.html", __dir__)
      SEQUENCE_PAGE = File.expand_path("pipeline_web/sequence.html", __dir__)
      AGENTS_PAGE = File.expand_path("pipeline_web/agents.html", __dir__)
      DIAGRAMS_PAGE = File.expand_path("pipeline_web/diagrams.html", __dir__)
      STREAM_SCRIPT = File.expand_path("pipeline_web/stream.js", __dir__)
      ANSWER_SCRIPT = File.expand_path("pipeline_web/answer.js", __dir__)
      DEFAULT_PORT = 4747
      ACT_SECONDS = 120

      # @param registry [Runtime::Registry, nil] handed to the readers
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `stages:` stands in for {PipelineStages}, `hub:` and `tap:` stand in
      #   for the journal follower and its file, `journal:` for the source it follows, `launcher:`
      #   a callable taking the launcher's arguments and answering its standard output (it stands
      #   in for the launcher)
      # @param root [String, nil] the checkout the readers and the launcher run in
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @root = root || Dir.pwd
        @launcher_root = ENV.fetch("PIPELINE_BOARD_LAUNCHER_ROOT", @root)
        @stages = settings[:stages] || PipelineStages.new(registry: registry, root: root)
        @wiring = settings[:wiring] || PipelineWiring.new(registry: registry)
        @launcher = settings[:launcher] || PipelineBoard::Actions.launcher(@root, ACT_SECONDS)
        @snapshot = PipelineBoard::Snapshot.kept_small(source: @stages.method(:state), registry: registry, settings: settings)
        @pushed = PipelineBoard::Pushed.new(stages: @stages, settings: settings)
      end

      # Stops following the journal and reading the state; the server calls it when it stops.
      def close = [@pushed, @snapshot].each(&:stop)

      # Runs one step the page asked for, through the launcher. The launcher's own command refuses
      # what it should (an answer to a session not blocked on a person, a push without confirm);
      # its refusal
      # comes back as the reason.
      #
      # @param action [String] a step from {Actions}
      # @param fields [Hash{Symbol => String}] the step's fields
      # @param confirm [Boolean] whether the page confirmed the step
      # @return [Hash{Symbol => String}] `ran:` the launcher command the step ran
      # @raise [PipelineBoard::Unavailable] with why the step did not run
      def act(action:, fields:, confirm:)
        action, fields = prepared(action, fields)
        argv = PipelineBoard::Actions.argv(action, fields, confirm: confirm)
        program = PipelineBoard::Actions.program(action)
        stdin = action == "reply" ? "#{fields[:text]}\r" : nil
        first = PipelineBoard::Actions.before(action, fields)
        ended = first && !PipelineBoard::EndedRun.checked?(@launcher, @launcher_root, program, first)
        return instead(action, fields, confirm) if ended

        @launcher.call(program, *argv, chdir: @launcher_root, stdin: stdin)
        @snapshot.refresh_now if action == "reply" || PipelineBoard::PruningStanding::STEPS.include?(action)
        { ran: "#{program} #{argv.first}" }
      end

      # The run a step names has ended. When the step declares an `ended` step and the run's session
      # still waits on a person, that step sends the text to the session; otherwise the step is
      # refused by name and the page keeps the text.
      def instead(action, fields, confirm)
        step = PipelineBoard::Actions.ended(action)
        waiting = PipelineBoard::EndedRun.waiting(step, @snapshot.latest[:sessions], fields[:target])
        act(action: step, fields: fields.merge(target: waiting[:id]), confirm: confirm)
      end

      # The step the page asked for, with the fields the launcher needs. An auto reply becomes a
      # reply; a reply and a discard read the session's own record first; a pause of a pruner with
      # no seat becomes a hold, which seats it paused.
      def prepared(action, fields)
        action = PipelineBoard::PruningStanding.step(action, @snapshot.latest[:pruning])
        return ["reply", auto_reply(fields)] if action == "auto_reply"
        return [action, resumable(fields)] if action == "reply"
        return [action, discardable(fields)] if action == "discard"
        return [action, fields.merge(repo: @launcher_root)] if action == "review"
        return [action, fields.merge(repo: @launcher_root, key: "plan-#{Time.now.to_i}")] if action == "plan"

        [action, fields]
      end

      # A reply resumes the blocked session the page named, in the session's own directory. The
      # board takes the session's id and directory from its own state, never from the page, and
      # refuses a session it does not report as blocked.
      #
      # @param fields [Hash{Symbol => String}] the request's fields, with `target` the session's id
      # @return [Hash{Symbol => String}] the fields with the session's resume id and directory
      # @raise [PipelineBoard::Unavailable] when the session is not blocked or cannot be resumed
      def resumable(fields)
        row = blocked_session(fields[:target])
        raise PipelineBoard::Unavailable, "no resumable blocked session #{fields[:target]}" unless row

        fields.merge(attach: row[:attach])
      end

      # A discard names the session's own state, read from the board, never from the page; the
      # bluebook refuses a state it does not allow.
      #
      # @param fields [Hash{Symbol => String}] the request's fields, with `target` the session's id
      # @return [Hash{Symbol => String}] the fields with `condition` set to the session's state
      # @raise [PipelineBoard::Unavailable] when no session with that id is on the board
      def discardable(fields)
        row = Array(@snapshot.latest[:sessions]).find { |found| found[:id] == fields[:target] }
        raise PipelineBoard::Unavailable, "no session #{fields[:target]} on the board" unless row

        fields.merge(condition: row[:state].to_s)
      end

      # The answers the board gives on its own, by the kind a session tagged its question with.
      # Owner decisions have no kind here, so no answer is given for them.
      AUTO_REPLIES = { "confirm" => "yes", "retry" => "retry" }.freeze

      # @param fields [Hash{Symbol => String}] the request's fields, with `target` the session's id
      # @return [Hash{Symbol => String}] `target` and the reply text for the session's question kind
      # @raise [PipelineBoard::Unavailable] when the session is not blocked or has no answer kind
      def auto_reply(fields)
        row = blocked_session(fields[:target])
        raise PipelineBoard::Unavailable, "no blocked session #{fields[:target]}" unless row

        text = AUTO_REPLIES[row[:question_kind].to_s]
        kind = row[:question_kind].to_s.empty? ? "no kind" : row[:question_kind]
        raise PipelineBoard::Unavailable, "#{kind} is not auto-answered" unless text

        { target: fields[:target], text: text }
      end

      # @return [Hash, nil] the blocked session with this id, when it carries a resume id and a
      #   directory
      def blocked_session(id)
        Array(@snapshot.latest[:sessions]).find do |found|
          found[:id] == id && found[:status] == "blocked" && !found[:attach].to_s.empty?
        end
      end

      # Serves the board until interrupted.
      #
      # @param held [Hash] the `PipelineBoard` record: `port`
      # @return [Hash{Symbol => Hash}] `last:` why the server ended
      def listen(**held)
        port = held[:port].is_a?(Hash) ? held[:port][:value] : held[:port]
        server = open_at(port)
        warn "PipelineBoard listening on http://#{server.address}:#{server.port}/ (Ctrl-C to stop)"
        trap("INT") { server.stop }
        server.join
        { last: { value: "stopped" } }
      end

      # @param port [Integer, nil] 0 binds a free port; nil the board's default
      # @return [PipelineBoard::Server] a running server
      def open_at(port)
        @snapshot.start
        @pushed.start
        PipelineBoard::Server.new(port: port || DEFAULT_PORT, app: self).start
      end

      # @return [String] the page, with each pushed tile drawn into its place, so it reads whole
      #   with the stream off
      def page = @pushed.page(File.read(PAGE))

      # @return [Hash] every section the page shows
      def state = @snapshot.latest

      # @return [String] the wiring diagram's page
      def wiring_page = File.read(WIRING_PAGE)

      # @param key [String] an AgentRun's key or its session id
      # @return [Hash, nil] what `/api/runs/<key>` answers; nil when no run has that key
      # @raise [PipelineBoard::Unavailable] when the run records cannot be read
      def run_detail(key) = @stages.run_detail(key)

      # @param key [String] a SendTrain run key
      # @return [Hash, nil] what `/api/trains/<key>` answers; nil when no boarding has that key
      # @raise [PipelineBoard::Unavailable] when the boarding cannot be read
      def train_detail(key) = @stages.train_detail(key)

      # @return [String] the sequence diagram's page
      def sequence_page = File.read(SEQUENCE_PAGE)

      # @return [String] the agents' page: who hands work to whom, and what each role is doing
      def agents_page = File.read(AGENTS_PAGE)

      # @return [String] the diagrams' page: the wiring and sequence diagrams, one at a time
      def diagrams_page = File.read(DIAGRAMS_PAGE)

      # @return [String] the script every page loads to share one event stream per browser
      def stream_script = File.read(STREAM_SCRIPT)

      # @return [String] the script that answers a session waiting on you, shared by the pages
      def answer_script = File.read(ANSWER_SCRIPT)

      # @return [Hash] the wiring graph (`nodes` and `edges`) with its `digest`, as the bluebook
      #   files declare it now, or `{unknown: reason}`
      def wiring
        @wiring.reading
      rescue PipelineBoard::Unavailable => e
        { unknown: e.message }
      end

      # Yields each event the held state lists once and again when its reactions change, the state
      # whenever it changes, the wiring's digest whenever the bluebooks are drawn differently, and
      # the HTML of each tile a journal line changed, until the reader goes away. It acts when the
      # journal grows, not on a clock.
      #
      # @yieldparam event [Hash] an event row, an `unknown` note, a `state` hash, a `wiring` digest,
      #   a `tile` fragment or a heartbeat
      def stream(&)
        PipelineBoard::Stream.new(hub: @pushed.hub, state: method(:state), wiring: method(:wiring)).each(&)
      end
    end
  end
end
