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

    def scalar_from_json_expr(struct_name, key, scalar_type)
      accessor = SCALAR_JSON_ACCESSOR.fetch(scalar_type)
      wrap = scalar_type == "String" ? ".map(|s| s.to_string())" : ""
      %(v.require(#{key.inspect}, #{struct_name.inspect})?.#{accessor}()#{wrap}.ok_or_else(|| #{json_type_error(struct_name, key, scalar_type)})?)
    end

    def scalar_to_json_expr(scalar_type, rust_expr)
      case scalar_type
      when "String"  then "crate::kernel::Json::Str(#{rust_expr}.clone())"
      when "Integer" then "crate::kernel::Json::int(#{rust_expr})"
      when "Float"   then "crate::kernel::Json::Num(#{rust_expr})"
      end
    end

    # One constructor per real attribute — value objects and Args structs
    # only (see header). A list attribute's element type must carry its own
    # `from_json` (every real element type here is a plain value object,
    # per this corpus — `CardPayment.Authorize`'s `tags: Vec<Tag>` is the
    # one live case; an entity-typed list attribute is not a shape any
    # command argument declares, per emit_entity's own header).
    def emit_from_json_flat(struct_name, attributes, value_objects_by_name)
      field_exprs = attributes.map do |attr|
        ident = rust_ident_field(attr[:name])
        key = rust_field(attr[:name])
        scalar = effective_scalar_type(attr[:type])
        rhs =
          if attr[:list]
            elem_type = rust_ident(attr[:type])
            "match v.get(#{key.inspect}).and_then(crate::kernel::Json::as_array) { " \
              "Some(items) => items.iter().map(#{elem_type}::from_json).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?, " \
              "None => Vec::new(), }"
          elsif scalar
            scalar_from_json_expr(struct_name, key, scalar)
          else
            nested_type = rust_ident(attr[:type])
            "#{nested_type}::from_json(v.require(#{key.inspect}, #{struct_name.inspect})?)?"
          end
        "        #{ident}: #{rhs},"
      end

      <<~RUST
        impl #{struct_name} {
            pub fn from_json(v: &crate::kernel::Json) -> Result<Self, crate::kernel::Refusal> {
                Ok(Self {
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
    def emit_to_json_flat(struct_name, attributes, value_objects_by_name, optional: false, extra_fields: [])
      field_exprs = attributes.map do |attr|
        ident = rust_ident_field(attr[:name])
        key = rust_field(attr[:name])
        scalar = effective_scalar_type(attr[:type])
        value_expr =
          if attr[:list]
            "crate::kernel::Json::Array(self.#{ident}.iter().map(|x| x.to_json()).collect())"
          elsif optional && scalar
            "self.#{ident}.as_ref().map(|v| #{scalar_to_json_expr(scalar, 'v')}).unwrap_or(crate::kernel::Json::Null)"
          elsif optional
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

    def emit_extract_id(aggregate)
      name = rust_ident(aggregate[:name])
      components = aggregate[:identified_by].map do |path|
        head, *rest = path.split(".")
        walk = (["v.get(#{head.inspect})"] + rest.map { |seg| ".and_then(|x| x.get(#{seg.inspect}))" }).join
        missing = "#{name}: missing identity component #{path}"
        "(#{walk}).ok_or_else(|| crate::kernel::Refusal::TypeMismatch(#{missing.inspect}.to_string()))?.to_id_component()?"
      end

      body = components.size == 1 ? components.first : "vec![#{components.join(', ')}].join(\":\")"

      <<~RUST
        impl #{name} {
            pub fn extract_id(v: &crate::kernel::Json) -> Result<String, crate::kernel::Refusal> {
                Ok(#{body})
            }
        }
      RUST
    end
  end
end
