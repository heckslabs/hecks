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
        # rubocop:disable-next Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity
        def identified_by_impl(*targets, as: nil, &definition)
          return legacy_identified_by(*targets, as: as, &definition) if MetaValidator.shadow_parsing?

          refuse_second_identity!

          if definition
            unless targets.empty?
              raise Malformed,
                    "#{@name}.identified_by cannot combine a value-object type with a block"
            end

            type_name = identity_value_object_name
            value_object =
              begin
                ValueObjectBuilder.build(
                  type_name,
                  owner_value_objects: identity_pool,
                  &definition
                )
              rescue NameError => e
                # Must raise Malformed: EraGuard.shadow_parse retries frozen text only on
                # Malformed, and a bare identifier in an old block form raises NameError here.
                raise Malformed,
                      "#{@name}.identified_by do ... end could not be read as a value-object " \
                      "definition: #{e.message}"
              end
            raise Malformed, "#{@name}.identified_by do declares no identity attributes" if value_object.attributes.empty?

            install_identity_value_object!(value_object)
            @identity_type_pending = [value_object, as || :identity, attributes.size]
            return
          end

          raise Malformed, "#{@name}.identified_by names no identity" if targets.empty?

          if targets.one? && identity_type?(targets.first)
            @identity_type_pending = [targets.first, as, attributes.size]
            return
          end

          if targets.one?
            field = targets.first
            if as
              raise Malformed,
                    "#{@name}.identified_by takes no as: — name the declared field itself"
            end
            # Transitional: the self-hosted language and live corpus still use this form.
            @identity_field_pending = field
            return
          end

          unless targets.all? { |target| !identity_type?(target) }
            raise Malformed,
                  "#{@name}.identified_by takes one value-object type or two or more attribute names, not both"
          end
          raise Malformed, "#{@name}.identified_by compound keys take no as:" if as

          @identity_fields_pending = targets
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

          return unless @identity_type_pending || @identity_field_pending || @identity_fields_pending ||
                        (@identity_paths && !@identity_paths.empty?)

          raise Malformed, "#{@name} declares identified_by more than once"
        end

        # Parses the spellings frozen era text uses, for `EraGuard.shadow_parse`.
        def legacy_identified_by(*targets, as:, &path)
          target = targets.first
          if target
            raise Malformed, "#{@name}.identified_by takes a field name/value object or a block, not both" if path

            if targets.size > 1
              raise Malformed, "#{@name}.identified_by takes no as: with a compound key" if as

              @identity_fields_pending = targets
              return
            end

            if identity_type?(target)
              @identity_type_pending = [target, as, attributes.size]
            else
              if as
                raise Malformed,
                      "#{@name}.identified_by :#{target} takes no as: — as: only applies to identified_by ValueObject"
              end

              @identity_field_pending = target
            end
            return
          end

          raise Malformed, "#{@name}.identified_by names no field" unless path

          paths = Ports::Extraction.canonical(path).to_s.split.reject(&:empty?)
          raise Malformed, "#{@name}.identified_by names no field" if paths.empty?

          @identity_paths = paths
        end
      end
    end
  end
end
