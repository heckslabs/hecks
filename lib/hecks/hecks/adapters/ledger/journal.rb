# frozen_string_literal: true

require_relative "chain"

module Hecks
  module Adapters
    class Ledger
      # One chained journal of a booted domain: the persistence adapter that holds it, and the seals
      # kept beside it.
      #
      # An adapter's journal is chained when it can keep seals (`ledger_anchors`,
      # `record_ledger_anchor`) beside the entries it appends. A sequenced journal (Postgres,
      # Sqlite) seals up to its projection checkpoint, the point compaction deletes through, and
      # counts a seal by sequence; a journal with no sequence (Heki) seals everything it holds
      # and counts entries.
      class Journal
        # The seal before the first: nothing covered, the genesis digest.
        START = { through: 0, head: Chain::GENESIS }.freeze

        # @return [String] the aggregate's storage name, as the journal is named
        attr_reader :name

        # @param aggregate [Bluebook::Aggregate] the aggregate the journal belongs to
        # @param adapter [Object] the persistence adapter holding its entries
        # @return [Journal, nil] the chained journal, or nil when the adapter keeps no seals
        def self.of(aggregate, adapter)
          return unless %i[ledger_anchors record_ledger_anchor entries].all? { |method| adapter.respond_to?(method) }

          new(aggregate, adapter)
        end

        # @param aggregate [Bluebook::Aggregate] the aggregate the journal belongs to
        # @param adapter [Object] a persistence adapter that keeps seals
        def initialize(aggregate, adapter)
          @name = aggregate.storage_name
          @aggregate = aggregate
          @adapter = adapter
        end

        # @return [Boolean] whether any seal is kept beside the journal
        def sealed? = !@adapter.ledger_anchors.empty?

        # Seals the journal at its end, unless nothing was appended since its last seal.
        #
        # @return [Hash, nil] `name:`, `through:`, `head:` and `previous:` of the seal the journal
        #   now stands at; nil when it was never sealed and holds nothing
        def seal
          last = @adapter.ledger_anchors.last
          base = last || START
          fresh = unsealed(base)
          return last && { name: @name }.merge(last) if fresh.empty?

          record(base, fresh)
        end

        # Compares each seal with the journal and with the seal before it.
        #
        # @return [Hash] `seals:` how many seals are held, `entries:` how many were re-walked
        # @raise [Runtime::WiringError] on the first seal that does not follow the one before it,
        #   or whose head the journal does not reproduce
        def verify
          held = @adapter.ledger_anchors
          before = START
          walked = held.sum do |anchor|
            refuse(anchor, "does not follow the seal before it") unless anchor[:previous] == before[:head]
            count = rewalk(anchor, before)
            before = anchor
            count
          end
          { seals: held.size, entries: walked }
        end

        private

        def record(base, fresh)
          through = fresh.last.sequence || (base[:through] + fresh.size)
          head = Chain.fold(base[:head], @aggregate, fresh)
          @adapter.record_ledger_anchor(through: through, head: head, previous: base[:head])
          { name: @name, through: through, head: head, previous: base[:head] }
        end

        # The entries appended since a seal, in order.
        def unsealed(base)
          return @adapter.entries unless @adapter.respond_to?(:entries_since)

          @adapter.entries_since(base[:through]).select { |entry| entry.sequence <= @adapter.checkpoint }
        end

        # Recomputes one seal's head from the journal, when its entries are still held.
        def rewalk(anchor, before)
          return 0 unless @adapter.respond_to?(:entries_since) && @adapter.respond_to?(:compacted_through)
          return 0 if @adapter.compacted_through >= anchor[:through]

          held = @adapter.entries_since(before[:through]).select { |entry| entry.sequence <= anchor[:through] }
          refuse(anchor, "no longer matches the journal") unless Chain.fold(anchor[:previous], @aggregate, held) == anchor[:head]
          held.size
        end

        def refuse(anchor, reason)
          raise Runtime::WiringError, "#{@name}: the seal through #{anchor[:through]} #{reason}"
        end
      end
    end
  end
end
