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
    def emit_fielded_flat(struct_name, attributes, value_objects_by_name, extra_arms: [])
      arms = attributes.filter_map do |attr|
        key   = rust_field(attr[:name])
        ident = rust_ident_field(attr[:name])
        scalar = effective_scalar_type(attr[:type])
        # `attr[:optional]` — a real `Option<T>` field per se (0014/0015's
        # struct-field change), distinct from `emit_fielded_record`'s own
        # BLANKET Option-wrap below (every record field, unconditionally).
        if attr[:list] && attr[:optional]
          %(            "#{key}" => self.#{ident}.as_ref().map(|v| Field::Value(Value::List(v.len()))).or(Some(Field::Value(Value::Nil))),)
        elsif attr[:list]
          %(            "#{key}" => Some(Field::Value(Value::List(self.#{ident}.len()))),)
        elsif attr[:optional] && scalar
          %(            "#{key}" => self.#{ident}.as_ref().map(|v| Field::Value(#{scalar_to_value(scalar, "v")})).or(Some(Field::Value(Value::Nil))),)
        elsif attr[:optional]
          nested = value_objects_by_name[attr[:type]]
          next nil unless nested && !nested[:closed_set]

          %(            "#{key}" => self.#{ident}.as_ref().map(|v| Field::Nested(v)).or(Some(Field::Value(Value::Nil))),)
        elsif scalar
          %(            "#{key}" => Some(Field::Value(#{scalar_to_value(scalar, "self.#{ident}")})),)
        else
          nested = value_objects_by_name[attr[:type]]
          next nil unless nested && !nested[:closed_set]

          %(            "#{key}" => Some(Field::Nested(&self.#{ident})),)
        end
      end
      arms += extra_arms

      <<~RUST
        impl crate::kernel::Fielded for #{struct_name} {
            fn field(&self, name: &str) -> Option<crate::kernel::Field<'_>> {
                use crate::kernel::Field;
                #{"use crate::kernel::Value;" if arms.any? { |arm| arm.include?("Value") }}
                match name {
        #{arms.join("\n")}
                    _ => None,
                }
            }
        }
      RUST
    end

    # Aggregate records differ from value objects/args structs in one main
    # way — every non-list attribute is `Option`-wrapped (see emit_record's
    # own comment for why), so a `None` field reads as `Value::Nil` rather
    # than being absent from the match at all — PLUS the one list-typed
    # exception `emit_record` itself now makes (`list_attr_creation_
    # optional?`, mutations.rb).
    def emit_fielded_record(aggregate, value_objects_by_name)
      name = rust_ident(aggregate[:name])
      arms = aggregate[:attributes].filter_map do |attr|
        key   = rust_field(attr[:name])
        ident = rust_ident_field(attr[:name])
        scalar = effective_scalar_type(attr[:type])
        if attr[:list] && list_attr_creation_optional?(aggregate, attr[:name])
          %(            "#{key}" => self.#{ident}.as_ref().map(|v| Field::Value(Value::List(v.len()))).or(Some(Field::Value(Value::Nil))),)
        elsif attr[:list]
          %(            "#{key}" => Some(Field::Value(Value::List(self.#{ident}.len()))),)
        elsif scalar
          value = scalar_to_value(scalar, "v")
          %(            "#{key}" => self.#{ident}.as_ref().map(|v| Field::Value(#{value})).or(Some(Field::Value(Value::Nil))),)
        else
          nested = value_objects_by_name[attr[:type]]
          next nil unless nested && !nested[:closed_set]

          %(            "#{key}" => self.#{ident}.as_ref().map(|v| Field::Nested(v)).or(Some(Field::Value(Value::Nil))),)
        end
      end
      if aggregate[:lifecycle]
        key   = rust_field(aggregate[:lifecycle][:field])
        ident = rust_ident_field(aggregate[:lifecycle][:field])
        arms << %(            "#{key}" => Some(Field::Value(Value::Str(self.#{ident}.clone()))),)
      end

      <<~RUST
        impl crate::kernel::Fielded for #{name} {
            fn field(&self, name: &str) -> Option<crate::kernel::Field<'_>> {
                use crate::kernel::{Field, Value};
                match name {
        #{arms.join("\n")}
                    _ => None,
                }
            }
        }
      RUST
    end
  end
end
