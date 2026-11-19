# frozen_string_literal: true

require_relative "landed_since"
require_relative "orphaned_work"
require_relative "claude_sessions"

module Hecks
  module Adapters
    class Dispatching
      # The facts a {Settler} judges the ended sessions by, read from one filling's work items and
      # the machine's settings: what landed, whether `claude` can be run, which sessions are quiet,
      # which started items hold a place for nothing, and which items are filed stalls.
      module SettleRule
        module_function

        # @param items [WorkItems] the filling's work items
        # @param machine [Settings] the world's settings
        # @param repo [String, nil] the checkout whose landed commits are read
        # @param sessions [#quiet?, nil] a stand-in for the `claude` session listing, for a spec
        # @return [Hash{Symbol => Object}] the {Settler}'s `landed:`, `gone:`, `sessions:`,
        #   `orphans:` and `stall:` rule; `stall:` is left out for a stand-in that cannot answer it
        def of(items, machine, repo:, sessions: nil)
          { landed: LandedSince.new(items, repo: repo), gone: machine,
            sessions: sessions || ClaudeSessions.listing(machine),
            orphans: OrphanedWork.new(items, min_age: machine.run_gone_minutes * 60),
            stall: (->(key) { items.stall_item?(key) } if items.respond_to?(:stall_item?)) }
        end
      end
    end
  end
end
