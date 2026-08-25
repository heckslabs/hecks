module RustProjection
  module Projector
    module_function

    # `use crate::generated::<mod_name>::<owner>::<Type>;` for every value
    # object THIS aggregate's own commands/entity-commands/port operations
    # reference by NAME but never declare locally — the ONLY place a
    # "foreign" value-object type can appear at all: an aggregate's own
    # attributes, a value object's own fields, and an entity's own
    # attributes are always LOCAL by construction (the DSL only lets a
    # construct reference a value object already visible where it's
    # declared), but a COMMAND argument can name ANY value object the
    # whole domain declares (`domain_generator.rb`'s own header on
    # `domain_value_object_owner`) — `SafeDepositBox.Rent`'s own
    # `attribute :customer, CustomerNumber` (`Customer`'s own VO) is the
    # corpus's one live example.
    #
    # A struct field's own type/a `TypeName::from_json(...)` call still
    # emits the SAME bare identifier `rust_type`/`rust_ident` always did
    # — this is what makes that identifier actually resolve for a foreign
    # type, the same way any other Rust file imports a sibling module's
    # own struct, rather than threading a qualified path through every
    # codegen call site that ever builds one.
    #
    # SAME-CHAPTER ONLY — `domain_value_object_owner` is built from THIS
    # domain's own `ir[:aggregates]` alone (`DomainGenerator.call` runs
    # once per chapter), so a value object declared in a DIFFERENT
    # attached chapter is a real, narrower gap this doesn't cover; no
    # command in the corpus needs it today (checked directly), so it's
    # left unresolved rather than guessed at, the same way `command_skip_
    # reason`'s own unresolved shapes already are.
    def cross_aggregate_vo_imports(aggregate, domain_value_object_owner, mod_name)
      local_names = aggregate[:value_objects].map { |vo| vo[:name] }.to_set
      attrs = (aggregate[:commands] + aggregate[:entities].flat_map { |e| e[:commands] } +
               aggregate[:ports].flat_map { |p| p[:operations] })
              .flat_map { |c| c[:attributes] }

      # A type name that's ALSO declared LOCALLY is never foreign, no
      # matter what `domain_value_object_owner` says — many aggregates
      # across this corpus independently declare their own same-named VO
      # ("Position", "IdentityPath", ...; not a shared concept, just a
      # common one), and `domain_value_object_owner` keeps only ONE
      # owner per name domain-wide. The local declaration always wins;
      # only a type THIS aggregate never declares at all can be foreign.
      foreign_types = attrs.map { |a| a[:type] }.uniq.reject { |type| local_names.include?(type) }
      foreign_types.filter_map { |type| domain_value_object_owner[type] && [type, domain_value_object_owner[type]] }
                   .sort_by { |(type, owner)| [owner, type] }
                   .map { |(type, owner)| "use crate::generated::#{mod_name}::#{owner.downcase}::#{rust_ident(type)};" }
    end

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
      return false unless source_vo && target_vo
      return closed_sets_bridgeable?(source_vo, target_vo) if source_vo[:closed_set] || target_vo[:closed_set]

      target_vo[:attributes].all? do |t_attr|
        source_vo[:attributes].any? { |s_attr| s_attr[:name] == t_attr[:name] } || !t_attr[:default].nil?
      end
    end

    # ONE CLOSED SET INTO ANOTHER — `sets :draw_offer, to: :side` (chess:
    # a `Color`, white/black, into a `DrawOffer`, none/white/black).
    # `Value.for_attribute` coerces through the sole scalar at runtime
    # and refuses a non-member; here it is admitted only when it can
    # NEVER refuse — both single-field, every source member also a
    # target member — so the generated bridge is an infallible `match`,
    # one arm per source member, usable inside a creating command's own
    # record-building closure where nothing may fail.
    def closed_set_bridge_members(source_vo, target_vo)
      return nil unless source_vo[:closed_set] && target_vo[:closed_set]
      return nil unless source_vo[:attributes].size == 1 && target_vo[:attributes].size == 1

      target_values = target_vo[:members].map { |row| row.to_h.values.first.to_s }
      source_rows   = source_vo[:members]
      return nil unless source_rows.all? { |row| target_values.include?(row.to_h.values.first.to_s) }

      source_rows
    end

    def closed_sets_bridgeable?(source_vo, target_vo)
      !closed_set_bridge_members(source_vo, target_vo).nil?
    end

    def vo_field_rhs(source_expr, source_vo, target_type, value_objects_by_name)
      target_vo = value_objects_by_name[target_type]
      if (rows = closed_set_bridge_members(source_vo, target_vo))
        arms = rows.map { |row| "#{rust_ident(source_vo[:name])}::#{closed_set_variant(row)} => #{rust_ident(target_type)}::#{closed_set_variant(row)}" }
        return "match &#{source_expr} { #{arms.join(', ')} }"
      end

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
      # target scalar unwraps cleanly into one. Compared via `effective_
      # scalar_type` on BOTH sides, same as the Reference-vs-bare-String
      # check above — not exact type-name equality: `CustomerNumber`'s
      # own field is a plain `String`, and `SafeDepositBox.Rent`'s own
      # `sets :customer` target is `Reference<Customer>` (also `String`
      # at the Rust representation level) — a real, live cross-aggregate
      # example (`CustomerNumber` is declared on `Customer`'s own
      # aggregate, resolved here only once `value_objects_by_name` widens
      # to the whole domain — `domain_generator.rb`'s own header), not a
      # hypothetical exact-name match this used to require and neither
      # side ever actually has.
      return false unless source_vo && !source_vo[:closed_set] && source_vo[:attributes].size == 1

      unwrapped_type = source_vo[:attributes].first[:type]
      unwrapped_type == target_type ||
        (effective_scalar_type(unwrapped_type) && effective_scalar_type(unwrapped_type) == effective_scalar_type(target_type))
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
      return literal_hash_bridgeable?(value, target_type, value_objects_by_name) if value.is_a?(Hash) && target_type
      return false if value.is_a?(Hash)
      return false unless value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
      return true unless target_type && value_objects_by_name[target_type]

      # A SCALAR literal into a SINGLE-FIELD value object — `Value.
      # for_attribute`'s own rewrap, the coercion every `sets :x, to:
      # "literal"` onto a closed set (a chess rook's `moved: "moved"`)
      # or a plain one-field VO relies on at runtime: the literal is the
      # sole field's value, and bridges exactly as the hash it stands for.
      sole = sole_field_of(target_type, value_objects_by_name)
      return false unless sole

      literal_hash_bridgeable?({ sole => value }, target_type, value_objects_by_name)
    end

    # The rendered right-hand side of ANY literal into a target type —
    # a Hash through `literal_hash_rhs`, a scalar into a single-field
    # value object through the same after the rewrap above, a scalar
    # into a scalar as itself.
    def literal_rhs_for(value, target_type, value_objects_by_name)
      return literal_hash_rhs(value, target_type, value_objects_by_name) if value.is_a?(Hash)

      sole = target_type && value_objects_by_name[target_type] && sole_field_of(target_type, value_objects_by_name)
      return literal_hash_rhs({ sole => value }, target_type, value_objects_by_name) if sole

      literal_rhs(value)
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
        vo[:attributes].all? { |attr| hash.key?(attr[:name].to_sym) || hash.key?(attr[:name].to_s) }
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
          key = [attr[:name].to_sym, attr[:name].to_s].find { |k| hash.key?(k) }
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
      target_attr = aggregate[:attributes].find { |a| a[:name].to_s == mutation[:target].to_s }
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

        key = [target_integer_field.to_sym, target_integer_field.to_s].find { |k| value.key?(k) }
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
      unless default.nil?
        return literal_rhs(default) unless default.is_a?(Hash)

        # BACKFILLED FROM THE TARGET VO'S OWN PER-FIELD DEFAULTS —
        # `attribute :refunded_amount, Money, default: { cents: 0 }`
        # names only `cents`; Money's own `currency` attribute carries
        # its own `default: "USD"`. Every OTHER caller of
        # literal_hash_rhs here (mutations.rb x3, bridging.rb's own
        # `literal_rhs` dispatch) checks literal_hash_bridgeable? first
        # and takes a different path when it's false; this was the one
        # caller that called literal_hash_rhs on the raw, possibly-
        # partial declared default UNCONDITIONALLY — found live,
        # generating lifeadelics' vendored payments.bluebook, the first
        # domain in the corpus to declare a Hash default that leans on
        # its own VO's per-field defaults rather than naming every
        # field explicitly. Ruby's own runtime (Coercion#build) already
        # backfills exactly this way at object-construction time; this
        # brings codegen's compile-time literal to the same completed
        # shape before handing it to literal_hash_rhs, rather than
        # inventing a second, parallel completion path.
        return literal_hash_rhs(complete_hash_default(default, attr[:type], value_objects_by_name), attr[:type], value_objects_by_name)
      end

      vo = value_objects_by_name[attr[:type]]
      return nil unless vo && !vo[:closed_set] && vo[:attributes].all? { |f| !f[:default].nil? }

      fields = vo[:attributes].map { |f| "#{rust_ident_field(f[:name])}: #{literal_rhs(f[:default])}" }
      "#{rust_ident(attr[:type])} { #{fields.join(', ')} }"
    end

    # A field the completed hash still lacks — the ORIGINAL hash didn't
    # name it AND the target VO's own attribute has no default either —
    # is left OUT of the returned hash entirely, not set to nil: adding
    # a `nil`-valued key would satisfy `literal_hash_bridgeable?`/
    # `literal_hash_rhs`'s own `hash.key?` check and silently emit
    # `literal_rhs(nil)` for a field that is genuinely, unrecoverably
    # missing — exactly the gap their own "should have caught this"
    # guard exists to catch, and must keep catching after this.
    def complete_hash_default(hash, target_type, value_objects_by_name)
      vo = value_objects_by_name[target_type]
      return hash unless vo && !vo[:closed_set]

      vo[:attributes].each_with_object({}) do |field, completed|
        key = [field[:name].to_sym, field[:name].to_s].find { |k| hash.key?(k) }
        if key
          completed[field[:name].to_sym] = hash[key]
        elsif !field[:default].nil?
          completed[field[:name].to_sym] = field[:default]
        end
      end
    end
  end
end
