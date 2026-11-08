# frozen_string_literal: true

module Hecks
  module Adapters
    class Sweeping
      # Decides, for each spare daemon host, whether a sweep may stop it. A host is stopped only
      # when the daemon's log traces it to a session that was removed, that session is not listed,
      # and the process started when the log says that host was spawned (so a reused pid is not
      # mistaken for it). Every other host is kept, with the reason.
      class SparePlan
        # One host and the verdict on it.
        Verdict = Struct.new(:host, :session, :stop, :why) do
          # @return [String] the verdict on one line
          def line = "#{stop ? "stop" : "keep"}  pid #{host.pid}  #{session || "untraced"}  #{why}"
        end

        # How far a process's start may be from its logged spawn, in seconds.
        SKEW = 120

        # @param table [ProcessTable] the process table
        # @param claims [Hash{Integer => SpareTrace::Claim}] the log's claims by host pid
        # @param removed [Array<String>] the short ids of the removed sessions
        # @param listed [Array<String>] the short ids of the sessions still listed
        def initialize(table:, claims:, removed:, listed:)
          @table = table
          @claims = claims
          @removed = removed
          @listed = listed
        end

        # @return [Array<Verdict>] one per spare host
        def verdicts = @table.hosts.map { |host| verdict(host) }

        private

        def verdict(host)
          claim = @claims[host.pid]
          return Verdict.new(host, nil, false, "no claim in the daemon log") unless claim

          why = refusal(host, claim)
          Verdict.new(host, claim.session, why.nil?, why || "claimed by removed session #{claim.session}")
        end

        def refusal(host, claim)
          return "session #{claim.session} was not removed by this prune" unless @removed.include?(claim.session)
          return "session #{claim.session} is still listed" if @listed.include?(claim.session)

          "its start does not match the log's spawn of this host" unless same_process?(host, claim)
        end

        def same_process?(host, claim) = (@table.started(host) - claim.spawned_at).abs <= SKEW
      end
    end
  end
end
