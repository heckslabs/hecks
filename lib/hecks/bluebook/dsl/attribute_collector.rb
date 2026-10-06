require_relative "attribute_collector/identity_resolution"

module Hecks
  module Bluebook
    module DSL
      # Mixin for DSL builders that declare attributes: `attribute`, `list_of`, `one_of`,
      # closed-set synthesis, and `identified_by` resolution.
      module AttributeCollector
        include IdentityResolution

        ListOf = Struct.new(:type)
        # `:values` shadows Struct#values so the accessor returns the flat permitted-value array.
        # rubocop:disable-next Lint/StructNewOverride
        OneOf  = Struct.new(:values)

        UNSET = Object.new.freeze
        private_constant :UNSET

        ATTRIBUTE_FIELD_OPTIONS = %i[default optional pattern admits].freeze
        ATTRIBUTE_OPTIONS = [*ATTRIBUTE_FIELD_OPTIONS, :one_of].freeze
        private_constant :ATTRIBUTE_FIELD_OPTIONS, :ATTRIBUTE_OPTIONS

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
        # `admits:` names an already-declared closed set as qualified text, checked on read.
        # `one_of:` declares an inline closed set, meaningful only inside a `value_object`.
        #
        # @param name [Symbol] the field's name
        # @param type [Module, ListOf, OneOf] a bare constant or a wrapper
        # @param options [Hash] `default:`, `optional:`, `pattern:`, `admits:` or `one_of:`
        # @return [void]
        # @raise [Malformed] on a duplicate name, a missing or quoted type, a disallowed pattern
        # @raise [ArgumentError] on any other keyword
        def attribute_impl(name, type = UNSET, **options)
          # The FieldName invariant on Root.Attribute enforces the name.
          opts = attribute_options(options)
          refuse_duplicate_attribute!(name)
          refuse_unfit_type!(name, type)
          refuse_unshared_pattern(name, opts[:pattern]) if opts[:pattern]

          type = synthesise_closed_set(name, type) if type.is_a?(OneOf)
          attributes << typed_attribute(name, type, opts.slice(*ATTRIBUTE_FIELD_OPTIONS))

          install_inline_closed_set(name, opts[:one_of]) if opts[:one_of]
        end

        # Wraps a type so `attribute_impl` records it as list-valued: `attribute :x, list_of(Y)`.
        #
        # Reached through WordGate's "Type"-context fallback; one `["Type", "list_of"]` entry in
        # GenericDispatch::BOOTSTRAP_CALLS_FALLBACK covers bootstrap.
        def list_of_impl(type) = ListOf.new(type)

        # Wraps permitted values so `attribute_impl` synthesises a closed-set value object:
        #
        #   attribute :status, one_of("open", "shut")
        #
        # Shares its name with `ValueObjectBuilder#one_of_impl`, whose `super` resolves by name.
        def one_of_impl(*values) = OneOf.new(values)

        private

        # `reference_to Account` mints `:account`, no `_id` (ADR 0025). Under shadow-parsing the
        # suffix is kept so frozen era text reconstructs the name it was minted under.
        def default_reference_name(target)
          suffix = MetaValidator.shadow_parsing? ? "_id" : ""
          :"#{Naming.snake(target)}#{suffix}"
        end

        # The keyword options `attribute` accepts, defaulted; anything else is refused the way a
        # keyword parameter list would refuse it.
        def attribute_options(options)
          unknown = options.keys - ATTRIBUTE_OPTIONS
          unless unknown.empty?
            raise ArgumentError, "unknown keyword#{"s" if unknown.size > 1}: #{unknown.map(&:inspect).join(", ")}"
          end

          { default: nil, optional: false, pattern: nil, admits: nil, one_of: nil }.merge(options)
        end

        def typed_attribute(name, type, field_options)
          list = type.is_a?(ListOf)
          Attribute.new(name: name, type: list ? type.type : type, list: list, **field_options)
        end

        def refuse_unfit_type!(name, type)
          if type.equal?(UNSET)
            raise Malformed, "#{name} declares no type — attribute :#{name}, SomeType is required, " \
                             "there is no default"
          end

          # `list_of("X")` carries quoted text one level down; check it before unwrapping.
          quoted = type.is_a?(ListOf) ? type.type : type
          return unless quoted.is_a?(::String)

          raise Malformed, "#{name}'s type #{quoted.inspect} is quoted text — give the bare constant " \
                           "(#{quoted}) instead; a forward reference to a value object declared later " \
                           "in the same block already resolves without quoting"
        end

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
      end
    end
  end
end
