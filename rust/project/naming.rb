module RustProjection
  module Projector
    module_function

    SCALAR      = { "String" => "String", "Integer" => "i64", "Float" => "f64" }.freeze
    SCALAR_KIND = { "String" => :string, "Integer" => :int, "Float" => :float }.freeze

    # `Reference<X>` is not a scalar per the IR's own vocabulary, but it
    # behaves like one for codegen purposes: aggregates-and-value-objects.md's
    # "Pointing at another aggregate" section is explicit that a reference
    # "is a bare id — a String — not a nested object." So a reference is
    # represented as a plain `String`, the same as any other id, at the
    # STRUCT-FIELD level. `resolve_references` (Ruby's own existence check —
    # `command_rules/references.rb`, read directly) is now generated too,
    # but at the registry level (`reactions.rb`'s `reference_check`,
    # `registry.rb`'s own emit), which is where Ruby's own version reaches
    # through `@registry.repository(domain, target)` — not here, and not by
    # changing this field's Rust type.
    def reference_type?(type_name) = type_name.to_s.start_with?("Reference<")

    # `X` out of `Reference<X>` — the target aggregate's own bare name, the
    # same string `command_rules/references.rb#referenced_aggregate` reaches
    # via `attribute.type.resolve.name`. `nil` for anything that isn't a
    # reference type at all, same shape as `reference_type?`.
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

    # Two different jobs a field name does in generated code, and they must
    # NOT share one function: as a STRING LITERAL (a `Fielded::field` match
    # arm's key, a payload map key) the plain name is correct Rust — `"type"`
    # IS the string a caller passes to look a field up by name. As an
    # IDENTIFIER (a struct field, `self.X`/`args.X`/`record.X`) a name that
    # collides with a Rust keyword is a syntax error unless raw-escaped —
    # found live: the self-hosted grammar's own `Attribute`/`Argument`
    # aggregates declare a field literally named `type`, because that is
    # what it is.
    RUST_KEYWORDS = %w[
      as break const continue crate dyn else enum extern false fn for if impl
      in let loop match mod move mut pub ref return self Self static struct
      super trait true type unsafe use where while abstract become box do
      final macro override priv typeof unsized virtual yield try
    ].freeze

    def rust_field(name) = name.to_s
    def rust_ident_field(name)
      field = rust_field(name)
      RUST_KEYWORDS.include?(field) ? "r##{field}" : field
    end

    # A closed-set member's value is business text, not a pre-sanitized Rust
    # identifier — splitting on `_`/whitespace alone was enough for every
    # value pizzas/banking ever declared ("small", "large", "open"...), but
    # the self-hosted grammar's own Vocabulary chapter has closed sets whose
    # members are glob patterns ("*.port", "Translations/*.bluebook") —
    # `.capitalize` leaves `*`/`.`/`/` untouched, so the OLD version emitted
    # `Translations/*.bluebook` as a literal enum variant line, and Rust's
    # lexer read the embedded `/*` as an unterminated block comment. Split on
    # ANY run of non-alphanumeric characters instead, so every character that
    # isn't a valid identifier constituent is a word boundary, not preserved
    # text.
    def closed_set_variant(row)
      _, value = row.first
      value.to_s.split(/[^A-Za-z0-9]+/).reject(&:empty?).map(&:capitalize).join
    end

    def screaming_snake(name)
      name.to_s.gsub(/([a-z0-9])([A-Z])/, '\1_\2').upcase
    end

    def scalar_to_value(type_name, rust_expr)
      case type_name
      when "String"  then "Value::Str(#{rust_expr}.clone())"
      when "Integer" then "Value::Int(#{rust_expr})"
      when "Float"   then "Value::Float(#{rust_expr})"
      end
    end

    def literal_rhs(literal)
      case literal
      when String        then "#{literal.inspect}.to_string()"
      when Integer, Float then literal.to_s
      when true, false     then literal.to_s
      else raise "unsupported literal mutation source #{literal.inspect} — not one of String/Integer/Float/Boolean"
      end
    end
  end
end
