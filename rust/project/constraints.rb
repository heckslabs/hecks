module RustProjection
  module Projector
    module_function

    # `admits:`/`pattern:` (`attribute_collector.rb`'s own keyword args) sit
    # on the SAME `IR::Attribute` shape wherever `attribute()` is called —
    # a value object's own field (`EmailAddress.address, pattern: ...`) or
    # an aggregate/command's own usage-level attribute (`ExternalTransfer`'s
    # `direction, MovementDirection, admits: "Account::LedgerDirection"`).
    # Ruby checks BOTH doors (`admission.rb`'s own `check_admitted`/
    # `check_patterns`, called from `Value.build`, and `admit_declared_set`,
    # called from `coerce_declared_arguments`) — this file is the shared
    # half both `types.rb` (the value-object door) and `commands.rb` (the
    # command/entity-command-argument door) call into.

    # The scalar `admitted_scalar`/`check_patterns` actually operate on —
    # bare already if the attribute's own declared type IS the scalar
    # (`String`), or the sole field of a single-field value object (the
    # "one-field holder" `admission.rb`'s own comment names). `nil` for
    # anything else (a multi-field VO, a closed-set VO with more than one
    # discriminant) — not a shape either door can unwrap either.
    def scalar_field_expr(value_expr, attr_type, value_objects_by_name)
      return value_expr if attr_type == "String"

      vo = value_objects_by_name[attr_type]
      return nil unless vo && vo[:attributes].size == 1

      "#{value_expr}.#{rust_ident_field(vo[:attributes].first[:name])}"
    end

    # `admitted_members`/`chapter_of`, read directly (`admission.rb`):
    # `"Aggregate::SetName"` resolved against the FULL domain — a closed
    # set may be declared anywhere in the same chapter, not just the
    # current aggregate. `aggregates_by_name` is `domain_generator.rb`'s
    # own full-IR lookup (already built for `reference_checks`). `nil` —
    # not generated, not refused at runtime like Ruby's own
    # `undeclared_set` — when the target can't be resolved to an actual
    # closed-set value object at codegen time: there is no repository to
    # check against here, only a compile-time member table, so an
    # unresolvable target is the same "can't honestly generate this" shape
    # as every other skip in this generator.
    def admitted_set_members(admits, aggregates_by_name)
      aggregate_name, set_name = admits.to_s.split("::", 2)
      aggregate = aggregates_by_name[aggregate_name]
      return nil unless aggregate && set_name

      vo = aggregate[:value_objects].find { |v| v[:name] == set_name }
      return nil unless vo && vo[:closed_set]

      vo[:members].map { |row| row.first[1] }
    end

    # `InvariantViolation`/`admits_declared_set` — `refusal_wording.rb`'s
    # own template, `"{name} admits {admits} — {admitted} — got {offered}"`
    # — read directly and reproduced byte-for-byte: `name`/`admits` print
    # bare (a Ruby Symbol/String's own `to_s`), `admitted`/`offered` are
    # each already `.inspect`-quoted. The member LIST is baked in as a
    # compile-time-known `&[&str]` literal (`admitted_set_members` already
    # resolved it at codegen time) — `{:?}` on the offered `&str` produces
    # the same quoted form Ruby's own `.inspect` does for a plain string.
    def emit_admits_check(value_expr, attr, aggregates_by_name, value_objects_by_name)
      return nil unless attr[:admits]

      members = admitted_set_members(attr[:admits], aggregates_by_name)
      return nil unless members

      scalar = scalar_field_expr(value_expr, attr[:type], value_objects_by_name)
      return nil unless scalar

      members_array = "[#{members.map(&:inspect).join(', ')}]"
      prefix = "#{attr[:name]} admits #{attr[:admits]} — #{members.map(&:inspect).join(', ')} — got "
      "if !#{members_array}.contains(&#{scalar}.as_str()) { return Err(crate::kernel::Refusal::InvariantViolation(format!(\"{}{:?}\", #{prefix.inspect}, #{scalar}))); }"
    end

    # `TypeMismatch`/`pattern_mismatch` — `refusal_wording.rb`:
    # `"{type}.{field} must match {pattern}, got {offered}"`. `pattern`
    # prints bare (the raw regex SOURCE string, not re-escaped — Ruby's
    # own template interpolates `attribute.pattern` verbatim); `offered`
    # is `.inspect`-quoted, same as `admits`'s own wording.
    def emit_pattern_check(value_expr, attr, owner_type_name, value_objects_by_name)
      return nil unless attr[:pattern]

      scalar = scalar_field_expr(value_expr, attr[:type], value_objects_by_name)
      return nil unless scalar

      prefix = "#{owner_type_name}.#{attr[:name]} must match #{attr[:pattern]}, got "
      "if !crate::kernel::pattern::matches(#{attr[:pattern].inspect}, &#{scalar}) { return Err(crate::kernel::Refusal::TypeMismatch(format!(\"{}{:?}\", #{prefix.inspect}, #{scalar}))); }"
    end
  end
end
