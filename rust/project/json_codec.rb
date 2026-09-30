module RustProjection
  module Projector
    module_function

    # Generates the WASM/CLI JSON boundary (to_json/from_json) alongside
    # each Fielded impl; entities and aggregate records only get to_json.

    def json_type_error(struct_name, key, expectation)
      "crate::kernel::Refusal::TypeMismatch(#{"#{struct_name}.#{key}: expected #{expectation}".inspect}.to_string())"
    end

    # The refusal for a scalar offered where a list argument goes; worded as Ruby's
    # `Value.refuse_scalar_list`, with the offered value known only at runtime.
    def list_shape_error(struct_name, key, element_type, value_var)
      template = "#{struct_name}.#{key} expects list_of(#{element_type}), got {}"
      "crate::kernel::Refusal::TypeMismatch(format!(#{template.inspect}, #{value_var}.inspect()))"
    end

    # A String mismatch also reports TypeMismatch when the value is an
    # Array/Hash/Null, matching Ruby's laxer scalar-shape check; other
    # scalar mismatches fall through to the generic wording.
    def scalar_type_error(struct_name, key, scalar_type, value_var)
      return json_type_error(struct_name, key, scalar_type) unless %w[Integer Float String].include?(scalar_type)

      template = "#{struct_name}.#{key} expects #{scalar_type}, got {}"
      proper = "crate::kernel::Refusal::TypeMismatch(format!(#{template.inspect}, #{value_var}.inspect()))"
      return proper if scalar_type != "String"

      generic = json_type_error(struct_name, key, scalar_type)
      "if matches!(#{value_var}, crate::kernel::Json::Array(_) | crate::kernel::Json::Object(_) | crate::kernel::Json::Null) " \
        "{ #{proper} } else { #{generic} }"
    end

    # A missing required field refuses with the same wording as an
    # explicit null value (Ruby's check_required_fields).
    def required_field_expr(struct_name, key, expected)
      message = "#{struct_name}.#{key} expects #{expected}, got nil"
      "v.get(#{key.inspect}).ok_or_else(|| crate::kernel::Refusal::TypeMismatch(#{message.inspect}.to_string()))?"
    end

    # Boolean fields read via as_bool, mirroring naming.rb's SCALAR table.
    SCALAR_JSON_ACCESSOR = { "String" => "as_str", "Integer" => "as_i64", "Float" => "as_f64",
                             "TrueClass" => "as_bool", "FalseClass" => "as_bool" }.freeze

    # A single-attribute value object also accepts a bare JSON scalar in
    # place of the wrapped {"field": ...} shape, matching Ruby's coercion.
    def sole_field_of(type_name, value_objects_by_name)
      vo = value_objects_by_name[type_name]
      return nil unless vo && vo[:attributes]&.size == 1

      vo[:attributes].first[:name].to_s
    end

    # Wraps a single-field value object's value with coerce_single_field
    # before calling its from_json, so the bare-scalar shorthand applies.
    def composite_from_json_expr(attr, value_objects_by_name, value_expr)
      nested_type = rust_ident(attr[:type])
      sole = sole_field_of(attr[:type], value_objects_by_name)
      source =
        if sole
          "&#{value_expr}.coerce_single_field(#{sole.inspect})"
        else
          "#{value_expr}.expect_value_object_shape(#{attr[:name].to_s.inspect}, #{attr[:type].to_s.inspect})?"
        end
      "#{nested_type}::from_json(#{source})?"
    end

    # A scalar-represented list element (e.g. list_of(String), or a
    # has_many reference) reads like any other scalar field rather than
    # calling a from_json that was never generated for it.
    def list_element_from_json_mapper(struct_name, key, attr, value_objects_by_name)
      scalar = effective_scalar_type(attr[:type])
      if scalar
        body = scalar_from_json_value_expr(struct_name, key, scalar, "item")
        return "|item| #{body.sub(/\?\z/, '')}"
      end

      nested_type = rust_ident(attr[:type])
      sole = sole_field_of(attr[:type], value_objects_by_name)
      return "|item| #{nested_type}::from_json(&item.coerce_single_field(#{sole.inspect}))" if sole

      "#{nested_type}::from_json"
    end

    # The inverse of list_element_from_json_mapper: a scalar-represented
    # element serializes like any other scalar field.
    def list_element_to_json_expr(attr)
      scalar = effective_scalar_type(attr[:type])
      scalar ? scalar_to_json_expr(scalar, "x") : "x.to_json()"
    end

    # A required value-object argument given a bare JSON null builds from
    # an empty object rather than one literal null field, matching Ruby's
    # leniency for a command-argument door (not a nested field's own null).
    def required_composite_argument_expr(struct_name, key, attr, value_objects_by_name)
      fetch = required_field_expr(struct_name, key, attr[:type])
      nested_type = rust_ident(attr[:type])
      sole = sole_field_of(attr[:type], value_objects_by_name)
      guarded = "match #{fetch} { crate::kernel::Json::Null => crate::kernel::Json::Object(Vec::new()), other => other.clone() }"
      return "#{nested_type}::from_json(&(#{guarded}).coerce_single_field(#{sole.inspect}))?" if sole

      "#{nested_type}::from_json((#{guarded}).expect_value_object_shape(#{attr[:name].to_s.inspect}, " \
        "#{attr[:type].to_s.inspect})?)?"
    end

    # A scalar field missing from the caller's JSON falls back to the
    # attribute's own default:, matching Value.build's rule.
    def scalar_from_json_expr(struct_name, key, scalar_type, default: nil)
      accessor = SCALAR_JSON_ACCESSOR.fetch(scalar_type)
      wrap = scalar_type == "String" ? ".map(|s| s.to_string())" : ""
      # Matches on presence first so a present-but-wrong-shape value still
      # refuses instead of silently falling back to the default.
      #
      # default.nil?, not `if default` — a boolean attribute's own default
      # can legitimately be false, which plain Ruby truthiness would treat
      # as "no default."
      unless default.nil?
        return %(match v.get(#{key.inspect}) { Some(x) => x.#{accessor}()#{wrap}.ok_or_else(|| #{scalar_type_error(struct_name,
                                                                                                                   key, scalar_type, 'x')})?, None => #{literal_rhs(default)} })
      end

      %({ let x = #{required_field_expr(struct_name, key,
                                        scalar_type)}; x.#{accessor}()#{wrap}.ok_or_else(|| #{scalar_type_error(struct_name, key,
                                                                                                                scalar_type, 'x')})? })
    end

    # scalar_from_json_expr's scalar-extraction half, applied to a value
    # already looked up (avoids a second key lookup).
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
      when "TrueClass", "FalseClass" then "crate::kernel::Json::Bool(#{rust_expr})"
      end
    end

    # The allowlist of names a caller may address a command by: declared
    # attributes plus id, the aggregate's identity heads, any reference
    # key, and correlation keys a saga may smuggle through.
    #
    # extra_identity_heads: an entity dispatch also addresses the entity's
    # own identity head, read directly out of args rather than declared.
    def command_argument_allowlist(aggregate, command, process_managers, extra_identity_heads: [])
      reference_key = command[:references].to_s.empty? ? nil : Hecks::Naming.reference_key(command[:references]).to_s
      identity_heads = aggregate[:identified_by].map { |path| path.split(".").first }
      correlation_keys = Array(process_managers).filter_map { |pm| pm[:correlates_by]&.split(".")&.first }
      (["id", reference_key] + identity_heads + extra_identity_heads + correlation_keys).compact.uniq
    end

    # Emits the AbsentArgument check: every required, undeclared-missing
    # name the caller's JSON omits, sorted, refused before any field is
    # built (ADR 0037 finding 3). Only ever emitted for a command's own
    # args struct — a value object's missing field is required_field_expr's
    # job.
    def emit_absent_argument_check(command_name, attributes)
      required = attributes.reject { |a| a[:optional] }.map { |a| rust_field(a[:name]) }.sort
      return "" if required.empty?

      declared = attributes.map { |a| a[:name].to_s }
      <<~RUST
        let absent: Vec<&str> = [#{required.map(&:inspect).join(', ')}].into_iter().filter(|key| v.get(key).is_none()).collect();
        if !absent.is_empty() {
            return Err(crate::kernel::Refusal::AbsentArgument(crate::kernel::refusal_wording::AbsentArgumentAbsentArgsArgs {
                command: #{command_name.inspect},
                absent: &absent,
                declared: &[#{declared.map(&:inspect).join(', ')}],
            }.render_args()));
        }
      RUST
    end

    # Emits the UnknownArgument check: any key outside known_keys refuses
    # before any field is built, using the shared refusal-wording template.
    def emit_unknown_argument_check(command_name, known_keys, declared_names)
      declared = declared_names.map(&:to_s)
      <<~RUST
        let unknown = v.unknown_keys(&[#{known_keys.map(&:inspect).join(', ')}]);
        if !unknown.is_empty() {
            let unknown: Vec<&str> = unknown.iter().map(|key| key.as_str()).collect();
            return Err(crate::kernel::Refusal::UnknownArgument(crate::kernel::refusal_wording::UnknownArgumentUnknownArgsArgs {
                command: #{command_name.inspect},
                unknown: &unknown,
                declared: &[#{declared.map(&:inspect).join(', ')}],
            }.render_args()));
        }
      RUST
    end

    # Builds one field's RHS. interleave_checks: true (every command/
    # entity-command Args struct) builds each field's shape then runs its
    # own invariant check immediately, before the next field starts, so an
    # earlier argument's invariant failure wins over a later argument's
    # shape failure — matching Ruby's per-argument dispatch order exactly.
    def flat_field_rhs(struct_name, attr, key, value_objects_by_name, absent_argument_check)
      scalar = effective_scalar_type(attr[:type])
      if attr[:list] && attr[:optional]
        # Option<Vec<T>> — absent key means None, unlike a required list
        # argument, which defaults to an empty Vec below.
        mapper = list_element_from_json_mapper(struct_name, key, attr, value_objects_by_name)
        array_error = json_type_error(struct_name, key, "an array")
        "match v.get(#{key.inspect}) { " \
        "Some(x) => Some(x.as_array().ok_or_else(|| #{array_error})?.iter().map(#{mapper}).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?), " \
        "None => None, }".sub("match v.get(#{key.inspect}) { ", "match v.get(#{key.inspect}) { Some(crate::kernel::Json::Null) | None => None, ").sub(", None => None, }", " }")
      elsif attr[:list]
        # A list argument is an array: a lone scalar is refused, as Ruby's
        # `Value.refuse_scalar_list` does; null and an absent key are the empty list.
        mapper = list_element_from_json_mapper(struct_name, key, attr, value_objects_by_name)
        shape_error = list_shape_error(struct_name, key, attr[:type], "x")
        "match v.get(#{key.inspect}) { Some(crate::kernel::Json::Null) | None => Vec::new(), " \
          "Some(x) => x.as_array().ok_or_else(|| #{shape_error})?.iter().map(#{mapper}).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?, }"
      elsif attr[:optional] && scalar
        # A null value is the same absence as an omitted key for an
        # optional argument (Ruby's nil passthrough).
        "match v.get(#{key.inspect}) { Some(crate::kernel::Json::Null) | None => None, Some(x) => Some(#{scalar_from_json_value_expr(
          struct_name, key, scalar, 'x'
        )}) }"
      elsif attr[:optional]
        "match v.get(#{key.inspect}) { Some(crate::kernel::Json::Null) | None => None, Some(x) => Some(#{composite_from_json_expr(
          attr, value_objects_by_name, 'x'
        )}) }"
      elsif scalar
        scalar_from_json_expr(struct_name, key, scalar, default: attr[:default])
      elsif absent_argument_check
        required_composite_argument_expr(struct_name, key, attr, value_objects_by_name)
      else
        composite_from_json_expr(attr, value_objects_by_name, required_field_expr(struct_name, key, attr[:type]))
      end
    end

    # Builds the unknown-then-absent argument checks shared by
    # emit_argument_gates' two gate functions, matching dispatch order.
    def unknown_and_absent_argument_checks(command_name, attributes, unknown_argument_allowlist, absent_argument_check)
      check =
        if unknown_argument_allowlist
          known_keys = (attributes.map { |a| rust_field(a[:name]) } + unknown_argument_allowlist).uniq
          emit_unknown_argument_check(command_name, known_keys, attributes.map { |a| a[:name] })
        else
          ""
        end
      check += emit_absent_argument_check(command_name, attributes) if absent_argument_check
      check
    end

    # Emits one gate function per declared dispatch step, called in order
    # by kernel::ArgumentGates; reordering the steps in vocabulary.bluebook
    # changes which refusal wins with no generator change.
    def emit_argument_gates(struct_name, command_name, attributes, unknown_argument_allowlist)
      unknown = if unknown_argument_allowlist
                  unknown_and_absent_argument_checks(command_name, attributes,
                                                     unknown_argument_allowlist, false)
                else
                  ""
                end
      absent = emit_absent_argument_check(command_name, attributes)

      [
        "impl #{struct_name} {",
        argument_gate_fn("decode_arguments", emit_object_shape_check(struct_name)),
        "",
        argument_gate_fn("refuse_unknown_arguments", unknown),
        "",
        argument_gate_fn("refuse_absent_arguments", absent),
        "}\n"
      ].join("\n")
    end

    # An empty body still gets its own function (the kernel calls every
    # declared step for every command); its parameter is named _v so an
    # empty body never warns.
    def argument_gate_fn(name, body)
      parameter = body.empty? ? "_v" : "v"
      "    pub fn #{name}(#{parameter}: &crate::kernel::Json) -> Result<(), crate::kernel::Refusal> {\n#{body}        Ok(())\n    }"
    end

    def emit_from_json_flat(struct_name, attributes, value_objects_by_name, unknown_argument_allowlist: nil, command_name: struct_name,
                            absent_argument_check: false, interleave_checks: false, aggregates_by_name: nil)
      idents = attributes.map { |attr| rust_ident_field(attr[:name]) }
      field_exprs = attributes.zip(idents).map do |attr, ident|
        key = rust_field(attr[:name])
        rhs = flat_field_rhs(struct_name, attr, key, value_objects_by_name, absent_argument_check)

        if interleave_checks
          checks = argument_check_lines(attr, ident, aggregates_by_name, value_objects_by_name)
          (["        let #{ident} = #{rhs};"] + checks).join("\n")
        else
          Exemplar.render("field_assignment", "tmpl_ident" => ident, "tmpl_rhs_placeholder()" => rhs)
        end
      end

      unknown_check = unknown_and_absent_argument_checks(command_name, attributes, unknown_argument_allowlist,
                                                         absent_argument_check)

      emit_from_json_skeleton(struct_name, field_exprs, unknown_check, shorthand_fields: interleave_checks ? idents : nil)
    end

    # Checked before any field is read: a composite value offered as
    # anything but an object (or the single-field auto-wrap) would
    # otherwise default every field silently when each declares a
    # default:, instead of refusing.
    def emit_object_shape_check(struct_name)
      message = "#{struct_name} expects an object"
      <<~RUST
        if !matches!(v, crate::kernel::Json::Object(_)) {
            return Err(crate::kernel::Refusal::TypeMismatch(format!("#{message}, got {}", v.inspect())));
        }
      RUST
    end

    # shorthand_fields: nil keeps field_exprs as complete `ident: rhs,`
    # struct-literal lines. An Array (interleaved callers) instead folds
    # already-terminated let+check blocks into the preamble, closing the
    # struct literal over plain field-init shorthand.
    def emit_from_json_skeleton(struct_name, field_exprs, unknown_check, shorthand_fields: nil)
      preamble = emit_object_shape_check(struct_name) + unknown_check
      field_block =
        if shorthand_fields
          preamble += field_exprs.map { |f| "#{f}\n" }.join
          shorthand_fields.map { |f| "        #{f}," }.join("\n")
        else
          field_exprs.map { |f| "        #{f}" }.join("\n")
        end
      # Trailing "\n" — see emit_to_json_flat's own comment on why.
      "#{Exemplar.render(
        'from_json_flat',
        'TmplFlatType2'                                                => struct_name,
        "let _tmpl_unknown_check_placeholder = ();\n        Ok(Self {" => "#{preamble}        Ok(Self {",
        'tmpl_ident: tmpl_rhs_placeholder(),'                          => field_block
      )}\n"
    end

    # optional: true Option-wraps every non-list field (aggregate records);
    # extra_fields appends verbatim pairs (used for the lifecycle field,
    # which is never Option-wrapped). sparse: true drops a
    # (key, Json::Null) pair entirely, matching Ruby's payload: args for
    # command-args serialization; sparse: false keeps every key, correct
    # for a persisted record.
    def emit_to_json_flat(struct_name, attributes, value_objects_by_name, optional: false, extra_fields: [], aggregate: nil,
                          sparse: false)
      field_exprs = attributes.map do |attr|
        ident = rust_ident_field(attr[:name])
        key = rust_field(attr[:name])
        scalar = effective_scalar_type(attr[:type])
        # attr[:optional] is data-driven off the declaration, not a
        # runtime emptiness check — an empty-but-required field (e.g. an
        # unmatched ledger) must stay required.
        #
        # aggregate is passed only for a record's own to_json; the
        # aggregate attribute's own optional: flag can differ from the
        # command argument's, so list_attr_creation_optional? is the
        # record-level equivalent check.
        record_optional_list = attr[:list] && aggregate && list_attr_creation_optional?(aggregate, attr[:name],
                                                                                        value_objects_by_name)
        field_optional = optional || attr[:optional]
        # A record's own list field is Option-wrapped only per
        # list_attr_creation_optional? — using attr[:optional] directly
        # here would call as_ref on a plain Vec<T> field that was never
        # Option-wrapped.
        list_is_optional = aggregate ? record_optional_list : attr[:optional]
        elem_to_json = list_element_to_json_expr(attr) if attr[:list]
        value_expr =
          if attr[:list] && list_is_optional
            "self.#{ident}.as_ref().map(|v| crate::kernel::Json::Array(v.iter().map(|x| #{elem_to_json}).collect())).unwrap_or(crate::kernel::Json::Null)"
          elsif attr[:list]
            "crate::kernel::Json::Array(self.#{ident}.iter().map(|x| #{elem_to_json}).collect())"
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
      field_exprs += extra_fields.map do |key, expr|
        Exemplar.render("to_json_field", '"tmpl_field_name"' => key.inspect, "tmpl_json_value_placeholder()" => expr)
      end
      field_block = field_exprs.map { |f| "        #{f}" }.join("\n")

      # Trailing "\n" is required because commands.rb's entity-command
      # heredoc interpolates this return value directly.
      rendered = if sparse
                   Exemplar.render("to_json_flat_sparse", "TmplFlatType3"                     => struct_name,
                                                          "tmpl_to_json_field_block_sparse()" => field_block)
                 else
                   Exemplar.render("to_json_flat", "TmplFlatType2"              => struct_name,
                                                   "tmpl_to_json_field_block()" => field_block)
                 end
      "#{rendered}\n"
    end

    # The inverse of emit_to_json_flat's record/entity to_json, not a
    # third case of emit_from_json_flat: here an unset Option field's key
    # is always present with value Json::Null (matching Ruby's JSON
    # round-trip), so Some(&Json::Null) reads as absence everywhere
    # emit_from_json_flat only ever checks for a missing key. Used by
    # Store::from_seed (rust/host) to seed prior state directly instead
    # of replaying command history.
    def emit_from_json_state(struct_name, attributes, value_objects_by_name, optional: false, extra_fields: [], aggregate: nil)
      field_exprs = attributes.map do |attr|
        ident = rust_ident_field(attr[:name])
        key = rust_field(attr[:name])
        scalar = effective_scalar_type(attr[:type])
        record_optional_list = attr[:list] && aggregate && list_attr_creation_optional?(aggregate, attr[:name],
                                                                                        value_objects_by_name)
        list_is_optional = aggregate ? record_optional_list : attr[:optional]
        field_optional = optional || attr[:optional]

        rhs =
          if attr[:list] && list_is_optional
            mapper = list_element_from_json_mapper(struct_name, key, attr, value_objects_by_name)
            array_error = json_type_error(struct_name, key, "an array")
            "match v.get(#{key.inspect}) { " \
              "Some(&crate::kernel::Json::Null) | None => None, " \
              "Some(x) => Some(x.as_array().ok_or_else(|| #{array_error})?.iter().map(#{mapper}).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?), }"
          elsif attr[:list]
            mapper = list_element_from_json_mapper(struct_name, key, attr, value_objects_by_name)
            "match v.get(#{key.inspect}).and_then(crate::kernel::Json::as_array) { " \
              "Some(items) => items.iter().map(#{mapper}).collect::<Result<Vec<_>, crate::kernel::Refusal>>()?, " \
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

      # extra_fields carries (key, serialize_expr[, deserialize_rhs])
      # tuples; deserialize_rhs is required for anything that isn't the
      # lifecycle field's always-String shape (e.g. a bool flag). Omitted,
      # the String reader below still applies.
      extra_field_exprs = extra_fields.map do |key, _serialize_expr, deserialize_rhs|
        ident = rust_ident_field(key)
        rhs = deserialize_rhs || "v.require(#{key.inspect}, #{struct_name.inspect})?.as_str()" \
                                 ".ok_or_else(|| #{json_type_error(struct_name, key, 'a string')})?.to_string()"
        Exemplar.render("field_assignment", "tmpl_ident" => ident, "tmpl_rhs_placeholder()" => rhs)
      end

      emit_from_json_skeleton(struct_name, field_exprs + extra_field_exprs, "")
    end

    # A single-field closed set only; emit_value_object's multi-attribute
    # branch generates neither Fielded nor invariant checking, so it gets
    # no JSON codec either. The admitted-member wording is resolved here
    # at codegen time since every member is already known statically.
    def emit_closed_set_codec(vo)
      name = rust_ident(vo[:name])
      sole_attribute = vo[:attributes].first
      field_name = rust_field(sole_attribute[:name])
      rows = vo[:members].map { |row| [closed_set_variant(row), row.first.last.to_s] }

      # Both arm shapes need `TmplMemberA`/`tmpl_member_a` per row, so one
      # subs hash serves both `render_each` calls below.
      row_subs = rows.map { |variant, raw| { "TmplKind" => name, "TmplMemberA" => variant, '"tmpl_member_a"' => raw.inspect } }

      type_name = vo[:name].to_s
      # The member list goes over raw; the wording itself is
      # InvariantViolationClosedSetMemberArgs::render_args's own
      # RefusalSiteArgument row.
      admitted  = "[#{rows.map { |_variant, raw| raw.inspect }.join(', ')}]"
      # Uses the same missing-key wording required_field_expr gives every
      # other composite field, resolved here since the sole field's name
      # and type are already known statically.
      null_message = "#{type_name}.#{sole_attribute[:name]} expects #{sole_attribute[:type]}, got nil"

      Exemplar.assemble(
        "closed_set_codec",
        {
          "TmplKind"                     => name,
          '"tmpl_field_name"'            => field_name.inspect,
          '"tmpl_closed_set_type"'       => type_name.inspect,
          '["tmpl_closed_set_member_a"]' => admitted,
          '"tmpl_null_field_message"'    => null_message.inspect
        },
        slots: {
          "closed_set_codec:TO_JSON_ARM"   => Exemplar.render_each("closed_set_codec:TO_JSON_ARM", row_subs),
          "closed_set_codec:FROM_JSON_ARM" => Exemplar.render_each("closed_set_codec:FROM_JSON_ARM", row_subs)
        }
      )
    end

    # A multi-field closed set is a data table, not a tag enum, with
    # &'static str fields — from_json can only select and clone one of
    # the table's fixed rows, since nothing can construct a fresh
    # &'static str from parsed JSON.
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
          when "TrueClass", "FalseClass" then "crate::kernel::Json::Bool(self.#{ident})"
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
          "tmpl_accessor_fn"  => "crate::kernel::Json::#{accessor}",
          "tmpl_field"        => ident
        )
      end

      Exemplar.render(
        "closed_set_table_codec",
        "TmplTableRow"                => name,
        "tmpl_to_json_fields_block()" => to_json_fields_block,
        "TMPL_TABLE"                  => const_name,
        "tmpl_from_json_conditions()" => match_conditions.join(" && ")
      )
    end

    # Whether every identified_by component resolves to a dotted path or
    # a bare declared attribute; a third addressing-key shape has no JSON
    # source under this CLI's step shape and is skipped by the caller.
    def extract_id_supported?(aggregate)
      aggregate[:identified_by].all? do |path|
        head, *rest = path.split(".")
        rest.any? || head
      end
    end

    # Mirrors CommandInterpreter#hydrate's three-tier identity chain:
    # identity_of, then identity_from(:id), then identity_from(reference
    # key) — needed because a process manager's with: forwarding can
    # supply only the reference argument, not the identity field itself.
    def emit_extract_id(aggregate)
      emit_extract_id_shaped(aggregate, method_name: "extract_id", coercion: "to_id_component")
    end

    # The same extract_id shape using to_id_component_lenient instead of
    # the strict coercion; wired only into entity/nested-entity addressing,
    # never a root aggregate's own hydrate.
    def emit_extract_id_lenient(entity)
      emit_extract_id_shaped(entity, method_name: "extract_id_lenient", coercion: "to_id_component_lenient")
    end

    def emit_extract_id_shaped(aggregate, method_name:, coercion:)
      name = rust_ident(aggregate[:name])
      reference_key = Hecks::Naming.snake(aggregate[:name])

      # tmpl_id_coercion also goes into each tier1_subs entry, since the
      # nested TIER1_LINE slot renders independently of the outer subs.
      tier1_subs = aggregate[:identified_by].each_with_index.map do |path, i|
        { '"tmpl_path"' => path.inspect, "c0" => "c#{i}", "tmpl_id_coercion" => coercion }
      end
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
          "TmplExtractIdType"             => name,
          "tmpl_extract_id_name"          => method_name,
          "tmpl_id_coercion"              => coercion,
          '"tmpl_reference_key"'          => reference_key.inspect,
          "tmpl_tier1_join_placeholder()" => tier1_join,
          '"tmpl_error_text"'             => "#{name}: no identity found (tried #{tried})".inspect
        },
        field_id:        "extract_id:TIER1_LINE",
        field_subs_list: tier1_subs
      )
    end

    # Ruby's own `wants` (element_of) is tier-1-only, unlike extract_id's
    # three-tier chain, since every identity-path head is already known
    # present by the time wants is computed. Joined with ", ", not ":".
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
          "TmplExtractWantsType"          => name,
          "tmpl_wants_join_placeholder()" => wants_join
        },
        field_id:        "extract_wants:TIER1_LINE",
        field_subs_list: tier1_subs
      )
    end

    # An entity element's own identity read off an already-constructed
    # Rust value rather than raw JSON, using the same dotted-path,
    # join-with-":" shape extract_id produces, so dispatch_entity's
    # matches closure can compare as plain strings.
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
