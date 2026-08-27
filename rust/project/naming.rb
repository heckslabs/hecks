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

    # A DOMAIN'S OWN NAME (`File.basename(domain)`, `bin/project_rust`) has
    # to double as THREE things at once: a directory name, a bare Rust
    # module identifier (`pub mod #{name};` — module names get no raw-
    # identifier `r#name` escape hatch the way struct FIELDS do via
    # `rust_ident_field`), and a Cargo `[features]` key. `RUST_KEYWORDS`
    # above rules out the second; this list rules out the third — every
    # key that already appears elsewhere in `rust/Cargo.toml` outside
    # `[features]` (`[package]`'s `name`/`version`/`edition`/etc., `[lib]`/
    # `[[bin]]`'s `name`/`path`) plus `default`, which Cargo itself
    # reserves for the auto-enabled feature set. `bin/project_rust`'s own
    # feature-sync regex used to search the WHOLE Cargo.toml text for
    # `/^name\s*=/` (now scoped to `[features]` only — see its own
    # comment), so a domain named one of these used to silently never
    # get its own feature line while still being set as `default`,
    # producing a Cargo.toml that referenced an undeclared feature.
    CARGO_RESERVED_DOMAIN_NAMES = %w[
      name version edition path authors license description
      default features package lib bin dependencies
      dev-dependencies build-dependencies workspace
    ].freeze

    # TRUE exactly when `name` is safe to use, unescaped, as all three of
    # the above at once. Plain lowercase-identifier shape (no leading
    # digit, no `-`, not empty) rules out landmine class 1 (an outright
    # Rust syntax error); the two reserved-word checks rule out class 2
    # (a legal identifier that collides with something load-bearing).
    def valid_domain_mod_name?(name)
      str = name.to_s
      str.match?(/\A[a-z_][a-z0-9_]*\z/) &&
        !RUST_KEYWORDS.include?(str) &&
        !CARGO_RESERVED_DOMAIN_NAMES.include?(str)
    end

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

    # TRUE for anything `fielded.rb`'s three "is this attribute a nested
    # value object" sites can safely emit `Field::Nested(&self.x)` for —
    # every ordinary (non-closed-set) VO always could; a single-field
    # CLOSED SET (an enum, `emit_closed_set_enum`) now can too, once it
    # carries its own `Fielded` impl (`emit_closed_set_fielded_impl`,
    # below) answering "value" the same way any other single-field VO's
    # own generated `Fielded` impl already does. FALSE for a MULTI-FIELD
    # closed set (`emit_closed_set_table` — Syntax::Keyword, Argument):
    # genuinely no `Fielded` impl exists or is proven needed for that
    # shape (json_codec.rb's own `emit_closed_set_codec` header: "nothing
    # in either example domain looks one up generically or passes one as
    # a command argument") — `Field::Nested` would fail to compile
    # against it, and nothing in the corpus has ever needed it to.
    #
    # FOUND LIVE, a real, previously-invisible gap: no domain ever
    # declared a `given`/expression referencing a closed-set-typed
    # attribute before lifeadelics' vendored embryonaut_bluebooks/
    # payments (`Payment::Succeed`'s own "the processor matches..."
    # given, over `processor: Processor` and `reported_processor:
    # Processor`, both `one_of:` closed sets) — found live, a reaction-
    # triggered Payment::Succeed refusing with "cannot resolve
    # \"processor\" — no such attribute or argument" even though the
    # aggregate held a real, rehydrated `processor` value the whole time.
    def fielded_capable_nested?(vo)
      !vo[:closed_set] || vo[:attributes].size == 1
    end

    # THE `Fielded` IMPL A SINGLE-FIELD CLOSED SET NEVER GOT —
    # `emit_value_object`'s own single-field-closed-set branch (types.rb)
    # used to return early with JUST the bare enum (`emit_closed_set_
    # enum`), matching neither `emit_fielded_flat`'s shape (it has no
    # `attributes` to iterate, being a tag, not a struct) nor needing one
    # before `fielded_capable_nested?` above started asking. Answers
    # "value" — the SAME single field every other closed-set codec
    # already treats it as (`emit_closed_set_codec`'s own `to_json`:
    # `Json::obj(vec![("value", ...)])`) — with the identical match this
    # enum's own `to_json` already builds, reproduced here rather than
    # shared via a common helper method (lower-risk: purely additive,
    # touches nothing about the enum's own EXISTING to_json/from_json
    # generation or any other caller of it).
    def emit_closed_set_fielded_impl(vo)
      name = rust_ident(vo[:name])
      arms = vo[:members].map do |row|
        _, raw = row.first
        "#{name}::#{closed_set_variant(row)} => #{rust_string_literal(raw.to_s)}.to_string(),"
      end.join(" ")

      "impl crate::kernel::Fielded for #{name} {\n" \
        "    fn field(&self, name: &str) -> Option<crate::kernel::Field<'_>> {\n" \
        "        use crate::kernel::{Field, Value};\n" \
        "        match name {\n" \
        "            \"value\" => Some(Field::Value(Value::Str(match self { #{arms} }))),\n" \
        "            _ => None,\n" \
        "        }\n" \
        "    }\n" \
        "    fn as_scalar(&self) -> Option<crate::kernel::Value> {\n" \
        "        match self.field(\"value\") { Some(crate::kernel::Field::Value(v)) => Some(v), _ => None }\n" \
        "    }\n" \
        "}"
    end

    def literal_rhs(literal)
      case literal
      when String        then "#{rust_string_literal(literal)}.to_string()"
      when Integer, Float then literal.to_s
      when true, false     then literal.to_s
      else raise "unsupported literal mutation source #{literal.inspect} — not one of String/Integer/Float/Boolean"
      end
    end

    # RUST STRING LITERAL ESCAPING (R5) — free-form bluebook text (a
    # `given`/`ensures`/invariant description, a `then_set ... to:`
    # literal, a closed-set member's raw value, the domain's whole IR
    # embedded verbatim as `IR_JSON`) has to become a Rust string literal
    # somewhere in generated code. Ruby's own `String#inspect` LOOKS like
    # it does this job — it already backslash-escapes `"`/`\`/newlines/
    # tabs — but it escapes for RUBY'S OWN benefit, not Rust's:
    # verified live —
    #
    #   "cost #{"#"}{x}".inspect  => "\"cost \\\#{x}\""   (Ruby needs \# so
    #                                the re-read literal doesn't interpolate)
    #   "\x01".inspect            => "\"\\u0001\""        (Ruby's own \uXXXX,
    #                                no braces)
    #
    # Neither `\#` nor a brace-less `\uXXXX` is a legal Rust escape — Rust
    # has no `\#` escape at all, and requires `\u{XXXX}` — so a
    # description containing a literal `#{`/`#@` or a raw control
    # character produces generated Rust that fails to compile (the exact
    # R5 landmine). This escapes only what RUST's own string-literal
    # grammar actually needs — backslash, double-quote, and control
    # characters (`\n`/`\r`/`\t` where they have a short escape, braced
    # `\u{XX}` otherwise) — and leaves everything else, including a
    # literal `#{`/`#@` (meaningless in Rust — it has no string
    # interpolation), untouched.
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
