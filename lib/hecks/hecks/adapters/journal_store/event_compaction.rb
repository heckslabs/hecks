# frozen_string_literal: true

require "hecks"
require "time"

module Hecks
  module Adapters
    class JournalStore
      # The shared event log of a booted domain's Sqlite databases, and what dropping the events
      # older than a window does to it. The log is one table for a whole database, so the scope is
      # the database: every projection bound to a journal in the domain must have caught up before
      # any event goes. The adapter deletes what it is told to; this decides what and whether.
      class EventCompaction
        SECONDS_A_DAY = 86_400

        # @param path [String] the domain directory
        # @param window_days [Integer] events recorded within this many days stay
        # @param now [Time] the moment the window is counted back from
        # @raise [Runtime::NotFound] if the directory does not exist
        def initialize(path, window_days:, now: Time.now.utc)
          raise Runtime::NotFound, "no such domain #{path.inspect}" unless Dir.exist?(path.to_s)

          @registry = Hecks.boot(File.expand_path(path), install_driving: false).registry
          @cutoff = (now - (window_days * SECONDS_A_DAY)).utc.iso8601
        end

        # @return [Array<Sqlite>] one adapter per database file whose event log can be compacted
        def stores
          @stores ||= repositories.map(&:adapter).select { |adapter| adapter.respond_to?(:compact_events!) }
                                  .uniq(&:path)
        end

        # @return [Integer] how many events the window would drop, over every database
        def candidates = stores.sum { |store| store.events_before(@cutoff) }

        # @return [Integer] how many bound projections have not caught up with their journal
        def bound = lagging.size

        # Drops the events before the window.
        #
        # @return [Array<String>] one line per database
        # @raise [Runtime::WiringError] if a bound projection has not caught up
        def apply!
          raise Runtime::WiringError, "a projection has not caught up: #{lagging.join(", ")}" if bound.positive?

          stores.map do |store|
            "COMPACTED #{store.path}: dropped #{store.compact_events!(before: @cutoff)} events recorded " \
              "before #{@cutoff}"
          end
        end

        private

        def repositories
          @registry.bluebooks.flat_map do |domain_name, bluebook|
            bluebook.aggregates.map { |aggregate| @registry.repository(domain_name, aggregate) }
          end.select { |repository| repository.is_a?(Ports::Persistence::AppendOnly) }
        end

        def lagging
          @lagging ||= @registry.bluebooks.flat_map do |domain_name, bluebook|
            bluebook.aggregates.filter_map do |aggregate|
              aggregate.hecks_name if behind?(domain_name, aggregate)
            end
          end
        end

        def behind?(domain_name, aggregate)
          worker = Ports::Projection.worker(@registry, domain_name, aggregate)
          worker && worker.checkpoint < @registry.repository(domain_name, aggregate).entries.length
        end
      end
    end
  end
end
