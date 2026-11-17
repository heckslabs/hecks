# frozen_string_literal: true

require_relative "record_index/records"
require_relative "record_index/store"

module Hecks
  module Adapters
    # The `Records` port's adapter for `Find::Index`: a full-text search over the work items,
    # findings and decisions of the booted Tickets store, answered without a model.
    #
    # The index is a SQLite FTS5 file (the `path` setting, else `record_index.db` beside the
    # other development ledgers) brought up to date on each query by upserting only the records
    # whose text changed, so it never lags and a query over a settled ledger rewrites nothing.
    # The Tickets records are read and never written.
    class RecordIndex
      # The hits returned when `top` is not named.
      DEFAULT_TOP = 10

      # @param registry [Runtime::Registry, nil] the booted registry whose Tickets records are read
      # @param settings [Hash] `path:` the index file, ":memory:" for none
      # @param aggregate [Object, nil] unused
      # @param root [String, nil] unused
      def initialize(registry: nil, settings: {}, aggregate: nil, root: nil)
        @registry = registry
        @path = settings[:path] || File.join(Dir.home, ".claude", "hecks-dev", "record_index.db")
      end

      # @param args [Hash] the query's arguments: `words`, `kind`, `top`
      # @return [Hash{Symbol => String}] `text:` one `kind id: snippet` row per hit, best first,
      #   empty when nothing matches
      def find(**args)
        store.sync(Records.new(@registry).all)
        hits = store.search(plain(args[:words]).to_s, kind: plain(args[:kind]), top: top(args[:top]))
        { text: hits.map { |kind, id, snippet| "#{kind} #{id}: #{snippet}" }.join("\n") }
      end

      private

      def store = @store ||= Store.new(@path)

      def top(argument) = [plain(argument)&.to_i || DEFAULT_TOP, DEFAULT_TOP].min

      def plain(argument) = argument.is_a?(Hash) ? argument[:value] : argument
    end
  end
end
