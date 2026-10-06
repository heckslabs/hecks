module Hecks
  module Bluebook
    module DSL
      # Mixin for DSL builders that declare attributes: `attribute`, `list_of`, `one_of`,
      # closed-set synthesis, and `identified_by` resolution.
      module AttributeCollector
        ListOf = Struct.new(:type)
        # `:values` shadows Struct#values so the accessor returns the flat permitted-value array.
        # rubocop:disable-next Lint/StructNewOverride
        OneOf  = Struct.new(:values)

        UNSET = Object.new.freeze
        private_constant :UNSET

        # Returns the attributes declared so far, minting the accumulating list on first use.
        #
        # @return [Array<Bluebook::Attribute>] the attributes declared so far, in declaration order
        def attributes = @attributes ||= []

        # Value objects synthesised from inline closed sets, collected here and
        # installed by whoever owns value objects (the aggregate).
        #
        # @return [Array<Bluebook::ValueObject>] the value objects synthesised so far
        def closed_sets = @closed_sets ||= []

        # Declares one field on the owning construct; the type is a bare constant (ADR 0025).
        #
        #   attribute :op, String, admits: "Vocabulary::QueryComparator"
        #
        # `admits:` names an already-declared closed set as qualified text, checked on read.
        # `one_of:` declares an inline closed set and is only meaningful inside a `value_object`.
        #
        # @param type [Module, ListOf, OneOf] a bare constant or a `list_of`/`one_of` wrapper
        # @return [void]
        # @raise [Malformed] on a duplicate name, a missing or quoted type, a disallowed
        #   pattern, or `one_of:` outside a `value_object`
        def attribute_impl(name, type = UNSET, default: nil, optional: false, pattern: nil,
                           admits: nil, one_of: nil)
          # The FieldName invariant on Root.Attribute enforces the name.

          refuse_duplicate_attribute!(name)

          if type.equal?(UNSET)
            raise Malformed, "#{name} declares no type — attribute :#{name}, SomeType is required, " \
                             "there is no default"
          end

          # `list_of("X")` carries quoted text one level down; check it before unwrapping.
          quoted = type.is_a?(ListOf) ? type.type : type
          if quoted.is_a?(::String)
            raise Malformed, "#{name}'s type #{quoted.inspect} is quoted text — give the bare constant " \
                             "(#{quoted}) instead; a forward reference to a value object declared later " \
                             "in the same block already resolves without quoting"
          end

          refuse_unshared_pattern(name, pattern) if pattern

          type = synthesise_closed_set(name, type) if type.is_a?(OneOf)
          list = type.is_a?(ListOf)
          attributes << Attribute.new(
            name:     name,
            type:     list ? type.type : type,
            list:     list,
            default:  default,
            optional: optional,
            pattern:  pattern,
            admits:   admits
          )

          install_inline_closed_set(name, one_of) if one_of
        end

        # Wraps a type so `attribute_impl` records it as list-valued: `attribute :x, list_of(Y)`.
        #
        # Reached through WordGate's "Type"-context fallback; one `["Type", "list_of"]` entry in
        # GenericDispatch::BOOTSTRAP_CALLS_FALLBACK covers bootstrap.
        def list_of_impl(type) = ListOf.new(type)

        # `reference_to Account` mints `:account`, no `_id` (ADR 0025). Under shadow-parsing the
        # suffix is kept so frozen era text reconstructs the name it was minted under.
        private def default_reference_name(target)
          suffix = MetaValidator.shadow_parsing? ? "_id" : ""
          :"#{Naming.snake(target)}#{suffix}"
        end

        # Wraps permitted values so `attribute_impl` synthesises a closed-set value object:
        #
        #   attribute :status, one_of("open", "shut")
        #
        # Shares its name with `ValueObjectBuilder#one_of_impl`, whose `super` resolves by name.
        def one_of_impl(*values) = OneOf.new(values)

        private

        def relationship_attribute(target, kind, name, optional: false, list: false)
          refuse_duplicate_attribute!(name)
          attributes << Attribute.new(
            name:         name,
            type:         Reference.new(target),
            list:         list,
            optional:     optional,
            relationship: kind
          )
        end

        # `one_of:` on a field is meaningful only inside a `value_object` (ADR 0025);
        # ValueObjectBuilder overrides this and every other includer refuses.
        def install_inline_closed_set(name, _values)
          raise Malformed,
                "#{name}'s one_of: only means something inside a value_object — name a closed set " \
                "with the type-position one_of(...) instead"
        end

        # Refused where every owner mints an attribute: readers look names up with `find`/`any?`
        # and would silently discard the second declaration.
        def refuse_duplicate_attribute!(name)
          return unless attributes.any? { |attribute| attribute.name == name }

          raise Malformed, "#{name} is declared twice — an attribute name is declared once, not twice"
        end

        # Refused at declaration: a regex whose meaning depends on the engine must not load
        # (PatternSubset says which constructs and why).
        def refuse_unshared_pattern(name, pattern)
          rejection = PatternSubset.validate(pattern)
          return unless rejection

          raise Malformed,
                "#{name}'s pattern #{pattern.inspect} uses a #{rejection.construct} — " \
                "#{rejection.reason}"
        end

        def synthesise_closed_set(name, one_of)
          type = Naming.pascal(name)
          closed_sets << ValueObject.declare(
            name:       type,
            attributes: [Attribute.new(name: :value, type: "String")],
            members:    one_of.values.map { |value| { value: value.to_s } },
            closed_set: true
          )
          type
        end

        # Each selected identity head contributes all its scalar leaves in declaration order.
        def resolve_identity_field!(field, value_objects, context_name)
          attr = attributes.find { |a| a.name == field }

          # A bare `:id` or `_id`-suffixed name with no matching attribute is the walk-parent/
          # fallback-identity convention (Instance#materialize_identity! falls back to `:id`).
          return [field.to_s] if attr.nil? && (field.to_s == "id" || field.to_s.end_with?("_id"))

          raise Malformed, "#{context_name}.identified_by :#{field} names no attribute #{context_name} declares" unless attr

          identity_paths_for_attribute(attr, value_objects, context_name, field.to_s, [])
        end

        # A named or inline identity mints one structured field, then expands
        # each scalar leaf beneath it into the existing path-shaped IR.
        def resolve_identity_type!(type, as, insert_at, value_objects, context_name)
          target = Naming.demodulise(type.respond_to?(:hecks_name) ? type.hecks_name : type)
          matches = value_objects.select { |value_object| value_object.hecks_name.to_s == target }
          raise Malformed, "#{context_name}.identified_by names duplicate value object #{target}" if matches.size > 1

          vo = type.respond_to?(:attributes) ? type : matches.first
          raise Malformed, "#{context_name}.identified_by names #{target}, which is not a declared value object" unless vo
          raise Malformed, "#{context_name}.identified_by names #{target}, which declares no attributes" if vo.attributes.empty?

          field = (as || Naming.snake(target)).to_sym
          if attributes.any? { |attribute| attribute.name == field }
            raise Malformed,
                  "#{context_name}.identified_by #{target} mints :#{field}, but that attribute is already declared"
          end

          # `Attribute.new` directly: `vo` is an anonymous class whose `to_s` would spell
          # "#<Class:0x...>", so the demodulised `target` text is the type.
          attributes << Attribute.new(name: field, type: target)
          # Moved to `insert_at`, the attribute count when `identified_by` was called; resolution
          # runs at build time, so appending would put the identity field last.
          attributes.insert(insert_at, attributes.pop)
          vo.attributes.flat_map do |attribute|
            identity_paths_for_attribute(attribute, value_objects, context_name,
                                         "#{field}.#{attribute.name}", [target])
          end
        end

        def identity_paths_for_attribute(attribute, value_objects, context_name, path, visited)
          if attribute.list?
            raise Malformed,
                  "#{context_name}'s identity member #{path} is a list — an identity member must be scalar"
          end
          if attribute.optional?
            raise Malformed,
                  "#{context_name}'s identity member #{path} is optional — an identity must be wholly known"
          end

          return [path] if attribute.reference?

          nested = value_objects.find { |value_object| value_object.hecks_name.to_s == attribute.type.to_s }
          return [path] unless nested

          if visited.include?(nested.hecks_name.to_s)
            cycle = [*visited, nested.hecks_name.to_s].join(" -> ")
            raise Malformed, "#{context_name}'s identity value objects form a cycle: #{cycle}"
          end

          # A bare field derives one scalar, so each value object on the way must wrap exactly one
          # field (ADR 0025); otherwise it would silently mint an unannounced compound key.
          if nested.attributes.size != 1
            candidates = nested.attributes.map(&:name).join(", ")
            raise Malformed,
                  "#{context_name}.identified_by :#{path} names #{nested.hecks_name}, which has " \
                  "#{nested.attributes.size} field#{"s" unless nested.attributes.size == 1} (#{candidates})"
          end

          member = nested.attributes.first
          identity_paths_for_attribute(member, value_objects, context_name, "#{path}.#{member.name}",
                                       [*visited, nested.hecks_name.to_s])
        end
      end
    end
  end
end
