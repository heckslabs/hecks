require_relative "../naming"
require_relative "best_effort"
require_relative "../indifferent_key"
require_relative "value"

module Hecks
  module Runtime
    # Resolves an aggregate's or entity's identity string from a command payload.
    #
    # Identity.scalar("number.value", account_number_value_object)  # => "acct-1"
    module Identity
      module_function

      # Reads `key` from `hash` by whichever Symbol/String spelling is present.
      # Presence decides, not `||`, so a held `false` is not mistaken for absent.
      def hash_lookup(hash, key) = IndifferentKey.read(hash, key)

      # Digs the fields of `path` out of `held`, past the head the caller consumed.
      # A path with no fields past the head returns `held` unchanged.
      def scalar(path, held)
        _head, *fields = path.to_s.split(".")
        return held if fields.empty?

        fields.reduce(Value.materialize(held)) do |dug, field|
          dug.is_a?(Hash) ? hash_lookup(dug, field) : nil
        end
      end

      # Joins every declared identity part of `construct` from `args`, in declaration order.
      # `value_owner` is the aggregate that coerces value-object parts (an entity's owner).
      # Returns nil unless every part resolves: half an identity would name a different record.
      def of(construct, args, value_owner: construct)
        paths = construct.identity_paths
        return nil if paths.empty?

        parts = paths.map { |path| from(construct, args, path, value_owner: value_owner) }
        # A blank part names nothing, the same as an absent one.
        return nil if parts.any? { |part| part.nil? || (part.respond_to?(:empty?) && part.empty?) }

        Naming.identity(parts)
      end

      # Resolves one identity path, dotted or a bare head such as `:id`, against `args`.
      # A dotted path yields the scalar inside the value object, never the object serialised.
      def from(construct, args, key, value_owner: construct)
        return nil unless key

        head, *rest = key.to_s.split(".")
        head = head.to_sym
        return nil unless args.key?(head)

        return dotted_scalar(args[head], rest) unless rest.empty?

        bare_head(construct, head, args[head], value_owner)
      end

      # The scalar a dotted path names inside the held value object (or its hash).
      def dotted_scalar(held, rest)
        held = held.to_h if held.respond_to?(:to_h)
        # An ID is always a scalar: a caller may pass the carrying field's value directly.
        return held.to_s unless held.is_a?(Hash)

        rest.reduce(held) { |h, f| h.is_a?(Hash) ? hash_lookup(h, f) : nil }&.to_s
      end

      # A bare head's value, coerced only when the caller named the attribute; a saga's key is
      # already resolved.
      def bare_head(construct, head, raw, value_owner)
        attribute = construct.identity_heads.include?(head) ? construct.attribute(head) : nil
        return raw unless attribute

        # Unwrap the coerced value object so `to_s` never leaks an object address into an id.
        Value.materialize_unwrapped(Value.for_attribute(value_owner, attribute, raw)).to_s
      end

      # Renders the declared identity paths of `construct` for a refusal message.
      def reading(construct)
        construct.identity_paths.join(", ")
      end

      # Resolves a best-effort identity for `construct` to use as a lock key; never raises.
      # Returns nil when nothing resolves, and the caller then locks by aggregate type alone.
      def best_effort(construct, args, route = nil, reference_key: nil)
        BestEffort.call(nil) do
          route&.aggregate ||
            of(construct, args) ||
            from(construct, args, :id) ||
            (reference_key && from(construct, args, reference_key))
        end
      end
    end
  end
end
