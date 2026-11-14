# frozen_string_literal: true

require_relative "../claude_executable"
require_relative "../claude_resolving_shell"
require_relative "../claude_session_listing"

module Hecks
  module Adapters
    class Dispatching
      # The sessions `claude agents` lists, which the settle asks about a run's session.
      module ClaudeSessions
        # @param machine [Settings] names where `claude` may be installed
        # @return [ClaudeSessionListing] the listing, run with the `claude` found on `PATH` or there
        def self.listing(machine)
          executable = ClaudeExecutable.new(candidates: machine.claude_candidates)
          ClaudeSessionListing.new(ClaudeExecutable::COMMAND, shell: ClaudeResolvingShell.new(executable: executable))
        end
      end
    end
  end
end
