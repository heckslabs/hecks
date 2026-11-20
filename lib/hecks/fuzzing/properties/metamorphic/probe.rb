# frozen_string_literal: true

require_relative "../../../rust_build/kernel_client"
require_relative "../../../rust_build/kernel_input"

module Hecks
  module Fuzzing
    module Properties
      module Metamorphic
        # A connection to a kernel's `--serve` host protocol (ADR 0189) that a metamorphic property
        # drives: it opens fresh named sessions, sends a domain's verb and dry-run steps into them,
        # and reads `instances`, `snapshot` and `restore` back. Nothing else of the kernel is read.
        #
        # The kernel asks for an id through the `identity_generation` callback when a command
        # needs a run key. Each session answers from its own id script when it was given one, and
        # otherwise mints `id-1`, `id-2`, ... from a counter of its own, so two sessions that play
        # the same steps receive the same ids. The ids each message consumed are recorded with its
        # reply, so a later session can be handed exactly the ids an earlier one used.
        class Probe
          # The fact the kernel asks for when it mints a run key (`run_keys.rs`).
          IDENTITY_FACT = "identity_generation"

          # The keys of a step the serve session reads; a query or seed step is not played.
          STEP_KEYS = %w[verb dry_run args role actor_id occurred_at].freeze

          # Raised when the kernel will not open a session or greet the probe.
          class Refused < StandardError; end

          # One message sent: the message, the kernel's reply and the ids it consumed.
          Played = Struct.new(:message, :reply, :ids, keyword_init: true) do
            # @return [Boolean] whether the kernel accepted the message
            def ok? = reply["ok"] == true

            # @return [Boolean] whether the message was a command dispatch
            def verb? = message.key?("verb")
          end

          # Connects to a kernel binary built for the domain, greeted with the domain's IR tables.
          #
          # @param binary [String] a kernel built for one domain (`cargo build --features <domain>`)
          # @param domain_path [String] the domain directory, whose generated IR feeds the tables
          # @param wrap [#call, nil] takes the client and answers the client the probe talks to
          #   (a planted fault, see {Faults}); the client itself when nil
          # @return [Probe] greeted and ready to open sessions
          # @raise [Refused] when the kernel refuses the hello
          def self.for(binary, domain_path, wrap: nil)
            connect = lambda do |answerer|
              client = RustBuild::KernelClient.new(binary, answerer)
              wrap ? wrap.call(client) : client
            end
            new(connect, RustBuild::KernelInput.tables_for(domain_path))
          end

          # The steps a serve session can play: verb and dry-run steps, cut to the keys it reads.
          #
          # @param steps [Array<Hash>] a step list in the shape of `spec/corpus/*.json`
          # @return [Array<Hash>] the playable steps, in order
          def self.playable(steps)
            steps.filter_map { |step| step.slice(*STEP_KEYS) if step.key?("verb") || step.key?("dry_run") }
          end

          # The dry run of a verb step: the same arguments and caller, not dispatched.
          #
          # @param step [Hash] a verb step
          # @return [Hash] the dry-run message
          def self.dry_run_of(step) = step.except("verb").merge("dry_run" => step.fetch("verb"))

          # @param connect [#call] takes the answerer and answers a host-protocol client
          # @param tables [Hash] the hello tables the host builds from the IR
          def initialize(connect, tables)
            @client = connect.call(method(:answer))
            @scripts = {}
            @opened = 0
            greet(tables)
          end

          # Opens a fresh session for the block and closes it after.
          #
          # @param ids [Array<String>, nil] the ids the session hands out, in order; minted when nil
          # @yieldparam name [String] the session's name
          # @return [Object] what the block returns
          # @raise [Refused] when the kernel will not open the session
          def session(ids: nil)
            name = open_session(ids)
            yield name
          ensure
            @client.call("close" => name) if name
          end

          # Sends one step into a session and records the ids it consumed.
          #
          # @param name [String] an open session
          # @param message [Hash] a verb, dry-run, snapshot or restore message
          # @return [Played] the message, the reply and the ids consumed
          def send_step(name, message)
            @current = name
            @consumed = []
            reply = @client.call(message.merge("session" => name))
            Played.new(message: message, reply: reply, ids: @consumed)
          ensure
            @current = nil
          end

          # Plays steps into a session, one message each.
          #
          # @param name [String] an open session
          # @param steps [Array<Hash>] playable steps
          # @return [Array<Played>] what each step answered
          def play(name, steps) = steps.map { |step| send_step(name, step) }

          # @param name [String] an open session
          # @return [Hash{String => Array<Hash>}] the session's records, by aggregate
          def instances(name) = @client.call("instances" => true, "session" => name).fetch("instances", {})

          # Ends the connection.
          #
          # @return [void]
          def close = @client.close

          private

          def greet(tables)
            answer = @client.call("hello" => tables.merge("protocols" => [1], "callbacks" => true))
            raise Refused, "the kernel refused the hello: #{answer["error"]}" unless answer["ok"]
          end

          def open_session(ids)
            name = "probe-#{@opened += 1}"
            answer = @client.call("open" => name)
            raise Refused, "the kernel did not open #{name}: #{answer["error"]}" unless answer["ok"]

            @scripts[name] = { ids: ids&.dup, minted: 0 }
            name
          end

          # Answers the identity fact from the session's script or its counter; every other fact
          # goes unanswered, as a batch run with no clock leaves it.
          def answer(fact, _type, _verb)
            return nil unless fact == IDENTITY_FACT && @current

            script = @scripts.fetch(@current)
            (script[:ids] ? script[:ids].shift : "id-#{script[:minted] += 1}").tap { |id| @consumed << id }
          end
        end
      end
    end
  end
end
