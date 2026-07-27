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
