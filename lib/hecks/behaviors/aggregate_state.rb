# Hecks::Behaviors::AggregateState
#
# Per-instance aggregate state held by the in-memory runtime.
# Mirrors hecks_life/src/runtime/mod.rs `AggregateState`. Pure
# field bag; the Interpreter and dispatch loop apply mutations
# and read fields.
#
#   state = AggregateState.new("1")
#   state.set("status", Value.from("approved"))
#   state.get("status").to_display     # => "approved"
require_relative "value"

module Hecks
  module Behaviors
    class AggregateState
      attr_reader :id, :fields

      def initialize(id)
        @id = id.to_s
        @fields = {}
      end

      def get(field)
        @fields[field.to_s] || Value.null
      end

      def set(field, value)
        @fields[field.to_s] = value.is_a?(Value) ? value : Value.from(value)
      end

      def append(field, value)
        current = @fields[field.to_s]
        items = current && current.list? ? current.raw.dup : []
        items << (value.is_a?(Value) ? value : Value.from(value))
        @fields[field.to_s] = Value.new(:list, items)
      end

      def increment(field, amount = 1)
        n = (get(field).numeric || 0) + amount
        @fields[field.to_s] = Value.from(n.to_i)
      end

      def decrement(field, amount = 1)
        n = (get(field).numeric || 0) - amount
        @fields[field.to_s] = Value.from(n.to_i)
      end

      # Float-aware variant for fractional increments like 0.01.
      # Stores the result as a Str (matching Rust runtime's behavior)
      # so it round-trips through the DSL's numeric coercion.
      def increment_float(field, amount)
        n = (get(field).numeric || 0.0) + amount
        @fields[field.to_s] = Value.new(:str, format_numeric(n))
      end

      def format_numeric(n)
        n == n.to_i ? n.to_i.to_s : n.to_s
      end

      def toggle(field)
        current = get(field)
        new_val = current.kind == :bool ? !current.raw : true
        @fields[field.to_s] = Value.from(new_val)
      end
    end
  end
end
