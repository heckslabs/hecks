# frozen_string_literal: true

require_relative "pipeline_stages"
require_relative "pipeline_wiring"
require_relative "pipeline_web/server"
require_relative "pipeline_web/stream"
require_relative "pipeline_web/snapshot"
require_relative "pipeline_web/flag_watch"

module Hecks
  module Adapters
    # The `Web` port's adapter: opens the board on 127.0.0.1 and answers `GET /`, `GET /api/state`
    # and the `GET /api/events` stream until it is stopped. Every answer is read from
    # {PipelineStages}; the one write is the red flag's sync, which {PipelineBoard::FlagWatch} runs
    # every minute while {#listen} serves, so the flag follows CI with no agent session open.
    class PipelineWeb
      PAGE = File.expand_path("pipeline_web/page.html", __dir__)
      WIRING_PAGE = File.expand_path("pipeline_web/wiring.html", __dir__)
      SEQUENCE_PAGE = File.expand_path("pipeline_web/sequence.html", __dir__)
      DEFAULT_PORT = 4747

      # @param registry [Runtime::Registry, nil] handed to the readers
      # @param aggregate [Object, nil] unused
      # @param settings [Hash] `stages:` stands in for {PipelineStages}, `interval:` is the seconds
      #   between looks at the journal on a stream
      # @param root [String, nil] the checkout the readers run in
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @stages = settings[:stages] || PipelineStages.new(registry: registry, root: root)
        @wiring = settings[:wiring] || PipelineWiring.new(registry: registry)
        @interval = settings.fetch(:interval, 1.0)
        @root = root
        @watch_flag = settings.fetch(:watch_flag, true)
        @snapshot = PipelineBoard::Snapshot.new(source: @stages.method(:state), background: settings.fetch(:background, true))
      end

      # Serves the board until interrupted, syncing the red flag with CI meanwhile.
      #
      # @param held [Hash] the `PipelineBoard` record: `port`
      # @return [Hash{Symbol => Hash}] `last:` why the server ended
      def listen(**held)
        port = held[:port].is_a?(Hash) ? held[:port][:value] : held[:port]
        flag_watch = start_flag_watch
        server = open_at(port)
        warn "PipelineBoard listening on http://#{server.address}:#{server.port}/ (Ctrl-C to stop)"
        trap("INT") { server.stop }
        server.join
        flag_watch&.stop
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

      # Yields each event of the journal once and again when its reactions change, until the reader
      # goes away.
      #
      # @yieldparam event [Hash] an event row, an `unknown` note or a heartbeat
      def stream(&)
        PipelineBoard::Stream.new(feed: @stages.method(:feed), interval: @interval).each(&)
      end

      private

      # @return [PipelineBoard::FlagWatch, nil] the started sync, or nil when the board opted out
      def start_flag_watch
        return unless @watch_flag

        PipelineBoard::FlagWatch.new(root: @root || Dir.pwd).start
      end
    end
  end
end
