# frozen_string_literal: true

module Hecks
  module Fuzzing
    module Properties
      module Metamorphic
        # Planted engine bugs, the mutation harness's counterpart for the metamorphic properties.
        # `Mutation::Operators` plants bugs in a bluebook, and a correct kernel runs a mutated
        # bluebook self-consistently, so no metamorphic property can fail on those. These plant
        # the bug in the engine instead: each wraps the host-protocol client and answers as a
        # kernel with that bug would. A property earns its place by failing on the fault
        # `CATALOG` names for it.
        module Faults
          # A client that forwards every message unchanged, the base each fault overrides.
          class Honest
            # @param client [#call, #close] a host-protocol client
            def initialize(client)
              @client = client
            end

            # Sends one message.
            #
            # @param message [Hash] a protocol message
            # @return [Hash] the reply
            def call(message) = @client.call(message)

            # Ends the connection.
            #
            # @return [void]
            def close = @client.close
          end

          # A refused dispatch still writes: the session's next `instances` reply holds a record
          # the refusal left behind.
          class RefusalWrites < Honest
            # A record no command created.
            PLANTED = { "id" => "planted-by-a-refusal" }.freeze

            # Sends a message, remembering a refusal and planting its record in the next read.
            #
            # @param message [Hash] a protocol message
            # @return [Hash] the reply; an `instances` reply after a refusal holds the plant
            def call(message)
              reply = super
              return plant(reply) if message.key?("instances") && @refused

              @refused = message.key?("verb") && reply["ok"] == false
              reply
            end

            private

            def plant(reply)
              instances = reply.fetch("instances", {})
              reply.merge("instances" => instances.merge("Planted" => [*instances["Planted"], PLANTED]))
            end
          end

          # A dry run dispatches: the dry-run message goes to the kernel as the real command.
          class DryRunDispatches < Honest
            # Sends a dry run as its verb, every other message unchanged.
            #
            # @param message [Hash] a protocol message
            # @return [Hash] the reply
            def call(message)
              return super unless message.key?("dry_run")

              super(message.except("dry_run").merge("verb" => message["dry_run"]))
            end
          end

          # A dry run answers the opposite of what the command would do.
          class DryRunFlips < Honest
            # Sends a message, inverting a dry run's `ok`.
            #
            # @param message [Hash] a protocol message
            # @return [Hash] the reply
            def call(message)
              reply = super
              message.key?("dry_run") ? reply.merge("ok" => reply["ok"] != true) : reply
            end
          end

          # A restore answers ok and puts nothing back.
          class RestoreIgnored < Honest
            # Swallows a restore, every other message unchanged.
            #
            # @param message [Hash] a protocol message
            # @return [Hash] the reply
            def call(message) = message.key?("restore") ? { "ok" => true } : super
          end

          # Every session is the default session: opening and closing do nothing, and every
          # message runs in one store.
          class SharedStore < Honest
            # Sends a message without its session; answers an open or close itself.
            #
            # @param message [Hash] a protocol message
            # @return [Hash] the reply
            def call(message)
              return { "ok" => true } if message.key?("open") || message.key?("close")

              super(message.except("session"))
            end
          end

          # A closed session's store is recycled: the next session opened starts with the records
          # the closed one last held, beside its own.
          class RecycledStore < Honest
            # Sends a message, carrying a closed session's records into the next one opened.
            #
            # @param message [Hash] a protocol message
            # @return [Hash] the reply, with inherited records in an `instances` reply
            def call(message)
              reply = super
              (@held ||= {})[message["open"]] = @left if message.key?("open")
              @left = @read&.delete(message["close"]) if message.key?("close")
              message.key?("instances") ? inherit(message["session"], reply) : reply
            end

            private

            def inherit(session, reply)
              inherited = @held&.fetch(session, nil) || {}
              merged = reply.fetch("instances", {}).merge(inherited) { |_aggregate, own, old| combined(own, old) }
              (@read ||= {})[session] = merged
              reply.merge("instances" => merged)
            end

            # The kernel keys an aggregate's records by id; an inherited record keeps a key of its
            # own, so a session holding the same ids still reads twice the records.
            def combined(own, old)
              return Array(own) + Array(old) unless own.is_a?(Hash) && old.is_a?(Hash)

              own.merge(old.transform_keys { |id| "recycled:#{id}" })
            end
          end

          # Each fault, the property it must make fail, and what it plants.
          CATALOG = {
            refusal_writes:     { trips: :refusals_leave_the_store_identical, fault: RefusalWrites,
                                          plants: "a refused command leaves a record behind" },
            dry_run_dispatches: { trips: :dry_runs_change_nothing, fault: DryRunDispatches,
                                          plants: "a dry run is dispatched for real" },
            dry_run_flips:      { trips: :dry_run_agrees_with_dispatch, fault: DryRunFlips,
                                          plants: "a dry run answers the opposite of the dispatch" },
            restore_ignored:    { trips: :snapshot_restore_is_identity, fault: RestoreIgnored,
                                          plants: "restore answers ok and restores nothing" },
            shared_store:       { trips: :sessions_never_share_a_store, fault: SharedStore,
                                          plants: "every session runs in the default store" },
            recycled_store:     { trips:  %i[journal_replay_is_identity same_steps_same_history],
                                  fault:  RecycledStore,
                                  plants: "a new session starts with the last closed session's records" }
          }.freeze

          module_function

          # The wrapper that plants one fault, for `Probe.for(..., wrap:)`.
          #
          # @param name [Symbol] a key of `CATALOG`
          # @return [#call] takes a client and answers it wrapped in the fault
          # @raise [KeyError] when no fault has that name
          def wrap(name) = CATALOG.fetch(name).fetch(:fault).method(:new)

          # @param name [Symbol] a key of `CATALOG`
          # @return [Array<Symbol>] the properties the fault must make fail
          def trips(name) = Array(CATALOG.fetch(name).fetch(:trips))
        end
      end
    end
  end
end
