module RustProjection
  module Projector
    module_function

    def emit_check_invariants(vo, value_objects_by_name, aggregates_by_name)
      name = rust_ident(vo[:name])
      body = vo[:invariants].map do |inv|
        expr = ExprEmitter.emit_predicate(inv[:canonical])
        message = "#{name} violates its invariant: #{inv[:description]}"
        <<~RUST.rstrip
                  {
                      let ctx = crate::kernel::EvalContext { args: &crate::kernel::NoFields, instance: self };
                      if !crate::kernel::interpret(&#{expr}, &ctx)?.truthy() {
                          return Err(crate::kernel::Refusal::InvariantViolation(#{message.inspect}.to_string()));
                      }
                  }
        RUST
      end

      # `check_admitted`/`check_patterns` — `admission.rb`'s/`coercion.rb`'s
      # OWN door: `pattern:`/`admits:` declared on the VALUE OBJECT'S OWN
      # field (`EmailAddress.address, pattern: ...`), not on some outer
      # usage — the OTHER door is `commands.rb`'s own `invariant_checks`,
      # for a command/entity-command argument's usage-level `admits:`
      # (`ExternalTransfer.Request`'s own `direction`).
      vo[:attributes].each do |attr|
        next if attr[:list]

        field = "self.#{rust_ident_field(attr[:name])}"
        admits_line = emit_admits_check(field, attr, aggregates_by_name, value_objects_by_name)
        body << "        #{admits_line}" if admits_line
        pattern_line = emit_pattern_check(field, attr, name, value_objects_by_name)
        body << "        #{pattern_line}" if pattern_line
      end

      vo[:attributes].each do |attr|
        next if SCALAR.key?(attr[:type])

        nested = value_objects_by_name[attr[:type]]
        next unless nested && !nested[:closed_set]

        field = rust_ident_field(attr[:name])
        body << (attr[:list] ? "        for item in &self.#{field} { item.check_invariants()?; }" : "        self.#{field}.check_invariants()?;")
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

    # A multi-field closed set — not a choice among tags, a fixed DATA
    # TABLE. Emitted as a plain struct (the same shape a non-closed-set
    # value object gets) plus every member as one entry in a `pub const`
    # array of struct literals. No `Fielded`/`check_invariants` generated —
    # nothing in this corpus looks one of these up generically by field
    # name or checks an invariant on it; a real future need should extend
    # this, not be worked around by skipping the gap silently.
    def emit_closed_set_table(vo)
      name = rust_ident(vo[:name])

      field_subs_list = vo[:attributes].map do |attr|
        type = rust_type(attr[:type], list: attr[:list])
        type = "&'static str" if type == "String" # static data — a borrowed literal, not an owned String
        { "TmplFieldType" => type, "tmpl_field" => rust_ident_field(attr[:name]) }
      end
      struct_part = Exemplar.compose("plain_struct", { "TmplType" => name }, field_id: "struct_field", field_subs_list: field_subs_list)

      # A member's row only carries the fields its declaration actually SET —
      # `Keyword`'s own `status` (declares `default: "admitted"`) and `was`
      # (no default at all) are both missing from most rows, found live as a
      # missing-struct-field compile error. Iterate every DECLARED attribute,
      # not just what a given row happens to carry, falling back to the
      # attribute's own `default:` (or "" absent one) exactly the way a real
      # member's own construction would.
      member_literals = vo[:members].map do |row|
        present = row.to_h { |field_name, value| [field_name.to_s, value] }
        fields = vo[:attributes].map do |attr|
          field_name = attr[:name].to_s
          raw = present.key?(field_name) ? present[field_name] : (attr[:default] || "")
          literal = case attr[:type]
                    when "Integer" then raw.to_i.to_s
                    when "Float"   then "#{raw.to_f}f64"
                    else raw.to_s.inspect # String, or an unrecognized type — treated as text, not silently dropped
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
        # One field per member (Size: small/large) is a real ENUM CHOICE —
        # the member IS the whole fact, so a tag is the honest Rust shape.
        # More than one field (Vocabulary::Comparison: symbol PLUS three
        # algebra flags; Syntax::Keyword: eight fields, several members
        # sharing the same `word` across different `context`s) is not a
        # choice among interchangeable tags at all — it's a small, fixed
        # DATA TABLE, and forcing it into an enum either loses the other
        # fields or collides different members that happen to share
        # whichever one field got picked as the tag (found live: several
        # Keyword rows share a `word`, differing only in `context`).
        return emit_closed_set_table(vo) if vo[:attributes].size > 1

        variants = vo[:members].map { |row| closed_set_variant(row) }
        return Exemplar.compose(
          "closed_set_enum",
          { "TmplKind" => name },
          field_id: "closed_set_enum:VARIANT",
          field_subs_list: variants.map { |v| { "TmplMemberA" => v } }
        )
      end

      field_subs_list = vo[:attributes].map do |attr|
        type = rust_type(attr[:type], list: attr[:list])
        type = "Option<#{type}>" if attr[:optional]
        { "TmplFieldType" => type, "tmpl_field" => rust_ident_field(attr[:name]) }
      end
      struct_part = Exemplar.compose("plain_struct", { "TmplType" => name }, field_id: "struct_field", field_subs_list: field_subs_list)

      [
        struct_part,
        emit_fielded_flat(name, vo[:attributes], value_objects_by_name),
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

    # An entity, resolved to a Rust type the SAME mechanical way a value
    # object is — same six-key `attributes` shape, same `Fielded` impl. No
    # `check_invariants` (entities declare no `invariants` of their own —
    # every field's OWN value object already checked itself, either at the
    # command argument boundary or via `literal_hash_rhs`/`value_rhs`
    # below) and no dispatch functions for the entity's OWN commands
    # (`Amend`/`Reverse` — a real, separate, still-unbuilt feature: an
    # entity's commands address ONE element of the list by its own
    # identity, not the whole aggregate, and nothing here generates that
    # addressing). This only makes an entity usable as an `append` TARGET.
    def emit_entity(entity, value_objects_by_name)
      name = rust_ident(entity[:name])
      field_subs_list = entity[:attributes].map do |attr|
        type = rust_type(attr[:type], list: attr[:list])
        # `optional: true` — a caller-omittable field (0014/0015's own
        # gap: `SafeDepositBox::Visit.note`, populated by `LogVisit`'s
        # `append` and later overwritten by `Visit.Annotate`'s `set`, is
        # the one real case). `command_skip_reason`'s own new check
        # (bridging.rb) guarantees anything that reaches this branch has
        # only OPTIONAL sources feeding it, or only feeds a field this IS
        # optional here — the mismatched case (an optional source into a
        # non-optional VO field) is skipped, loudly, before generation.
        type = "Option<#{type}>" if attr[:optional]
        { "TmplFieldType" => type, "tmpl_field" => rust_ident_field(attr[:name]) }
      end
      field_subs_list << { "TmplFieldType" => "String", "tmpl_field" => rust_ident_field(entity[:lifecycle][:field]) } if entity[:lifecycle]
      struct_part = Exemplar.compose("plain_struct", { "TmplType" => name }, field_id: "struct_field", field_subs_list: field_subs_list)

      # An entity command's own TransitionCheck reads this field generically
      # (kernel::dispatch_entity, the same way an aggregate command's does
      # off emit_fielded_record's own lifecycle arm) — entity_lifecycle_arm
      # is this struct's one, in the flat (non-Option) shape emit_entity's
      # own field actually has.
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
        # Every field starts optional at the Rust-struct level regardless of
        # the IR's own optional: flag — a creating command may not set every
        # field on step one (Order.CreatePizza never sets customer_name), and
        # Rust has no notion of "field exists but is unset" the way a Ruby
        # Hash does. Non-optional-per-IR fields are asserted present at
        # generated-dispatch time instead, not encoded away here.
        #
        # A LIST field is the one exception to the blanket wrap — UNLESS
        # `list_attr_creation_optional?` says otherwise (`CardPayment.
        # tags`, mutations.rb's own header): most list attributes are
        # populated only by `append` from non-creating commands and start
        # at `Instance.defaults`' own `[]` baseline forever until
        # something appends, which `Vec<T>` (never absent) already
        # represents correctly.
        type = rust_type(attr[:type], list: attr[:list])
        type = "Option<#{type}>" if !attr[:list] || list_attr_creation_optional?(aggregate, attr[:name])
        { "TmplFieldType" => type, "tmpl_field" => rust_ident_field(attr[:name]) }
      end
      field_subs_list << { "TmplFieldType" => "String", "tmpl_field" => rust_ident_field(aggregate[:lifecycle][:field]) } if aggregate[:lifecycle]
      struct_part = Exemplar.compose("plain_struct", { "TmplType" => name }, field_id: "struct_field", field_subs_list: field_subs_list)

      "#{struct_part}\n\n#{emit_fielded_record(aggregate, value_objects_by_name)}"
    end
  end
end
