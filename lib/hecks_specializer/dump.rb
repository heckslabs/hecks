# lib/hecks_specializer/dump.rb
#
# Hecks::Specializer::Dump — emits hecks_life/src/dump.rs.
# Moved from bin/specialize-dump.

module Hecks
  module Specializer
    class Dump
      include Target

      SHAPE = REPO_ROOT.join("hecks_conception/capabilities/dump_shape/fixtures/dump_shape.fixtures")
      TARGET_RS = REPO_ROOT.join("hecks_life/src/dump.rs")

      def emit
        serializers = by_aggregate("Serializer").sort_by { |s| s["attrs"]["order"].to_i }
        [
          emit_header,
          emit_imports,
          serializers.map { |s| emit_serializer(s) }.join,
        ].join
      end

      private

      def emit_header
        <<~RS
          //! Canonical IR dump — JSON shape that both Ruby and Rust must agree on.
          //!
          //! GENERATED FILE — do not edit.
          //! Source:    hecks_conception/capabilities/dump_shape/
          //! Regenerate: bin/specialize dump --output hecks_life/src/dump.rs
          //! Contract:  specializer.hecksagon :specialize_dump shell adapter
          //!
          //! This is the parity contract. Hand-written so the JSON shape is chosen
          //! explicitly, not accidentally derived from Rust struct field names or
          //! serde defaults. When the Ruby BluebookModel serializer (canonical_ir.rb)
          //! produces the same shape, both parsers can be diffed deterministically.
          //!
          //! Shape:
          //!   { name, category, vision, aggregates[], policies[], fixtures[], vows[] }
          //!
          //! Each Aggregate, Command, Attribute, etc. has a fixed key order and
          //! omits no fields (uses null where absent). Stable field naming —
          //! `attributes[*].type` (not Rust's internal `attr_type`),
          //! `references[*].target`, etc. — so the contract reads naturally.
          //!
          //! Usage:
          //!   hecks-life dump path/to/foo.bluebook
          //!   # → JSON to stdout, exit 0

        RS
      end

      def emit_imports
        <<~RS
          use crate::ir::{
              Aggregate, Attribute, Command, Domain, Fixture, Given, Lifecycle, Mutation,
              MutationOp, Policy, Query, Reference, Transition, ValueObject,
          };
          use serde_json::{json, Value};

        RS
      end

      def emit_serializer(ser)
        case ser["attrs"]["body_kind"]
        when "json_object"     then emit_json_object(ser)
        when "embedded_helper" then emit_embedded_helper(ser)
        when "enum_match"      then emit_enum_match(ser)
        else raise "unknown body_kind: #{ser["attrs"]["body_kind"]}"
        end
      end

      def emit_field(fattrs, binding)
        key = fattrs["key"]
        source = fattrs["source"]
        helper = fattrs["helper_fn"]
        case fattrs["mapping_kind"]
        when "direct"
          %(        "#{key}": #{binding}.#{source},)
        when "recurse_list"
          %(        "#{key}": #{binding}.#{source}.iter().map(#{helper}).collect::<Vec<_>>(),)
        when "recurse_optional"
          %(        "#{key}": #{binding}.#{source}.as_ref().map(#{helper}),)
        when "helper_call"
          %(        "#{key}": #{helper}(&#{binding}.#{source}),)
        when "normalize"
          %(        "#{key}": normalize_value(&#{binding}.#{source}),)
        when "fixture_pairs"
          :fixture_pairs
        else
          raise "unknown mapping_kind: #{fattrs["mapping_kind"]}"
        end
      end

      def emit_json_object(ser)
        a = ser["attrs"]
        pub = a["is_entry"] == "true" ? "pub " : ""
        fields = json_fields_for(a["name"])
        pair_field = fields.find { |f| f["attrs"]["mapping_kind"] == "fixture_pairs" }

        if pair_field
          emit_json_object_with_pairs(a, fields, pair_field, pub)
        else
          lines = fields.map { |f| emit_field(f["attrs"], a["input_binding"]) }
          body = lines.join("\n")
          <<~RS
            #{pub}fn #{a["name"]}(#{a["input_binding"]}: &#{a["target_type"]}) -> #{a["return_type"]} {
                json!({
            #{body}
                })
            }

          RS
        end
      end

      def emit_json_object_with_pairs(a, fields, pair_field, pub)
        binding = a["input_binding"]
        pair_source = pair_field["attrs"]["source"]
        pair_key = pair_field["attrs"]["key"]
        preamble = [
          "    // Use array of [key, value] pairs to preserve order — same shape Ruby will emit.",
          "    let pairs: Vec<Value> = #{binding}.#{pair_source}.iter()",
          "        .map(|(k, v)| json!([k, normalize_value(v)]))",
          "        .collect();",
        ].join("\n")

        body_lines = fields.map do |f|
          if f["attrs"]["mapping_kind"] == "fixture_pairs"
            %(        "#{pair_key}": pairs,)
          else
            emit_field(f["attrs"], binding)
          end
        end

        <<~RS
          #{pub}fn #{a["name"]}(#{binding}: &#{a["target_type"]}) -> #{a["return_type"]} {
          #{preamble}
              json!({
          #{body_lines.join("\n")}
              })
          }

        RS
      end

      def emit_embedded_helper(ser)
        a = ser["attrs"]
        path = REPO_ROOT.join(a["snippet_path"])
        body = read_snippet_body(path)

        doc = case a["name"]
              when "normalize_value"
                <<~COMMENT
                  // Strip whitespace adjacent to brackets/braces/parens. Source representations
                  // differ ("[ a, b ]" vs "[a, b]") even when semantically identical; both
                  // runtimes normalize so the canonical output agrees.
                COMMENT
              else
                ""
              end

        signature = "fn #{a["name"]}(#{a["input_binding"]}: &#{a["target_type"]}) -> #{a["return_type"]}"
        <<~RS
          #{doc}#{signature} {
          #{body}}

        RS
      end

      def emit_enum_match(ser)
        a = ser["attrs"]
        cases = by_aggregate("EnumCase")
                  .select { |c| c["attrs"]["serializer"] == a["name"] }
                  .sort_by { |c| c["attrs"]["order"].to_i }
        widest = cases.map { |c| c["attrs"]["variant"].length }.max
        arms = cases.map do |c|
          variant = c["attrs"]["variant"]
          emits = c["attrs"]["emits"]
          pad = " " * (widest - variant.length)
          %(        #{variant}#{pad} => "#{emits}",)
        end
        <<~RS
          fn #{a["name"]}(#{a["input_binding"]}: &#{a["target_type"]}) -> #{a["return_type"]} {
              match #{a["input_binding"]} {
          #{arms.join("\n")}
              }
          }

        RS
      end

      def json_fields_for(serializer_name)
        by_aggregate("JsonField")
          .select { |f| f["attrs"]["serializer"] == serializer_name }
          .sort_by { |f| f["attrs"]["order"].to_i }
      end
    end

    register :dump, Dump
  end
end
