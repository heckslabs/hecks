# frozen_string_literal: true

module Hecks
  module Adapters
    class Dispatching
      # Why a yielded work item is not tried again yet. A yield records a kind: a `transient` one
      # (a launch that failed for a reason that may pass) waits out a backoff, and a `structural`
      # one (the run key is taken, a Passage is missing) waits for what blocks it. The plan reads
      # the answer, so a fill does not pick the same item again every few minutes.
      module Parking
        # Minutes a transient yield waits, by how many times the item has yielded; the last repeats.
        BACKOFF_MINUTES = [5, 15, 45].freeze

        # Minutes a missing Passage parks an item before it is tried again.
        PASSAGE_MINUTES = 60

        # Run statuses that keep the key: a dispatch under it is refused by name.
        RUN_ENDED = %w[finished tidied refused retired].freeze

        # The refusal of a dispatch under a run key that is still taken.
        KEY_TAKEN = /already_recorded|is already recorded/

        # The words of a refusal that no Passage tracks the change.
        NO_PASSAGE = "no Passage with"

        # What a yield recorded: its kind, and when a transient or passage yield may be tried again.
        Kind = Struct.new(:name, :retry_at)

        module_function

        # Classifies a launcher refusal by the code or words the domain refused with.
        #
        # @param reason [String] the refusal that sent the item back
        # @param count [Integer] how many times the item has yielded, this one included
        # @param now [Time] the time of the yield
        # @return [Kind] `already_recorded`, `missing_passage` or `transient`, with the retry time
        def classify(reason, count:, now: Time.now.utc)
          text = reason.to_s
          return Kind.new("already_recorded", nil) if text.match?(KEY_TAKEN)
          return Kind.new("missing_passage", now + (PASSAGE_MINUTES * 60)) if text.include?(NO_PASSAGE)

          Kind.new("transient", now + (minutes_for(count) * 60))
        end

        # @param count [Integer] how many times the item has yielded
        # @return [Integer] minutes to wait
        def minutes_for(count) = BACKOFF_MINUTES[[count.to_i - 1, 0].max] || BACKOFF_MINUTES.last

        # Why an item is parked, or nil when it may start.
        #
        # @param item [#key, #yield_kind, #retry_at] a planned work item
        # @param runs [#call] answers the AgentRun states by run key, read only for a taken key
        # @param now [Time] the time to judge against
        # @return [String, nil] the reason, worded `parked: ...`
        def reason(item, runs:, now: Time.now.utc)
          case item.yield_kind.to_s
          when "already_recorded" then taken_reason(item, runs.call)
          when "missing_passage", "transient" then waiting_reason(item, now)
          end
        end

        def taken_reason(item, runs)
          status = runs.fetch(item.key, {})[:status].to_s
          return if status.empty? || RUN_ENDED.include?(status)

          "parked: run #{item.key} is #{status} and keeps its key until it ends (already_recorded)"
        end

        def waiting_reason(item, now)
          due = parse(item.retry_at)
          return unless due && due > now

          "parked: #{item.yield_kind} yield ##{item.yield_count.to_i}, tried again after #{due.utc.strftime("%H:%M")}Z"
        end

        def parse(text)
          require "time"
          text.to_s.empty? ? nil : Time.iso8601(text.to_s)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
