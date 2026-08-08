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

    SCALAR_JSON_ACCESSOR = { "String" => "as_str", "Integer" => "as_i64", "Float" => "as_f64" }.freeze

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
      return %(match v.get(#{key.inspect}) { Some(x) => x.#{accessor}()#{wrap}.ok_or_else(|| #{json_type_error(struct_name, key, scalar_type)})?, None => #{literal_rhs(default)} }) if default

      %(v.require(#{key.inspect}, #{struct_name.inspect})?.#{accessor}()#{wrap}.ok_or_else(|| #{json_type_error(struct_name, key, scalar_type)})?)
    end

    # The scalar-extraction half of `scalar_from_json_expr`, applied to an
    # ALREADY-LOCATED Json value (`x`) instead of looking the key up itself
    # — `emit_from_json_flat`'s own `attr[:optional]` branch already has
    # `x` in hand from a `Some(x) = v.get(key)` match, so it needs just the
    # "read a scalar out of this value" part, not a second key lookup.
    def scalar_from_json_value_expr(struct_name, key, scalar_type, value_expr)
      accessor = SCALAR_JSON_ACCESSOR.fetch(scalar_type)
      wrap = scalar_type == "String" ? ".map(|s| s.to_string())" : ""
      %(#{value_expr}.#{accessor}()#{wrap}.ok_or_else(|| #{json_type_error(struct_name, key, scalar_type)})?)
    end

    def scalar_to_json_expr(scalar_type, rust_expr)
      case scalar_type
      when "String"  then "crate::kernel::Json::Str(#{rust_expr}.clone())"
      when "Integer" then "crate::kernel::Json::int(#{rust_expr})"
      when "Float"   then "crate::kernel::Json::Num(#{rust_expr})"
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
      reference_key = command[:references].to_s.empty? ? nil : Hecksagain::Naming.reference_key(command[:references]).to_s
      identity_heads = aggregate[:identified_by].map { |path| path.split(".").first }
      correlation_keys = Array(process_managers).filter_map { |pm| pm[:correlates_by]&.split(".")&.first }
      (["id", reference_key] + identity_heads + correlation_keys).compact.uniq
    end

    def emit_unknown_argument_check(struct_name, known_keys, declared_names)
      <<~RUST
                let unknown = v.unknown_keys(&[#{known_keys.map(&:inspect).join(', ')}]);
                if !unknown.is_empty() {
                    return Err(crate::kernel::Refusal::UnknownArgument(format!(
                        "#{struct_name} does not declare {} — it takes #{declared_names.join(', ')}",
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
    def emit_from_json_flat(struct_name, attributes, value_objects_by_name, unknown_argument_allowlist: nil)
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
            nested_type = rust_ident(attr[:type])
            "match v.get(#{key.inspect}) { Some(x) => Some(#{nested_type}::from_json(x)?), None => None, }"
          elsif scalar
            scalar_from_json_expr(struct_name, key, scalar, default: attr[:default])
          else
            nested_type = rust_ident(attr[:type])
            "#{nested_type}::from_json(v.require(#{key.inspect}, #{struct_name.inspect})?)?"
          end
        "        #{ident}: #{rhs},"
      end

      unknown_check =
        if unknown_argument_allowlist
          known_keys = (attributes.map { |a| rust_field(a[:name]) } + unknown_argument_allowlist).uniq
          emit_unknown_argument_check(struct_name, known_keys, attributes.map { |a| a[:name] })
        else
          ""
        end

      <<~RUST
        impl #{struct_name} {
            pub fn from_json(v: &crate::kernel::Json) -> Result<Self, crate::kernel::Refusal> {
        #{unknown_check}        Ok(Self {
        #{field_exprs.join("\n")}
                })
            }
        }
      RUST
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
    def emit_to_json_flat(struct_name, attributes, value_objects_by_name, optional: false, extra_fields: [], aggregate: nil)
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
        record_optional_list = attr[:list] && aggregate && list_attr_creation_optional?(aggregate, attr[:name])
        field_optional = optional || attr[:optional]
        value_expr =
          if attr[:list] && (attr[:optional] || record_optional_list)
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
        "        (#{key.inspect}.to_string(), #{value_expr}),"
      end
      field_exprs += extra_fields.map { |key, expr| "        (#{key.inspect}.to_string(), #{expr})," }

      <<~RUST
        impl #{struct_name} {
            pub fn to_json(&self) -> crate::kernel::Json {
                crate::kernel::Json::Object(vec![
        #{field_exprs.join("\n")}
                ])
            }
        }
      RUST
    end

    # A single-field CLOSED SET only — `emit_value_object`'s own branch on
    # `vo[:attributes].size > 1` (a data table, not a tag) generates neither
    # `Fielded` nor invariant checking today, and doesn't get a JSON codec
    # here either, for the same reason: nothing in either example domain
    # looks one up generically or passes one as a command argument.
    def emit_closed_set_codec(vo)
      name = rust_ident(vo[:name])
      field_name = rust_field(vo[:attributes].first[:name])
      rows = vo[:members].map { |row| [closed_set_variant(row), row.first.last.to_s] }

      to_json_arms = rows.map { |variant, raw| "            #{name}::#{variant} => #{raw.inspect}," }
      from_json_arms = rows.map { |variant, raw| "            #{raw.inspect} => Ok(#{name}::#{variant})," }

      <<~RUST
        impl #{name} {
            pub fn to_json(&self) -> crate::kernel::Json {
                let member = match self {
        #{to_json_arms.join("\n")}
                };
                crate::kernel::Json::obj(vec![(#{field_name.inspect}, crate::kernel::Json::str(member))])
            }

            pub fn from_json(v: &crate::kernel::Json) -> Result<Self, crate::kernel::Refusal> {
                let raw = v.require(#{field_name.inspect}, #{name.inspect})?.as_str()
                    .ok_or_else(|| #{json_type_error(name, field_name, 'string')})?;
                match raw {
        #{from_json_arms.join("\n")}
                    other => Err(crate::kernel::Refusal::TypeMismatch(format!("#{name}: unknown member {:?}", other))),
                }
            }
        }
      RUST
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
    # (bridging.rb) performs for a command's literal `then_set`/`append`
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
          when "Float"   then "crate::kernel::Json::Num(self.#{ident})"
          end
        "        (#{key.inspect}.to_string(), #{value_expr}),"
      end

      match_conditions = vo[:attributes].map do |attr|
        key = rust_field(attr[:name])
        ident = rust_ident_field(attr[:name])
        accessor = SCALAR_JSON_ACCESSOR.fetch(effective_scalar_type(attr[:type]))
        "v.get(#{key.inspect}).and_then(crate::kernel::Json::#{accessor}) == Some(row.#{ident})"
      end

      <<~RUST
        impl #{name} {
            pub fn to_json(&self) -> crate::kernel::Json {
                crate::kernel::Json::Object(vec![
        #{to_json_fields.join("\n")}
                ])
            }

            pub fn from_json(v: &crate::kernel::Json) -> Result<Self, crate::kernel::Refusal> {
                for row in #{const_name} {
                    if #{match_conditions.join(" && ")} {
                        return Ok(row.clone());
                    }
                }
                Err(crate::kernel::Refusal::TypeMismatch(format!("#{name}: no member matches {:?}", v)))
            }
        }
      RUST
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
      reference_key = Hecksagain::Naming.snake(aggregate[:name])

      tier1_lines = aggregate[:identified_by].each_with_index.map do |path, i|
        "            let c#{i} = v.dig(#{path.inspect})?.to_id_component().ok()?;"
      end
      tier1_join =
        if aggregate[:identified_by].size == 1
          "c0"
        else
          "vec![#{aggregate[:identified_by].size.times.map { |i| "c#{i}" }.join(', ')}].join(\":\")"
        end

      tried = (aggregate[:identified_by] + ["id", reference_key]).join(", ")

      <<~RUST
        impl #{name} {
            pub fn extract_id(v: &crate::kernel::Json) -> Result<String, crate::kernel::Refusal> {
                let by_identity = (|| -> Option<String> {
        #{tier1_lines.join("\n")}
                    Some(#{tier1_join})
                })();
                let by_id_key = v.get("id").and_then(|j| j.to_id_component().ok());
                let by_reference_key = v.get(#{reference_key.inspect}).and_then(|j| j.to_id_component().ok());

                by_identity.or(by_id_key).or(by_reference_key).ok_or_else(|| {
                    crate::kernel::Refusal::TypeMismatch(#{"#{name}: no identity found (tried #{tried})".inspect}.to_string())
                })
            }
        }
      RUST
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

      <<~RUST
        impl #{name} {
            pub fn identity(&self) -> String {
                #{body}
            }
        }
      RUST
    end
  end
end
