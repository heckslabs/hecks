# frozen_string_literal: true

require_relative "pipeline_stages"
require_relative "pipeline_wiring"
require_relative "pipeline_web/server"
require_relative "pipeline_web/stream"
require_relative "pipeline_web/snapshot"

module Hecks
  module Adapters
    # The `Web` port's adapter: opens the board on 127.0.0.1 and answers `GET /`, `GET /api/state`
    # and the `GET /api/events` stream until it is stopped. Every answer is read from
    # {PipelineStages}; the one write is `POST /api/answer`, which runs `AgentRun.answer!` through
    # the launcher and nothing else.
    class PipelineWeb
      PAGE = File.expand_path("pipeline_web/page.html", __dir__)
      WIRING_PAGE = File.expand_path("pipeline_web/wiring.html", __dir__)
      SEQUENCE_PAGE = File.expand_path("pipeline_web/sequence.html", __dir__)
      DEFAULT_PORT = 4747
      ANSWER_SECONDS = 60

      # @param registry [Runtime::Registry, nil] handed to the readers
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `stages:` stands in for {PipelineStages}, `interval:` is the seconds
      #   between looks at the journal on a stream, `answerer:` a callable taking the launcher's
      #   arguments and answering its standard output (it stands in for the launcher)
      # @param root [String, nil] the checkout the readers and the launcher run in
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @root = root || Dir.pwd
        @stages = settings[:stages] || PipelineStages.new(registry: registry, root: root)
        @wiring = settings[:wiring] || PipelineWiring.new(registry: registry)
        @answerer = settings[:answerer] || ->(*args) { PipelineBoard::Probe.run(*args, chdir: @root, seconds: ANSWER_SECONDS) }
        @interval = settings.fetch(:interval, 1.0)
        @snapshot = PipelineBoard::Snapshot.new(source: @stages.method(:state), background: settings.fetch(:background, true))
      end

      # Sends a blocked session its answer by running `AgentRun.answer!` through the launcher, which
      # resumes the session with it. The command refuses an answer to a session that is not blocked
      # on a person, or one that says nothing; its refusal comes back as the reason.
      #
      # @param run [String] the AgentRun's key
      # @param answer [String] what the session is told
      # @return [Hash{Symbol => Boolean}] `answered:` true once the command has run
      # @raise [PipelineBoard::Unavailable] with the command's refusal
      def answer(run:, answer:)
        @answerer.call("exe/hecks", "AgentRun.answer!", "to=#{run}", "answer.value=#{answer}", "--wait")
        { answered: true }
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
