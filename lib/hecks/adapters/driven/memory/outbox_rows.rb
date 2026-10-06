module Hecks
  module Adapters
    class Memory
      # The in-process transactional outbox: rows move pending, claimed, delivered without a
      # database, held in the adapter's `@outbox` and `@outbox_deliveries`. See `Runtime::Outbox`.
      module OutboxRows
        # Holds new outbox rows, skipping any whose `delivery_id` is already held.
        #
        # @param rows [Array<Runtime::Outbox::Row>] pending rows to enqueue; each accepted row
        #   has its `id` assigned in place
        # @return [Array<Runtime::Outbox::Row>] the rows actually enqueued, `[]` when every one
        #   was a duplicate
        def outbox_enqueue(rows)
          rows.filter_map do |row|
            next nil if @outbox_deliveries.key?(row.delivery_id)

            row.id = @outbox.size + 1
            @outbox << row
            @outbox_deliveries[row.delivery_id] = true
            row
          end
        end

        # Marks a pending outbox row claimed and counts the delivery attempt.
        #
        # @param id [Integer] the row id `outbox_enqueue` assigned
        # @return [Boolean] true when the row was pending and is now claimed; false when it is
        #   unknown or not pending
        def outbox_claim(id) # rubocop:disable Naming/PredicateMethod
          row = outbox_row(id)
          return false unless row&.pending?

          row.status = "claimed"
          row.attempts += 1
          true
        end

        # Records a delivery outcome on an outbox row, whatever status it held.
        #
        # @param id [Integer] the row id `outbox_enqueue` assigned
        # @param status [String, Symbol] the new status, one of `Runtime::Outbox::STATUSES`;
        #   not validated here
        # @param error [String, nil] the failure description, or nil to clear it
        # @return [Boolean] true when the row exists and was updated; false when no row has `id`
        def outbox_settle(id, status:, error: nil) # rubocop:disable Naming/PredicateMethod
          row = outbox_row(id) or return false
          row.status = status.to_s
          row.error  = error
          true
        end

        # Lists outbox rows in enqueue order, as copies a caller may mutate freely.
        #
        # @param status [String, Symbol, nil] only rows with this status; nil lists every row
        # @return [Array<Runtime::Outbox::Row>] shallow copies of the matching rows, `[]` when
        #   none match
        def outbox_rows(status: nil)
          rows = status ? @outbox.select { |row| row.status == status.to_s } : @outbox
          rows.map(&:dup)
        end

        private

        # Finds a held outbox row by id in constant time.
        #
        # Ids are assigned as the 1-based position at enqueue and rows are never
        # removed, so the id is the row's index plus one.
        def outbox_row(id)
          return nil unless id.is_a?(Integer) && id >= 1

          @outbox[id - 1]
        end
      end
    end
  end
end
