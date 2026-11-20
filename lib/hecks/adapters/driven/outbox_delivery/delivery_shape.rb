module Hecks
  module Adapters
    module OutboxDelivery
      # One outbox row in the `Delivery` aggregate's attribute shape: each value object as
      # `{ value: }`, the event's uid as `event_id`, and the row's status as the lifecycle state.
      # The outbox's five states are `Delivery`'s five, so the status passes through unchanged.
      module DeliveryShape
        module_function

        # @param row [Runtime::Outbox::Row] the outbox row
        # @return [Hash{Symbol => Object}] the row as a `Delivery`
        def of(row)
          { delivery_id: wrap(row.delivery_id), event_id: wrap(row.event_uid), domain: wrap(row.domain),
            consumer: wrap(row.consumer), kind: wrap(row.kind), error: row.error && wrap(row.error),
            status: row.status }
        end

        # @param value [String] a plain value
        # @return [Hash{Symbol => String}] the value as a one-field value object
        def wrap(value) = { value: value.to_s }
      end
    end
  end
end
