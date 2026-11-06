# frozen_string_literal: true

require_relative "pipeline_stages"
require_relative "pipeline_wiring"
require_relative "pipeline_web/actions"
require_relative "pipeline_web/server"
require_relative "pipeline_web/stream"
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
      DEFAULT_PORT = 4747
      ACT_SECONDS = 120

      # @param registry [Runtime::Registry, nil] handed to the readers
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `stages:` stands in for {PipelineStages}, `interval:` is the seconds
      #   between looks at the journal on a stream, `launcher:` a callable taking the launcher's
      #   arguments and answering its standard output (it stands in for the launcher)
      # @param root [String, nil] the checkout the readers and the launcher run in
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @root = root || Dir.pwd
        @launcher_root = ENV.fetch("PIPELINE_BOARD_LAUNCHER_ROOT", @root)
        @stages = settings[:stages] || PipelineStages.new(registry: registry, root: root)
        @wiring = settings[:wiring] || PipelineWiring.new(registry: registry)
        @launcher = settings[:launcher] || lambda do |*args, chdir: @root, stdin: nil|
          PipelineBoard::Probe.run(*args, chdir: chdir, seconds: ACT_SECONDS, stdin: stdin)
        end
        @interval = settings.fetch(:interval, 1.0)
        @snapshot = PipelineBoard::Snapshot.new(source: @stages.method(:state), background: settings.fetch(:background, true))
      end

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
        check_first(program, first) if first
        @launcher.call(program, *argv, chdir: @launcher_root, stdin: stdin)
        @snapshot.refresh_now if action == "reply"
        { ran: "#{program} #{argv.first}" }
      end

      # Runs the command a step names to run first (an answer checks the run), so the run holds the
      # job's own state before the step's rule is asked. Its refusal ends the step.
      def check_first(program, argv)
        @launcher.call(program, *argv, chdir: @launcher_root, stdin: nil)
      rescue PipelineBoard::Unavailable => e
        raise PipelineBoard::Unavailable, "the session could not be checked first: #{e.message}"
      end

      # The step the page asked for, with the fields the launcher needs. An auto reply becomes a
      # reply; a reply and a discard read the session's own record first.
      def prepared(action, fields)
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
        PipelineBoard::Server.new(port: port || DEFAULT_PORT, app: self).start
      end

      # @return [String] the page
      def page = File.read(PAGE)

      # @return [Hash] every section the page shows
      def state = @snapshot.latest

      # @return [String] the wiring diagram's page
      def wiring_page = File.read(WIRING_PAGE)

      # @return [String] the sequence diagram's page
      def sequence_page = File.read(SEQUENCE_PAGE)

      # @return [String] the agents' page: who hands work to whom, and what each role is doing
      def agents_page = File.read(AGENTS_PAGE)

      # @return [Hash] the wiring graph (`nodes` and `edges`), or `{unknown: reason}`
      def wiring
        @wiring.graph
      rescue PipelineBoard::Unavailable => e
        { unknown: e.message }
      end

      # Yields each event of the journal once and again when its reactions change, and the state
      # whenever it changes, until the reader goes away.
      #
      # @yieldparam event [Hash] an event row, an `unknown` note, a `state` hash or a heartbeat
      def stream(&)
        PipelineBoard::Stream.new(feed: @stages.method(:feed), state: method(:state), interval: @interval).each(&)
      end
    end
  end
end
