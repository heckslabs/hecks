require_relative "../../naming"
require_relative "../../rendering"
require_relative "../errors"
require_relative "../refusal_wording"

module Hecks
  module Runtime
    class Value
      # How a reference-typed attribute's offered value becomes the target's identity, and how a
      # wrong-shaped one is refused. Extended into `Value` beside `Coercion`.
      module References
        # Coerces a reference-typed attribute's offered value into the target's own
        # canonical identity string.
        #
        # @param attribute [Bluebook::Attribute] the reference-typed attribute
        # @param value [Object] a bare scalar identity, a `Runtime::Value`, or a Hash
        #   naming the target's own identity fields
        # @return [String, Object] the joined identity String, or `value` unchanged
        #   when it cannot be resolved
        def reference_identity(attribute, value)
          target = reference_target(attribute, value)
          return value unless target

          parts = identity_parts(value, target)
          return Naming.identity(parts) unless parts.any? { |part| blank_identity_part?(part) }

          sole_scalar_identity(value, target.identity_paths) || value
        end

        # Unwraps `value` to a bare scalar when `paths` names exactly one identity
        # field and `value` is itself a single-attribute value object — the only
        # case where unwrapping cannot be ambiguous.
        #
        # @param value [Object] the offered reference value to unwrap
        # @param paths [Array<String>] the target's own declared identity paths
        # @return [Object, nil] the unwrapped scalar, or nil if it does not apply
        def sole_scalar_identity(value, paths)
          return nil unless value.is_a?(self) && paths.one?
          return nil unless value.value_object.sole_attribute

          materialize_unwrapped(value)
        end

        # Whether `value` is itself the target's own single identity value object.
        #
        # @param value [Object] the offered reference value to check
        # @param target [Bluebook::Aggregate] the reference's own resolved target
        # @return [String, nil] the target's identity head name, or nil
        def direct_identity_head(value, target)
          return nil unless value.is_a?(self) && target.identity_heads.one?

          head = target.identity_heads.first
          target.attribute(head)&.type.to_s == value.type_name ? head.to_s : nil
        end

        # One identity path's own value out of the materialized hash, stripping a
        # leading segment already covered by `direct_identity_head`.
        #
        # @param materialized [Hash, Object] the offered reference value as a Hash
        # @param path [String, Symbol] one dotted identity path to dig
        # @param direct_head [String, nil] leading segment to strip, if present
        # @return [Object, nil] the value found by walking `path`, or nil if missing
        def identity_part(materialized, path, direct_head)
          segments = path.to_s.split(".")
          segments.shift if direct_head && segments.first == direct_head
          segments.reduce(materialized) do |held, segment|
            next nil unless held.is_a?(Hash)

            # `key?` decides which spelling answers — a genuinely-held `false`
            # must not fall through to the other spelling and read as `nil`.
            sym = segment.to_sym
            held.key?(sym) ? held[sym] : held[segment]
          end
        end

        # Coerces a `has_many` reference-typed attribute's offered value.
        #
        # @param attribute [Bluebook::Attribute] the `has_many` reference attribute
        # @param value [Object] the offered value; must be an Array
        # @return [Array] `value`, deep-frozen and duped
        # @raise [Runtime::TypeMismatch] if `value` is not an Array
        def reference_list(attribute, value)
          unless value.is_a?(Array)
            raise TypeMismatch,
                  "#{attribute.name} is a has_many relationship — pass a list of identities"
          end

          Freezer.deep(value.dup)
        end

        # A reference is an ID; refused at the payload gate if it arrives as a
        # Hash or `Runtime::Value` instead. `nil` stays legitimate for an optional
        # reference — a required reference's own `nil` is refused elsewhere (C3.7).
        #
        # @param command [Class] the command `attribute` is declared on, named in a refusal
        # @param attribute [Bluebook::Attribute] the attribute to check; a no-op unless
        #   reference-typed
        # @param value [Object] the offered value
        # @return [void]
        # @raise [Runtime::TypeMismatch] if `value` (or an element, for `has_many`) is a
        #   Hash or `Runtime::Value` rather than a plain identity
        def refuse_object_reference(command, attribute, value)
          return unless attribute.reference?

          offence = object_reference_offence(attribute, value)
          return unless offence

          raise TypeMismatch,
                RefusalWording.render_site("TypeMismatch", "reference_wrong_shape",
                                           command: command.hecks_name, attribute: attribute.name,
                                           offered: reference_shape_description(offence.first),
                                           known_by: known_by(attribute))
        end

        # A list argument is an Array whatever its element type, so a lone scalar offered for
        # it is refused; nil stays legitimate, as for any optional argument. The single-element
        # form belongs to the `append`/`remove` effects, which take one element and are
        # coerced against the aggregate's own list, never through this gate.
        #
        # @param command [#hecks_name] what `attribute` is declared on, named in a refusal
        # @param attribute [Bluebook::Attribute] the attribute to check; a no-op unless list-typed
        #   (a `has_many` reference list has its own refusal)
        # @param value [Object] the offered value
        # @return [void]
        # @raise [Runtime::TypeMismatch] if `value` is neither nil nor an Array
        def refuse_scalar_list(command, attribute, value)
          return unless attribute.list? && !attribute.reference? && !value.nil? && !value.is_a?(Array)

          numeric_field_mismatch!(command.hecks_name, attribute.name, "list_of(#{attribute.type})", Rendering.describe(value))
        end

        # "an object" for the Hash/Value shape; `Rendering.describe` otherwise —
        # the same rendering every other TypeMismatch in this file uses.
        #
        # @param value [Object] the wrongly-shaped offered value to describe
        # @return [String] `"an object"` for a Hash or `Runtime::Value`; otherwise
        #   `Rendering.describe(value)`
        def reference_shape_description(value)
          return "an object" if value.is_a?(Hash) || value.is_a?(self)

          Rendering.describe(value)
        end

        # "(Account is known by number)" — what to send instead. No article, since
        # "an Account" vs "a Customer" would make a pinned refusal hinge on spelling.
        #
        # @param attribute [Bluebook::Attribute] the reference-typed attribute to
        #   describe the target's identity heads for
        # @return [String] `" (Target is known by head1, head2)"`, or `""` if the
        #   target or its identity heads cannot be resolved
        def known_by(attribute)
          heads = Array(attribute.type.resolve&.identity_heads)
          return "" if heads.empty?

          " (#{attribute.type.target_name} is known by #{heads.join(", ")})"
        end

        private

        # The target aggregate whose identity an offered value can name, when it has one.
        def reference_target(attribute, value)
          return nil unless value.is_a?(self) || value.is_a?(Hash)

          target = attribute.type.resolve
          target if target && !target.identity_paths.empty?
        end

        def identity_parts(value, target)
          materialized = materialize(value)
          direct_head  = direct_identity_head(value, target)
          target.identity_paths.map { |path| identity_part(materialized, path, direct_head) }
        end

        def blank_identity_part?(part)
          part.nil? || (part.respond_to?(:empty?) && part.empty?)
        end

        # What a reference argument offers that is not a plain identity: `[offered]`, or nil when
        # nothing is wrong. The one-element list tells an offered nil from nothing offered.
        def object_reference_offence(attribute, value)
          return list_reference_offence(value) if attribute.list?
          return nil if value.nil? && attribute.optional?
          return nil if value.is_a?(String)

          [value]
        end

        def list_reference_offence(value)
          offered = Array(value).find { |item| item.is_a?(Hash) || item.is_a?(self) }
          offered && [offered]
        end
      end
    end
  end
end
