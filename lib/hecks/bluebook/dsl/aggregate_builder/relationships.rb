module Hecks
  module Bluebook
    module DSL
      # The words that tie an aggregate to others: `reference_to`, `has_many`, `has_one`,
      # `belongs_to`, and the `projects` fields read through a reference.
      class AggregateBuilder
        # Declares a reference from this aggregate's own head to another aggregate's identity.
        #
        # @param type [Module, Symbol, String] the referenced aggregate, written as a bare
        #   constant
        # @param as [Symbol, nil] the attribute's name; nil derives it from `type`
        # @param optional [Boolean] whether the reference may be absent
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] if `as` (or the derived name) is already declared
        def reference_to_impl(type, as: nil, optional: false)
          target = Naming.demodulise(type)
          @reference_targets << target
          relationship_attribute(target, :reference_to,
                                 as || default_reference_name(target), optional: optional)
        end

        # Declares that this aggregate holds its own kept-fresh copy of a field reached through
        # a reference, so a rule can read it locally instead of reaching across the boundary.
        #
        # `from:` names the local reference, not the target aggregate, so two references to the
        # same aggregate can each carry their own projection.
        #
        # @param name [Symbol, String] the local field receiving the projected remote value
        # @param from [Symbol, String] the local reference and remote field, dotted, such as
        #   `:"customer.status"`
        # @return [Array<Bluebook::ProjectedField>] every projected field declared so far, this
        #   one last
        # @raise [Bluebook::DSL::Malformed] if `from` is not `reference.field` shaped
        def projects_impl(name, from:)
          reference, _, remote_field = from.to_s.rpartition(".")

          if reference.empty? || remote_field.empty?
            raise Malformed,
                  "#{@name}.projects :#{name} names #{from.inspect}, which is not " \
                  "reference.field — say which reference and which field on it, e.g. " \
                  "from: :\"customer.status\""
          end

          @projected_fields << ProjectedField.new(name: name.to_sym, reference: reference.to_sym,
                                                  remote_field: remote_field.to_sym)
        end

        # `has_many_impl`/`has_one_impl` are DSL keywords (`has_many`/`has_one` in a bluebook),
        # not real predicates, so Naming/PredicatePrefix does not apply here.
        # rubocop:disable Naming/PredicatePrefix

        # Declares a list-typed relationship to another aggregate, referenced by its plural name.
        #
        # Under `MetaValidator.shadow_parsing?`, routes to the collapsing single-reference
        # form instead, so frozen era text keeps its original meaning.
        #
        # @param type [Module, Symbol, String] the related aggregate's plural name, a bare constant
        # @param as [Symbol, nil] the attribute's name; nil derives it from `type`
        # @param legacy_options [Hash] must be empty outside shadow-parsing; under
        #   shadow-parsing, `:optional` is read for the legacy single-reference form
        # @return [void]
        # @raise [Bluebook::DSL::Malformed] outside shadow-parsing, if non-empty, or if the
        #   derived name is already declared
        def has_many_impl(type, as: nil, **legacy_options)
          return legacy_has_many(type, as: as, optional: legacy_options.fetch(:optional, false)) if MetaValidator.shadow_parsing?

          refuse_has_many_options!(legacy_options)

          plural = Naming.demodulise(type)
          target = Naming.singularize(plural)
          @reference_targets << target
          relationship_attribute(target, :has_many, as || Naming.snake(plural).to_sym,
                                 list: true)
        end

        # Declares a single-valued relationship this aggregate holds toward another.
        #
        # @param type [Module, Symbol, String] the related aggregate, a bare constant
        # @param as [Symbol, nil] the attribute's name; nil derives it from `type`
        # @param optional [Boolean] whether the relationship may be absent
        # @return [void]
        def has_one_impl(type, as: nil, optional: false)
          return legacy_has_one(type, as: as, optional: optional) if MetaValidator.shadow_parsing?

          target = Naming.demodulise(type)
          @reference_targets << target
          relationship_attribute(target, :has_one, as || Naming.snake(target).to_sym,
                                 optional: optional)
        end
        # rubocop:enable Naming/PredicatePrefix

        # Declares a single-valued relationship toward the aggregate that owns this one.
        #
        # @param type [Module, Symbol, String] the owning aggregate, a bare constant
        # @param as [Symbol, nil] the attribute's name; nil derives it from `type`
        # @param optional [Boolean] whether the relationship may be absent
        # @return [void]
        def belongs_to_impl(type, as: nil, optional: false)
          return legacy_has_one(type, as: as, optional: optional) if MetaValidator.shadow_parsing?

          target = Naming.demodulise(type)
          @reference_targets << target
          relationship_attribute(target, :belongs_to, as || Naming.snake(target).to_sym,
                                 optional: optional)
        end

        private

        def refuse_has_many_options!(options)
          return if options.empty?

          raise Malformed,
                "#{@name}.has_many takes no #{options.keys.first}: — an empty list already means none"
        end

        # Shadow-parsing's collapsing behavior for has_many/has_one/belongs_to.
        def legacy_has_many(type, as:, optional: false)
          plural = Naming.demodulise(type)
          reference_to_impl(Naming.singularize(plural), as: as || Naming.snake(plural).to_sym, optional: optional)
        end

        def legacy_has_one(type, as:, optional: false)
          reference_to_impl(type, as: as || Naming.snake(Naming.demodulise(type)).to_sym, optional: optional)
        end
      end
    end
  end
end
