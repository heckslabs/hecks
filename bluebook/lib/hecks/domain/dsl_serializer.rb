module Hecks
  # Hecks::DslSerializer
  #
  # Serializes a Domain IR back into DSL source code. The output is valid
  # Ruby that can be eval'd to reconstruct the domain.
  #
  #   DslSerializer.new(domain).serialize
  #   # => 'Hecks.domain "Pizzas" do ...'
  #
  class DslSerializer
    def initialize(domain)
      @domain = domain
    end

    # @return [String] valid Ruby DSL source code
    def serialize
      lines = ["Hecks.domain \"#{@domain.name}\" do"]
      lines << "  description \"#{@domain.description}\"" if @domain.description
      @domain.aggregates.each_with_index do |agg, i|
        lines << "" if i > 0
        lines.concat(serialize_aggregate(agg))
      end
      @domain.policies.each { |pol| lines.concat(serialize_domain_policy(pol)) }
      lines << "end"
      lines.join("\n") + "\n"
    end

    private

    def serialize_aggregate(agg)
      lines = ["  aggregate \"#{agg.name}\" do"]
      lines << "    description \"#{agg.description}\"" if agg.description
      lines.concat(serialize_attributes(agg.attributes, "    "))
      lines.concat(serialize_references(agg.references, "    "))
      lines.concat(serialize_value_objects(agg.value_objects))
      lines.concat(serialize_entities(agg.entities))
      lines.concat(serialize_validations(agg.validations))
      lines.concat(serialize_invariants(agg.invariants, "    "))
      lines.concat(serialize_scopes(agg.scopes))
      lines.concat(serialize_computed_attributes(agg.computed_attributes))
      lines.concat(serialize_queries(agg.queries))
      lines.concat(serialize_specifications(agg.specifications))
      lines.concat(serialize_commands(agg.commands))
      lines.concat(serialize_policies(agg.policies))
      lines.concat(serialize_subscribers(agg.subscribers))
      lines << "  end"
      lines
    end

    def serialize_attributes(attrs, indent)
      attrs.map { |a| "#{indent}attribute :#{a.name}, #{dsl_type(a)}" }
    end

    def serialize_value_objects(vos)
      vos.flat_map do |vo|
        lines = ["", "    value_object \"#{vo.name}\" do"]
        lines << "      description \"#{vo.description}\"" if vo.description
        lines.concat(serialize_attributes(vo.attributes, "      "))
        lines.concat(serialize_invariants(vo.invariants, "      "))
        lines << "    end"
      end
    end

    def serialize_entities(entities)
      entities.flat_map do |ent|
        lines = ["", "    entity \"#{ent.name}\" do"]
        lines << "      description \"#{ent.description}\"" if ent.description
        lines.concat(serialize_attributes(ent.attributes, "      "))
        lines.concat(serialize_invariants(ent.invariants, "      "))
        lines << "    end"
      end
    end

    def serialize_validations(validations)
      validations.map { |v| ["", "    validation :#{v.field}, #{v.rules.inspect}"] }.flatten
    end

    def serialize_invariants(invariants, indent)
      invariants.flat_map do |inv|
        ["", "#{indent}invariant \"#{inv.message}\" do",
         "#{indent}  #{Hecks::Utils.block_source(inv.block)}",
         "#{indent}end"]
      end
    end

    def serialize_scopes(scopes)
      scopes.reject(&:callable?).flat_map do |s|
        formatted = s.conditions.map { |k, v| "#{k}: #{v.inspect}" }.join(", ")
        ["", "    scope :#{s.name}, #{formatted}"]
      end
    end

    def serialize_queries(queries)
      queries.flat_map do |q|
        ["", "    query \"#{q.name}\" do",
         "      #{Hecks::Utils.block_source(q.block)}",
         "    end"]
      end
    end

    def serialize_computed_attributes(computed_attrs)
      (computed_attrs || []).flat_map do |ca|
        ["", "    computed :#{ca.name} do",
         "      #{Hecks::Utils.block_source(ca.block)}",
         "    end"]
      end
    end

    def serialize_specifications(specs)
      specs.flat_map do |spec|
        params = spec.block&.parameters&.map { |_, n| n.to_s } || []
        param_str = params.empty? ? "|object|" : "|#{params.join(", ")}|"
        ["", "    specification \"#{spec.name}\" do #{param_str}",
         "      #{Hecks::Utils.block_source(spec.block)}",
         "    end"]
      end
    end

    def serialize_references(refs, indent)
      (refs || []).map do |ref|
        role_opt = ref.name.to_s == ref.type.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                                           .gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase ? "" : ", role: \"#{ref.name}\""
        qualified = ref.domain ? "#{ref.domain}::#{ref.type}" : ref.type
        "#{indent}reference_to \"#{qualified}\"#{role_opt}"
      end
    end

    def serialize_commands(commands)
      commands.flat_map do |cmd|
        lines = ["", "    command \"#{cmd.name}\" do"]
        lines << "      description \"#{cmd.description}\"" if cmd.description
        if cmd.emits
          emits_names = Array(cmd.emits)
          lines << "      emits #{emits_names.map { |n| "\"#{n}\"" }.join(", ")}"
        end
        lines.concat(serialize_attributes(cmd.attributes, "      "))
        lines.concat(serialize_references(cmd.references, "      "))
        cmd.read_models.each { |rm| lines << "      read_model \"#{rm.name}\"" }
        cmd.external_systems.each { |ext| lines << "      external \"#{ext.name}\"" }
        cmd.actors.each { |act| lines << "      actor \"#{act.name}\"" }
        lines << "    end"
      end
    end

    def serialize_policies(policies)
      policies.flat_map do |pol|
        lines = ["", "    policy \"#{pol.name}\" do"]
        lines << "      description \"#{pol.description}\"" if pol.description
        lines << "      on \"#{pol.event_name}\""
        lines << "      trigger \"#{pol.trigger_command}\""
        lines << "      async true" if pol.async
        lines << "      condition { |event| #{Hecks::Utils.block_source(pol.condition)} }" if pol.condition
        lines << "    end"
      end
    end

    def serialize_subscribers(subscribers)
      subscribers.flat_map do |sub|
        async_opt = sub.async ? ", async: true" : ""
        lines = ["", "    on_event \"#{sub.event_name}\"#{async_opt} do |event|"]
        lines << "      #{Hecks::Utils.block_source(sub.block)}" if sub.block
        lines << "    end"
      end
    end

    def serialize_domain_policy(pol)
      lines = ["", "  policy \"#{pol.name}\" do"]
      lines << "    on \"#{pol.event_name}\""
      lines << "    trigger \"#{pol.trigger_command}\""
      lines << "    async true" if pol.async
      if pol.attribute_map.any?
        mapping = pol.attribute_map.map { |from, to| "#{from}: :#{to}" }.join(", ")
        lines << "    map #{mapping}"
      end
      lines << "    condition { |event| #{Hecks::Utils.block_source(pol.condition)} }" if pol.condition
      lines << "  end"
      lines
    end

    def dsl_type(attr)
      if attr.list?
        "list_of(\"#{attr.type}\")"
      else
        attr.type.to_s
      end
    end
  end
end
