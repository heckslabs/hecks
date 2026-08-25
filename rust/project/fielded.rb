module RustProjection
  module Projector
    module_function

    # ── FIELDED — one match arm per real attribute, generated identically
    # for value objects, command args structs, and (via emit_fielded_record,
    # below) aggregate records. This is the mechanical glue Rust's lack of
    # reflection still requires — READING a named field generically, unlike
    # WRITING one, needs no per-command bespoke control flow, only this
    # uniform per-type table.
    # `extra_arms:` — raw `"key" => ...,` lines appended verbatim, never
    # run through the attribute-typed branches above. Exists for the
    # LIFECYCLE field on an ENTITY: `emit_entity` gives an entity struct a
    # bare `String` field for it (the same as `emit_record` does for an
    # aggregate), but unlike `emit_record` (which routes through
    # `emit_fielded_record`, its own record-shaped sibling with a
    # lifecycle arm built in), `emit_fielded_flat` had no lifecycle
    # awareness at all until an entity command's own `TransitionCheck`
    # needed to read it generically — the same gap `emit_to_json_flat`'s
    # `extra_fields:` closes for JSON, here for `Fielded` lookup.
    #
    # Each arm below renders from one of six leaf shapes in
    # rust/src/exemplar/fielded.rs (`fielded_arm_list_optional`,
    # `_list`, `_optional_scalar`, `_optional_nested`, `_scalar`,
    # `_nested`) — flush-left text, the SAME fixed 12-space prefix the
    # original hand-built strings baked in added back here, not through
    # `compose`'s auto-reindent (see `closed_set_table_codec`'s own
    # header, json_codec.rb, for why plain `render` is the right choice
    # when a leaf is reused across more than one outer shape).
    def emit_fielded_flat(struct_name, attributes, value_objects_by_name, extra_arms: [])
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

      # The trailing "\n" restores the OLD heredoc's own implicit one
      # (`<<~RUST` always ends its result in a newline) — every caller's
      # own blank-line arithmetic between this and whatever comes next
      # (`emit_value_object`, `emit_entity`) was written assuming it,
      # and `Exemplar.render`'s dedent `.rstrip`s trailing whitespace,
      # which would otherwise silently collapse two blank lines to one.
      "#{Exemplar.render(
        'fielded_flat',
        'TmplFlatType' => struct_name,
        '"tmpl_arms_placeholder" => tmpl_arms_block(),' => arms.join("\n"),
        '"tmpl_items_placeholder" => tmpl_items_block(),' => items_arms(attributes, value_objects_by_name, [], optional: ->(attr) { attr[:optional] }).join("\n"),
        "tmpl_as_scalar_placeholder()" => as_scalar_expr(attributes),
        'use crate::kernel::Value;' => (arms.any? { |arm| arm.include?('Value') } ? 'use crate::kernel::Value;' : '')
      )}\n"
    end

    # `Fielded::items` — one arm per list attribute whose ELEMENT this
    # generator can hand the kernel: a scalar (through `scalar_to_value`,
    # the same reading the scalar field arms use) or a nested value
    # object/entity that has a `Fielded` impl of its own. A list of
    # anything else gets no arm and stays a length-only field, exactly
    # as before the enumeration operators existed. `optional` decides
    # per attribute whether the list is `Option`-wrapped — the flat and
    # record emitters answer that differently (see each caller).
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

    # Aggregate records differ from value objects/args structs in one main
    # way — every non-list attribute is `Option`-wrapped (see emit_record's
    # own comment for why), so a `None` field reads as `Value::Nil` rather
    # than being absent from the match at all — PLUS the one list-typed
    # exception `emit_record` itself now makes (`list_attr_creation_
    # optional?`, mutations.rb). Its `scalar`/`nested` arms reuse
    # `emit_fielded_flat`'s own `_optional_scalar`/`_optional_nested`
    # shapes verbatim (blanket-Option-wrapped, same as those two already
    # are) — only `list`/`list_optional` and the lifecycle arm are
    # rendered here directly.
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
      arms = arms.map { |a| "            #{a}" }

      # Trailing "\n" — see `emit_fielded_flat`'s own comment on why.
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

    # `Resolver#unwrap_scalar` — a struct whose SOLE attribute is `value`
    # reads as that value (see the exemplar's own `tmpl_as_scalar_
    # placeholder` comment); anything else answers `None`.
    def as_scalar_expr(attributes)
      sole_value = attributes.size == 1 && attributes.first[:name].to_s == "value" && !attributes.first[:list]
      sole_value ? 'match self.field("value") { Some(crate::kernel::Field::Value(v)) => Some(v), _ => None }' : "None"
    end
  end
end
