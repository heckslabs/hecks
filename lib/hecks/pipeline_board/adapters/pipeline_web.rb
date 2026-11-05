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
        @stages = settings[:stages] || PipelineStages.new(registry: registry, root: root)
        @wiring = settings[:wiring] || PipelineWiring.new(registry: registry)
        @launcher = settings[:launcher] || ->(*args) { PipelineBoard::Probe.run(*args, chdir: @root, seconds: ACT_SECONDS) }
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
        argv = PipelineBoard::Actions.argv(action, fields, confirm: confirm)
        @launcher.call("exe/hecks", *argv)
        { ran: argv.first }
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
