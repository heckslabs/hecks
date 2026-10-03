require "hecks/vocabulary"
require "hecks/bluebook/model_check"

module RustProjection
  # Domain-to-Rust codegen support: type mapping, reserved-name checks, and
  # literal escaping shared by the Rust code generator.
  module Projector
    module_function

    # Ruby has no single Boolean class, so a boolean attribute is declared
    # TrueClass or FalseClass; both keys must map here.
    SCALAR = { "String" => "String", "Integer" => "i64", "Float" => "f64",
                   "TrueClass" => "bool", "FalseClass" => "bool" }.freeze
    SCALAR_KIND = { "String" => :string, "Integer" => :int, "Float" => :float,
                     "TrueClass" => :bool, "FalseClass" => :bool }.freeze

    # A `Reference<X>` is represented as a plain `String` at the
    # struct-field level — it's a bare id, not a nested object (see
    # aggregates-and-value-objects.md's "Pointing at another aggregate").
    def reference_type?(type_name) = type_name.to_s.start_with?("Reference<")

    # Returns nil when `type_name` isn't a `Reference<...>` at all.
    def reference_target(type_name)
      match = type_name.to_s.match(/\AReference<(.+)>\z/)
      match && match[1]
    end

    def effective_scalar_type(type_name)
      return "String" if reference_type?(type_name)

      type_name if SCALAR.key?(type_name)
    end

    def rust_type(type_name, list:)
      scalar = effective_scalar_type(type_name)
      inner = scalar ? SCALAR.fetch(scalar) : rust_ident(type_name)
      list ? "Vec<#{inner}>" : inner
    end

    def rust_ident(name) = name.to_s.gsub(/[^A-Za-z0-9]/, "")
    def dispatch_fn_name(cmd) = cmd.gsub(/(?<=.)([A-Z])/, '_\1').downcase

    # A field name plays two different roles in generated code: a
    # string-literal match-arm/payload key (plain text) and a struct-field
    # identifier (must be raw-escaped when it collides with a Rust
    # keyword) — kept as separate functions so escaping only ever applies
    # to the identifier role.
    #
    # Declared once as the `RustReservedWord` vocabulary;
    # `hecks project_reserved_names` projects the same table into
    # hecks-codegen's `reserved_names.rs`.
    RUST_KEYWORDS = Hecks::Vocabulary.fetch("RustReservedWord")

    # A domain's own name doubles as a directory, a bare Rust module
    # identifier (module names get no raw-identifier escape hatch), and a
    # Cargo `[features]` key. This list rules out the third: every key
    # already used elsewhere in `rust/Cargo.toml` outside `[features]`,
    # plus `default`, which Cargo itself reserves for the auto-enabled
    # feature set.
    #
    # Declared once as the `CargoReservedName` vocabulary.
    CARGO_RESERVED_DOMAIN_NAMES = Hecks::Vocabulary.fetch("CargoReservedName")

    # Checks identifier shape locally; delegates the reserved-word half to
    # `ModelCheck.rust_reserved_name_findings`, the one shared check.
    def valid_domain_mod_name?(name)
      str = name.to_s
      str.match?(/\A[a-z_][a-z0-9_]*\z/) &&
        Hecks::Bluebook::ModelCheck.rust_reserved_name_findings(domain_name: str).empty?
    end

    # Identifier-shape check only (a PascalCase name always passes); whether
    # the downcased name is a Rust keyword is `reserved_name_refusal`'s job,
    # below. An aggregate name never doubles as a Cargo feature key.
    def legal_aggregate_mod_identifier?(name)
      name.to_s.downcase.match?(/\A[a-z_][a-z0-9_]*\z/)
    end

    # Returns nil when every name is usable, else the message
    # `DomainGenerator.call` raises. Must return the identical string as
    # hecks-codegen's `naming::reserved_name_refusal`
    # (rust/codegen/src/naming.rs) for the same input.
    def reserved_name_refusal(source_label, mod_name, aggregate_names)
      names = aggregate_names.map(&:to_s)
      reserved = Hecks::Bluebook::ModelCheck.rust_reserved_name_findings(aggregate_names: names, rust_target: true)
                                            .map(&:subject)
      refused = names.select { |name| reserved.include?(name) || !legal_aggregate_mod_identifier?(name) }
      if refused.any?
        return "#{source_label}: aggregate name(s) #{refused.map(&:inspect).join(', ')} can't be used as-is — " \
               "downcased, each becomes a bare Rust module identifier (`pub mod #{refused.first.downcase};`) and a " \
               "generated file name, and at least one is not a plain identifier or is a Rust keyword " \
               "(RustReservedWord). Module names get no raw-identifier (r#name) escape hatch — rename the aggregate."
      end
      return nil if valid_domain_mod_name?(mod_name)

      "#{source_label}: domain module name #{mod_name.to_s.inspect} can't be used as-is — it has to double as a Rust " \
        "module identifier and a Cargo feature name, and this one is either not a plain lowercase identifier, is a " \
        "Rust keyword (RustReservedWord), or is a reserved Cargo.toml key (CargoReservedName). Rename the domain."
    end

    # Every declared `name` in the IR, in document order. The `fields` maps under
    # `mutations` are skipped: their keys are attribute names and their values
    # are source text, not declarations. So is `translations`: an era edge names
    # data paths (`attendee.first_name`, a backfill into a nested value object)
    # that the host applies to stored rows and never writes into Rust.
    def declared_names(node, out = [])
      case node
      when Hash
        node.each do |key, value|
          if %w[fields translations].include?(key.to_s)
            next
          elsif key.to_s == "name" && value.is_a?(String)
            out << value
          else
            declared_names(value, out)
          end
        end
      when Array
        node.each { |item| declared_names(item, out) }
      end
      out
    end

    # Returns nil when every declared name is a plain identifier, else the
    # message `DomainGenerator.call` raises. Attribute, command, event, query
    # and port names are written into the generated crate as field, struct and
    # function names, so a name like "a: String, pub evil: u8" would otherwise
    # inject code into it. Must return the identical string as hecks-codegen's
    # `naming::unsafe_name_refusal` (rust/codegen/src/naming.rs).
    def unsafe_name_refusal(source_label, ir)
      refused = declared_names(ir).uniq.reject { |name| name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/) }
      return nil if refused.empty?

      "#{source_label}: declared name(s) #{refused.map(&:inspect).join(', ')} can't be used as-is — each is " \
        "written into the generated Rust as an identifier, and at least one is not a plain identifier (letters, " \
        "digits and underscores, not starting with a digit). Rename it in the bluebook."
    end

    # `r#crate`/`r#self`/`r#super`/`r#Self` are not valid raw-identifier
    # syntax in Rust at all, so these four can't be escaped the way
    # `rust_ident_field` escapes every other `RUST_KEYWORDS` entry.
    RUST_UNESCAPABLE_KEYWORDS = %w[crate self super Self].freeze

    def rust_field(name) = name.to_s

    def rust_ident_field(name)
      field = rust_field(name)
      if RUST_UNESCAPABLE_KEYWORDS.include?(field)
        raise "rust_ident_field(#{field.inspect}): #{field.inspect} is a Rust keyword that cannot be rescued by a raw " \
              "identifier (r##{field} is not valid Rust syntax for crate/self/super/Self in any position) — rename " \
              "the attribute/field in the bluebook."
      end

      RUST_KEYWORDS.include?(field) ? "r##{field}" : field
    end

    # Splits on any run of non-alphanumeric characters, since closed-set
    # members can be glob patterns like `*.port`. `Self`, the one
    # capitalized Rust keyword, is renamed by original casing (SelfType/
    # SelfValue) so two different values can't collide into it.
    def closed_set_variant(row)
      _, value = row.first
      variant = value.to_s.split(/[^A-Za-z0-9]+/).reject(&:empty?).map(&:capitalize).join
      return variant unless variant == "Self"

      value.to_s.start_with?("S") ? "SelfType" : "SelfValue"
    end

    def screaming_snake(name)
      name.to_s.gsub(/([a-z0-9])([A-Z])/, '\1_\2').upcase
    end

    def scalar_to_value(type_name, rust_expr)
      case type_name
      when "String"  then "Value::Str(#{rust_expr}.clone())"
      when "Integer" then "Value::Int(#{rust_expr})"
      when "Float"   then "Value::Float(#{rust_expr})"
      when "TrueClass", "FalseClass" then "Value::Bool(#{rust_expr})"
      end
    end

    # True when `vo` can emit `Field::Nested(&self.x)`: any ordinary value
    # object, or a single-field closed set (which has its own `Fielded`
    # impl). False for a multi-field closed set, which has no `Fielded`
    # impl to emit against.
    def fielded_capable_nested?(vo)
      !vo[:closed_set] || vo[:attributes].size == 1
    end

    # `Fielded` impl for a single-field closed set: answers "value" as its
    # one field, matching the same arms the enum's own generated `to_json`
    # already builds (reproduced here rather than shared, so it never
    # touches the enum's existing to_json/from_json generation).
    def emit_closed_set_fielded_impl(vo)
      name = rust_ident(vo[:name])
      arms = vo[:members].map do |row|
        _, raw = row.first
        "#{name}::#{closed_set_variant(row)} => #{rust_string_literal(raw.to_s)}.to_string(),"
      end.join(" ")

      "impl crate::kernel::Fielded for #{name} {\n    " \
        "fn field(&self, name: &str) -> Option<crate::kernel::Field<'_>> {\n        " \
        "use crate::kernel::{Field, Value};\n        " \
        "match name {\n            " \
        "\"value\" => Some(Field::Value(Value::Str(match self { #{arms} }))),\n            " \
        "_ => None,\n        " \
        "}\n    " \
        "}\n    " \
        "fn as_scalar(&self) -> Option<crate::kernel::Value> {\n        " \
        "match self.field(\"value\") { Some(crate::kernel::Field::Value(v)) => Some(v), _ => None }\n    " \
        "}\n" \
        "}"
    end

    def literal_rhs(literal)
      case literal
      when String then "#{rust_string_literal(literal)}.to_string()"
      when Integer, Float, true, false then literal.to_s
      else raise "unsupported literal mutation source #{literal.inspect} — not one of String/Integer/Float/Boolean"
      end
    end

    # Ruby's String#inspect escapes for Ruby's own read-back (e.g. a
    # brace-less `\uXXXX`), which isn't valid Rust syntax. This escapes
    # only what Rust's string-literal grammar needs: backslash,
    # double-quote, and control characters.
    def rust_string_literal(str)
      escaped = str.to_s.each_char.map do |ch|
        case ch
        when "\\" then "\\\\"
        when "\"" then "\\\""
        when "\n" then "\\n"
        when "\r" then "\\r"
        when "\t" then "\\t"
        else
          cp = ch.ord
          cp < 0x20 || cp == 0x7F ? format("\\u{%x}", cp) : ch
        end
      end.join
      "\"#{escaped}\""
    end
  end
end
