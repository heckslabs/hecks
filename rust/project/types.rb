module RustProjection
  module Projector
    module_function

    # `check_invariants` mirroring `Value.build` (runtime/value/coercion.rb). `offered` sorts only
    # the top-level fields, matching Ruby's `canonical_fields`.
    def emit_check_invariants(vo, value_objects_by_name, aggregates_by_name)
      name = rust_ident(vo[:name])
      type_name = vo[:name].to_s

      # Ruby's order (`Value.build`, coercion.rb): nested value objects, then field
      # constraints, then invariants last, so a failed pattern is a `TypeMismatch`.
      body = []

      vo[:attributes].each do |attr|
        next if SCALAR.key?(attr[:type])

        nested = value_objects_by_name[attr[:type]]
        next unless nested && !nested[:closed_set]

        field = rust_ident_field(attr[:name])
        body << (attr[:list] ? "        for item in &self.#{field} { item.check_invariants()?; }" : "        self.#{field}.check_invariants()?;")
      end

      # `pattern:`/`admits:` declared on the value object's own fields; command-argument
      # usage-level `admits:` is handled in commands.rb.
      vo[:attributes].each do |attr|
        next if attr[:list]

        field = "self.#{rust_ident_field(attr[:name])}"
        admits_line = emit_admits_check(field, attr, aggregates_by_name, value_objects_by_name)
        body << "        #{admits_line}" if admits_line
        pattern_line = emit_pattern_check(field, attr, name, value_objects_by_name)
        body << "        #{pattern_line}" if pattern_line
      end

      body += vo[:invariants].map do |inv|
        expr = ExprEmitter.emit_ast(inv[:ast])
        <<~RUST.rstrip
                  {
                      let ctx = crate::kernel::EvalContext { args: &crate::kernel::NoFields, instance: self };
                      if !crate::kernel::interpret(&#{expr}, &ctx)?.truthy() {
                          let mut offered = self.to_json();
                          if let crate::kernel::Json::Object(fields) = &mut offered {
                              fields.sort_by(|a, b| a.0.cmp(&b.0));
                          }
                          let offered = offered.to_json_string();
                          return Err(crate::kernel::Refusal::InvariantViolation(crate::kernel::refusal_wording::InvariantViolationValueObjectInvariantArgs {
                              name: #{type_name.inspect},
                              description: #{rust_string_literal(inv[:description])},
                              offered: offered.as_str(),
                          }.render_args()));
                      }
                  }
        RUST
      end

      <<~RUST
        impl #{name} {
            pub fn check_invariants(&self) -> Result<(), crate::kernel::Refusal> {
        #{body.join("\n")}
                Ok(())
            }
        }
      RUST
    end

    # A multi-field closed set: a plain struct plus a `pub const` array of members.
    # No `Fielded` or `check_invariants`.
    def emit_closed_set_table(vo)
      name = rust_ident(vo[:name])

      field_subs_list = vo[:attributes].map do |attr|
        type = rust_type(attr[:type], list: attr[:list])
        type = "&'static str" if type == "String" # static data — a borrowed literal, not an owned String
        { "TmplFieldType" => type, "tmpl_field" => rust_ident_field(attr[:name]) }
      end
      struct_part = Exemplar.compose("plain_struct", { "TmplType" => name }, field_id: "struct_field", field_subs_list: field_subs_list)

      # Rows carry only the fields they set; missing ones fall back to `default:` or "".
      member_literals = vo[:members].map do |row|
        present = row.to_h { |field_name, value| [field_name.to_s, value] }
        fields = vo[:attributes].map do |attr|
          field_name = attr[:name].to_s
          raw = present.key?(field_name) ? present[field_name] : (attr[:default] || "")
          literal = case attr[:type]
                    when "Integer" then raw.to_i.to_s
                    when "Float"   then "#{raw.to_f}f64"
                    else rust_string_literal(raw.to_s) # String, or an unrecognized type — treated as text, not silently dropped
                    end
          Exemplar.render("closed_set_table_row_field", "tmpl_field" => rust_ident_field(attr[:name]), "tmpl_value_placeholder()" => literal)
        end.join(", ")
        "    #{name} { #{fields} },"
      end

      "#{struct_part}\n\npub const #{screaming_snake(vo[:name])}: &[#{name}] = &[\n#{member_literals.join("\n")}\n];"
    end

    def emit_value_object(vo, value_objects_by_name, aggregates_by_name)
      name = rust_ident(vo[:name])

      if vo[:closed_set]
        # One field is an enum tag. Several are a data table: members can share any
        # single field (Keyword rows share `word`), so no one field can be the tag.
        return emit_closed_set_table(vo) if vo[:attributes].size > 1

        variants = vo[:members].map { |row| closed_set_variant(row) }
        enum_part = Exemplar.compose(
          "closed_set_enum",
          { "TmplKind" => name },
          field_id: "closed_set_enum:VARIANT",
          field_subs_list: variants.map { |v| { "TmplMemberA" => v } }
        )
        # Consumer of `fielded_capable_nested?` (naming.rb).
        return "#{enum_part}\n\n#{emit_closed_set_fielded_impl(vo)}"
      end

      field_subs_list = vo[:attributes].map do |attr|
        type = rust_type(attr[:type], list: attr[:list])
        type = "Option<#{type}>" if attr[:optional]
        { "TmplFieldType" => type, "tmpl_field" => rust_ident_field(attr[:name]) }
      end
      struct_part = Exemplar.compose("plain_struct", { "TmplType" => name }, field_id: "struct_field", field_subs_list: field_subs_list)

      [
        struct_part,
        emit_fielded_flat(name, vo[:attributes], value_objects_by_name,
                          entity_names: aggregates_by_name.values.flat_map { |a| a[:entities].map { |e| e[:name] } }),
        emit_check_invariants(vo, value_objects_by_name, aggregates_by_name),
      ].join("\n\n")
    end

    def unsupported_attribute_types(aggregate, value_objects_by_name)
      entity_names = aggregate[:entities].map { |e| e[:name] }
      aggregate[:attributes]
        .reject do |attr|
          effective_scalar_type(attr[:type]) || value_objects_by_name.key?(attr[:type]) ||
            (attr[:list] && entity_names.include?(attr[:type]))
        end
        .map { |attr| attr[:type] }
        .uniq
    end

    # An entity as a struct with a `Fielded` impl and no `check_invariants`.
    # Commands addressing one element by identity are not generated; this only enables `append`.
    def emit_entity(entity, value_objects_by_name)
      name = rust_ident(entity[:name])
      field_subs_list = entity[:attributes].map do |attr|
        type = rust_type(attr[:type], list: attr[:list])
        # `optional: true` becomes `Option<T>`; `command_skip_reason` (bridging.rb) skips
        # optional sources feeding a non-optional field.
        type = "Option<#{type}>" if attr[:optional]
        { "TmplFieldType" => type, "tmpl_field" => rust_ident_field(attr[:name]) }
      end
      field_subs_list << { "TmplFieldType" => "String", "tmpl_field" => rust_ident_field(entity[:lifecycle][:field]) } if entity[:lifecycle]
      struct_part = Exemplar.compose("plain_struct", { "TmplType" => name }, field_id: "struct_field", field_subs_list: field_subs_list)

      # The entity's TransitionCheck reads the lifecycle field generically, in the flat shape.
      lifecycle_arm =
        if entity[:lifecycle]
          field = rust_field(entity[:lifecycle][:field])
          ident = rust_ident_field(entity[:lifecycle][:field])
          [%(            "#{field}" => Some(Field::Value(Value::Str(self.#{ident}.clone()))),)]
        else
          []
        end
      "#{struct_part}\n\n#{emit_fielded_flat(name, entity[:attributes], value_objects_by_name, extra_arms: lifecycle_arm)}"
    end

    def emit_record(aggregate, value_objects_by_name)
      name = rust_ident(aggregate[:name])
      field_subs_list = aggregate[:attributes].map do |attr|
        # Optional because a creating command may not set every field. A list field stays a
        # `Vec<T>` unless `list_attr_creation_optional?`.
        type = rust_type(attr[:type], list: attr[:list])
        type = "Option<#{type}>" if !attr[:list] || list_attr_creation_optional?(aggregate, attr[:name], value_objects_by_name)
        { "TmplFieldType" => type, "tmpl_field" => rust_ident_field(attr[:name]) }
      end
      field_subs_list << { "TmplFieldType" => "String", "tmpl_field" => rust_ident_field(aggregate[:lifecycle][:field]) } if aggregate[:lifecycle]
      # One plain `bool` field per event a command `corrects` (see `corrects_flag_field`).
      correctable_event_names(aggregate).each { |ev| field_subs_list << { "TmplFieldType" => "bool", "tmpl_field" => corrects_flag_field(ev) } }
      struct_part = Exemplar.compose("plain_struct", { "TmplType" => name }, field_id: "struct_field", field_subs_list: field_subs_list)

      "#{struct_part}\n\n#{emit_fielded_record(aggregate, value_objects_by_name)}"
    end

    # `projects` fields become always-optional String attributes. The caller merges them onto
    # `aggregate[:attributes]` for record emission only, never for command Args or from_json_flat.
    def projected_field_pseudo_attributes(aggregate)
      (aggregate[:projected_fields] || []).map do |field|
        { name: field[:name], type: "String", list: false, optional: true }
      end
    end

    # `impl SetProjectedField`: one arm per `projects` field, empty match when there are none,
    # so dispatch can require the bound unconditionally.
    def emit_set_projected_field(aggregate)
      name = rust_ident(aggregate[:name])
      arms = (aggregate[:projected_fields] || []).map do |field|
        ident = rust_ident_field(field[:name])
        "            #{field[:name].inspect} => self.#{ident} = value,"
      end
      <<~RUST
        impl crate::kernel::SetProjectedField for #{name} {
            fn set_projected_field(&mut self, name: &'static str, value: Option<String>) {
                match name {
        #{arms.join("\n")}
                    _ => {}
                }
            }
        }
      RUST
    end

    # `<NAME>_PROJECTED_FIELDS`: one `ProjectedFieldSpec` row per `projects` field, empty if none.
    def emit_projected_field_table(aggregate)
      name = screaming_snake(aggregate[:name])
      rows = (aggregate[:projected_fields] || []).map do |field|
        "    crate::kernel::ProjectedFieldSpec { field: #{field[:name].inspect}, reference: #{field[:reference].inspect}, " \
          "remote_field: #{field[:remote_field].inspect} },"
      end
      "pub static #{name}_PROJECTED_FIELDS: &[crate::kernel::ProjectedFieldSpec] = &[\n#{rows.join("\n")}\n];\n"
    end
  end
end
