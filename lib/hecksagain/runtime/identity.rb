require_relative "../naming"
require_relative "value"

module Hecksagain
  module Runtime
    # THE SCALAR AN IDENTITY PATH NAMES.
    #
    # An identity is DECLARED as a path — `identified_by { number.value }` — and
    # this is the one place that reads one. It follows the path and nothing else.
    #
    # What it replaced was `Value.identifier`, which opened a one-field value
    # object and took whatever was inside : that let `identified_by :number` pass
    # for an identity, with the runtime guessing which field had been meant. The
    # guess is gone. A declaration that names no field is now refused when the
    # bluebook loads (`an aggregate that is identified names a field`, `an entity
    # is known by a field`), so by the time anything is dispatched there is
    # always a path here to follow.
    #
    # Usage:
    #
    #   Identity.scalar("number.value", account_number_value_object)  # => "acct-1"
    #
    module Identity
      module_function

      # The head names the ATTRIBUTE and is consumed by whoever looked the value
      # up; what is left is the walk down into it. A path with no fields to walk
      # — an aggregate that declares no identity and falls back to `id` — hands
      # back what it was given, because there is nothing declared to dig for.
      def scalar(path, held)
        _head, *fields = path.to_s.split(".")
        return held if fields.empty?

        fields.reduce(Value.materialize(held)) do |dug, field|
          dug.is_a?(Hash) ? (dug[field.to_sym] || dug[field]) : nil
        end
      end

      # THE IDENTITY IS THE JOIN OF ITS PARTS, in declaration order. Shared by
      # `CommandInterpreter` (an aggregate acting on itself) and
      # `EntityInterpreter` (a piece addressed through its aggregate) — a piece
      # declares an identity the same shape a head does, so it derives one the
      # same way. `construct` answers `identity_paths` / `identity_heads` /
      # `attribute` (an Aggregate or an Entity, either one) ; `value_owner`
      # answers for coercion (`Value.for_attribute`'s first argument), which for
      # an entity is its OWNING aggregate — an entity's value objects resolve
      # through the aggregate's namespace, not its own.
      #
      # A part the payload does not carry makes the WHOLE identity unresolvable,
      # rather than half of one. Half an identity names nothing, and joining what
      # did arrive would silently name a different record on every dispatch — the
      # precise failure that minting an id caused, arrived at by another road.
      def of(construct, args, value_owner: construct)
        paths = construct.identity_paths
        return nil if paths.empty?

        parts = paths.map { |path| from(construct, args, path, value_owner: value_owner) }
        # A BLANK PART NAMES NOTHING, the same as an ABSENT one — Rust's hydrate
        # has always refused an empty scalar for exactly this reason ("AN ID IS
        # A SCALAR", and "" is not a fact about anything). Ruby only checked
        # `nil?` here, so a canonical text extracted as "" (an expression whose
        # source did not survive extraction) resolved to a REAL, empty-string
        # identity on the Ruby side while Rust refused to address it at all —
        # the same record, findable through one runtime and not the other.
        return nil if parts.any? { |part| part.nil? || part.empty? }

        Naming.identity(parts)
      end

      # A path digs into the value object that carries the identity, so what is
      # stored is the SCALAR inside it rather than the object serialised whole.
      def from(construct, args, key, value_owner: construct)
        return nil unless key

        head, *rest = key.to_s.split(".")
        head = head.to_sym
        return nil unless args.key?(head)

        unless rest.empty?
          held = args[head]
          held = held.to_h if held.respond_to?(:to_h)
          # AN ID IS ALWAYS A SCALAR. The path says WHICH FIELD carries it, so a
          # caller may hand that field's value straight over — a string or a
          # number, never a serialised object. Only a value object that actually
          # arrived whole has to be opened.
          return held.to_s unless held.is_a?(Hash)

          return rest.reduce(held) { |h, f| h.is_a?(Hash) ? (h[f.to_sym] || h[f]) : nil }&.to_s
        end

        # Coerced against the identity ATTRIBUTE only when the caller actually
        # named it. A saga addresses an aggregate by its correlation key, and
        # that key carries the id ALREADY RESOLVED — coercing "w1" against a
        # WireReference asked the caller to pass fields for a value object they
        # never mentioned.
        attribute = construct.identity_heads.include?(head) ? construct.attribute(head) : nil
        raw       = args[head]
        attribute ? Value.for_attribute(value_owner, attribute, raw) : raw
      end

      # How an identity READS when the runtime has to name it in a refusal — the
      # paths as they were declared, so the message quotes the bluebook back.
      def reading(construct)
        construct.identity_paths.join(", ")
      end
    end
  end
end
