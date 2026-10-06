module Hecks
  module Fuzzing
    module Properties
      # Tenant-scoping property over a replayed history: no stored record references a record
      # carrying a different tenant value.
      module TenantScope
        # One stored record under inspection: where it lives, its state, and its own tenant.
        Record = Struct.new(:bluebooks, :instances, :key, :domain_name, :state, :field, :tenant) do
          # The aggregate called `name` in the record's own domain, or nil.
          def aggregate_named(name) = bluebooks[domain_name]&.aggregate(name)

          # The key of the stored record `id` of `target` in the record's own domain.
          def target_key(target, id) = "#{domain_name}::#{target.name}##{id}"
        end

        # Checks that no stored record references a record carrying a different tenant value.
        #
        # Commands cannot declare `authorize`, so nothing refuses a cross-tenant write.
        # Tenants compare via Query::InMemory.comparable: value objects with different
        # declared names are unequal under Value#== even for the same tenant.
        def commands_respect_tenant_scope(history)
          bluebooks = history.fetch(:bluebooks)
          instances = history.fetch(:instances)
          offenders = instances.flat_map { |key, state| tenant_offenders(bluebooks, instances, key, state) }
          offenders.empty? || offenders.join("; ")
        end

        # One message per reference of the stored record `key` that crosses a tenant.
        def tenant_offenders(bluebooks, instances, key, state)
          domain_name = key.split("::").first
          aggregate = aggregate_for_key(bluebooks, key)
          return [] unless aggregate

          field = tenant_field_for(aggregate)
          return [] unless field && state.key?(field)

          record = Record.new(bluebooks, instances, key, domain_name, state, field,
                              Ports::Query::InMemory.comparable(state[field]))
          aggregate.attributes.filter_map { |attribute| cross_tenant_offense(record, attribute) }
        end

        # The aggregate a stored-record key `Domain::Aggregate#id` belongs to, or nil.
        def aggregate_for_key(bluebooks, key)
          bluebooks[key.split("::").first]&.aggregate(key.split("::").last.split("#").first)
        end

        # The message for one reference whose target carries a different tenant, or nil.
        def cross_tenant_offense(record, attribute)
          return unless attribute.type.is_a?(Bluebook::Reference)

          target = record.aggregate_named(attribute.type.target_name)
          target_id = record.state[attribute.name]
          return unless target && target_id

          target_field, target_tenant = referenced_tenant(record, target, target_id)
          return if target_field.nil? || target_tenant == record.tenant

          cross_tenant_message(record, "#{attribute.name}: #{target_id.inspect}",
                               record.target_key(target, target_id), target_field, target_tenant)
        end

        def cross_tenant_message(record, reference, target_key, target_field, target_tenant)
          "#{record.key} (#{record.field}: #{record.tenant.inspect}) references #{reference}, " \
            "but #{target_key} carries #{target_field}: #{target_tenant.inspect} — a cross-tenant write nothing refused"
        end

        # The tenant field and value of the stored record `target_id` names, or nil.
        def referenced_tenant(record, target, target_id)
          target_field = tenant_field_for(target)
          target_state = record.instances[record.target_key(target, target_id)]
          return unless target_field && target_state&.key?(target_field)

          [target_field, Ports::Query::InMemory.comparable(target_state[target_field])]
        end

        # The field named by `authorize ..., tenant:` on any of the aggregate's queries, or nil.
        def tenant_field_for(aggregate)
          authorization = aggregate.queries.filter_map(&:authorization).find(&:tenant)
          authorization&.tenant&.to_sym
        end
      end
    end
  end
end
