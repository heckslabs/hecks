module RustProjection
  module Projector
    module_function

    # Scalar that `admits:`/`pattern:` checks operate on: the value itself for a `String`, or
    # the sole field of a single-field value object. `nil` for any other shape.
    def scalar_field_expr(value_expr, attr_type, value_objects_by_name)
      return value_expr if attr_type == "String"

      vo = value_objects_by_name[attr_type]
      return nil unless vo && vo[:attributes].size == 1

      "#{value_expr}.#{rust_ident_field(vo[:attributes].first[:name])}"
    end

    # An optional attribute is `Option<T>`, so the check must sit inside an `if let Some(..)`.
    # Returns `[scalar_expr, nil]` when required, `[expr_over_binding, option_source]` when not.
    def optional_scalar_expr(value_expr, attr, value_objects_by_name)
      return [scalar_field_expr(value_expr, attr[:type], value_objects_by_name), nil] unless attr[:optional]

      [scalar_field_expr(OPTIONAL_BINDING, attr[:type], value_objects_by_name), value_expr]
    end

    # Binds by reference into the `Option`; a `None` field skips the check, as in Ruby.
    OPTIONAL_BINDING = "__optional_value"

    def wrap_if_optional(check, optional_source)
      return check unless optional_source

      "if let Some(#{OPTIONAL_BINDING}) = &#{optional_source} { #{check} }"
    end

    # Members of the closed set named by `"Aggregate::SetName"`, resolved against the full domain.
    # `nil` when the target is not a closed-set value object: codegen skips the check.
    def admitted_set_members(admits, aggregates_by_name)
      aggregate_name, set_name = admits.to_s.split("::", 2)
      aggregate = aggregates_by_name[aggregate_name]
      return nil unless aggregate && set_name

      vo = aggregate[:value_objects].find { |v| v[:name] == set_name }
      return nil unless vo && vo[:closed_set]

      vo[:members].map { |row| row.first[1] }
    end

    # Emits the `admits_declared_set` check. The member list is resolved at codegen time and passed
    # as a `&[&str]` literal; the refusal wording lives only in Vocabulary::RefusalTemplate.
    def emit_admits_check(value_expr, attr, aggregates_by_name, value_objects_by_name)
      return nil unless attr[:admits]

      members = admitted_set_members(attr[:admits], aggregates_by_name)
      return nil unless members

      scalar, optional_source = optional_scalar_expr(value_expr, attr, value_objects_by_name)
      return nil unless scalar

      members_array = "[#{members.map(&:inspect).join(', ')}]"
      check = Exemplar.render(
        "admits_check",
        '["tmpl_member_a", "tmpl_member_b"]' => members_array,
        "tmpl_scalar" => scalar,
        '"tmpl_admits_name"' => attr[:name].to_s.inspect,
        '"tmpl_admits_target"' => attr[:admits].to_s.inspect
      )
      wrap_if_optional(check, optional_source)
    end

    # Emits the `pattern_mismatch` check. The regex goes over as its raw source string, unescaped,
    # matching Ruby's verbatim interpolation.
    def emit_pattern_check(value_expr, attr, owner_type_name, value_objects_by_name)
      return nil unless attr[:pattern]

      scalar, optional_source = optional_scalar_expr(value_expr, attr, value_objects_by_name)
      return nil unless scalar

      check = Exemplar.render(
        "pattern_check",
        '"tmpl_pattern_text"' => attr[:pattern].inspect,
        "tmpl_scalar" => scalar,
        '"tmpl_pattern_owner"' => owner_type_name.to_s.inspect,
        '"tmpl_pattern_field"' => attr[:name].to_s.inspect
      )
      wrap_if_optional(check, optional_source)
    end
  end
end
