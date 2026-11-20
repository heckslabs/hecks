# frozen_string_literal: true

require_relative "../../rust_build/kernel_client"
require_relative "../../rust_build/kernel_input"
require_relative "../replay/engine/kernel"

module Hecks
  module Fuzzing
    module Differential
      # The Rust kernel as an engine over the host protocol (ADR 0189): one warm `--serve`
      # process per engine, and a named session of its own for each sequence. The fields the
      # serve session answers (`SERVED`) come from it; the rest of the wire view (refusals by
      # kind, queries, reactions, sagas) still comes from the per-domain batch run of the same
      # binary, the fallback until the serve session answers them too.
      class ServeEngine
        # The wire fields a serve session answers today.
        SERVED = %w[instances events dry_runs].freeze

        # The fact the kernel asks for when its identity script is spent (`run_keys.rs`).
        IDENTITY_FACT = "identity_generation"

        # @return [String] the kernel binary this engine runs
        attr_reader :binary

        # @param binary [String] a kernel built for one domain (`cargo build --features <domain>`)
        # @param batch [#call] the engine the unserved fields come from
        # @param connect [#call] opens a client from a binary and an answerer block
        def initialize(binary, batch: Fuzzing::Engine::Kernel.new(binary), connect: nil)
          @binary = binary
          @batch = batch
          @connect = connect || ->(path, answerer) { RustBuild::KernelClient.new(path, answerer) }
          @sequences = 0
        end

        # @param domain_path [String] the domain directory, whose generated IR feeds the tables
        # @param steps [Array<Hash>] the step list
        # @param identity [Array<String>, nil] the ids the identity port hands out, in order
        # @return [Hash] the batch output with the `SERVED` fields as the session answered them,
        #   and `"served"`, those field names
        # @raise [Engine::Kernel::Failed] when either run of the kernel fails
        def call(domain_path, steps, identity: nil)
          output = @batch.call(domain_path, steps, identity: identity)
          output.merge(served(domain_path, steps, identity), "served" => SERVED)
        end

        # Ends the serve process, if one is running.
        #
        # @return [void]
        def close
          @client&.close
          @client = nil
        end

        private

        def served(domain_path, steps, identity)
          @identity = Array(identity).dup
          session = "sequence-#{@sequences += 1}"
          client(domain_path).open_session(session)
          play(steps, session).merge("instances" => @client.call("instances" => true, "session" => session)["instances"])
        rescue RustBuild::KernelClient::Unreachable => e
          close
          raise Fuzzing::Engine::Kernel::Failed, "#{binary} --serve: #{e.message}"
        ensure
          @client&.close_session(session)
        end

        def play(steps, session)
          steps.each_with_object({ "events" => [], "dry_runs" => [] }) do |step, served|
            if step["dry_run"]
              served["dry_runs"] << @client.call(step.merge("session" => session))
            elsif step["verb"]
              served["events"].concat(Array(@client.call(step.merge("session" => session))["events"]))
            end
          end
        end

        # The hello goes through `call`: `KernelClient#hello` carries only `needs`, and the
        # session must also hold the query needs, command defaults and run-required verbs.
        def client(domain_path)
          @client ||= @connect.call(binary, method(:answer)).tap { |opened| hello(opened, domain_path) }
        end

        def hello(opened, domain_path)
          tables = RustBuild::KernelInput.tables_for(domain_path)
          answer = opened.call("hello" => tables.merge("protocols" => [1], "callbacks" => true))
          raise RustBuild::KernelClient::Unreachable, answer["error"] unless answer["ok"]
        end

        # Answers the identity fact from the sequence's script and leaves every other fact
        # unanswered, as the batch run does with no clock.
        def answer(fact, _type, _verb) = fact == IDENTITY_FACT ? @identity.shift : nil
      end
    end
  end
end
