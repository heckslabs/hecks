# frozen_string_literal: true

require "hecks/hecks/adapters/claude_jobs"
require "hecks/agents/adapters/hand_run_hold"
require "hecks/runtime/asking"

module Hecks
  module Adapters
    # The standing seats among the listed sessions, for `HandRunWatch`: for each seat role the one
    # session listed under exactly that name (the pinned one, else the last listed), sighted with the
    # facts the bluebook judges by: what launched it and which session is registered under the key.
    #
    # It states facts and judges nothing: whether a sighted session is the seat, and whether it is
    # registered, are the `SeatSighting` policies'.
    class PinnedSeats
      # @param listing [#call] answers the listed sessions, as `claude agents` prints them
      # @param jobs [String, nil] the jobs directory (default `~/.claude/jobs`)
      # @param roles [#call, nil] stand-in: answers the seat roles
      # @param registered [#call, nil] stand-in: answers `[{run:, session:}]`, the registered hand runs
      def initialize(listing:, jobs: nil, roles: nil, registered: nil)
        @listing = listing
        @jobs = ClaudeJobs.new(directory: jobs)
        @roles = roles || -> { StandingRoles.read(Runtime::Asking.registry) }
        @registered = registered || -> { HandRunHold.new(registry: Runtime::Asking.registry).rows }
      end

      # Sights each seat's session that is not already the registered one.
      #
      # @return [Integer] how many sightings were recorded
      def sight
        held = @registered.call.to_h { |row| [row[:run].to_s, row[:session].to_s] }
        seats = Array(@roles.call).filter_map { |role| entry_for(role) && [role, entry_for(role)] }
        seats.count { |role, entry| sighted?(role, entry, held.fetch(role, "")) }
      end

      # The seat roles the Agents bluebook's `StandingSeat` rows name.
      module StandingRoles
        # @param registry [Runtime::Registry, nil] the booted registry
        # @return [Array<String>] the roles; none when the bluebook is not booted
        def self.read(registry)
          rows = registry && rows_of(registry.bluebook("Agents"))
          rows ? rows.members.map { |row| row[:role].to_s } : []
        end

        def self.rows_of(bluebook)
          role = bluebook&.aggregates&.find { |each| each.hecks_name == "Role" }
          role&.value_objects&.find { |object| object.hecks_name == "StandingSeat" }
        end
      end

      private

      def entry_for(role)
        named = @listing.call.select { |entry| entry["name"].to_s == role }
        named.find { |entry| pinned?(entry) } || named.last
      end

      def pinned?(entry) = @jobs.pinned_ids.any? { |id| full(entry).start_with?(id) }

      def full(entry) = (entry.key?("sessionId") ? entry["sessionId"] : entry["id"]).to_s

      def sighted?(role, entry, registered)
        id = full(entry)
        return false if id == registered

        Hecks::Agents::SeatSighting.sight!(session: { value: id }, name: { value: role },
                                           launched_by: { value: @jobs.launched_by(id) }, registered: { value: registered },
                                           message: { value: "seat-#{role}-#{id[0, 8]}" }, notice: { value: notice(role, id) },
                                           sender: { value: "hecks" }, kind: { value: "answer" })
        true
      end

      def notice(role, id) = "Your session id is now #{id}; it is registered under #{role}."
    end
  end
end
