# = Hecks::Conventions::DisplayContract
#
# Named display conventions shared by Ruby and Go generators. Every
# inline rendering pattern is defined here once and referenced by
# name, so both targets produce identical UI behavior.
#
#   Hecks::Conventions::DisplayContract.cell_expression(attr, "obj")
#   Hecks::Conventions::DisplayContract.lifecycle_transitions(lifecycle)
#   Hecks::Conventions::DisplayContract.aggregate_summary(agg)
#   Hecks::Conventions::DisplayContract.policy_labels(domain)
#   Hecks::Conventions::DisplayContract.available_roles(domain)
#
module Hecks::Conventions
  module DisplayContract
    # True when the attribute is a foreign-key reference (ends in _id, type String).
    #
    # @param attr [Attribute] the attribute to check
    # @return [Boolean]
    def self.reference_attr?(attr)
      attr.name.to_s.end_with?("_id") && attr.type == String && !attr.list?
    end

    # Column/field label for a reference attribute — strips "_id" and humanizes.
    #   reference_column_label(attr_named(:model_id)) # => "Model"
    #
    # @param attr [Attribute] a reference attribute
    # @return [String] humanized label without "Id"
    def self.reference_column_label(attr)
      base = attr.name.to_s.sub(/_id\z/, "")
      UILabelContract.label(base)
    end

    # Find the aggregate referenced by a _id attribute within a domain.
    #
    # @param attr [Attribute] a reference attribute
    # @param domain [Domain] the domain IR to search
    # @return [Aggregate, nil]
    def self.find_referenced_aggregate(attr, domain)
      base = attr.name.to_s.sub(/_id\z/, "")
      pascal = Hecks::Utils.sanitize_constant(base)
      domain.aggregates.find { |a| a.name == pascal } ||
        domain.aggregates.find { |a| a.name.end_with?(pascal) }
    end

    # Format a cell value for index table display.
    # List attributes show "N items"; scalars show the value.
    # Reference attributes resolve to the referenced entity's name.
    #
    # @param attr [Attribute] the attribute to display
    # @param obj_var [String] the variable name for the object
    # @param lang [Symbol] :ruby or :go
    # @param domain [Domain, nil] domain IR for reference lookups
    # @return [String] code expression
    def self.cell_expression(attr, obj_var, lang:, domain: nil)
      field = lang == :go ? GoFieldName.call(attr.name) : attr.name
      if attr.list?
        case lang
        when :go then "fmt.Sprintf(\"%d items\", len(#{obj_var}.#{field}))"
        when :ruby then "#{obj_var}.#{field}.size.to_s + \" items\""
        end
      elsif reference_attr?(attr) && domain
        ref_agg = find_referenced_aggregate(attr, domain)
        if ref_agg
          ref_const = ref_agg.name
          case lang
          when :ruby
            "(-> { _r = #{ref_const}.all.find { |x| x.id == #{obj_var}.#{field} }; _r&.respond_to?(:name) ? _r.name.to_s : #{obj_var}.#{field}.to_s[0..7] + \"...\" }).call"
          when :go then "fmt.Sprintf(\"%v\", #{obj_var}.#{field})"
          end
        else
          case lang
          when :go then "fmt.Sprintf(\"%v\", #{obj_var}.#{field})"
          when :ruby then "#{obj_var}.#{field}.to_s[0..7] + \"...\""
          end
        end
      else
        case lang
        when :go then "fmt.Sprintf(\"%v\", #{obj_var}.#{field})"
        when :ruby then "#{obj_var}.#{field}.to_s"
        end
      end
    end

    # Format lifecycle transitions for display.
    # Returns array of "Command Name → target_state" strings.
    #
    # @param lc [Lifecycle] the lifecycle IR
    # @return [Array<String>] formatted transition labels
    def self.lifecycle_transitions(lc)
      lc.transitions.map do |cmd_name, _|
        label = UILabelContract.label(Hecks::Utils.underscore(cmd_name))
        target = lc.target_for(cmd_name)
        "#{label} \u2192 #{target}"
      end
    end

    # Extract aggregate summary strings for config page.
    #
    # @param agg [Aggregate] the aggregate IR
    # @return [Hash] { commands: "Cmd1, Cmd2", ports: "admin: find | guest: all" }
    def self.aggregate_summary(agg)
      cmds = agg.commands.map(&:name).join(", ")
      ports = agg.ports.values.map { |p|
        "#{p.name}: #{p.allowed_methods.join(", ")}"
      }.join(" | ")
      ports = "(none)" if ports.empty?
      { commands: cmds, ports: ports }
    end

    # Format all policies (aggregate + domain level) for display.
    #
    # @param domain [Domain] the domain IR
    # @return [Array<String>] formatted "EventName → PolicyName" strings
    def self.policy_labels(domain)
      agg_policies = domain.aggregates.flat_map { |a|
        a.policies.reject { |p| p.respond_to?(:guard?) && p.guard? }
          .map { |p| "#{p.event_name} \u2192 #{p.name}" }
      }
      domain_policies = domain.policies.map { |p|
        "#{p.event_name} \u2192 #{p.trigger_command}"
      }
      agg_policies + domain_policies
    end

    # Extract available roles from port definitions.
    # Falls back to ["admin"] if no ports are defined.
    #
    # @param domain [Domain] the domain IR
    # @return [Array<String>] role names
    def self.available_roles(domain)
      roles = domain.aggregates.flat_map { |a| a.ports.keys }.uniq.map(&:to_s)
      roles.empty? ? ["admin"] : roles
    end

    # Determine the display field for a reference dropdown.
    # Uses "name" if the referenced aggregate has it, otherwise "id".
    #
    # @param ref_agg [Aggregate] the referenced aggregate
    # @return [String] the field name to display
    # Returns the field name to display in reference dropdowns.
    # Go callers should use go_reference_display_field for correct casing.
    def self.reference_display_field(ref_agg)
      ref_agg.attributes.find { |a| a.name.to_s == "name" } ? "name" : "id"
    end

    # Go-specific: returns PascalCase field name (ID not Id).
    def self.go_reference_display_field(ref_agg)
      ref_agg.attributes.find { |a| a.name.to_s == "name" } ? "Name" : "ID"
    end

    # Build home page aggregate card data.
    #
    # @param agg [Aggregate] the aggregate IR
    # @param plural [String] the plural URL segment
    # @return [Hash] { name:, href:, command_names:, attributes:, policies: }
    def self.home_aggregate_data(agg, plural)
      user_attrs = agg.attributes.reject { |a|
        Hecks::Utils::RESERVED_AGGREGATE_ATTRS.include?(a.name.to_s)
      }
      {
        name: UILabelContract.plural_label(agg.name),
        href: "/#{plural}",
        command_names: agg.commands.map { |c| UILabelContract.label(c.name) }.join(", "),
        attributes: user_attrs.size,
        policies: agg.policies.size,
      }
    end

    # Humanized domain name for display.
    # "GovernanceDomain" → "Governance"
    def self.domain_label(domain_name)
      UILabelContract.label(domain_name.sub(/Domain$/, ""))
    end

    # Go field name helper — PascalCase.
    GoFieldName = ->(name) { Hecks::Utils.sanitize_constant(name) }
  end
end
