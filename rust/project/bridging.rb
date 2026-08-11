module RustProjection
  module Projector
    module_function

    # Ruby's real cross-type coercion — `Value::Coercion#fields_for`, read
    # directly: a value object rebuilds into ANY differently-named target
    # value object that shares its field NAMES, matched by name, not
    # position, with the target's own `default:` filling anything the
    # source doesn't carry (`Value.build`'s own fallback). `PositiveMoney`
    # into a `Money` slot — `Credit`'s own `amount`, appended onto a
    # `LedgerEntry` — is the real, live example this corpus carries, not
    # a hypothetical: both declare `cents`/`currency`, so every target
    # field is answered by name.
    def vo_field_bridgeable?(source_vo, target_vo)
      return false unless source_vo && target_vo && !source_vo[:closed_set] && !target_vo[:closed_set]

      target_vo[:attributes].all? do |t_attr|
        source_vo[:attributes].any? { |s_attr| s_attr[:name] == t_attr[:name] } || !t_attr[:default].nil?
      end
    end

    def vo_field_rhs(source_expr, source_vo, target_type, value_objects_by_name)
      target_vo = value_objects_by_name[target_type]
      fields = target_vo[:attributes].map do |t_attr|
        field = rust_ident_field(t_attr[:name])
        if source_vo[:attributes].any? { |s_attr| s_attr[:name] == t_attr[:name] }
          "#{field}: #{source_expr}.#{field}.clone()"
        else
          "#{field}: #{literal_rhs(t_attr[:default])}"
        end
      end
      "#{rust_ident(target_type)} { #{fields.join(', ')} }"
    end

    # Why a command is skipped, or nil if it isn't. Named per-command, per-
    # reason, so coverage is visible at generation time rather than only
    # discoverable by noticing a dispatch function that should exist doesn't.
    # Shared with `value_rhs`, which actually performs whichever bridge
    # this says is possible — kept as one function so the "can we generate
    # this" check and the "here's how" generator can never silently
    # disagree about what counts as bridgeable. Used by BOTH `:set`'s own
    # RHS and `:append`'s per-field RHS — the two real places a command
    # copies one already-typed thing into a differently-typed slot.
    def bridgeable_value_types?(source_type, target_type, value_objects_by_name)
      return true if source_type == target_type
      # Both sides are represented by the identical Rust scalar even
      # though their DECLARED type names differ — `Reference<ValueObject>`
      # into a plain `String` field (the self-hosted grammar's own
      # `Aggregate.Attribute` append, `type:`) is the real, live case:
      # `effective_scalar_type` already maps a Reference to `"String"`,
      # the same representation a bare `String` attribute gets.
      return true if effective_scalar_type(source_type) && effective_scalar_type(source_type) == effective_scalar_type(target_type)

      source_vo = value_objects_by_name[source_type]
      target_vo = value_objects_by_name[target_type]
      return vo_field_bridgeable?(source_vo, target_vo) if target_vo

      # A bare scalar target (the lifecycle field, "String") — only a
      # single-field source VO whose one field's own type already IS the
      # target scalar unwraps cleanly into one.
      source_vo && !source_vo[:closed_set] && source_vo[:attributes].size == 1 && source_vo[:attributes].first[:type] == target_type
    end

    def value_rhs(source_expr, source_type, target_type, value_objects_by_name)
      return "#{source_expr}.clone()" if source_type == target_type
      return "#{source_expr}.clone()" if effective_scalar_type(source_type) && effective_scalar_type(source_type) == effective_scalar_type(target_type)

      source_vo = value_objects_by_name[source_type]
      target_vo = value_objects_by_name[target_type]
      return vo_field_rhs(source_expr, source_vo, target_type, value_objects_by_name) if target_vo

      raise "unsupported coercion #{source_type} -> #{target_type} — bridgeable_value_types? should have caught this" unless source_vo && !source_vo[:closed_set] && source_vo[:attributes].size == 1

      "#{source_expr}.#{rust_ident_field(source_vo[:attributes].first[:name])}.clone()"
    end

    def literal_set_bridgeable?(value, target_type, value_objects_by_name)
      return true if value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
      return false unless value.is_a?(Hash) && target_type

      literal_hash_bridgeable?(value, target_type, value_objects_by_name)
    end

    # A literal Hash's own bridgeability into a target type — either an
    # ordinary VO (every declared field present, by Symbol or String key)
    # or a CLOSED SET (the Hash matches one member row's own fields
    # exactly, the same match `admit_member` performs at runtime — an
    # append's literal `direction: { value: "debit" }` targets exactly
    # this shape, `LedgerDirection`). Shared by `:set`'s literal source and
    # `:append`'s literal fields — the same Hash-shaped literal, unmarked
    # from either `classified_source`'s raw value or `Marks.read` of an
    # `appended_fields` string, bridges the identical way once it's a Hash.
    def literal_hash_bridgeable?(hash, target_type, value_objects_by_name)
      vo = value_objects_by_name[target_type]
      return false unless vo

      if vo[:closed_set]
        vo[:members].any? { |member| member.all? { |field, value| [hash[field.to_sym], hash[field.to_s]].include?(value) } }
      else
        vo[:attributes].all? { |attr| hash.key?(attr[:name]) || hash.key?(attr[:name].to_s) }
      end
    end

    def literal_hash_rhs(hash, target_type, value_objects_by_name)
      vo = value_objects_by_name[target_type]
      raise "unsupported literal hash source #{hash.inspect} -> #{target_type} — literal_hash_bridgeable? should have caught this" unless vo

      if vo[:closed_set]
        row = vo[:members].find { |member| member.all? { |field, value| [hash[field.to_sym], hash[field.to_s]].include?(value) } }
        raise "literal #{hash.inspect} matches no member of #{target_type} — literal_hash_bridgeable? should have caught this" unless row

        "#{rust_ident(target_type)}::#{closed_set_variant(row)}"
      else
        fields = vo[:attributes].map do |attr|
          key = [attr[:name], attr[:name].to_s].find { |k| hash.key?(k) }
          raise "literal #{hash.inspect} missing field #{attr[:name]} for #{target_type} — literal_hash_bridgeable? should have caught this" unless key

          "#{rust_ident_field(attr[:name])}: #{literal_rhs(hash[key])}"
        end
        "#{rust_ident(target_type)} { #{fields.join(', ')} }"
      end
    end

    def integer_field_of(vo)
      return nil unless vo && !vo[:closed_set]

      attr = vo[:attributes].find { |a| a[:type] == "Integer" }
      attr && attr[:name]
    end

    # The target half of an `:increment`/`:decrement` mutation — the
    # attribute plus which of ITS OWN fields is the one Integer field the
    # arithmetic actually touches. `nil` when the target isn't a plain
    # (non-list) value-object attribute with exactly one such field.
    def arithmetic_target_field(mutation, aggregate, value_objects_by_name)
      target_attr = aggregate[:attributes].find { |a| a[:name] == mutation[:target] }
      return nil unless target_attr && !target_attr[:list]

      field = integer_field_of(value_objects_by_name[target_attr[:type]])
      field && [target_attr, field]
    end

    # The amount half — resolved to a raw Rust integer-typed EXPRESSION, not
    # a value object, since only the one shared field ever actually
    # participates in the arithmetic (arithmetic.rb's own
    # `arithmetic_value_object`, read directly: `current.with(field,
    # current[field] + sign*amount[field])` — every OTHER field of `current`
    # passes through untouched, which is exactly what emit_mutation_line's
    # `..current` struct-update syntax gives it). A bare `Integer`-typed
    # argument needs no field walk; a VO-typed argument needs its own
    # Integer field read off; a literal (`ScheduledPayment.Retry`'s `{value:
    # 1}` — not `.inspect`'d, see literal_set_bridgeable? above) reads that
    # same field out of the Hash directly. Returns nil, not raise, when
    # nothing bridges — command_skip_reason's half of this pairing.
    def arithmetic_amount_expr(source, command, value_objects_by_name, target_integer_field)
      if source[:kind] == "literal"
        value = source[:value]
        return literal_rhs(value) if value.is_a?(Integer)
        return nil unless value.is_a?(Hash)

        key = [target_integer_field, target_integer_field.to_s].find { |k| value.key?(k) }
        key && value[key].is_a?(Integer) ? literal_rhs(value[key]) : nil
      elsif source[:kind] == "argument"
        arg_attr = command[:attributes].find { |a| a[:name].to_s == source[:name] }
        return nil unless arg_attr
        return "args.#{rust_ident_field(arg_attr[:name])}" if arg_attr[:type] == "Integer"

        field = integer_field_of(value_objects_by_name[arg_attr[:type]])
        field && "args.#{rust_ident_field(arg_attr[:name])}.#{rust_ident_field(field)}"
      end
    end

    # An aggregate attribute a CREATING command's own arguments never
    # mention — `Runtime::Instance.defaults`/`.default_for`, read directly:
    # every declared attribute gets a value the moment a record is minted,
    # not just the ones the creating command happened to name. Two real
    # shapes: the attribute itself carries a `default:` (rare — checked
    # first, so it wins the way Ruby's own `default_for` orders its two
    # `return`s), or its VALUE OBJECT's every field carries one of its own
    # (`RetryCount { value: Integer, default: 0 }` — `ScheduledPayment`
    # never sets `attempts:` at all; `Value.build(value_object, {})` builds
    # it from nothing but those defaults). `nil` — not raise — for anything
    # else, the same as Ruby's own `default_for` returning a real `nil`
    # (no default anywhere): the record's field is genuinely unset, not a
    # gap this generator failed to bridge.
    def creation_default_rhs(attr, value_objects_by_name)
      default = attr[:default]
      return default.is_a?(Hash) ? literal_hash_rhs(default, attr[:type], value_objects_by_name) : literal_rhs(default) unless default.nil?

      vo = value_objects_by_name[attr[:type]]
      return nil unless vo && !vo[:closed_set] && vo[:attributes].all? { |f| !f[:default].nil? }

      fields = vo[:attributes].map { |f| "#{rust_ident_field(f[:name])}: #{literal_rhs(f[:default])}" }
      "#{rust_ident(attr[:type])} { #{fields.join(', ')} }"
    end
  end
end
