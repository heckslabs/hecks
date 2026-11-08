# frozen_string_literal: true

require "time"

module Hecks
  module Adapters
    class Sweeping
      # Ties a spare daemon's host process to the session that claimed it, from the daemon's log.
      #
      # The log records `spare spawned host pid=P` and then `claimed-spare S` when a session takes
      # that spare, so the host spawned just before a claim is the one the session runs in. A host
      # no claim follows is the daemon's warm spare or a stray, and traces to no session.
      class SpareTrace
        # One claim: the host pid, the session that took it and when the host was spawned.
        Claim = Struct.new(:pid, :session, :spawned_at)

        SPAWNED = /\A\[(?<at>[^\]]+)\] \[bg\] bg spare spawned host pid=(?<pid>\d+)/
        CLAIMED = /\[bg\] bg claimed-spare (?<session>[0-9a-f]{8})\b/

        # @param log [String] the daemon's log file
        def initialize(log:)
          @log = log
        end

        # @return [Hash{Integer => Claim}] each claimed host pid with its claim, newest winning
        def claims
          pending = nil
          File.foreach(@log, chomp: true).with_object({}) do |line, found|
            pending = spawn_of(line) || pending
            claim = CLAIMED.match(line)
            next unless claim && pending

            found[pending.pid] = Claim.new(pending.pid, claim[:session], pending.spawned_at)
            pending = nil
          end
        rescue SystemCallError
          {}
        end

        private

        def spawn_of(line)
          match = SPAWNED.match(line)
          match && Claim.new(match[:pid].to_i, nil, Time.parse(match[:at]))
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
