require "json"
require "securerandom"
require "time"
require_relative "event"
require_relative "value"
require_relative "../naming"

module Hecks
  module Runtime
    # A durable outbox (ADR 0053): one row per (event, consumer), written in
    # the same transaction as the aggregate save so a reaction is never lost.
    module Outbox
      # pending -> claimed -> delivered | failed
      STATUSES = %w[pending claimed delivered failed].freeze

      # How long a row stays claimed before it counts as stalled: a claim that old was left by a
      # process that is gone, where a younger one is a reaction running in another process. Ten
      # minutes is the ceiling a reaction is expected to stay inside.
      STALLED_AFTER = 600

      # `claimed_for` is the seconds since the row was claimed, read from the store's own clock; nil
      # when the store does not say.
      Row = Struct.new(:id, :delivery_id, :event_uid, :aggregate, :domain, :kind, :consumer, :event,
                       :status, :attempts, :error, :claimed_for, keyword_init: true) do
        def pending?   = status == "pending"
        def claimed?   = status == "claimed"
        def delivered? = status == "delivered"
        def failed?    = status == "failed"

        # A claimed row is stalled when its age is unknown or past `STALLED_AFTER`; a younger one is
        # a reaction still running.
        def stalled? = claimed? && (claimed_for.nil? || claimed_for >= STALLED_AFTER)

        # @return [Integer, nil] whole seconds since the claim, or nil when the store does not say
        def claimed_seconds_ago = claimed_for&.round

        # Wire shape persisted by adapters; `Outbox.event_from` reverses it.
        def to_h
          { id: id, delivery_id: delivery_id, event_uid: event_uid, aggregate: aggregate, domain: domain,
            kind: kind, consumer: consumer, event: event, status: status, attempts: attempts, error: error }
        end

        def to_s = "#{consumer} ← #{event[:name]}(#{event[:aggregate]}##{event[:id]}) [#{status}]"
        def inspect = "#<Outbox::Row #{self}>"
      end

      module_function

      def serialize_event(event)
        event.to_h.merge(correlation: event.correlation)
      end

      # Emitting domain's own bluebook first, then load order (C10.2) — the
      # same order `PolicyInterpreter#policies_for` and `Fanout.policies` use.
      def bluebooks_home_first(registry, domain)
        home, others = registry.bluebooks.each_value.partition { |bluebook| bluebook.name == domain }
        home + others
      end

      def event_from(hash)
        hash = hash.transform_keys(&:to_sym)
        Event.new(
          name:        hash[:name],
          aggregate:   hash[:aggregate],
          id:          hash[:id],
          payload:     Value.deep_symbolize(hash[:payload] || {}),
          occurred_at: hash[:occurred_at],
          correlation: hash[:correlation]
        ).emit!
      end
    end
  end
end

require_relative "outbox/fanout"
require_relative "outbox/relay"
