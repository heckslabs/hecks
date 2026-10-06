require "json"
require "securerandom"
require "time"
require_relative "event"
require_relative "../naming"

module Hecks
  module Runtime
    # A durable outbox (ADR 0053): one row per (event, consumer), written in
    # the same transaction as the aggregate save so a reaction is never lost.
    module Outbox
      # pending -> claimed -> delivered | failed
      STATUSES = %w[pending claimed delivered failed].freeze

      Row = Struct.new(:id, :delivery_id, :event_uid, :aggregate, :domain, :kind, :consumer, :event,
                       :status, :attempts, :error, keyword_init: true) do
        def pending?   = status == "pending"
        def claimed?   = status == "claimed"
        def delivered? = status == "delivered"
        def failed?    = status == "failed"

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
          payload:     deep_symbolize(hash[:payload] || {}),
          occurred_at: hash[:occurred_at],
          correlation: hash[:correlation]
        ).emit!
      end

      def deep_symbolize(value)
        case value
        when Hash  then value.to_h { |k, v| [k.to_sym, deep_symbolize(v)] }
        when Array then value.map { |element| deep_symbolize(element) }
        else value
        end
      end
    end
  end
end

require_relative "outbox/fanout"
require_relative "outbox/relay"
