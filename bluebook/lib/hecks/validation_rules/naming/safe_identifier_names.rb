module Hecks
  module ValidationRules
    module Naming

    # Hecks::ValidationRules::Naming::SafeIdentifierNames
    #
    # Validates that all names in the domain model contain only safe characters
    # that can be interpolated into generated Go (and Ruby) code without risk of
    # injection or syntax errors. Enforces strict character-set rules per category:
    #
    # - Type-level names (aggregates, VOs, entities, commands, events, queries,
    #   policies): /\A[A-Z][a-zA-Z0-9]*\z/
    # - Attribute names and lifecycle fields: /\A[a-z][a-z0-9_]*\z/
    # - Lifecycle state values: /\A[a-z][a-z0-9_]*\z/
    # - Domain names: /\A[A-Z][a-zA-Z0-9]*\z/
    # - Enum values: /\A[a-zA-Z0-9_]+\z/
    # - Invariant messages: no backticks, no unbalanced quotes
    #
    # Part of the ValidationRules::Naming group -- run by +Hecks.validate+.
    #
    #   rule = SafeIdentifierNames.new(domain)
    #   rule.errors  # => ["Unsafe aggregate name 'Pizza`Danger': ..."]
    #
    class SafeIdentifierNames < BaseRule
      TYPE_NAME_RE   = /\A[A-Z][a-zA-Z0-9]*\z/
      ATTR_NAME_RE   = /\A[a-z][a-z0-9_]*\z/
      DOMAIN_NAME_RE = /\A[A-Z][a-zA-Z0-9]*\z/
      ENUM_VALUE_RE  = /\A[a-zA-Z0-9_]+\z/

      # Validates all names in the domain model.
      #
      # @return [Array<String>] error messages for each unsafe name found
      def errors
        errs = []
        errs.concat(check_domain_name)
        @domain.aggregates.each do |agg|
          errs.concat(check_type_name(agg.name, "aggregate"))
          errs.concat(check_aggregate_members(agg))
        end
        errs
      end

      private

      # Validates the domain name.
      #
      # @return [Array<String>] error messages (empty if valid)
      def check_domain_name
        return [] if @domain.name =~ DOMAIN_NAME_RE
        [error("Unsafe domain name '#{@domain.name}': must start with an uppercase letter and contain only alphanumeric characters",
          hint: "Rename your domain to PascalCase, e.g. 'MyDomain'")]
      end

      # Validates all members of an aggregate: attributes, value objects,
      # entities, commands, events, queries, policies, lifecycle, and invariants.
      #
      # @param agg [Hecks::DomainModel::Structure::Aggregate] the aggregate to check
      # @return [Array<String>] error messages (empty if all valid)
      def check_aggregate_members(agg)
        errs = []
        agg.attributes.each do |attr|
          errs.concat(check_attr_name(attr.name.to_s, agg.name))
          errs.concat(check_enum_values(attr, agg.name))
        end
        agg.value_objects.each do |vo|
          errs.concat(check_type_name(vo.name, "value object"))
          vo.attributes.each do |attr|
            errs.concat(check_attr_name(attr.name.to_s, "#{agg.name}::#{vo.name}"))
            errs.concat(check_enum_values(attr, "#{agg.name}::#{vo.name}"))
          end
        end
        agg.entities.each do |ent|
          errs.concat(check_type_name(ent.name, "entity"))
          ent.attributes.each do |attr|
            errs.concat(check_attr_name(attr.name.to_s, "#{agg.name}::#{ent.name}"))
          end
        end
        agg.commands.each do |cmd|
          errs.concat(check_type_name(cmd.name, "command"))
          cmd.attributes.each do |attr|
            errs.concat(check_attr_name(attr.name.to_s, "#{agg.name}::#{cmd.name}"))
          end
        end
        agg.events.each  { |evt| errs.concat(check_type_name(evt.name, "event")) }
        agg.queries.each { |q|   errs.concat(check_type_name(q.name, "query")) }
        agg.policies.each { |pol| errs.concat(check_type_name(pol.name, "policy")) }
        errs.concat(check_lifecycle(agg))
        agg.invariants.each { |inv| errs.concat(check_invariant_message(inv.message, agg.name)) }
        errs
      end

      # Validates a PascalCase type-level name.
      #
      # @param name [String] the name to validate
      # @param kind [String] the label for the error message (e.g., "aggregate")
      # @return [Array<String>] error messages (empty if valid)
      def check_type_name(name, kind)
        return [] if name =~ TYPE_NAME_RE
        [error("Unsafe #{kind} name '#{name}': must start with an uppercase letter and contain only alphanumeric characters",
          hint: "Rename to PascalCase with only letters and digits")]
      end

      # Validates an attribute or lifecycle field name (snake_case).
      #
      # @param name [String] the attribute name to validate
      # @param context [String] the context label for the error message
      # @return [Array<String>] error messages (empty if valid)
      def check_attr_name(name, context)
        return [] if name =~ ATTR_NAME_RE
        [error("Unsafe attribute name '#{name}' in #{context}: must start with a lowercase letter and contain only lowercase letters, digits, and underscores",
          hint: "Rename to snake_case, e.g. 'my_attribute'")]
      end

      # Validates enum values on an attribute.
      #
      # @param attr [Hecks::DomainModel::Structure::Attribute] the attribute to check
      # @param context [String] the context label for the error message
      # @return [Array<String>] error messages (empty if all enum values are valid)
      def check_enum_values(attr, context)
        return [] unless attr.enum
        attr.enum.flat_map do |val|
          next [] if val.to_s =~ ENUM_VALUE_RE
          [error("Unsafe enum value '#{val}' on attribute '#{attr.name}' in #{context}: must contain only alphanumeric characters and underscores",
            hint: "Use only letters, digits, and underscores in enum values")]
        end
      end

      # Validates lifecycle field, default state, and all transition states.
      #
      # @param agg [Hecks::DomainModel::Structure::Aggregate] the aggregate to check
      # @return [Array<String>] error messages (empty if no lifecycle or all valid)
      def check_lifecycle(agg)
        lc = agg.lifecycle
        return [] unless lc
        errs = []
        errs.concat(check_attr_name(lc.field.to_s, "#{agg.name} lifecycle field"))
        errs.concat(check_state_value(lc.default.to_s, agg.name, "default"))
        lc.transitions.each do |cmd_name, transition|
          target = transition.respond_to?(:target) ? transition.target : transition.to_s
          errs.concat(check_state_value(target, agg.name, "transition target for #{cmd_name}"))
          if transition.respond_to?(:from) && transition.from
            errs.concat(check_state_value(transition.from.to_s, agg.name, "transition from-state for #{cmd_name}"))
          end
        end
        errs
      end

      # Validates a lifecycle state value (must be snake_case).
      #
      # @param value [String] the state value to validate
      # @param agg_name [String] aggregate name for context
      # @param label [String] label describing where this state value appears
      # @return [Array<String>] error messages (empty if valid)
      def check_state_value(value, agg_name, label)
        return [] if value =~ ATTR_NAME_RE
        [error("Unsafe lifecycle state '#{value}' (#{label}) in #{agg_name}: must start with a lowercase letter and contain only lowercase letters, digits, and underscores",
          hint: "Rename to snake_case, e.g. 'my_state'")]
      end

      # Validates an invariant message for dangerous characters.
      # Backticks are rejected outright (they break Go raw string literals and
      # Ruby heredocs). Unbalanced double quotes are also flagged since they can
      # break out of interpolated string contexts in generated code. Single
      # quotes (apostrophes) are not checked because contractions in natural
      # English messages are common and safe.
      #
      # @param message [String] the invariant message to validate
      # @param agg_name [String] aggregate name for context
      # @return [Array<String>] error messages (empty if safe)
      def check_invariant_message(message, agg_name)
        errs = []
        if message.include?("`")
          errs << error("Unsafe invariant message in #{agg_name}: backtick not allowed in '#{message}'",
            hint: "Remove backticks from the invariant message")
        end
        if message.count('"').odd?
          errs << error("Unsafe invariant message in #{agg_name}: unbalanced double quotes in '#{message}'",
            hint: "Balance the double quotes or remove them from the message")
        end
        errs
      end
    end
    Hecks.register_validation_rule(SafeIdentifierNames)
    end
  end
end
