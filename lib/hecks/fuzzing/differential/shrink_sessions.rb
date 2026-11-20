# frozen_string_literal: true

require "timeout"
require_relative "serve_engine"
require_relative "wire_comparison"
require_relative "../replay"

module Hecks
  module Fuzzing
    module Differential
      # Judges shrink candidates of a Ruby-vs-kernel finding in fresh named sessions of one warm
      # `--serve` kernel, so a candidate costs a session instead of a process. It answers only the
      # fields a session serves (`ServeEngine::SERVED`), so it judges only a finding whose
      # signature names nothing else ({servable?}); the shrinker that asks it stays unchanged.
      class ShrinkSessions
        # Raised by {open} when the binary will not speak the host protocol in time.
        class Unserved < StandardError; end

        # Seconds the first hello may take before the binary is taken not to serve: a binary that
        # reads its whole input before answering would otherwise wait for it forever.
        HELLO_WAIT = 3

        # The batch half of `ServeEngine`, answering nothing, so no process runs per candidate.
        NO_BATCH = ->(_domain_path, _steps, **_options) { {} }

        CONNECT = ->(binary, answerer) { RustBuild::KernelClient.new(binary, answerer) }

        # @param signature [Set<String>] a finding's `Shrinker.signature`
        # @return [Boolean] whether every key names a field a serve session answers
        def self.servable?(signature)
          !signature.empty? && signature.all? { |key| ServeEngine::SERVED.include?(key.split(":").first) }
        end

        # Starts the kernel and says hello at once, so a binary that cannot serve is refused here
        # by name and not as a failed candidate.
        #
        # @param binary [String] a kernel built for the domain's Cargo feature
        # @param differ [Object] the duck-typed `RustConformanceHelpers` interface
        # @param domain_path [String] the domain directory
        # @param connect [#call] opens a client from a binary and an answerer block
        # @return [ShrinkSessions] connected
        # @raise [Unserved] when the hello is refused or takes longer than {HELLO_WAIT}
        def self.open(binary, differ:, domain_path:, connect: CONNECT)
          opened = []
          recording = ->(path, answerer) { connect.call(path, answerer).tap { |client| opened << client } }
          engine = ServeEngine.new(binary, batch: NO_BATCH, connect: recording)
          Timeout.timeout(HELLO_WAIT) { engine.call(domain_path, []) }
          new(engine, differ: differ, domain_path: domain_path)
        rescue Timeout::Error, Engine::Kernel::Failed => e
          opened.each(&:close)
          raise Unserved, "#{binary} does not serve the host protocol: #{e.message}"
        end

        # @param engine [ServeEngine] connected, with a batch that answers nothing
        # @param differ [Object] the duck-typed `RustConformanceHelpers` interface
        # @param domain_path [String] the domain directory
        def initialize(engine, differ:, domain_path:)
          @engine = engine
          @differ = differ
          @domain_path = domain_path
        end

        # Replays `steps` on Ruby and in a fresh session, with no identity script, as
        # `Differential.diff` does, and compares the served fields as it compares them.
        #
        # @param steps [Array<Hash>] a shrink candidate
        # @return [Array<Hash>] one `{field:, ruby:, rust:}` entry per disagreeing served field
        # @raise [Engine::Kernel::Failed] when the kernel stops answering
        def divergences(steps)
          ruby = Replay.call(@domain_path, steps, self_consistency: false)
          served = @engine.call(@domain_path, steps)
          @differ.strip_emitted_flags!(served["instances"])
          @differ.strip_occurred_at!(served["events"])
          WireComparison.served_divergences(WireComparison.ruby_view(ruby), served)
        end

        # Ends the kernel.
        #
        # @return [void]
        def close = @engine.close
      end
    end
  end
end
