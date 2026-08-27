module RustProjection
  module Projector
    module_function

    # THE WASM/CLI JSON BOUNDARY — `to_json`/`from_json`, generated
    # alongside every `Fielded` impl (fielded.rb) for the exact same types:
    # value objects and command Args structs get both directions; entities
    # and aggregate records get `to_json` only (nothing constructs a whole
    # entity or record straight from JSON — `Hydrate::Create`'s own `build`
    # closure, and `append`'s auto-minted identity/lifecycle, already cover
    # entities; a record only ever comes from a `dispatch_*` call). Mirrors
    # `emit_fielded_flat`/`emit_fielded_record`'s own split for the same
    # reason: reading (both directions here) is one mechanical per-attribute
    # table; nothing about identity/lifecycle/hydration needs re-deciding.

    def json_type_error(struct_name, key, expectation)
      "crate::kernel::Refusal::TypeMismatch(#{"#{struct_name}.#{key}: expected #{expectation}".inspect}.to_string())"
    end

    # `TypeMismatch numeric_field`'s own template (`refusal_wording.rb`):
    # `"{type}.{field} expects {expected}, got {offered}"` — `offered` is
    # `value.inspect` on the Ruby side, `Json::inspect` (json.rs) on this
    # one. Scoped to `Integer`/`Float` specifically (the template's own
    # name) — a `String` scalar mismatch keeps `json_type_error`'s own
    # generic wording, since nothing in this corpus exercises Ruby's own
    # wording for THAT shape and this generator shouldn't guess at it.
    def scalar_type_error(struct_name, key, scalar_type, value_var)
      return json_type_error(struct_name, key, scalar_type) unless %w[Integer Float].include?(scalar_type)

      template = "#{struct_name}.#{key} expects #{scalar_type}, got {}"
      "crate::kernel::Refusal::TypeMismatch(format!(#{template.inspect}, #{value_var}.inspect()))"
    end

    SCALAR_JSON_ACCESSOR = { "String" => "as_str", "Integer" => "as_i64", "Float" => "as_f64" }.freeze

    # `Value.for_attribute` → `fields_for`'s own bare-scalar branch
    # (lib/hecks/runtime/value/coercion.rb), at codegen time instead
    # of runtime: a value-object-typed field whose OWN type has exactly
    # one attribute accepts a bare JSON scalar in the caller's place of
    # the wrapped `{"field": ...}` shape — `size: "large"` alongside
    # `size: { value: "large" }`, both admitted, matching Ruby exactly.
    # `nil` for anything else (no such type in `value_objects_by_name` —
    # every real composite attribute type IS declared there, since a
    # value object is scoped to its own aggregate — or a genuinely
    # multi-field one), so every OTHER composite branch below is
    # unchanged. Mirrors `Behaviour::ValueObject#sole_attribute`
    # (value_object.rb) against the exported IR's own Hash shape
    # (`vo[:attributes]`, not a live `Bluebook::Attribute` object).
    def sole_field_of(type_name, value_objects_by_name)
      vo = value_objects_by_name[type_name]
      return nil unless vo && vo[:attributes]&.size == 1

      vo[:attributes].first[:name].to_s
    end

    # The `NestedType::from_json(expr)?` call itself, wrapped in
    # `Json::coerce_single_field` (kernel/json.rs) first when `attr`'s
    # own type is single-field — shared by both composite branches in
    # `emit_from_json_flat`/`emit_from_json_state` below (required and
    # `attr[:optional]`) so the bare-scalar decision is made once, not
    # copied four times.
    def composite_from_json_expr(attr, value_objects_by_name, value_expr)
      nested_type = rust_ident(attr[:type])
      sole = sole_field_of(attr[:type], value_objects_by_name)
      source = sole ? "&#{value_expr}.coerce_single_field(#{sole.inspect})" : value_expr
      "#{nested_type}::from_json(#{source})?"
    end

    # `default:` — `Value.build`'s own fallback (bridging.rb's
    # `creation_default_rhs` comment, the same rule applied here instead of
    # only at creation time): a scalar field the caller's JSON doesn't
    # carry isn't automatically a missing-argument refusal if the
    # ATTRIBUTE itself declares a `default:` — `PositiveMoney.currency`
    # (default `"USD"`) is the live example a process manager's own `with:`
    # forwarding surfaces: `Transfer`'s own `amount` type (`TransferMoney`)
    # has no `currency` field at all, so a leg dispatching `Account.Debit`
    # with `amount: :amount` forwards a bare `{"cents": N}` — Ruby's
    # `Value.for_attribute` fills the missing field from the TARGET type's
    # own default the identical way; this is that, generated.
    def scalar_from_json_expr(struct_name, key, scalar_type, default: nil)
      accessor = SCALAR_JSON_ACCESSOR.fetch(scalar_type)
      wrap = scalar_type == "String" ? ".map(|s| s.to_string())" : ""
      # A KEY the caller's JSON never mentions at all falls back to the
      # attribute's own `default:`, matching `Value.build`'s own rule
      # (bridging.rb's `creation_default_rhs` comment). A key that IS
      # present but the wrong shape (`{"cents": "lots"}` for an `Integer`
      # field) is a real `TypeMismatch` Ruby's own `Value.for_attribute`
      # refuses regardless of whether a default exists — found live
      # (`Banking::Account#acct-6`'s own corpus mismatch): the OLD
      # `.and_then(accessor)...unwrap_or_else(default)` chain couldn't
      # distinguish "absent" from "present but unparseable," so a
      # non-numeric string silently became the default instead of a
      # refusal. `match` on presence FIRST, so only the "absent" arm ever
      # reaches for the default.
      return %(match v.get(#{key.inspect}) { Some(x) => x.#{accessor}()#{wrap}.ok_or_else(|| #{scalar_type_error(struct_name, key, scalar_type, 'x')})?, None => #{literal_rhs(default)} }) if default

      %({ let x = v.require(#{key.inspect}, #{struct_name.inspect})?; x.#{accessor}()#{wrap}.ok_or_else(|| #{scalar_type_error(struct_name, key, scalar_type, 'x')})? })
    end

    # The scalar-extraction half of `scalar_from_json_expr`, applied to an
    # ALREADY-LOCATED Json value (`x`) instead of looking the key up itself
    # — `emit_from_json_flat`'s own `attr[:optional]` branch already has
    # `x` in hand from a `Some(x) = v.get(key)` match, so it needs just the
    # "read a scalar out of this value" part, not a second key lookup.
    def scalar_from_json_value_expr(struct_name, key, scalar_type, value_expr)
      accessor = SCALAR_JSON_ACCESSOR.fetch(scalar_type)
      wrap = scalar_type == "String" ? ".map(|s| s.to_string())" : ""
      %(#{value_expr}.#{accessor}()#{wrap}.ok_or_else(|| #{scalar_type_error(struct_name, key, scalar_type, value_expr)})?)
    end

    def scalar_to_json_expr(scalar_type, rust_expr)
      case scalar_type
      when "String"  then "crate::kernel::Json::Str(#{rust_expr}.clone())"
      when "Integer" then "crate::kernel::Json::int(#{rust_expr})"
      when "Float"   then "crate::kernel::Json::Float(#{rust_expr})"
      end
    end

    # `CommandInterpreter::ArgumentGate#refuse_unknown_arguments`'s own
    # allowlist (argument_gate.rb, read directly): `known = command.
    # attributes + [:id, *aggregate.identity_heads, reference_key(command)]
    # + correlation_keys(domain)` — declared attributes plus every OTHER
    # name a caller is legitimately allowed to address a command by or
    # smuggle a saga's correlation through. Only ever passed for an
    # AGGREGATE-level command's own `from_json` (`emit_unknown_argument_
    # check`'s own caller) — entity commands run no such check at all
    # (`EntityInterpreter::DISPATCH_ORDER` has no `refuse_unknown_arguments`/
    # `refuse_absent_arguments` step, commands.rb's own header on
    # `emit_entity_command`), and a nested value object's own fields are a
    # different, more permissive concern `Value.for_attribute`'s coercion
    # already covers — never this gate.
    def command_argument_allowlist(aggregate, command, process_managers)
      reference_key = command[:references].to_s.empty? ? nil : Hecks::Naming.reference_key(command[:references]).to_s
      identity_heads = aggregate[:identified_by].map { |path| path.split(".").first }
      correlation_keys = Array(process_managers).filter_map { |pm| pm[:correlates_by]&.split(".")&.first }
      (["id", reference_key] + identity_heads + correlation_keys).compact.uniq
    end

    # `command_name` — `ArgumentGate#refuse_unknown_arguments`'s own
    # `UnknownArgument unknown_args` template (`refusal_wording.rb`):
    # `"{command} does not declare {unknown} — it takes {declared}"` —
    # `command` is `command.hecks_name` ("Credit"), NOT the args struct's
    # own name ("CreditArgs") — the two differ by exactly the same "Args"
    # suffix `rust_ident(command[:name]) + "Args"` always adds, confirmed
    # against Ruby's own live wording.
    def emit_unknown_argument_check(command_name, known_keys, declared_names)
      <<~RUST
                let unknown = v.unknown_keys(&[#{known_keys.map(&:inspect).join(', ')}]);
                if !unknown.is_empty() {
                    return Err(crate::kernel::Refusal::UnknownArgument(format!(
                        "#{command_name} does not declare {} — it takes #{declared_names.join(', ')}",
                        unknown.join(", ")
                    )));
                }
      RUST
    end

    # One constructor per real attribute — value objects and Args structs
    # only (see header). A list attribute's element type must carry its own
    # `from_json` (every real element type here is a plain value object,
    # per this corpus — `CardPayment.Authorize`'s `tags: Vec<Tag>` is the
    # one live case; an entity-typed list attribute is not a shape any
    # command argument declares, per emit_entity's own header).
    #
    # `unknown_argument_allowlist:` — nil (the default, VOs and entity
    # commands) skips `refuse_unknown_arguments` entirely; an Array (only
    # ever an AGGREGATE command's own args struct) emits the check first.
    # `command_name:` — the command's own short name (`emit_unknown_
    # argument_check`'s own header), defaulting to `struct_name` for
    # every OTHER caller (value objects, entity commands — neither ever
    # passes `unknown_argument_allowlist`, so this default is never
    # actually read).
    def emit_from_json_flat(struct_name, attributes, value_objects_by_name, unknown_argument_allowlist: nil, command_name: struct_name)
      field_exprs = attributes.map do |attr|
        ident = rust_ident_field(attr[:name])
        key = rust_field(attr[:name])
        scalar = effective_scalar_type(attr[:type])
        rhs =
          if attr[:list] && attr[:optional]
            # `Option<Vec<T>>` — `None` when the caller never supplied
            # the key at all (`CardPayment.Authorize`'s own `tags:`),
            # not defaulted to an empty Vec the way a REQUIRED list
            # argument's own absent-key case still is, below.
            elem_type = rust_ident(attr[:type])
            array_error = json_type_error(struct_name, key, "an array")
            "match v.get(#{key.inspect}) { " \
              "Some(x) => Some(x.as_array().ok_or_else(|| #{array_error})?.iter().map(#{elem_type}::from_json).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?), " \
              "None => None, }"
          elsif attr[:list]
            elem_type = rust_ident(attr[:type])
            "match v.get(#{key.inspect}).and_then(crate::kernel::Json::as_array) { " \
              "Some(items) => items.iter().map(#{elem_type}::from_json).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?, " \
              "None => Vec::new(), }"
          elsif attr[:optional] && scalar
            "match v.get(#{key.inspect}) { Some(x) => Some(#{scalar_from_json_value_expr(struct_name, key, scalar, 'x')}), None => None, }"
          elsif attr[:optional]
            "match v.get(#{key.inspect}) { Some(x) => Some(#{composite_from_json_expr(attr, value_objects_by_name, 'x')}), None => None, }"
          elsif scalar
            scalar_from_json_expr(struct_name, key, scalar, default: attr[:default])
          else
            composite_from_json_expr(attr, value_objects_by_name, "v.require(#{key.inspect}, #{struct_name.inspect})?")
          end
        Exemplar.render("field_assignment", "tmpl_ident" => ident, "tmpl_rhs_placeholder()" => rhs)
      end

      unknown_check =
        if unknown_argument_allowlist
          known_keys = (attributes.map { |a| rust_field(a[:name]) } + unknown_argument_allowlist).uniq
          emit_unknown_argument_check(command_name, known_keys, attributes.map { |a| a[:name] })
        else
          ""
        end

      emit_from_json_skeleton(struct_name, field_exprs, unknown_check)
    end

    # Shared by `emit_from_json_flat` and `emit_from_json_state` — the
    # SAME outer skeleton (`from_json_flat`, rust/src/exemplar/json.rs)
    # backs both; only the preamble (unknown-argument check, only ever
    # non-empty for an aggregate command's own top-level args) and each
    # field's RHS differ, both already-built plain strings by the time
    # they reach here.
    #
    # The preamble marker spans BOTH its own line and the following
    # `Ok(Self {` line as ONE substitution, not two independent ones —
    # deliberately, not a shortcut: a blank preamble must leave NO blank
    # line at all (`render` only replaces a marker's TEXT, never deletes
    # its own line, so a naive empty-string substitution would strand
    # one), while a real command with NO fields at all legitimately DOES
    # render `Ok(Self {\n\n        })` (an empty `field_exprs` block) —
    # a blank-line STRIP tried first here, and wrongly ate that second,
    # real case along with the first. Reconstructing the exact two-line
    # span in Ruby (unknown_check already ends in its own "\n" when
    # present, matching the ORIGINAL's own string concatenation) fixes
    # the one case this needs fixed without touching the other.
    def emit_from_json_skeleton(struct_name, field_exprs, unknown_check)
      field_block = field_exprs.map { |f| "        #{f}" }.join("\n")
      # Trailing "\n" — see `emit_to_json_flat`'s own comment on why.
      "#{Exemplar.render(
        'from_json_flat',
        'TmplFlatType2' => struct_name,
        "let _tmpl_unknown_check_placeholder = ();\n        Ok(Self {" => "#{unknown_check}        Ok(Self {",
        'tmpl_ident: tmpl_rhs_placeholder(),' => field_block
      )}\n"
    end

    # `optional:` mirrors `emit_fielded_record`'s own Option-wrap: every
    # non-list aggregate-RECORD field serializes `Json::Null` when unset,
    # the same way it reads `Value::Nil` through `Fielded`. Value objects
    # and Args structs (never Option-wrapped) pass `optional: false`.
    #
    # `extra_fields:` — `[[key, rust_value_expr], ...]` appended verbatim,
    # never run through the optional-wrap logic above. Exists for exactly
    # one caller: the LIFECYCLE field, which — like `emit_record`'s own
    # struct field and `emit_fielded_record`'s own extra match arm — is a
    # plain, never-`Option`-wrapped `String` even on an otherwise
    # `optional: true` aggregate record, so it can't be folded into the
    # generic per-attribute loop above without special-casing every branch
    # in it for one field.
    # `sparse:` — COMMAND ARGS STRUCTS ONLY (this method's two Args call
    # sites, domain_generator.rb + commands.rb, pass `sparse: true`;
    # value objects and aggregate/entity records never do). Per-field
    # expression logic below is IDENTICAL either way — `sparse:` only
    # picks which of the two OUTER exemplar templates wraps the result:
    # `to_json_flat` keeps every `(key, value)` pair, `null` included for
    # an unset optional field (correct for a persisted record, which
    # legitimately HAS every declared field) ; `to_json_flat_sparse`
    # drops a `(key, Json::Null)` pair entirely, matching Ruby's own
    # `payload: args` — an event's payload should carry exactly the keys
    # the caller actually supplied, not every key the command COULD have
    # accepted. See `rust/src/exemplar/json.rs`'s own comment on
    # `to_json_flat_sparse` for the full argument, including why the
    # filter is safe (no required field's own conversion ever produces
    # `Json::Null`).
    def emit_to_json_flat(struct_name, attributes, value_objects_by_name, optional: false, extra_fields: [], aggregate: nil, sparse: false)
      field_exprs = attributes.map do |attr|
        ident = rust_ident_field(attr[:name])
        key = rust_field(attr[:name])
        scalar = effective_scalar_type(attr[:type])
        # `attr[:optional]` — a real `Option<T>` struct field now
        # (0014/0015's struct-field change), data-driven off the
        # declaration, not a runtime "is it empty" heuristic (tried that
        # first for lists specifically, broke `ledger`-shaped fields —
        # unmatched by their creating command, legitimately `[]` in Ruby
        # too — see git history). `attr[:optional]` names EXACTLY the
        # fields Ruby itself treats as possibly-absent, leaving every
        # other field — including ones that happen to be empty right
        # now — exactly as it's always been.
        #
        # `aggregate` — passed only for a RECORD's own `to_json` (`attr`
        # here is the AGGREGATE's own attribute, whose `optional:` flag is
        # near-always `false` even when the command argument that feeds it
        # is `optional: true` — `CardPayment.tags` is exactly this: the
        # aggregate's own `tags` is `optional: false`, the command's own
        # `tags:` argument is `optional: true`). `list_attr_creation_
        # optional?` (mutations.rb) is the record-level equivalent check.
        record_optional_list = attr[:list] && aggregate && list_attr_creation_optional?(aggregate, attr[:name], value_objects_by_name)
        field_optional = optional || attr[:optional]
        # A RECORD's own list field (`aggregate` present) is Option-
        # wrapped ONLY per `list_attr_creation_optional?` — the exact
        # rule `emit_record` (types.rb) itself uses to decide the
        # struct field's real type; the aggregate's own `attr[:optional]`
        # is near-always true for an optional list attribute (Engagement
        # .use_cases, declared `optional: true`) whether or not any
        # creating command's `sets` actually threads a nullable
        # argument to it, so checking it here too would call `.as_ref()`
        # on a plain `Vec<T>` field that was never Option-wrapped in the
        # first place (a real bug, caught live: E0282 "type annotations
        # needed" on Engagement.use_cases). A non-record struct (Args,
        # `aggregate: nil`) has no such record-level rule to defer to —
        # `attr[:optional]` there matches `emit_fielded_flat`'s own list
        # field type directly, unchanged.
        list_is_optional = aggregate ? record_optional_list : attr[:optional]
        value_expr =
          if attr[:list] && list_is_optional
            "self.#{ident}.as_ref().map(|v| crate::kernel::Json::Array(v.iter().map(|x| x.to_json()).collect())).unwrap_or(crate::kernel::Json::Null)"
          elsif attr[:list]
            "crate::kernel::Json::Array(self.#{ident}.iter().map(|x| x.to_json()).collect())"
          elsif field_optional && scalar
            "self.#{ident}.as_ref().map(|v| #{scalar_to_json_expr(scalar, 'v')}).unwrap_or(crate::kernel::Json::Null)"
          elsif field_optional
            "self.#{ident}.as_ref().map(|v| v.to_json()).unwrap_or(crate::kernel::Json::Null)"
          elsif scalar
            scalar_to_json_expr(scalar, "self.#{ident}")
          else
            "self.#{ident}.to_json()"
          end
        Exemplar.render("to_json_field", '"tmpl_field_name"' => key.inspect, "tmpl_json_value_placeholder()" => value_expr)
      end
      field_exprs += extra_fields.map { |key, expr| Exemplar.render("to_json_field", '"tmpl_field_name"' => key.inspect, "tmpl_json_value_placeholder()" => expr) }
      field_block = field_exprs.map { |f| "        #{f}" }.join("\n")

      # Trailing "\n" — restores the OLD heredoc's own implicit one
      # (see `emit_fielded_flat`'s own comment, fielded.rb); needed here
      # because `commands.rb`'s entity-command heredoc interpolates this
      # return value directly, not through `f.puts` (which wouldn't care
      # either way).
      rendered = if sparse
                   Exemplar.render("to_json_flat_sparse", "TmplFlatType3" => struct_name,
                                                           "tmpl_to_json_field_block_sparse()" => field_block)
                 else
                   Exemplar.render("to_json_flat", "TmplFlatType2" => struct_name,
                                                    "tmpl_to_json_field_block()" => field_block)
                 end
      "#{rendered}\n"
    end

    # THE INVERSE OF `emit_to_json_flat`, for the SAME two struct kinds
    # that method serves when called with `aggregate:`/no `aggregate:` —
    # aggregate records and entities — NOT a third case of
    # `emit_from_json_flat` above. That method is command-args-shaped: a
    # caller either supplies a key or doesn't, and an ABSENT optional key
    # means "unset." Record/entity `to_json` (this same file, just
    # above) is different — an unset Option field's key is always
    # PRESENT, with value `Json::Null` (`.unwrap_or(crate::kernel::
    # Json::Null)`), because Ruby's own JSON.generate(state) round-trip
    # this mirrors does the same. So this reads `Some(&Json::Null)` the
    # same as `None` everywhere `emit_from_json_flat` only ever checked
    # for absence — the one real structural difference between "parse
    # caller-supplied args" and "parse this type's own to_json output
    # back."
    #
    # Takes the EXACT SAME parameters as `emit_to_json_flat`
    # (`optional:`, `aggregate:`) so both directions make the identical
    # per-field optionality decision — called with `optional: true,
    # aggregate: aggregate` for a record (domain_generator.rb, matching
    # `emit_record`'s "every field is Option<T>" struct rule) and with
    # the defaults for an entity (matching `emit_entity`'s own
    # `Option<T>` only when `attr[:optional]` rule).
    #
    # Exists for `Store::from_seed` (registry.rb) — a host driving this
    # kernel (rust/host, docs/decisions/0012) seeding prior state back
    # in instead of replaying full command history, the mechanical
    # inverse of `Store::instances()`'s own to_json dump.
    def emit_from_json_state(struct_name, attributes, value_objects_by_name, optional: false, extra_fields: [], aggregate: nil)
      field_exprs = attributes.map do |attr|
        ident = rust_ident_field(attr[:name])
        key = rust_field(attr[:name])
        scalar = effective_scalar_type(attr[:type])
        record_optional_list = attr[:list] && aggregate && list_attr_creation_optional?(aggregate, attr[:name], value_objects_by_name)
        list_is_optional = aggregate ? record_optional_list : attr[:optional]
        field_optional = optional || attr[:optional]

        rhs =
          if attr[:list] && list_is_optional
            elem_type = rust_ident(attr[:type])
            array_error = json_type_error(struct_name, key, "an array")
            "match v.get(#{key.inspect}) { " \
              "Some(&crate::kernel::Json::Null) | None => None, " \
              "Some(x) => Some(x.as_array().ok_or_else(|| #{array_error})?.iter().map(#{elem_type}::from_json).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?), }"
          elsif attr[:list]
            elem_type = rust_ident(attr[:type])
            "match v.get(#{key.inspect}).and_then(crate::kernel::Json::as_array) { " \
              "Some(items) => items.iter().map(#{elem_type}::from_json).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?, " \
              "None => Vec::new(), }"
          elsif field_optional && scalar
            "match v.get(#{key.inspect}) { " \
              "Some(&crate::kernel::Json::Null) | None => None, " \
              "Some(x) => Some(#{scalar_from_json_value_expr(struct_name, key, scalar, 'x')}), }"
          elsif field_optional
            "match v.get(#{key.inspect}) { " \
              "Some(&crate::kernel::Json::Null) | None => None, " \
              "Some(x) => Some(#{composite_from_json_expr(attr, value_objects_by_name, 'x')}), }"
          elsif scalar
            scalar_from_json_expr(struct_name, key, scalar, default: attr[:default])
          else
            composite_from_json_expr(attr, value_objects_by_name, "v.require(#{key.inspect}, #{struct_name.inspect})?")
          end
        Exemplar.render("field_assignment", "tmpl_ident" => ident, "tmpl_rhs_placeholder()" => rhs)
      end

      # `extra_fields` carries `(key, to_json-serialize-expr)` pairs
      # (`lifecycle_extra_field`'s own shape) — from_json only needs the
      # KEY back; the lifecycle field is always a plain, required
      # String, matching `emit_record`/`emit_entity`'s own never-
      # Option-wrapped struct field for it.
      extra_field_exprs = extra_fields.map do |key, _serialize_expr|
        ident = rust_ident_field(key)
        rhs = "v.require(#{key.inspect}, #{struct_name.inspect})?.as_str()" \
          ".ok_or_else(|| #{json_type_error(struct_name, key, 'a string')})?.to_string()"
        Exemplar.render("field_assignment", "tmpl_ident" => ident, "tmpl_rhs_placeholder()" => rhs)
      end

      emit_from_json_skeleton(struct_name, field_exprs + extra_field_exprs, "")
    end

    # A single-field CLOSED SET only — `emit_value_object`'s own branch on
    # `vo[:attributes].size > 1` (a data table, not a tag) generates neither
    # `Fielded` nor invariant checking today, and doesn't get a JSON codec
    # here either, for the same reason: nothing in either example domain
    # looks one up generically or passes one as a command argument.
    # `InvariantViolation`/`closed_set_member` — `refusal_wording.rb`'s own
    # template, `"{type} admits {admitted} — got {offered}"` — read
    # directly and reproduced byte-for-byte the same way `emit_admits_check`
    # (constraints.rb) already does for the sibling `admits_declared_set`
    # site: `type` prints bare (`value_object.hecks_name`, a plain string),
    # `admitted` is the FULL member list, each entry already `.inspect`-
    # quoted and joined with ", " (`admit_member`, admission.rb: `admitted.
    # map(&:inspect).join(", ")`) — resolved once here at codegen time,
    # since every member is already known statically, the same reasoning
    # `admitted_set_members` (constraints.rb) already applies to the OTHER
    # closed-set door.
    def emit_closed_set_codec(vo)
      name = rust_ident(vo[:name])
      field_name = rust_field(vo[:attributes].first[:name])
      rows = vo[:members].map { |row| [closed_set_variant(row), row.first.last.to_s] }

      # Both arm shapes need `TmplMemberA`/`tmpl_member_a` per row, so one
      # subs hash serves both `render_each` calls below.
      row_subs = rows.map { |variant, raw| { "TmplKind" => name, "TmplMemberA" => variant, '"tmpl_member_a"' => raw.inspect } }

      type_name = vo[:name].to_s
      admitted  = rows.map { |_variant, raw| raw.inspect }.join(", ")

      Exemplar.assemble(
        "closed_set_codec",
        {
          "TmplKind" => name,
          '"tmpl_field_name"' => field_name.inspect,
          "tmpl_field_name" => field_name,
          '"tmpl_closed_set_type"' => type_name.inspect,
          '"tmpl_closed_set_admitted"' => admitted.inspect,
        },
        slots: {
          "closed_set_codec:TO_JSON_ARM"   => Exemplar.render_each("closed_set_codec:TO_JSON_ARM", row_subs),
          "closed_set_codec:FROM_JSON_ARM" => Exemplar.render_each("closed_set_codec:FROM_JSON_ARM", row_subs),
        }
      )
    end

    # A multi-field closed set — a DATA TABLE (`emit_closed_set_table`'s
    # own shape), not a tag enum. Its `String` fields are `&'static str`,
    # not `String` — `emit_closed_set_table`'s own comment: "static data —
    # a borrowed literal, not an owned String," required so the `pub const`
    # array of struct literals can exist at all. That makes it a real,
    # separate case from an ordinary value object's `from_json`: nothing
    # can CONSTRUCT a fresh `&'static str` from a runtime-parsed JSON
    # string, so `from_json` here can only SELECT one of the table's own
    # fixed rows and clone it — the same match `literal_hash_bridgeable?`
    # (bridging.rb) performs for a command's literal `sets`/`append`
    # source, applied to the incoming JSON object instead of a literal Hash.
    def emit_closed_set_table_codec(vo)
      name = rust_ident(vo[:name])
      const_name = screaming_snake(vo[:name])

      to_json_fields = vo[:attributes].map do |attr|
        key = rust_field(attr[:name])
        ident = rust_ident_field(attr[:name])
        scalar = effective_scalar_type(attr[:type])
        value_expr =
          case scalar
          when "String"  then "crate::kernel::Json::Str(self.#{ident}.to_string())"
          when "Integer" then "crate::kernel::Json::int(self.#{ident})"
          when "Float"   then "crate::kernel::Json::Float(self.#{ident})"
          end
        Exemplar.render("to_json_field", '"tmpl_field_name"' => key.inspect, "tmpl_json_value_placeholder()" => value_expr)
      end
      to_json_fields_block = to_json_fields.map { |f| "        #{f}" }.join("\n")

      match_conditions = vo[:attributes].map do |attr|
        key = rust_field(attr[:name])
        ident = rust_ident_field(attr[:name])
        accessor = SCALAR_JSON_ACCESSOR.fetch(effective_scalar_type(attr[:type]))
        Exemplar.render(
          "closed_set_table_from_json_condition",
          '"tmpl_field_name"' => key.inspect,
          "tmpl_accessor_fn" => "crate::kernel::Json::#{accessor}",
          "tmpl_field" => ident
        )
      end

      Exemplar.render(
        "closed_set_table_codec",
        "TmplTableRow" => name,
        "tmpl_to_json_fields_block()" => to_json_fields_block,
        "TMPL_TABLE" => const_name,
        "tmpl_from_json_conditions()" => match_conditions.join(" && ")
      )
    end

    # An aggregate's identity, read straight off the incoming JSON step
    # args — the JSON-CLI counterpart to `identity_components`/
    # `build_identity_expr` (mutations.rb), which only ever runs for a
    # CREATING command's typed `args` struct today. An ACTING command's
    # generated `dispatch_*` takes `id: &str` as a caller-supplied parameter
    # (kernel/dispatch.rs's `Hydrate::Act`) — nothing generates how a caller
    # GETS that string. This is that: walk `identified_by`'s own dotted
    # paths directly against the raw JSON (the same paths, the same
    # join-with-":" for a composite identity — `SafeDepositBox`/`Statement`,
    # this corpus's two real composite-identity aggregates), shared by every
    # acting command's registry entry (registry.rb's `emit_registry`).
    #
    # Skipped (nil), loudly, by whoever calls this: an `identified_by`
    # component that resolves to neither a dotted path nor a bare declared
    # attribute — Ruby's `Naming::IDENTITY_JOIN` third shape, an addressing
    # key never present in `args` at all (Runtime::Identity.from's own
    # third branch, mutations.rb's `identity_components` comment) — has no
    # JSON source to read at all under this CLI's step shape (`{"verb",
    # "args"}`, no side-channel key). Not a real shape either example
    # domain's `identified_by` declares (checked against the live IR before
    # this was written), so it's a real, separate, still-open gap if a
    # future domain ever needs it — not silently worked around here.
    def extract_id_supported?(aggregate)
      aggregate[:identified_by].all? do |path|
        head, *rest = path.split(".")
        rest.any? || head
      end
    end

    # `CommandInterpreter#hydrate`'s own acting-command identity chain,
    # read directly:
    #
    #   id = identity_of(aggregate, args) ||
    #        identity_from(aggregate, args, :id) ||
    #        identity_from(aggregate, args, reference_key(command)) ||
    #        raise NotFound
    #
    # THREE tiers, tried in order, not one — `extract_id` used to be tier 1
    # alone, which is right for a caller who names the identity field
    # directly (`Account.Credit`'s own `number:`, matching `identified_by`'s
    # head) but wrong for a command whose own `reference_to` names a
    # DIFFERENT argument (`Transfer.Debited`'s `transfer:` — `Naming.
    # reference_key("Banking::Transfer") == "transfer"`, not `reference`,
    # the field `identified_by` actually names). A process manager's own
    # `with:` forwarding is what surfaces tier 3 for real: `Settlement`
    # dispatches `Transfer.Debited` with only `transfer:` set, never
    # `reference:`, exactly the shape tier 1 alone cannot resolve.
    def emit_extract_id(aggregate)
      name = rust_ident(aggregate[:name])
      reference_key = Hecks::Naming.snake(aggregate[:name])

      tier1_subs = aggregate[:identified_by].each_with_index.map { |path, i| { '"tmpl_path"' => path.inspect, "c0" => "c#{i}" } }
      tier1_join =
        if aggregate[:identified_by].size == 1
          "c0"
        else
          "vec![#{aggregate[:identified_by].size.times.map { |i| "c#{i}" }.join(', ')}].join(\":\")"
        end

      tried = (aggregate[:identified_by] + ["id", reference_key]).join(", ")

      Exemplar.compose(
        "extract_id",
        {
          "TmplExtractIdType" => name,
          '"tmpl_reference_key"' => reference_key.inspect,
          "tmpl_tier1_join_placeholder()" => tier1_join,
          '"tmpl_error_text"' => "#{name}: no identity found (tried #{tried})".inspect,
        },
        field_id: "extract_id:TIER1_LINE",
        field_subs_list: tier1_subs
      )
    end

    # `element_of`'s own `wants` (entity_interpreter.rb), for
    # `entity_element_missing`'s `{wants}` — the ONE genuinely runtime
    # piece `kernel::dispatch_entity`'s new refusal wording needs (see
    # `dispatch.rs`'s own header on that parameter). Deliberately a TIER1-
    # ONLY dig, unlike `emit_extract_id`'s three-tier chain: Ruby's own
    # `wants` never falls back to an `id`/reference-key tier at all — reread
    # `element_of`, it raises `entity_element_no_identity` the moment ANY
    # identity-path head is missing from `args`, so by the time `wants` is
    # actually computed every part is already known present. Joined with
    # `", "`, not `":"` — the one real difference from `extract_id`'s own
    # `tier1_join`, matching `wants.map { |_h, path, want| Identity.scalar
    # (path, want) }.join(", ")` exactly.
    def emit_extract_wants(entity)
      name = rust_ident(entity[:name])

      tier1_subs = entity[:identified_by].each_with_index.map { |path, i| { '"tmpl_path"' => path.inspect, "c0" => "c#{i}" } }
      wants_join =
        if entity[:identified_by].size == 1
          "c0"
        else
          "vec![#{entity[:identified_by].size.times.map { |i| "c#{i}" }.join(', ')}].join(\", \")"
        end

      Exemplar.compose(
        "extract_wants",
        {
          "TmplExtractWantsType" => name,
          "tmpl_wants_join_placeholder()" => wants_join,
        },
        field_id: "extract_wants:TIER1_LINE",
        field_subs_list: tier1_subs
      )
    end

    # An entity ELEMENT's own identity, read off an ALREADY-CONSTRUCTED
    # Rust value instead of raw JSON — `extract_id`'s counterpart for
    # `dispatch_entity`'s `matches` closure (kernel/dispatch.rs), which
    # compares each list element's OWN identity against the caller-supplied
    # target rather than walking JSON a second time. Same dotted-path,
    # same join-with-":", `self.` field access in place of `v.get(...)` —
    # deliberately the SAME string shape `extract_id` produces from JSON,
    # so `matches = |el| el.identity() == wanted_id` (wanted_id built by
    # `extract_id` against the entity's OWN identity fields in the raw
    # step args) is a plain string comparison, not a second parse.
    def emit_self_identity(entity)
      name = rust_ident(entity[:name])
      components = entity[:identified_by].map do |path|
        head, *rest = path.split(".")
        (["self.#{rust_ident_field(head)}"] + rest.map { |seg| ".#{rust_ident_field(seg)}" }).join + ".to_string()"
      end
      body = components.size == 1 ? components.first : "vec![#{components.join(', ')}].join(\":\")"

      Exemplar.render("self_identity", "TmplSelfIdentityType" => name, "tmpl_identity_body_placeholder()" => body)
    end
  end
end
