# frozen_string_literal: true

require "webrick"
require "rackup/handler/webrick"
require_relative "github_listening/secret_file"
require_relative "github_listening/receiver"

module Hecks
  module Adapters
    # The `Listening` port's adapter for `GithubWebhook`: reads the secret file, opens
    # `POST /github-webhook` on 127.0.0.1 and nothing else, and offers each signed delivery to
    # `GithubEvent.Record` in the registry it was booted with. It stamps a delivery with the time it
    # was taken; which kinds are kept, and that a delivery is kept once, the bluebook decides.
    class GithubListening
      # The only address the listener binds: a public path reaches it only through a proxy on
      # this machine.
      HOST = "127.0.0.1"

      # The command each delivery is offered to.
      RECORD = "Hecks::GithubEvent.Record"

      # @param registry [Runtime::Registry, nil] the booted registry deliveries are recorded in
      # @param aggregate [Bluebook::Aggregate, nil] `GithubWebhook`; unused
      # @param settings [Hash] `secret_path:` the secret file in place of {SecretFile::PATH}
      # @param root [String, nil] unused
      def initialize(registry: nil, aggregate: nil, settings: {}, root: nil)
        @registry = registry
        @secret_path = settings.fetch(:secret_path, SecretFile::PATH)
      end

      # Serves the receiver until the process is interrupted.
      #
      # @param held [Hash] `port:` the port to bind, as an Integer or `{value:}`
      # @return [Hash] `last:` why the listener ended
      # @raise [SecretFile::Missing] when the secret file is absent or empty; nothing is bound
      def listen(**held)
        server = open_at(plain(held[:port]))
        warn "GithubWebhook listening on http://#{HOST}:#{server.config[:Port]}#{Receiver::PATH} (Ctrl-C to stop)"
        trap("INT") { server.shutdown }
        server.start
        { last: { value: "stopped" } }
      end

      # The listener, bound and not yet started: `start` serves until `shutdown`.
      #
      # @param port [Integer] the port to bind; 0 binds a free one
      # @return [WEBrick::HTTPServer]
      # @raise [SecretFile::Missing] when the secret file is absent or empty; nothing is bound
      def open_at(port)
        app = receiver
        server = WEBrick::HTTPServer.new(BindAddress: HOST, Port: port, Logger: WEBrick::Log.new(File::NULL),
                                         AccessLog: [])
        server.mount("/", Rackup::Handler::WEBrick, app)
        server
      end

      # @return [Receiver] the rack app, signed with the secret file's secret
      # @raise [SecretFile::Missing] when the secret file is absent or empty
      def receiver = Receiver.new(secret: SecretFile.read(@secret_path), record: method(:record))

      # Records one delivery, stamped with when it was taken.
      #
      # @param facts [Hash{Symbol => Object}] the `Record` command's arguments but `received`
      # @return [Runtime::Dispatcher::Result]
      # @raise [StandardError] one of `Runtime::DOMAIN_REFUSALS` when the domain refuses it
      def record(facts)
        stamp = (Ports::Clock.now(@registry).to_r * 1_000_000).to_i
        Runtime::Dispatcher.new(@registry).dispatch_flat(RECORD, facts.merge(received: stamp))
      end

      private

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
