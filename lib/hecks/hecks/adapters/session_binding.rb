# frozen_string_literal: true

require_relative "started_work"
require_relative "pinned_role_holders"

module Hecks
  module Adapters
    # Reads the facts an `AgentRun.Rebind` is judged on: whether the named session is live, and
    # which other started run is already bound to it. It decides nothing; the bluebook's
    # `BindTheRunToTheLiveSession` and `RefuseTheRebindOfADeadOrHeldSession` do. A session is live
    # by the {PinnedRoleHolders.live?} rule, so one idle between turns is not.
    class SessionBinding
      # @param listing [#find] the `claude agents` listing ({ClaudeSessionListing})
      # @param runs [#call] answers every `AgentRun` record
      def initialize(listing:, runs:)
        @listing = listing
        @runs = runs
      end

      # @param held [Hash] the `AgentRun` record: `run`, `session`, and `target` the named session
      # @return [Hash{Symbol => Object}] `alive:`, `bound:` the key of another started run on the
      #   session (empty when none), `held:` the session the run holds, `target:` the listed id of
      #   the named session, and `note:` that in words
      # @raise [ConsoleCapture::Failure] when the sessions cannot be listed
      def call(held)
        target = value(held, :target)
        entry = @listing.find(target)
        ids = entry ? [entry["id"], entry["sessionId"]].compact.map(&:to_s) : [target]
        facts(held, entry, (entry && entry["id"]).to_s.then { |id| id.empty? ? target : id }, bound_to(held, ids))
      end

      private

      def facts(held, entry, target, bound)
        alive = !entry.nil? && PinnedRoleHolders.live?(entry)
        { alive: alive, bound: bound, held: value(held, :session), target: target,
          note: note(held, entry, target, bound) }
      end

      def note(held, entry, target, bound)
        return "no session #{target} is listed, so run #{value(held, :run)} stays where it is" unless entry
        return "session #{target} is #{entry["state"]}, not live: a run is rebound only to a live session" unless
          PinnedRoleHolders.live?(entry)
        return "session #{target} is already bound to run #{bound}" unless bound.empty?

        "run #{value(held, :run)} moves from #{value(held, :session)} to #{target}"
      end

      def bound_to(held, ids)
        own = value(held, :run)
        found = @runs.call.find do |run|
          value(run, :run) != own && value(run, :status) == "started" && ids.include?(value(run, :session))
        end
        found ? value(found, :run) : ""
      end

      def value(record, name)
        found = StartedWork.value(record, name)
        (found.is_a?(Hash) ? found[:value] : found).to_s
      end
    end
  end
end
