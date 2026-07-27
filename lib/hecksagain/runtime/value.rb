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
require "json"
module Hecksagain
  module Runtime
    class InvariantViolation < StandardError; end

    class Value
      # WHAT A VALUE-OBJECT-TYPED ATTRIBUTE DOES WITH WHAT ARRIVED.
      #
      # Value.build was only ever reached from the append path, so a scalar
      # attribute declared as a value object was assigned whatever arrived
      # and never validated. `amount: 2500` on an attribute typed Money sat
      # there as an Integer, and `amount.cents` — a dotted read into what
      # the domain says is a Money — walked into a non-Hash and answered
      # nil. Both runtimes did it, so parity was green over a value object
      # that never existed and an invariant that never fired.
      #
      # Not the aggregate's business and not the command's : this is what a
      # value IS, so it lives beside the rule that judges one.
      def self.for(aggregate, name, value)
        value_object = declared_by(aggregate, name)
        return value unless value_object
        return value if value.nil?

        build(value_object, fields_for(value_object, name, value))
      end

      # The value object a SCALAR attribute is declared as, or nil. A list
      # attribute is built element by element on the append path.
      def self.declared_by(aggregate, name)
        attribute = aggregate.attribute(name)
        return nil unless attribute&.scalar?

        aggregate.value_object(attribute.type)
      end

      # A SINGLE-ATTRIBUTE value object accepts a bare scalar, because
      # `kind: "current"` is unambiguous — there is exactly one field it
      # could mean, and making an author write `{ name: "current" }` buys
      # nothing. Anything richer must arrive as its fields, because guessing
      # which one of several a scalar meant is how a currency ends up in a
      # cents column.
      def self.fields_for(value_object, name, value)
        return value.transform_keys(&:to_sym) if value.is_a?(Hash)

        only = value_object.attributes
        return { only.first.name => value } if only.size == 1

        raise TypeMismatch,
              "#{name} is a #{value_object.name}, which has " \
              "#{only.map { |a| a.name }.join(', ')} — pass those fields, not " \
              "#{value.inspect}. A scalar can only stand in for a value " \
              "object with exactly one field."
      end

      def self.build(value_object, fields)
        admit_member(value_object, fields)
        value_object.invariants.each do |invariant|
          next if Bluebook::Expression::Evaluator.call(invariant.canonical, fields)

          # Rendered as canonical JSON with sorted keys rather than Ruby's
          # hash inspect — a message that differs between runtimes is a
          # difference the parity harness has to explain away, and an
          # explained-away difference is where a real one hides.
          raise InvariantViolation,
                "#{value_object.name} invariant violated — #{invariant.description} " \
                "(given #{canonical_fields(fields)})"
        end
        fields
      end

      # `one_of` declares the CLOSED SET of values this object may take. The
      # judgment falls on the DISCRIMINANT — the first declared attribute,
      # the value a caller actually offers. Values compare and render as
      # strings because the canonical IR serialises member rows as strings ;
      # both runtimes speak the seam's rendering, so the refusal reads
      # identically from either side.
      def self.admit_member(value_object, fields)
        return if value_object.members.empty?

        discriminant = value_object.attributes.first.name
        offered      = fields[discriminant]
        admitted     = value_object.members.map { |member| member[discriminant].to_s }
        return if admitted.include?(offered.to_s)

        raise InvariantViolation,
              "#{value_object.name} admits #{admitted.map(&:inspect).join(', ')} — got #{offered.inspect}"
      end

      def self.canonical_fields(fields)
        JSON.generate(fields.sort_by { |name, _| name.to_s }.to_h)
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
