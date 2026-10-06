module Hecks
  module Bluebook
    module DSL
      # `identified_by`, shared by AggregateBuilder and EntityBuilder (ADR 0025).
      # The includer must include AttributeCollector and define a private `identity_pool`.
      module IdentityDeclaration
        # Records which `identified_by` form a builder declared; resolution waits for build time.
        #
        #   identified_by AccountNumber, as: :number # one identity concept
        #   identified_by do ... end                 # a bespoke concept
        #   identified_by :branch, :number           # an existing compound key
        #
        # @param targets [Array<Symbol, Module>] a value-object type or attribute names
        # @param as [Symbol, nil] the field name to mint for a value-object-type target
        # @yield a bespoke value-object body for the identity's own value object
        # @raise [Bluebook::DSL::Malformed] on a repeat declaration or an invalid mix of forms
        def identified_by_impl(*targets, as: nil, &definition)
          return legacy_identified_by(*targets, as: as, &definition) if MetaValidator.shadow_parsing?

          refuse_second_identity!
          return declare_identity_block(targets, as, definition) if definition

          raise Malformed, "#{@name}.identified_by names no identity" if targets.empty?

          targets.one? ? declare_single_identity(targets.first, as) : declare_compound_identity(targets, as)
        end

        private

        # Resolves the pending identity against `identity_pool` at build time, not call time.
        def resolve_pending_identity!
          if @identity_type_pending
            type, as, insert_at = @identity_type_pending
            @identity_paths = resolve_identity_type!(type, as, insert_at, identity_pool, @name)
          elsif @identity_field_pending
            @identity_paths = resolve_identity_field!(@identity_field_pending, identity_pool, @name)
          elsif @identity_fields_pending
            @identity_paths = @identity_fields_pending.flat_map do |field|
              resolve_identity_field!(field, identity_pool, @name)
            end
          end
        end

        def identity_type?(target) = target.to_s.match?(/\A[A-Z]/)

        def refuse_second_identity!
          # Transitional: a one-symbol declaration may still be replaced by a later one.
          if @identity_field_pending && !@identity_type_pending && !@identity_fields_pending
            @identity_field_pending = nil
            return
          end

          return unless identity_declared?

          raise Malformed, "#{@name} declares identified_by more than once"
        end

        def identity_declared?
          pending = @identity_type_pending || @identity_field_pending || @identity_fields_pending
          pending || (@identity_paths && !@identity_paths.empty?)
        end

        def declare_identity_block(targets, as, definition)
          raise Malformed, "#{@name}.identified_by cannot combine a value-object type with a block" unless targets.empty?

          value_object = build_identity_value_object(identity_value_object_name, definition)
          raise Malformed, "#{@name}.identified_by do declares no identity attributes" if value_object.attributes.empty?

          install_identity_value_object!(value_object)
          @identity_type_pending = [value_object, as || :identity, attributes.size]
          nil
        end

        def build_identity_value_object(type_name, definition)
          ValueObjectBuilder.build(type_name, owner_value_objects: identity_pool, &definition)
        rescue NameError => e
          # Must raise Malformed: EraGuard.shadow_parse retries frozen text only on
          # Malformed, and a bare identifier in an old block form raises NameError here.
          raise Malformed,
                "#{@name}.identified_by do ... end could not be read as a value-object " \
                "definition: #{e.message}"
        end

        def declare_single_identity(target, as)
          if identity_type?(target)
            @identity_type_pending = [target, as, attributes.size]
            return
          end

          raise Malformed, "#{@name}.identified_by takes no as: — name the declared field itself" if as

          # Transitional: the self-hosted language and live corpus still use this form.
          @identity_field_pending = target
          nil
        end

        def declare_compound_identity(targets, as)
          unless targets.none? { |target| identity_type?(target) }
            raise Malformed,
                  "#{@name}.identified_by takes one value-object type or two or more attribute names, not both"
          end
          raise Malformed, "#{@name}.identified_by compound keys take no as:" if as

          @identity_fields_pending = targets
        end

        # Parses the spellings frozen era text uses, for `EraGuard.shadow_parse`.
        def legacy_identified_by(*targets, as:, &path)
          return legacy_identity_target(targets, as, path) if targets.first

          raise Malformed, "#{@name}.identified_by names no field" unless path

          paths = Ports::Extraction.canonical(path).to_s.split.reject(&:empty?)
          raise Malformed, "#{@name}.identified_by names no field" if paths.empty?

          @identity_paths = paths
        end

        def legacy_identity_target(targets, as, path)
          raise Malformed, "#{@name}.identified_by takes a field name/value object or a block, not both" if path

          if targets.size > 1
            raise Malformed, "#{@name}.identified_by takes no as: with a compound key" if as

            @identity_fields_pending = targets
          elsif identity_type?(targets.first)
            @identity_type_pending = [targets.first, as, attributes.size]
          else
            legacy_identity_field(targets.first, as)
          end
          nil
        end

        def legacy_identity_field(target, as)
          if as
            raise Malformed,
                  "#{@name}.identified_by :#{target} takes no as: — as: only applies to identified_by ValueObject"
          end

          @identity_field_pending = target
        end
      end
    end
  end
end
