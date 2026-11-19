# frozen_string_literal: true

require "hecks/hecks/adapters/console_capture"
require "hecks/hecks/adapters/dispatching/work_items"

module Hecks
  module Adapters
    class FleetControl
      # The AgentRun ledger and the `PinnedRole` rows of a booted registry, read and never written.
      # A boot that holds no AgentRun ledger is refused by name, so no session is reported as
      # holding no run when the ledger was only not booted.
      class Ledger
        # The refusal of a boot that holds no AgentRun ledger, as `exe/hecks agents` boots Agents
        # alone.
        NO_LEDGER = "the AgentRun ledger is not booted here, so no session can be joined to its run: " \
                    "read with exe/hecks Fleet.<query>, which boots the Hecks domain"

        # @param registry [Runtime::Registry, nil] whose ledger and rows are read
        # @param runs [#call, nil] stand-in: answers `{ runs:, sessions:, pinned: }`
        def initialize(registry, runs: nil)
          @registry = registry
          @stand_in = runs
        end

        # @param session [String] the full session id
        # @return [Array(String, Hash), nil] the key and state of the run that holds the session
        # @raise [ConsoleCapture::Failure] when no AgentRun ledger is booted
        def run_of(session)
          key = facts[:sessions][session.to_s]
          key && [key, facts[:runs].fetch(key, {})]
        end

        # @param name [String] the session's listed name
        # @return [String, nil] the pinned role the name begins with
        def pinned_role(name) = facts[:pinned].find { |role| name.to_s.start_with?(role) }

        private

        def facts = (@facts ||= @stand_in ? @stand_in.call : booted)

        def booted
          raise ConsoleCapture::Failure, NO_LEDGER unless ledger?

          items = Dispatching::WorkItems.new(@registry)
          { runs: items.runs, sessions: items.run_sessions, pinned: items.pinned_roles || [] }
        end

        def ledger?
          hecks = @registry&.bluebook("Hecks")
          hecks ? hecks.aggregates.any? { |aggregate| aggregate.hecks_name == "AgentRun" } : false
        end
      end
    end
  end
end
