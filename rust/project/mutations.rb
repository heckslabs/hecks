module RustProjection
  module Projector
    module_function

    # A list-typed aggregate attribute reads `nil` in Ruby, not `[]`,
    # under one precise condition (0019's/0014's own investigation, read
    # directly against `mutation_applier.rb`/`value/coercion.rb`, not
    # guessed): some CREATING command declares an explicit `:set`-op
    # mutation (`then_set attr, to: source`) targeting it, sourced from a
    # command argument the CALLER omitted. Every declared mutation runs
    # UNCONDITIONALLY during `apply_mutations` — `resolve_source`/`Value.
    # for_attribute` pass a missing argument through as a real `nil`,
    # overwriting `Instance.defaults`' own `[]` baseline every list
    # attribute otherwise starts with. `CardPayment.tags` (`then_set
    # :tags, to: :tags`, sourced from its own `optional: true` argument)
    # is the corpus's one live example; `Account.ledger` (touched only by
    # `Credit`/`Debit`'s own `append`, never a creating command's `:set`)
    # is the negative case that must stay `[]` — the exact regression the
    # 0014 doc's own reverted empty-list-to-null heuristic caused by not
    # distinguishing them.
    def list_attr_creation_optional?(aggregate, attr_name)
      aggregate[:commands].any? do |command|
        next false unless command[:references].nil? # creating

        command[:mutations].any? do |m|
          next false unless m[:op] == :set && m[:target] == attr_name && m[:source][:kind] == "argument"

          source_attr = command[:attributes].find { |a| a[:name].to_s == m[:source][:name].to_s }
          source_attr && source_attr[:optional]
        end
      end
    end

    # `append`'s TARGET, resolved to whichever real thing it is — a plain
    # value object (`Order.toppings`, a `Vec<Topping>`) or an ENTITY
    # (`Account.ledger`, a `Vec<LedgerEntry>`) — so field-type lookups can
    # read `[:attributes]` the same way regardless of which. `nil` when
    # the attribute names neither (a codegen bug if reached; every real
    # append target already passed `unsupported_attribute_types` above).
    def append_element(aggregate, target_type, value_objects_by_name)
      return value_objects_by_name[target_type] if value_objects_by_name.key?(target_type)

      aggregate[:entities].find { |e| e[:name] == target_type }
    end

    # An entity element's identity, auto-minted at append time exactly the
    # way `MutationApplier#entity_element` does it: sequential position
    # (`Array(current).size + 1`) wrapped into whichever single-field
    # value object the identity's own dotted path names —
    # `LedgerEntry.identified_by { sequence.value }`, the one real shape
    # this corpus needs. Returns `[attribute, its_value_object]`, or `nil`
    # when the shape doesn't match (a composite entity identity, or one
    # that isn't a bare-declared attribute) — command_skip_reason's half
    # of this pairing, same as every other bridgeable?/rhs pair here.
    def entity_identity_mint(entity, value_objects_by_name)
      id_path = entity[:identified_by]&.first
      return nil unless id_path

      head, *rest = id_path.split(".")
      return nil unless rest.size == 1

      attr = entity[:attributes].find { |a| a[:name].to_s == head }
      return nil unless attr

      vo = value_objects_by_name[attr[:type]]
      return nil unless vo && !vo[:closed_set] && vo[:attributes].size == 1 && vo[:attributes].first[:name].to_s == rest.first

      [attr, vo]
    end

    # Every `append` mutation's own field(s), checked against the element
    # they're building — the same "can we generate this" role
    # bridgeable_value_types?/literal_hash_bridgeable? already play for
    # `:set`, applied per-field instead of once. Two real problems this
    # catches that a blanket `.inspect`-string skip used to hide: a field
    # sourced from an argument whose type doesn't bridge to the field's
    # own declared type (`Credit`'s `PositiveMoney` `amount` into
    # `LedgerEntry`'s `Money` `amount` — DOES bridge, by field name; a
    # genuine mismatch would not), and — for an ENTITY target only — an
    # identity that can't be auto-minted and isn't supplied explicitly.
    def append_field_problems(command, aggregate, value_objects_by_name)
      command[:mutations].select { |m| m[:op] == :append }.flat_map do |m|
        target_attr = aggregate[:attributes].find { |a| a[:name] == m[:target] }
        element = target_attr && append_element(aggregate, target_attr[:type], value_objects_by_name)
        next ["#{m[:target]}: element type #{target_attr&.dig(:type).inspect} not resolvable"] unless element

        problems = m[:fields].filter_map do |field_name, source|
          field_attr = element[:attributes].find { |a| a[:name].to_s == field_name.to_s }
          next "#{m[:target]}.#{field_name}: not a declared field" unless field_attr

          # A SYMBOL names an argument, anything else IS the value — the one
          # distinction the wire spelling carries (Hecksagain::Literal), read
          # rather than sniffed off the first character.
          parsed = append_field_source(source)
          next literal_problem(m, field_name, parsed, field_attr, value_objects_by_name) unless parsed.is_a?(Symbol)

          arg_attr = command[:attributes].find { |a| a[:name].to_s == parsed.to_s }
          if arg_attr.nil?
            "#{m[:target]}.#{field_name}: sources undeclared argument #{parsed}"
          elsif !bridgeable_value_types?(arg_attr[:type], field_attr[:type], value_objects_by_name)
            "#{m[:target]}.#{field_name}: #{arg_attr[:type]} doesn't bridge to #{field_attr[:type]}"
          end
        end

        entity = aggregate[:entities].find { |e| e[:name] == target_attr[:type] }
        next problems unless entity

        present = m[:fields].keys.map(&:to_s)
        id_head = entity[:identified_by]&.first.to_s.split(".").first
        problems << "#{m[:target]}: #{entity[:name]}'s identity doesn't auto-mint" if !present.include?(id_head) && !entity_identity_mint(entity, value_objects_by_name)
        problems
      end
    end

    # `Marks.read` is the exact, already-proven inverse of the spelling
    # `appended_fields` writes — the OPPOSITE direction of the same round
    # trip the self-hosted grammar's own bootstrap uses it for. A Symbol
    # back means the field names a command ARGUMENT ; anything else IS the
    # literal value.
    def append_field_source(source) = Hecksagain::Bluebook::Assembly::Marks.read(source)

    def literal_problem(mutation, field_name, literal, field_attr, value_objects_by_name)
      return nil if literal.is_a?(Hash) && literal_hash_bridgeable?(literal, field_attr[:type], value_objects_by_name)

      "#{mutation[:target]}.#{field_name}: literal doesn't bridge to #{field_attr[:type]}"
    end

    # All transition rows this command names, collapsed into the one
    # `field`/`from_states` shape `TransitionCheck` wants — a command with
    # more than one `from:` (CloseAccount: from "open" OR "frozen") shares
    # one `to_state` across every matching row, per the "Lifecycles"
    # section above, so only `from_states` needs to be a list.
    def lifecycle_transition_for(command, aggregate)
      return nil unless aggregate[:lifecycle]

      rows = aggregate[:lifecycle][:transitions].select { |t| t[:command] == command[:name] }
      return nil if rows.empty?

      { field: aggregate[:lifecycle][:field], to_state: rows.first[:to_state], from_states: rows.map { |r| r[:from_state] }.uniq }
    end

    # Ruby's real `apply`, for `:set`, does `Value.for(aggregate,
    # mutation.target, value)` — it coerces whatever arrived into the
    # TARGET attribute's OWN declared type, not the source argument's.
    # `target_type` is that target type ("String" for the lifecycle field,
    # which is never VO-wrapped). The literal half is its own shape
    # (`literal_hash_rhs`, straight from the raw Hash — never `.inspect`'d,
    # see literal_set_bridgeable? above); the argument half is
    # `bridgeable_value_types?`/`value_rhs`'s shared job.
    def mutation_set_rhs(source, target_type, command, value_objects_by_name)
      if source[:kind] == "literal"
        value = source[:value]
        return literal_hash_rhs(value, target_type, value_objects_by_name) if value.is_a?(Hash)

        return literal_rhs(value)
      end

      source_attr = command[:attributes].find { |a| a[:name].to_s == source[:name] }
      value_rhs("args.#{rust_ident_field(source[:name])}", source_attr[:type], target_type, value_objects_by_name)
    end

    # `:append` and `:set` — the two `then_set` ops this slice generates.
    # `:set` has one real special case: the LIFECYCLE field is not one of
    # the aggregate's own `attributes` (see "Lifecycles" above), so it
    # can't be looked up there and isn't `Option`-wrapped on the record the
    # way every other field is — `Purchase`'s own `then_set :status, to:
    # "sold"` is a real, redundant instance of this (redundant with the
    # transition's own advance, harmless, same pattern as `Account.Open`'s
    # redundant `then_set` on an already-implicit creation attribute).
    # THE IDENTITY IS THE JOIN OF ITS PARTS (Naming::IDENTITY_JOIN is ":",
    # read directly) — one component per `identified_by` entry, each
    # resolved the same way `Runtime::Identity.from` resolves it: a dotted
    # path walks into the named argument's own field; a BARE component that
    # IS a declared command attribute reads that argument directly, no
    # walk; a bare component that is NOT a declared attribute (`owner_id` —
    # "never a declared attribute," per `language/bluebook/behavior.bluebook`'s
    # own comment) isn't in `args` at all — it's an addressing key allowed
    # through `refuse_unknown_arguments`'s allowlist the same way `id:`
    # already is, so the generated dispatch function takes it as its own
    # extra parameter, the same shape an acting command's caller-supplied
    # `id: &str` already has.
    def identity_components(aggregate, command)
      aggregate[:identified_by].map do |path|
        head, *rest = path.split(".")
        if rest.any?
          { expr: "args.#{rust_ident_field(head)}.#{rest.map { |seg| rust_ident_field(seg) }.join('.')}.to_string()", param: nil }
        elsif command[:attributes].any? { |a| a[:name].to_s == head }
          { expr: "args.#{rust_ident_field(head)}.to_string()", param: nil }
        else
          param = rust_ident_field(head)
          { expr: param, param: "#{param}: &str" }
        end
      end
    end

    def build_identity_expr(components)
      return components.first[:expr] if components.size == 1

      placeholders = components.map { "{}" }.join(":")
      "format!(#{placeholders.inspect}, #{components.map { |c| c[:expr] }.join(', ')})"
    end

    # One `append` field's value. An argument-sourced field runs through the
    # same `value_rhs` bridge `:set` does ; a literal is built inline.
    # `append_field_problems` already confirmed either direction bridges
    # before this could be reached.
    def append_field_rhs(source, field_attr, command, value_objects_by_name)
      parsed = append_field_source(source)
      return literal_hash_rhs(parsed, field_attr[:type], value_objects_by_name) unless parsed.is_a?(Symbol)

      arg_attr = command[:attributes].find { |a| a[:name].to_s == parsed.to_s }
      value_rhs("args.#{rust_ident_field(arg_attr[:name])}", arg_attr[:type], field_attr[:type], value_objects_by_name)
    end

    # `optional:` — true for an aggregate RECORD (every non-list field is
    # `Option`-wrapped, emit_record's own reason) and false for an ENTITY
    # element (emit_entity's fields are plain, never `Option`-wrapped — an
    # entity command's own `element_of`/copy-on-write already guarantees
    # the element it hands `apply_mutations` exists, so there is nothing
    # for `Option` to represent here the way "field exists but is unset on
    # a freshly created aggregate" needs it to on a record).
    def emit_mutation_line(mutation, aggregate, command, value_objects_by_name, optional: true)
      target_field   = rust_ident_field(mutation[:target])
      lifecycle_field = aggregate[:lifecycle] && aggregate[:lifecycle][:field].to_sym

      # The leading "        " restores the OLD code's own hardcoded
      # 8-space prefix — each `Exemplar.render` call below returns
      # flush-left text (a single-line shape's own dedent margin is
      # always its full indent, stripped to zero), and the CALLER
      # (commands.rb) joins these lines with "\n" expecting each one to
      # already carry its own indentation, the same as every other
      # single-line leaf in this generator.
      "        #{emit_mutation_line_body(mutation, aggregate, command, value_objects_by_name, target_field, lifecycle_field, optional)}"
    end

    def emit_mutation_line_body(mutation, aggregate, command, value_objects_by_name, target_field, lifecycle_field, optional)
      case mutation[:op]
      when :append
        target_attr = aggregate[:attributes].find { |a| a[:name] == mutation[:target] }
        vo_type = rust_ident(target_attr[:type])
        entity = aggregate[:entities].find { |e| e[:name] == target_attr[:type] }
        element = entity || value_objects_by_name[target_attr[:type]]

        fields_assignment = mutation[:fields].map do |field_name, source|
          field_attr = element[:attributes].find { |a| a[:name].to_s == field_name.to_s }
          "#{rust_ident_field(field_name)}: #{append_field_rhs(source, field_attr, command, value_objects_by_name)}"
        end

        # An ENTITY element carries two fields no `append: { ... }` binding
        # ever names, because Ruby never asks the caller to: its own
        # identity (auto-minted — entity_identity_mint, above, the same
        # `Array(current).size + 1` rule `entity_element` runs) and its own
        # lifecycle field (its declared `default:`, the same
        # `fields[entity.lifecycle.field] ||= entity.lifecycle.default`
        # entity_element runs). command_skip_reason already confirmed both
        # are mintable before this line could be reached.
        if entity
          present = mutation[:fields].keys.map(&:to_s)
          id_attr, id_vo = entity_identity_mint(entity, value_objects_by_name)
          if id_attr && !present.include?(id_attr[:name].to_s)
            mint = "#{rust_ident(id_attr[:type])} { #{rust_ident_field(id_vo[:attributes].first[:name])}: (record.#{target_field}.len() as i64) + 1 }"
            fields_assignment << "#{rust_ident_field(id_attr[:name])}: #{mint}"
          end
          if entity[:lifecycle] && !present.include?(entity[:lifecycle][:field].to_s)
            fields_assignment << "#{rust_ident_field(entity[:lifecycle][:field])}: #{entity[:lifecycle][:default].inspect}.to_string()"
          end
        end

        Exemplar.render(
          "mutation_append",
          "tmpl_field" => target_field,
          "tmpl_fields_placeholder()" => "#{vo_type} { #{fields_assignment.join(', ')} }"
        )
      when :set
        if mutation[:target] == lifecycle_field
          rhs = mutation_set_rhs(mutation[:source], "String", command, value_objects_by_name)
          Exemplar.render("mutation_set_plain", "tmpl_field" => target_field, "tmpl_rhs_placeholder2()" => rhs)
        else
          target_attr = aggregate[:attributes].find { |a| a[:name] == mutation[:target] }
          rhs = mutation_set_rhs(mutation[:source], target_attr[:type], command, value_objects_by_name)
          source_attr = mutation[:source][:kind] == "argument" ? command[:attributes].find { |a| a[:name].to_s == mutation[:source][:name].to_s } : nil

          if target_attr[:list] && optional && list_attr_creation_optional?(aggregate, target_attr[:name])
            # `CardPayment.Authorize`'s own redundant `then_set :tags, to:
            # :tags` (the same "re-set an already-implicit creation
            # attribute" pattern `Purchase`'s own status set already is) —
            # `list_attr_creation_optional?` (this file's own header) is
            # the SAME check `emit_record`/`record_fields` used to
            # Option-wrap this record field in the first place, so the
            # redundant re-set assigns the SAME `Option<Vec<T>>` shape
            # straight across, no unwrapping.
            Exemplar.render("mutation_set_plain", "tmpl_field" => target_field, "tmpl_rhs_placeholder2()" => rhs)
          elsif target_attr[:list] && source_attr && source_attr[:optional]
            # A record's own list field is plain `Vec<T>` by DEFAULT
            # (`emit_record`'s rule, unless the branch above applies) — an
            # OPTIONAL source argument unwraps with the identical `[]`
            # fallback `record_fields`' own creation-time case uses —
            # cleanly resolvable, not the `optional_source_mismatches`
            # shape that has to be skipped.
            Exemplar.render("mutation_set_unwrap_or_default", "tmpl_field" => target_field, "tmpl_optional_rhs_placeholder()" => rhs)
          elsif target_attr[:list]
            Exemplar.render("mutation_set_plain", "tmpl_field" => target_field, "tmpl_rhs_placeholder2()" => rhs)
          else
            # `target_attr[:optional]` — a PER-FIELD `Option<T>` target
            # (0014/0015's struct-field change: `SafeDepositBox::Visit.note`,
            # written by `Visit.Annotate`'s `then_set :note, to: :note`) —
            # not just `optional:`'s own whole-RECORD blanket wrap.
            #
            # `source_attr && source_attr[:optional]` — the SAME check
            # commands.rb's own record-creation path already makes
            # (see its "the optional arg's own Option<T> assigns
            # straight across" comment) and the sibling list-mutation
            # branch just above makes too: when the COMMAND's own
            # argument is already `Option<T>`, `rhs` already IS that
            # `Option<T>` — wrapping it again would be
            # `Option<Option<T>>`, not this field's real type,
            # regardless of whether `wrap` would otherwise be true for
            # blanket-record or per-field reasons.
            wrap = (optional || target_attr[:optional]) && !(source_attr && source_attr[:optional])
            if wrap
              Exemplar.render("mutation_set_wrapped", "tmpl_field" => target_field, "tmpl_rhs_placeholder2()" => rhs)
            else
              Exemplar.render("mutation_set_plain", "tmpl_field" => target_field, "tmpl_rhs_placeholder2()" => rhs)
            end
          end
        end
      when :increment, :decrement
        target_attr, integer_field = arithmetic_target_field(mutation, aggregate, value_objects_by_name)
        vo_type = rust_ident(target_attr[:type])
        field_ident = rust_ident_field(integer_field)
        amount_expr = arithmetic_amount_expr(mutation[:source], command, value_objects_by_name, integer_field)
        sign = mutation[:op] == :increment ? "+" : "-"
        current = optional ? "record.#{target_field}.clone().unwrap()" : "record.#{target_field}.clone()"
        updated = "#{vo_type} { #{field_ident}: current.#{field_ident} #{sign} (#{amount_expr}), ..current }"
        Exemplar.render(
          "mutation_arithmetic",
          "tmpl_field" => target_field,
          "tmpl_current_placeholder()" => current,
          "tmpl_updated_placeholder()" => (optional ? "Some(#{updated})" : updated)
        )
      end
    end
  end
end
