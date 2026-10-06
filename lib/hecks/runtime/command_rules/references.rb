require_relative "../errors"
require_relative "../refusal_wording"
require_relative "../value"
require_relative "../../rendering"
require_relative "tenant_boundary"

module Hecks
  module Runtime
    class CommandRules
      # Refuses a `reference_to` whose target identity does not exist.
      module References
        # Checks reference-typed command arguments against their target repositories.
        # Cross-domain targets are skipped: they may legitimately not be loaded.
        #
        # @raise [Runtime::NotFound] if an argument names an identity that does not exist
        def resolve_references(domain, command, args)
          command.attributes.each do |attribute|
            next unless attribute.reference? && args.key?(attribute.name)

            validate_reference_argument(domain, attribute, args[attribute.name])
          end
        end

        # Re-checks references, cardinality and tenant agreement against settled state.
        #
        # @raise [Runtime::TypeMismatch] if a required `has_one`/`belongs_to` holds nil
        # @raise [Runtime::NotFound] if a reference names an identity that does not exist
        # @raise [Runtime::Unauthorized] if a referenced record belongs to another tenant
        def resolve_state_references(domain, construct, state)
          boundary = TenantBoundary.new(self, domain, construct, state, tenant_field_for(construct))

          construct.attributes.each do |attribute|
            next unless attribute.reference?

            resolve_state_reference(domain, construct, attribute, state, boundary)
          end

          resolve_entity_references(domain, construct, state)
        end

        # One reference-typed argument's value, refused unless its target identity exists.
        def validate_reference_argument(domain, attribute, held)
          return if held.nil?

          target = referenced_aggregate(attribute)
          validate_reference_values(domain, target, held, list: attribute.list?) if target
        end

        # One reference-typed attribute of settled state: cardinality, target and tenant.
        def resolve_state_reference(domain, construct, attribute, state, boundary)
          held = state[attribute.name]
          validate_relationship_cardinality(construct, attribute, held)
          return if held.nil?

          target = referenced_aggregate(attribute)
          return unless target

          validate_reference_values(domain, target, held, list: attribute.list?)
          enforce_tenant_boundary(boundary, attribute, target, held)
        end

        # Re-checks the rows of each entity list `construct` holds, as their own constructs.
        def resolve_entity_references(domain, construct, state)
          Array(construct.entities).each do |entity|
            field = entity_list_field(construct, entity)
            next unless field

            Array(state[field.name]).each { |row| resolve_state_references(domain, entity, row) }
          end
        end

        # The attribute of `construct` that holds `entity`'s rows, by name or by type.
        def entity_list_field(construct, entity)
          construct.attribute(Naming.snake(entity.hecks_name).to_sym) ||
            construct.attributes.find { |attribute| attribute.type.to_s == entity.hecks_name.to_s }
        end

        # `has_one` and `belongs_to` require a target unless optional. Checked on state,
        # since a command may leave the field untouched.
        def validate_relationship_cardinality(construct, attribute, held)
          return if attribute.relationship.nil? || attribute.list?
          return unless held.nil? && !attribute.optional?

          raise TypeMismatch,
                "#{construct.hecks_name}.#{attribute.name} is a required " \
                "#{attribute.relationship} relationship — expected one " \
                "#{attribute.type.target_name} identity, got nil"
        end

        # Resolves the attribute's target through the chapter IR.
        #
        # @raise [Bluebook::DSL::Malformed] if the reference does not know its declaring aggregate
        def referenced_aggregate(attribute)
          attribute.type.resolve
        end

        # Refuses a reference-typed value whose target identity does not exist.
        def validate_reference_values(domain, target, held, list:)
          values = list ? Array(held) : [held]
          values.each do |value|
            key = reference_key(value)
            next if key.empty?
            next if @registry.repository(domain, target).find(key)

            raise NotFound,
                  RefusalWording.render_site("NotFound", "reference_target_missing",
                                             target: target.name, heads: target.identity_heads.join(", "),
                                             key: key)
          end
        end

        # Refuses a write whose record and referenced record disagree about their tenant.
        # Hooked into `resolve_state_references` so both interpreters are covered.
        def enforce_tenant_boundary(boundary, attribute, target, held)
          boundary.enforce(attribute, target, held, tenant_field_for(target))
        end

        # The field a query names in `authorize policy, tenant: :field`, or nil.
        def tenant_field_for(construct)
          authorization = construct.queries.filter_map(&:authorization).find(&:tenant)
          authorization&.tenant&.to_sym
        end

        # Renders a reference value as the string key its target record is looked up by.
        #
        # A compound identity arrives as a Value; `materialize_unwrapped` is needed so it joins
        # like `Identity.of` instead of rendering `Object#to_s`.
        def reference_key(value)
          unwrapped = Value.materialize_unwrapped(value)
          return Naming.identity(unwrapped.values).to_s if unwrapped.is_a?(Hash)

          unwrapped.to_s
        end

        # Recursion bound; simpler than cycle detection for a cycle no corpus rule declares.
        DEREFERENCE_DEPTH = 4
        private_constant :DEREFERENCE_DEPTH

        # Hydrates reference-typed attributes into the records they name, so `given`/`ensures`
        # can dot into them. Only command arguments are dereferenced (ADR 0025); a stored
        # reference must be a `projects` field.
        #
        # @return [Hash{Symbol => Object}] keyed by attribute name with `_id` stripped
        def dereference(domain, owner, source, depth: DEREFERENCE_DEPTH)
          return {} if depth <= 0 || owner.nil?

          owner.attributes.each_with_object({}) do |attribute, hydrated|
            next unless attribute.reference?

            target, record = dereferenced_record(domain, attribute, source)
            next unless record

            hydrated[dereferenced_name(attribute)] =
              record.state.merge(dereference(domain, target, record.state, depth: depth - 1))
          end
        end

        def dereferenced_name(attribute)
          attribute.name.to_s.delete_suffix("_id").to_sym
        end

        # The target aggregate and stored record a reference argument names, or nil when it names
        # nothing that exists.
        def dereferenced_record(domain, attribute, source)
          id = source[attribute.name]
          return if id.nil?

          target = referenced_aggregate(attribute)
          return unless target

          record = @registry.repository(domain, target).find(id.to_s)
          [target, record] if record
        end
      end
    end
  end
end
