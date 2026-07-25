# Value — constructs a value object and enforces its invariants.
#
# A VO is stored as a plain hash (it has no identity, so it needs no wrapper on
# disk), but its invariants are checked against a view that exposes the fields
# as methods — so the bluebook can say `{ amount > 0 }` rather than
# `{ self[:amount] > 0 }`.
#
# A violated invariant raises BEFORE the value reaches the aggregate. An
# aggregate never holds a value that broke its own rule.
#
#   Value.build(topping_vo, { name: "Basil", amount: 3 })  # => { name:..., amount:... }
module Hecksagain
  module Runtime
    class InvariantViolation < StandardError; end

    class Value
      def self.build(value_object, fields)
        view = new(value_object, fields)
        value_object.invariants.each do |invariant|
          next if view.instance_eval(&invariant.predicate)

          raise InvariantViolation,
                "#{value_object.name} invariant violated — #{invariant.description} " \
                "(given #{fields.inspect})"
        end
        fields
      end

      def initialize(value_object, fields)
        @value_object = value_object
        @fields       = fields
      end

      def method_missing(name, *args)
        return @fields[name] if @fields.key?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        @fields.key?(name) || super
      end
    end
  end
end
