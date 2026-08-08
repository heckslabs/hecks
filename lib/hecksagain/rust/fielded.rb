module Hecksagain
  module Rust
    module Projector
      module_function

      # ── FIELDED — one match arm per real attribute, generated identically
      # for value objects, command args structs, and (via emit_fielded_record,
      # below) aggregate records. This is the mechanical glue Rust's lack of
      # reflection still requires — READING a named field generically, unlike
      # WRITING one, needs no per-command bespoke control flow, only this
      # uniform per-type table.
      def emit_fielded_flat(struct_name, attributes, value_objects_by_name)
        arms = attributes.filter_map do |attr|
          key   = rust_field(attr[:name])
          ident = rust_ident_field(attr[:name])
          scalar = effective_scalar_type(attr[:type])
          if attr[:list]
            %(            "#{key}" => Some(Field::Value(Value::List(self.#{ident}.len()))),)
          elsif scalar
            %(            "#{key}" => Some(Field::Value(#{scalar_to_value(scalar, "self.#{ident}")})),)
          else
            nested = value_objects_by_name[attr[:type]]
            next nil unless nested && !nested[:closed_set]

            %(            "#{key}" => Some(Field::Nested(&self.#{ident})),)
          end
        end

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

      # Aggregate records differ from value objects/args structs in exactly
      # one way: every non-list attribute is `Option`-wrapped (see
      # emit_record's own comment for why), so a `None` field reads as
      # `Value::Nil` rather than being absent from the match at all.
      def emit_fielded_record(aggregate, value_objects_by_name)
        name = rust_ident(aggregate[:name])
        arms = aggregate[:attributes].filter_map do |attr|
          key   = rust_field(attr[:name])
          ident = rust_ident_field(attr[:name])
          scalar = effective_scalar_type(attr[:type])
          if attr[:list]
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
end
