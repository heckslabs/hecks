module RustProjection
  module Projector
    module_function

    # One `Fielded` match arm per attribute, shared by value objects, args structs and
    # (via emit_fielded_record) aggregate records.
    # `extra_arms:` are raw `"key" => ...,` lines appended verbatim, e.g. an entity's lifecycle
    # field. Arms render from the leaf shapes in rust/src/exemplar/fielded.rs with a fixed
    # 12-space prefix, using plain `render` because the leaves are shared across outer shapes.
    def emit_fielded_flat(struct_name, attributes, value_objects_by_name, extra_arms: [], entity_names: [])
      arms = attributes.filter_map do |attr|
        key   = rust_field(attr[:name])
        ident = rust_ident_field(attr[:name])
        scalar = effective_scalar_type(attr[:type])
        if attr[:list] && attr[:optional]
          Exemplar.render("fielded_arm_list_optional", '"tmpl_field"' => key.inspect, "tmpl_ident" => ident)
        elsif attr[:list]
          Exemplar.render("fielded_arm_list", '"tmpl_field"' => key.inspect, "tmpl_ident" => ident)
        elsif attr[:optional] && scalar
          Exemplar.render(
            "fielded_arm_optional_scalar",
            '"tmpl_field"' => key.inspect,
            "tmpl_ident" => ident,
            "tmpl_value_expr_placeholder(v)" => scalar_to_value(scalar, "v")
          )
        elsif attr[:optional]
          nested = value_objects_by_name[attr[:type]]
          next nil unless nested && fielded_capable_nested?(nested)

          Exemplar.render("fielded_arm_optional_nested", '"tmpl_field"' => key.inspect, "tmpl_ident" => ident)
        elsif scalar
          Exemplar.render(
            "fielded_arm_scalar",
            '"tmpl_field"' => key.inspect,
            "tmpl_value_expr_placeholder(&self.tmpl_ident)" => scalar_to_value(scalar, "self.#{ident}")
          )
        else
          nested = value_objects_by_name[attr[:type]]
          next nil unless nested && fielded_capable_nested?(nested)

          Exemplar.render("fielded_arm_nested", '"tmpl_field"' => key.inspect, "tmpl_ident" => ident)
        end
      end
      arms = arms.map { |a| "            #{a}" }
      arms += extra_arms

      # The trailing "\n" keeps the blank-line count callers expect; render's dedent rstrips.
      "#{Exemplar.render(
        'fielded_flat',
        'TmplFlatType' => struct_name,
        '"tmpl_arms_placeholder" => tmpl_arms_block(),' => arms.join("\n"),
        # `entity_names`: a list of entities is enumerated the same way the record does.
        '"tmpl_items_placeholder" => tmpl_items_block(),' => items_arms(attributes, value_objects_by_name, entity_names, optional: ->(attr) { attr[:optional] }).join("\n"),
        "tmpl_as_scalar_placeholder()" => as_scalar_expr(attributes),
        # Import only what the arms use, so a struct with no arms leaves no unused `use`.
        'use crate::kernel::Field;' => (arms.any? { |arm| arm.include?('Field') } ? 'use crate::kernel::Field;' : ''),
        'use crate::kernel::Value;' => (arms.any? { |arm| arm.include?('Value') } ? 'use crate::kernel::Value;' : '')
      )}\n"
    end

    # `Fielded::items`: one arm per list attribute whose element is a scalar or a fielded-capable
    # nested type or entity. `optional` says whether the list is `Option`-wrapped.
    def items_arms(attributes, value_objects_by_name, entity_names, optional:)
      attributes.filter_map do |attr|
        next nil unless attr[:list]

        key    = rust_field(attr[:name])
        ident  = rust_ident_field(attr[:name])
        scalar = effective_scalar_type(attr[:type])
        nested = value_objects_by_name[attr[:type]]
        fielded_element = scalar || (nested && fielded_capable_nested?(nested)) || entity_names.include?(attr[:type])
        next nil unless fielded_element

        shape = "fielded_items_arm_list_#{optional.call(attr) ? 'optional_' : ''}#{scalar ? 'scalar' : 'nested'}"
        subs = { '"tmpl_field"' => key.inspect, "tmpl_ident" => ident }
        subs["tmpl_value_expr_placeholder(v)"] = scalar_to_value(scalar, "v") if scalar
        "            #{Exemplar.render(shape, subs)}"
      end
    end

    # Record variant of emit_fielded_flat: non-list attributes are `Option`-wrapped, so `None`
    # reads as `Value::Nil`. Adds lifecycle and corrects-flag arms.
    def emit_fielded_record(aggregate, value_objects_by_name)
      name = rust_ident(aggregate[:name])
      arms = aggregate[:attributes].filter_map do |attr|
        key   = rust_field(attr[:name])
        ident = rust_ident_field(attr[:name])
        scalar = effective_scalar_type(attr[:type])
        if attr[:list] && list_attr_creation_optional?(aggregate, attr[:name], value_objects_by_name)
          Exemplar.render("fielded_arm_list_optional", '"tmpl_field"' => key.inspect, "tmpl_ident" => ident)
        elsif attr[:list]
          Exemplar.render("fielded_arm_list", '"tmpl_field"' => key.inspect, "tmpl_ident" => ident)
        elsif scalar
          Exemplar.render(
            "fielded_arm_optional_scalar",
            '"tmpl_field"' => key.inspect,
            "tmpl_ident" => ident,
            "tmpl_value_expr_placeholder(v)" => scalar_to_value(scalar, "v")
          )
        else
          nested = value_objects_by_name[attr[:type]]
          next nil unless nested && fielded_capable_nested?(nested)

          Exemplar.render("fielded_arm_optional_nested", '"tmpl_field"' => key.inspect, "tmpl_ident" => ident)
        end
      end
      if aggregate[:lifecycle]
        key   = rust_field(aggregate[:lifecycle][:field])
        ident = rust_ident_field(aggregate[:lifecycle][:field])
        arms << Exemplar.render("fielded_lifecycle_arm", '"tmpl_field"' => key.inspect, "tmpl_ident" => ident)
      end
      correctable_event_names(aggregate).each do |ev|
        ident = corrects_flag_field(ev)
        arms << Exemplar.render("fielded_corrects_flag_arm", '"tmpl_field"' => ident.inspect, "tmpl_ident" => ident)
      end
      arms = arms.map { |a| "            #{a}" }

      # Trailing "\n": see emit_fielded_flat.
      entity_names = (aggregate[:entities] || []).map { |e| e[:name] }
      "#{Exemplar.render(
        'fielded_record',
        'TmplRecordType' => name,
        '"tmpl_arms_placeholder" => tmpl_arms_block(),' => arms.join("\n"),
        '"tmpl_items_placeholder" => tmpl_items_block(),' => items_arms(
          aggregate[:attributes], value_objects_by_name, entity_names,
          optional: ->(attr) { list_attr_creation_optional?(aggregate, attr[:name], value_objects_by_name) }
        ).join("\n"),
        "tmpl_as_scalar_placeholder()" => as_scalar_expr(aggregate[:attributes])
      )}\n"
    end

    # `Resolver#unwrap_scalar`: a struct with exactly one scalar attribute reads as that
    # attribute's value whatever its name; anything else answers `None`.
    def as_scalar_expr(attributes)
      sole = attributes.size == 1 && !attributes.first[:list] ? attributes.first : nil
      return "None" unless sole && effective_scalar_type(sole[:type])

      "match self.field(#{rust_field(sole[:name]).inspect}) { Some(crate::kernel::Field::Value(v)) => Some(v), _ => None }"
    end
  end
end
