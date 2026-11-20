# frozen_string_literal: true

require_relative "started_work"
require_relative "work_holder"
require_relative "dispatching/work_items"

module Hecks
  module Adapters
    # Reads which live session other than a run's own holds the run's pinned role, so the
    # `AgentRun` bluebook can refuse a second session of the role by name. It reports facts:
    # whether a `PinnedRole` row names the run's role, the session that holds it, and a note.
    #
    # A run's role is the part it plays: its `works_as`, else its `agent` (an answerer is an
    # orchestrator agent working as `answerer`). A session holds a role when a started run of the
    # role is bound to it, or when its listed name is the role, alone or followed by a separator
    # and no further word (`ORCHESTRATOR`, `orchestrator 2`, `orchestrator-3`), so
    # `orchestrator-owner` is another role. A session is live while `claude agents` lists it
    # `busy`, or `working` or `blocked`; one idle between turns is not.
    class PinnedRoleHolders
      # The listed states of a session that is live whatever its status says.
      LIVE_STATES = %w[working blocked].freeze

      # The facts of a run whose role no `PinnedRole` row names, or that no other session holds.
      NONE = { pinned_role: "", role_holder: "", role_note: "" }.freeze

      # @param registry [Runtime::Registry, nil] holds the AgentRun records and `PinnedRole` rows
      # @param listing [#entries] the `claude agents` listing ({ClaudeSessionListing})
      # @return [PinnedRoleHolders] the reader over that registry and listing; no role is pinned
      #   when the Agents bluebook is not booted
      def self.booted(registry, listing)
        items = Dispatching::WorkItems.new(registry)
        new(listing: listing, runs: -> { WorkHolder.new(registry).runs }, pinned: -> { items.pinned_roles || [] })
      end

      # @param listing [#entries] the `claude agents` listing ({ClaudeSessionListing})
      # @param runs [#call] answers every `AgentRun` record
      # @param pinned [#call] answers the roles the `PinnedRole` rows name
      def initialize(listing:, runs:, pinned:)
        @listing = listing
        @runs = runs
        @pinned = pinned
      end

      # @param held [Hash] the `AgentRun` record: `agent`, `works_as` and `session`
      # @return [Hash{Symbol => String}] `pinned_role:` the run's role when a row names it,
      #   `role_holder:` the id of another live session holding it, `role_note:` that in words;
      #   each empty when there is none
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
      def call(held)
        role = pinned_role(held)
        return NONE if role.empty?

        other = holders(role).reject { |entry| ids(entry).include?(value(held, :session)) }.first
        other ? held_by(role, other) : NONE.merge(pinned_role: role)
      end

      # @param held [Hash] an `AgentRun` record: `agent` and `works_as`
      # @return [String] the run's role when a `PinnedRole` row names it, else empty
      def pinned_role(held) = Array(@pinned.call).map(&:to_s).include?(role_of(held)) ? role_of(held) : ""

      # The live sessions of every pinned role, for a sweep; how many make a finding is the
      # bluebook's.
      #
      # @return [Hash{Symbol => Object}] `live_ids:` one `role: id id` line per role with a live
      #   session, and `most:` the largest count of live sessions any one role has
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
      def census
        live = live_ids.reject { |_, ids| ids.empty? }
        { live_ids: live.map { |role, ids| "#{role}: #{ids.join(" ")}" }.join("\n"), most: live.values.map(&:size).max || 0 }
      end

      # @param entry [Hash] a session as `claude agents` lists it
      # @return [Boolean] whether it is live: listed `busy`, or `working` or `blocked`
      def self.live?(entry) = entry["status"].to_s == "busy" || LIVE_STATES.include?(entry["state"].to_s)

      private

      def live_ids = Array(@pinned.call).map(&:to_s).to_h { |role| [role, holders(role).map { |entry| entry["id"].to_s }] }

      def role_of(record) = value(record, :works_as).then { |part| part.empty? ? value(record, :agent) : part }

      def holders(role)
        bound = bound_sessions(role)
        Array(@listing.entries).select { |entry| live?(entry) && (named?(entry, role) || ids(entry).intersect?(bound)) }
      end

      def bound_sessions(role)
        started = @runs.call.select { |run| value(run, :status) == "started" }
        started.select { |run| role_of(run) == role }.map { |run| value(run, :session) }
      end

      def live?(entry) = self.class.live?(entry)

      def named?(entry, role) = entry["name"].to_s.match?(/\A#{Regexp.escape(role)}(?:\z|[\s:_-]+(?![A-Za-z]))/i)

      def ids(entry) = [entry["id"], entry["sessionId"]].compact.map(&:to_s)

      def held_by(role, entry)
        id = entry["id"].to_s
        { pinned_role: role, role_holder: id,
          role_note: "pinned role #{role} already has a live session #{id} (#{entry["name"]}, #{entry["state"]}): " \
                     "a pinned role has one live session, so the owner stops the extra one (claude stop #{id})" }
      end

      def value(record, name)
        found = StartedWork.value(record, name)
        (found.is_a?(Hash) ? found[:value] : found).to_s
      end
    end
  end
end
