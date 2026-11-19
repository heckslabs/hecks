# frozen_string_literal: true

module Hecks
  module Adapters
    class StallWatching
      # What the event tap already says about the stalls: which were filed, which were abandoned,
      # whether a kind's run has ended and whether its subject has settled. Each beat of the clock
      # is a process of its own with an empty `Stall` store, so the tap is the only memory a later
      # look has.
      class Standing
        # @param lines [Array<Hash>] tap lines in sequence order
        def initialize(lines)
          @lines = lines.select { |line| line["kind"] == "event" }
          @filed = ids("StallFiled")
          @abandoned = ids("StallAbandoned")
        end

        # @param stall [String] a stall key, `stall-<kind>-<subject>`
        # @return [Boolean] whether the tap holds a `StallFiled` for it
        def filed?(stall) = @filed.include?(stall)

        # @param stall [String] a stall key
        # @return [Boolean] whether the tap holds a `StallAbandoned` for it
        def abandoned?(stall) = @abandoned.include?(stall)

        # @param kind [Hash] a `StallKind` row
        # @param subject [String] the opening line's aggregate id, which is also the run's id
        # @param since [String] when the subject opened, so an earlier attempt's ending under the
        #   same run key does not count
        # @return [String, nil] the first event that ended the subject's run; none when the kind
        #   names no ending or the run goes on
        def ending(kind, subject, since)
          events = kind[:ends].to_s.split(",").map(&:strip)
          found = @lines.find do |line|
            ends?(kind, line, subject, events) && line["at"].to_s >= since.to_s
          end
          found && found["event"]
        end

        # @param kind [Hash] a `StallKind` row
        # @param subject [String] the opening line's aggregate id
        # @param since [String] when the subject opened, so only a later line settles it
        # @param branch [String, nil] the branch the opening line links, for `settled_on: "branch"`;
        #   `settled_on: "any"` settles on a line of any id
        # @return [String, nil] the first line after `since` that settled the subject, as
        #   "<aggregate> recorded <event>"; none when the kind names no settling or nothing settled
        def settled(kind, subject, since, branch)
          events = kind[:settled_by].to_s.split(",").map(&:strip)
          found = @lines.find do |line|
            settling?(kind, line, events, since) && settles?(kind, line, subject, branch)
          end
          found && "#{found["aggregate"]} recorded #{found["event"]}"
        end

        private

        def ends?(kind, line, subject, events)
          line["aggregate"] == kind[:ends_aggregate] && line["id"].to_s == subject && events.include?(line["event"])
        end

        def settling?(kind, line, events, since)
          line["aggregate"] == kind[:settled_aggregate] && events.include?(line["event"]) && line["at"].to_s >= since.to_s
        end

        # `settled_on: "branch"` matches any line that links the subject's branch, `"any"` every
        # line, and none the same id.
        def settles?(kind, line, subject, branch)
          case kind[:settled_on]
          when "any" then true
          when "branch" then !branch.nil? && line.dig("links", "branch") == branch
          else line["id"].to_s == subject
          end
        end

        def ids(event) = @lines.select { |line| line["event"] == event }.to_set { |line| line["id"].to_s }
      end
    end
  end
end
