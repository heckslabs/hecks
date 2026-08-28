module RustProjection
  module Projector
    module_function

    # `InvariantViolation`/`value_object_invariant` — `Value.build`'s own
    # invariant loop (runtime/value/coercion.rb), read directly: `"#{value_
    # object.hecks_name} invariant violated — #{invariant.description}
    # (given #{canonical_fields(fields)})"`, now itself routed through
    # `RefusalWording.render` on the Ruby side too (the one Ruby-side
    # change this migration makes — see refusal_wording.rb's own new
    # `value_object_invariant` entry). `name`/`description` are
    # codegen-time-static (`vo[:name]`/`inv[:description]`); `offered` is
    # the one genuinely runtime piece — Ruby's `canonical_fields` is
    # `JSON.generate(fields.sort_by { |name, _| name.to_s }.to_h)`, and
    # `self.to_json()` already produces the SAME per-field JSON `fields`
    # would (0021 closed that parity), just in DECLARATION order rather
    # than sorted — so this sorts the top-level `(name, value)` pairs
    # `to_json()` already built rather than re-deriving them, then
    # stringifies. Only the TOP level is sorted, matching Ruby exactly:
    # `canonical_fields` never recurses into a nested value object's own
    # field order, and neither does this.
    def emit_check_invariants(vo, value_objects_by_name, aggregates_by_name)
      name = rust_ident(vo[:name])
      type_name = vo[:name].to_s
      body = vo[:invariants].map do |inv|
        expr = ExprEmitter.emit_predicate(inv[:canonical])
        <<~RUST.rstrip
                  {
                      let ctx = crate::kernel::EvalContext { args: &crate::kernel::NoFields, instance: self };
                      if !crate::kernel::interpret(&#{expr}, &ctx)?.truthy() {
                          let mut offered = self.to_json();
                          if let crate::kernel::Json::Object(fields) = &mut offered {
                              fields.sort_by(|a, b| a.0.cmp(&b.0));
                          }
                          let offered = offered.to_json_string();
                          return Err(crate::kernel::Refusal::InvariantViolation(crate::kernel::RefusalSite::InvariantViolationValueObjectInvariant.render(&[
                              ("name", #{type_name.inspect}),
                              ("description", #{rust_string_literal(inv[:description])}),
                              ("offered", offered.as_str()),
                          ])));
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
        enum_part = Exemplar.compose(
          "closed_set_enum",
          { "TmplKind" => name },
          field_id: "closed_set_enum:VARIANT",
          field_subs_list: variants.map { |v| { "TmplMemberA" => v } }
        )
        # `fielded_capable_nested?`'s own real consumer — see its header
        # (naming.rb) for the full story. Purely additive alongside the
        # enum itself; nothing about `enum_part`'s own generation changed.
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
        type = "Option<#{type}>" if !attr[:list] || list_attr_creation_optional?(aggregate, attr[:name], value_objects_by_name)
        { "TmplFieldType" => type, "tmpl_field" => rust_ident_field(attr[:name]) }
      end
      field_subs_list << { "TmplFieldType" => "String", "tmpl_field" => rust_ident_field(aggregate[:lifecycle][:field]) } if aggregate[:lifecycle]
      # `corrects`'s own per-record flag fields — one plain, non-optional
      # `bool` per event name some command on this aggregate `corrects`
      # against (see `commands.rb`'s own `corrects_flag_field`/
      # `correctable_event_names` for the full reasoning). Appended the
      # same way the lifecycle field is, right above — a real struct
      # field, not a `list_of`/value-object shape, so it needs neither
      # `Option<T>` wrapping nor an entry in `emit_fielded_record`'s own
      # `attributes`-driven arm-building (handled by its own dedicated
      # arm instead, right alongside the lifecycle one there).
      correctable_event_names(aggregate).each { |ev| field_subs_list << { "TmplFieldType" => "bool", "tmpl_field" => corrects_flag_field(ev) } }
      struct_part = Exemplar.compose("plain_struct", { "TmplType" => name }, field_id: "struct_field", field_subs_list: field_subs_list)

      "#{struct_part}\n\n#{emit_fielded_record(aggregate, value_objects_by_name)}"
    end

    # THE SYNCHRONOUS HALF OF `projects` (S12, ADR 0025), the CODEGEN
    # side — `CommandInterpreter#seed_projected_fields`'s own target is
    # a genuinely dynamic Ruby Hash key; Rust's struct has no such thing,
    # so a `projects` field is generated as an ordinary `String`-typed,
    # always-optional ATTRIBUTE (struct field, `Fielded::field` read arm,
    # `to_json`/`from_json_state` key) rather than inventing a second,
    # parallel codegen path for it. `emit_record`'s caller
    # (`domain_generator.rb`) merges this onto `aggregate[:attributes]`
    # for exactly those four emissions — never for a command's own Args
    # struct (a projected field is never a command argument) and never
    # for `emit_from_json_flat` (command-args parsing), so the merge
    # happens at the ONE call site that builds the record shape, not
    # inside `emit_record`/`emit_fielded_record` themselves.
    #
    # `type: "String"` — every real `projects` declaration in the corpus
    # today projects a lifecycle `status` field or another projected
    # field, both always String; see `reference_lookup.rs`'s own
    # `seeded_projections` header for the same scoping note on the Rust
    # runtime side.
    def projected_field_pseudo_attributes(aggregate)
      (aggregate[:projected_fields] || []).map do |field|
        { name: field[:name], type: "String", list: false, optional: true }
      end
    end

    # `impl crate::kernel::SetProjectedField for X` — the write half a
    # generic `Fielded::field` read has no counterpart for
    # (`reference_lookup.rs`'s own trait header). One match arm per
    # `projects` field this aggregate declares; an aggregate with none
    # still implements the trait, empty match body, so `kernel::dispatch`
    # can require the bound unconditionally rather than special-casing
    # "this aggregate has no projections."
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

    # `#{NAME}_PROJECTED_FIELDS` — one static table per aggregate,
    # `crate::kernel::ProjectedFieldSpec` rows read at dispatch time
    # (`commands.rb`'s own `tmpl_seed_projections_placeholder`
    # substitution) to compute `seeded_projections` off the SAME
    # `with_references` already built for given/ensures evaluation.
    # Empty for an aggregate with no `projects` fields, the same
    # "always emitted, sometimes empty" shape `REFERENCE_TABLE`'s own
    # per-aggregate rows already use (reference_specs.rb).
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
