module Hecks
  module MCP
    # Hecks::MCP::DomainSerializer
    #
    # Serializes a Hecks domain model into structured JSON for MCP tool responses.
    # Converts the full domain IR (aggregates, commands, queries, policies,
    # validations, invariants, value objects, entities, services) into a nested
    # Hash suitable for JSON output.
    #
    # Used by InspectTools#describe_domain to give AI agents a complete, parseable
    # view of the domain in a single call.
    #
    #   domain = session.to_domain
    #   json = Hecks::MCP::DomainSerializer.call(domain)
    #   # => { domain: "Pizzas", aggregates: [...], policies: [...], services: [...] }
    #
    module DomainSerializer
      # Serializes a full domain model into a structured Hash.
      #
      # @param domain [Hecks::DomainModel::Structure::Domain] the domain to serialize
      # @return [Hash] structured representation of the entire domain
      def self.call(domain)
        {
          domain: domain.name,
          aggregates: domain.aggregates.map { |agg| serialize_aggregate(agg) },
          policies: domain.policies.map { |p| serialize_policy(p) },
          services: domain.services.map { |s| serialize_service(s) }
        }
      end

      # Serializes an aggregate into a Hash with all of its components.
      #
      # @param agg [Hecks::DomainModel::Structure::Aggregate] the aggregate
      # @return [Hash] structured aggregate data
      def self.serialize_aggregate(agg)
        {
          name: agg.name,
          attributes: agg.attributes.map { |a| serialize_attribute(a) },
          references: (agg.references || []).map { |r| { name: r.name.to_s, type: r.type, role: r.name.to_s } },
          commands: agg.commands.each_with_index.map { |cmd, i| serialize_command(cmd, agg.events[i]) },
          queries: agg.queries.map { |q| { name: q.name } },
          specifications: agg.specifications.map { |s| { name: s.name } },
          policies: agg.policies.map { |p| serialize_policy(p) },
          validations: agg.validations.map { |v| serialize_validation(v) },
          invariants: agg.invariants.map { |inv| { message: inv.message } },
          value_objects: agg.value_objects.map { |vo| serialize_value_object(vo) },
          entities: agg.entities.map { |e| serialize_entity(e) }
        }
      end

      # Serializes an attribute into a Hash.
      #
      # @param attr [Hecks::DomainModel::Structure::Attribute] the attribute
      # @return [Hash] structured attribute data
      def self.serialize_attribute(attr)
        h = { name: attr.name.to_s, type: attr.ruby_type }
        h[:list] = true if attr.list?
        h[:pii] = true if attr.pii?
        h[:enum] = attr.enum if attr.enum
        h[:default] = attr.default unless attr.default.nil?
        h
      end

      # Serializes a command and its paired event into a Hash.
      #
      # @param cmd [Hecks::DomainModel::Behavior::Command] the command
      # @param event [Hecks::DomainModel::Behavior::DomainEvent, nil] the paired event
      # @return [Hash] structured command data
      def self.serialize_command(cmd, event)
        h = {
          name: cmd.name,
          attributes: cmd.attributes.map { |a| serialize_attribute(a) },
          inferred_event: cmd.inferred_event_name
        }
        h[:guard] = cmd.guard_name if cmd.guard_name
        h[:actors] = cmd.actors unless cmd.actors.empty?
        h[:preconditions] = cmd.preconditions.map(&:message) unless cmd.preconditions.empty?
        h[:postconditions] = cmd.postconditions.map(&:message) unless cmd.postconditions.empty?
        h
      end

      # Serializes a policy into a Hash.
      #
      # @param policy [Hecks::DomainModel::Behavior::Policy] the policy
      # @return [Hash] structured policy data
      def self.serialize_policy(policy)
        h = { name: policy.name }
        if policy.reactive?
          h[:event_name] = policy.event_name
          h[:trigger_command] = policy.trigger_command
          h[:async] = policy.async if policy.async
        end
        h[:type] = policy.guard? ? "guard" : "reactive"
        h
      end

      # Serializes a validation into a Hash.
      #
      # @param validation [Hecks::DomainModel::Structure::Validation] the validation
      # @return [Hash] structured validation data
      def self.serialize_validation(validation)
        h = { field: validation.field.to_s }
        h[:presence] = true if validation.presence?
        h[:type] = validation.type_rule.to_s if validation.type_rule
        h[:uniqueness] = true if validation.uniqueness?
        h
      end

      # Serializes a value object into a Hash.
      #
      # @param vo [Hecks::DomainModel::Structure::ValueObject] the value object
      # @return [Hash] structured value object data
      def self.serialize_value_object(vo)
        {
          name: vo.name,
          attributes: vo.attributes.map { |a| serialize_attribute(a) },
          invariants: vo.invariants.map { |inv| { message: inv.message } }
        }
      end

      # Serializes an entity into a Hash.
      #
      # @param entity [Hecks::DomainModel::Structure::Entity] the entity
      # @return [Hash] structured entity data
      def self.serialize_entity(entity)
        {
          name: entity.name,
          attributes: entity.attributes.map { |a| serialize_attribute(a) },
          invariants: entity.invariants.map { |inv| { message: inv.message } }
        }
      end

      # Serializes a domain service into a Hash.
      #
      # @param service [Hecks::DomainModel::Behavior::Service] the service
      # @return [Hash] structured service data
      def self.serialize_service(service)
        {
          name: service.name,
          attributes: service.attributes.map { |a| serialize_attribute(a) }
        }
      end
    end
  end
end
