require_relative "../nondeterministic"
require_relative "../../rust_build/kernel_client"
require_relative "../../rust_build/kernel_input"

module Hecks
  module Fuzzing
    module Engine
      # Runs a step list in a Rust kernel: one {RustBuild::KernelClient} connection, one named
      # session per call (`open`, the steps, `instances`, `close`), so a call starts from an empty
      # store. A step the session cannot take (a query, a validation) is left out and named in
      # the history's `:uncarried`; `:queries` and `:sagas` come back empty because the session
      # answers neither.
      class KernelEngine
        # The name of the session a call opens.
        SESSION = "sequence".freeze

        # @param binary [String] a kernel built for the domain (`cargo build --features <domain>`)
        def initialize(binary:)
          @binary = binary
        end

        # @param domain_path [String] the domain directory; its IR supplies defaults and needs
        # @param steps [Array<Hash>] the step list
        # @return [Hash] instances, events, refusals, dry_runs, empty queries and sagas, uncarried
        def call(domain_path, steps, **)
          client = connect(domain_path)
          client.call("open" => SESSION)
          play(client, steps)
        ensure
          client&.close
        end

        private

        def connect(domain_path)
          client = RustBuild::KernelClient.new(@binary, nil)
          answer = client.call("hello" => { "protocols" => [1] }.merge(RustBuild::KernelInput.tables_for(domain_path)))
          raise RustBuild::KernelClient::Unreachable, answer["error"] unless answer["ok"]

          client
        end

        def play(client, steps)
          history = { events: [], refusals: [], dry_runs: [], queries: [], sagas: [], uncarried: [] }
          steps.each { |step| record(history, step, client.call(step.merge("session" => SESSION))) if carried?(step, history) }
          history.merge(instances: instances(client))
        end

        def carried?(step, history)
          return true if step.key?("verb") || step.key?("dry_run")

          history[:uncarried] << step.keys.first
          false
        end

        def record(history, step, answer)
          return history[:dry_runs] << { verb: step["dry_run"], ok: answer["ok"] } if step.key?("dry_run")
          return history[:events].concat(answer["events"].map { |event| bare(event) }) if answer["ok"]

          history[:refusals] << { verb: step["verb"], kind: nil, error: answer["error"] }
        end

        def instances(client)
          bare(client.call("instances" => true, "session" => SESSION).fetch("instances"))
        end

        # The value without the fields no two runs share and without the kernel's `emitted_*` flags.
        def bare(value)
          case value
          when Hash  then value.reject { |key, _| dropped?(key) }.transform_values { |inner| bare(inner) }
          when Array then value.map { |inner| bare(inner) }
          else value
          end
        end

        def dropped?(key) = key.start_with?("emitted_") || Nondeterministic.names(:event).map(&:to_s).include?(key)
      end
    end
  end
end
