# HecksValidations
#
# Server-side validation extension for Hecks domains. Reads validation
# rules and value object invariants from the domain IR at boot time and
# builds a static rules table. Provides a validate method that checks
# command parameters against the rules without touching the domain layer.
#
# The rules table is also exposed as JSON via the runtime for HTTP
# endpoints (/_validations) and client-side validation.
#
# Future gem: hecks_validations
#
#   # Gemfile
#   gem "pizzas_domain"
#   gem "hecks_validations"
#
#   # Check params before dispatching
#   error = HecksValidations.validate("Pizza", "create_pizza", name: "")
#   # => #<ValidationError "name can't be blank" field=:name rule=:presence>
#
Hecks.describe_extension(:validations,
  description: "Server-side parameter validation from domain rules",
  adapter_type: :driven,
  config: {},
  wires_to: :command_bus)

Hecks.register_extension(:validations) do |domain_mod, domain, runtime|
  # Build rules table from domain IR
  rules = {}
  domain.aggregates.each do |agg|
    safe = agg.name
    agg.commands.each do |cmd|
      cmd_snake = HecksTemplating::Names.domain_snake_name(cmd.name)
      cmd_rules = {}

      cmd.attributes.each do |attr|
        # Check aggregate-level validations
        validation = agg.validations.find { |val| val.field.to_s == attr.name.to_s }
        if validation
          cmd_rules[attr.name.to_s] = validation.rules.transform_keys(&:to_s)
          next
        end

        # Check if attr maps to a VO field
        agg.value_objects.each do |vo|
          vo_attr = vo.attributes.find { |va| va.name.to_s == attr.name.to_s }
          if vo_attr
            vo_rules = { "presence" => true }
            vo.invariants.each do |inv|
              vo_rules["positive"] = true if inv.message.to_s =~ /#{attr.name}.*positive|#{attr.name}.*> ?0/i
            end
            cmd_rules[attr.name.to_s] = vo_rules
          end
        end
      end

      rules["#{safe}/#{cmd_snake}"] = cmd_rules unless cmd_rules.empty?
    end
  end

  # Store rules on the domain module
  domain_mod.instance_variable_set(:@_validation_rules, rules)
  domain_mod.define_singleton_method(:validation_rules) { @_validation_rules }

  # Provide a validate method that returns a ValidationError or nil
  domain_mod.define_singleton_method(:validate_params) do |aggregate, command, params|
    cmd_rules = @_validation_rules["#{aggregate}/#{command}"]
    return nil unless cmd_rules

    cmd_rules.each do |field, checks|
      val = params[field.to_sym] || params[field.to_s]
      if checks["presence"] && (val.nil? || val.to_s.strip.empty?)
        return Hecks::ValidationError.new("#{field} can't be blank", field: field.to_sym, rule: :presence)
      end
      if checks["positive"] && val && val.to_f <= 0
        return Hecks::ValidationError.new("#{field} must be positive", field: field.to_sym, rule: :positive)
      end
    end
    nil
  end

  # Register command bus middleware that validates before dispatch
  runtime.use :validations do |command, next_handler|
    parts = command.class.name.split("::")
    agg_name = parts[-3]
    cmd_name = parts[-1]
    cmd_snake = HecksTemplating::Names.domain_snake_name(cmd_name)

    # Build params hash from command instance variables
    params = {}
    command.class.instance_method(:initialize).parameters.each do |_param_type, name|
      params[name] = command.send(name) if command.respond_to?(name)
    end

    error = domain_mod.validate_params(agg_name, cmd_snake, params)
    raise error if error

    next_handler.call
  end
end
