# frozen_string_literal: true

module Hecks
  module Adapters
    module InProcessOperations
      # The `Feed` query: the Hecks event tap's lines past a sequence number, read from the log the
      # Hecks world declares. It boots no domain, so answering it writes nothing.
      module Feeding
        # Answers the tap's lines past `since`, filtered by aggregate and event name.
        #
        # @param aggregate [Hash, String, nil] only lines of this aggregate, by bare name
        # @param since [Hash, Integer, nil] the sequence number already seen; 0 when absent
        # @param names [Hash, String, nil] comma-separated event names to keep; all when absent
        # @param limit [Hash, Integer, nil] the most lines scanned in one answer
        # @return [Hash] the `FeedTail` row: `cursor:` and `events:`
        # @raise [Runtime::NotFound] if the Hecks world declares no event log
        def feed(aggregate: nil, since: nil, names: nil, limit: nil)
          path = tap_path or raise Runtime::NotFound, "the Hecks world declares no event log"
          answer = Runtime::EventFeed.new(path: path).read(
            since: plain(since).to_i, aggregates: Array(plain(aggregate)).compact,
            names: feed_names(names), limit: (plain(limit) || 100).to_i
          )
          { cursor: answer[:cursor], events: answer[:events].map { |line| feed_entry(line) } }
        end

        private

        # One line of a feed answer, with the line itself as JSON text.
        #
        # @param line [Hash] a tap line
        # @return [Hash] a `FeedEntry` row
        def feed_entry(line)
          { seq: line["seq"], aggregate: line["aggregate"].to_s, event: line["event"].to_s,
            payload: JSON.generate(line) }
        end

        # The event names a feed was asked for, split on commas.
        #
        # @param names [Hash, String, nil] the comma-separated names
        # @return [Array<String>]
        def feed_names(names)
          listed = plain(names).to_s.split(",")
          listed.map(&:strip).reject(&:empty?)
        end

        # Where the Hecks world keeps its event tap, read from the domain's declarations without
        # booting it.
        #
        # @return [String, nil] the log's path; nil when the world declares none
        def tap_path
          world = Hecks.describe(File.expand_path("../..", __dir__)).registry.world("Hecks")
          Runtime::EventTap.path_for(world&.for_verb(Runtime::EventTap::VERB).to_h)
        end
      end
    end
  end
end
