module RustProjection
  module Projector
    module_function

    # True when a list attribute reads `nil` rather than `[]`: a creating command `sets` it from
    # an optional argument the caller omitted (`CardPayment.tags`). `Account.ledger` stays `[]`.
    def list_attr_creation_optional?(aggregate, attr_name, value_objects_by_name)
      aggregate[:commands].any? do |command|
        next false unless creates_owner?(aggregate, command, value_objects_by_name)

        command[:mutations].any? do |m|
          next false unless m[:op].to_s == "set" && m[:target].to_s == attr_name.to_s && m[:source][:kind] == "argument"

          source_attr = command[:attributes].find { |a| a[:name].to_s == m[:source][:name].to_s }
          source_attr && source_attr[:optional]
        end
      end
    end

    # Whether `command` builds the owner record from scratch. Needs `references: nil` plus a
    # supplied required owner field, by `:set` or a same-named argument. Arguments claimed by an
    # `append` don't count (`ValueObject.Member#position` is not the owner's). Completeness of
    # state is not the test: `Analyzer#complete_state?` disagrees on both sides.
    def creates_owner?(aggregate, command, value_objects_by_name)
      return false unless command[:references].nil?

      owner_fields = aggregate[:attributes].map { |a| a[:name].to_s }.to_set
      owner_fields << aggregate[:lifecycle][:field].to_s if aggregate[:lifecycle]
      required_fields = aggregate[:attributes].reject { |a| a[:list] || a[:optional] }.map { |a| a[:name].to_s }.to_set

      # Arguments claimed by an append never bare-name-match an owner field.
      append_claimed = Set.new
      command[:mutations].each do |m|
        next unless m[:op].to_s == "append"

        Array(m[:fields]&.values).each do |v|
          source = append_field_source(v)
          append_claimed << source.to_s if source.is_a?(Symbol)
        end
      end

      known_writes = Set.new

      # A same-named argument is copied across by `record_fields` with no `:set`.
      command[:attributes].each do |attr|
        name = attr[:name].to_s
        known_writes << name if owner_fields.include?(name) && !append_claimed.include?(name)
      end

      # A `:set` covers the source-from-another-argument shape (`sets :field, to: :other_arg`).
      command[:mutations].each do |m|
        next unless m[:op].to_s == "set"

        target = m[:target].to_s
        known_writes << target if owner_fields.include?(target)
      end

      required_fields.any? { |field| known_writes.include?(field) }
    end

    # Resolves an `append` target to its entity or value object, or nil if it is neither.
    def append_element(aggregate, target_type, value_objects_by_name)
      # LOCAL FIRST — an aggregate's own nested entity is scoped to that
      # Local entities win over the domain-wide value objects: Syntax's local `Argument` entity
      # shares a name with Command's `Argument` value object.
      local = aggregate[:entities].find { |e| e[:name] == target_type }
      return local if local

      value_objects_by_name[target_type]
    end

    # Identity attribute and its single-field value object for an auto-minted entity element,
    # or nil for a composite or non-bare identity.
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

    # Guard for a whole-list `:set` of entities: refuses duplicate identities pairwise.
    # Returns `[guard_text, effective_rhs]`; composite identities are left unguarded.
    def entity_list_replace_guard(aggregate, target_attr, target_field, rhs, value_objects_by_name)
      entity = aggregate[:entities].find { |e| e[:name] == target_attr[:type] }
      return ["", rhs] unless entity && entity[:identified_by]&.size == 1

      id_head = entity[:identified_by].first.to_s.split(".").first
      id_attr = entity[:attributes].find { |a| a[:name].to_s == id_head }
      return ["", rhs] unless id_attr

      id_field  = rust_ident_field(id_attr[:name])
      # Single-field unwrap, so `format!` prints the bare scalar as Ruby's refusal wording does.
      id_vo = value_objects_by_name[id_attr[:type]]
      offered_expr =
        if id_vo && !id_vo[:closed_set] && id_vo[:attributes].size == 1
          "e.#{id_field}.#{rust_ident_field(id_vo[:attributes].first[:name])}"
        else
          "e.#{id_field}"
        end
      local_var = "replaced_#{target_field}"
      entity_lit    = entity[:name].to_s.inspect
      aggregate_lit = aggregate[:name].to_s.inspect
      identity_lit  = entity[:identified_by].join(", ").inspect
      guard =
        "let #{local_var} = #{rhs};\n        " \
        "for (i, e) in #{local_var}.iter().enumerate() { if #{local_var}[..i].iter().any(|prior| prior.#{id_field} == e.#{id_field}) " \
        "{ let offered = format!(\"{:?}\", #{offered_expr}); " \
        "return Err(crate::kernel::Refusal::AlreadyExists(crate::kernel::refusal_wording::AlreadyExistsEntityDuplicateArgs " \
        "{ entity: #{entity_lit}, aggregate: #{aggregate_lit}, identity: #{identity_lit}, " \
        "offered: &[offered.as_str()] }.render_args())); } }\n        "
      [guard, local_var]
    end

    # Why an `append` can't be generated: an unresolvable element, an undeclared field, a source
    # that doesn't bridge, or an entity identity that is neither minted nor supplied.
    def append_field_problems(command, aggregate, value_objects_by_name)
      command[:mutations].select { |m| m[:op].to_s == "append" }.flat_map do |m|
        target_attr = aggregate[:attributes].find { |a| a[:name].to_s == m[:target].to_s }
        element = target_attr && append_element(aggregate, target_attr[:type], value_objects_by_name)
        next ["#{m[:target]}: element type #{target_attr&.dig(:type).inspect} not resolvable"] unless element

        problems = m[:fields].filter_map do |field_name, source|
          field_attr = element[:attributes].find { |a| a[:name].to_s == field_name.to_s }
          next "#{m[:target]}.#{field_name}: not a declared field" unless field_attr

          # A Symbol names an argument; anything else is the value (Hecks::Literal).
          parsed = append_field_source(source)
          next nil if parsed.is_a?(Hecks::StateRef) # checked by state_source_problems
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

    # Why a `remove:` can't be generated. Only entity-typed lists are supported, matched by a
    # single bridgeable identity field, the same shape `entity_identity_mint` requires.
    def remove_field_problems(command, aggregate, value_objects_by_name)
      command[:mutations].select { |m| m[:op].to_s == "remove" }.filter_map do |m|
        target_attr = aggregate[:attributes].find { |a| a[:name].to_s == m[:target].to_s }
        next "#{m[:target]}: not a declared list attribute" unless target_attr && target_attr[:list]

        entity = aggregate[:entities].find { |e| e[:name] == target_attr[:type] }
        next "#{m[:target]}: remove on a value-object-typed list is not generated yet" unless entity

        # `entity_identity_mint` inspects only the first head, so a composite identity is
        # excluded here.
        if Array(entity[:identified_by]).size != 1
          next "#{m[:target]}: #{entity[:name]}'s identity is composite — remove not generated yet"
        end

        id_attr, = entity_identity_mint(entity, value_objects_by_name)
        unless id_attr
          next "#{m[:target]}: #{entity[:name]}'s identity isn't a single bridgeable field — remove not generated yet"
        end

        unless m[:source].is_a?(Hash) && m[:source][:kind] == "argument"
          next "#{m[:target]}: remove sources a literal or record state, not an argument — not generated yet"
        end

        source_attr = command[:attributes].find { |a| a[:name].to_s == m[:source][:name].to_s }
        next "#{m[:target]}: remove sources undeclared argument #{m[:source][:name]}" unless source_attr

        unless bridgeable_value_types?(source_attr[:type], id_attr[:type], value_objects_by_name)
          next "#{m[:target]}: #{source_attr[:type]} doesn't bridge to #{id_attr[:type]}"
        end

        nil
      end
    end

    # Decodes an append field source: a Symbol names a command argument, anything else is a
    # literal.
    def append_field_source(source) = Hecks::Bluebook::Assembly::Marks.read(source)

    def literal_problem(mutation, field_name, literal, field_attr, value_objects_by_name)
      return nil if literal_set_bridgeable?(literal, field_attr[:type], value_objects_by_name)

      "#{mutation[:target]}.#{field_name}: literal doesn't bridge to #{field_attr[:type]}"
    end

    # Collapses the transition rows a command names into the `field`/`from_states` hash
    # TransitionCheck reads.
    def lifecycle_transition_for(command, aggregate)
      return nil unless aggregate[:lifecycle]

      rows = aggregate[:lifecycle][:transitions].select { |t| t[:command] == command[:name] }
      # `from:` without a transition only guards on state; `to_state: nil` means it moves
      # nothing.
      if rows.empty?
        froms = Array(command[:from]).compact.map(&:to_s)
        return nil if froms.empty?

        return { field: aggregate[:lifecycle][:field], to_state: nil, from_states: froms.uniq, unconstrained: false }
      end

      # A `from: nil` row is unconstrained and admits any state. It is carried as
      # `unconstrained`
      # rather than dropped: the caller also reads `to_state` to advance the lifecycle.
      froms = rows.map { |r| r[:from_state] }
      {
        field: aggregate[:lifecycle][:field],
        to_state: rows.first[:to_state],
        from_states: froms.compact.uniq,
        unconstrained: froms.any?(&:nil?)
      }
    end

    # Rust expression for a `:set` source, coerced to the target attribute's declared type.
    # With `target_list:` a list source maps element-wise instead of unwrapping a single-field
    # value object out of a `Vec<T>`.
    def mutation_set_rhs(source, target_type, command, value_objects_by_name, target_list: false)
      if source[:kind] == "literal"
        return literal_rhs_for(source[:value], target_type, value_objects_by_name)
      end

      # `state(:field)` clones the record's value; `pre` is the pre-dispatch state, so effect
      # order is irrelevant.
      return "pre.#{rust_ident_field(source[:name])}.clone()" if source[:kind] == "state"

      source_attr = command[:attributes].find { |a| a[:name].to_s == source[:name] }
      source_expr = "args.#{rust_ident_field(source[:name])}"
      if target_list && source_attr[:list] && list_bridge_requires_element_mapping?(source_attr[:type], target_type)
        return list_value_rhs(source_expr, source_attr[:type], target_type, value_objects_by_name)
      end

      value_rhs(source_expr, source_attr[:type], target_type, value_objects_by_name)
    end

    # Problems with `state(:field)` sources: only a same-type, same-list-ness copy is generated.
    # generator has no data for, and says so rather than guessing.
    def state_source_problems(command, aggregate, value_objects_by_name)
      command[:mutations].flat_map do |m|
        case m[:op].to_s
        when "set"
          next [] unless m[:source][:kind] == "state"
          [state_source_problem(m[:target], m[:source][:name], aggregate, aggregate[:attributes].find { |a| a[:name].to_s == m[:target].to_s })].compact
        when "append"
          target_attr = aggregate[:attributes].find { |a| a[:name].to_s == m[:target].to_s }
          element = target_attr && append_element(aggregate, target_attr[:type], value_objects_by_name)
          next [] unless element
          m[:fields].filter_map do |field_name, source|
            parsed = append_field_source(source)
            next unless parsed.is_a?(Hecks::StateRef)
            state_source_problem("#{m[:target]}.#{field_name}", parsed.name, aggregate, element[:attributes].find { |a| a[:name].to_s == field_name.to_s })
          end
        else
          []
        end
      end
    end

    def state_source_problem(label, state_name, aggregate, target_attr)
      state_attr = aggregate[:attributes].find { |a| a[:name].to_s == state_name.to_s }
      return "#{label}: sources state(:#{state_name}), which #{aggregate[:name]} does not declare" unless state_attr
      return "#{label}: no such target field" unless target_attr
      same = state_attr[:type] == target_attr[:type] && !!state_attr[:list] == !!target_attr[:list]
      "#{label}: state(:#{state_name}) is #{state_attr[:list] ? 'a list of ' : ''}#{state_attr[:type]}, the target wants #{target_attr[:list] ? 'a list of ' : ''}#{target_attr[:type]} — not generated yet" unless same
    end

    # One entry per `identified_by` component, as `{ expr:, param:, head: }`. A head that is
    # "declared" reads `args.<head>` (walking a dotted rest); otherwise the caller supplies it
    # as a
    # `&str` parameter, and `head:` is the raw JSON key the router reads it under.
    # Declared means a `:set` targets the head, or a same-named argument not claimed by an
    # append
    # supplies it (bare-name copy, `Governance::RoleAssignment.Assign`). A bare name shared with
    # an
    # appended attribute (`Aggregate.Attribute#name`) is not the owner's identity.
    def identity_components(aggregate, command)
      # Declared: a `:set` targets the head, or a same-named argument not claimed by an append.
      append_claimed = Set.new
      command[:mutations].each do |m|
        next unless m[:op].to_s == "append"

        Array(m[:fields]&.values).each do |v|
          source = append_field_source(v)
          append_claimed << source.to_s if source.is_a?(Symbol)
        end
      end
      declared_names = command[:attributes].map { |a| a[:name].to_s }.to_set - append_claimed

      aggregate[:identified_by].map do |path|
        head, *rest = path.split(".")
        set_target = command[:mutations].any? { |m| m[:op].to_s == "set" && m[:target].to_s == head }
        if set_target || declared_names.include?(head)
          if rest.any?
            { expr: "args.#{rust_ident_field(head)}.#{rest.map { |seg| rust_ident_field(seg) }.join('.')}.to_string()", param: nil }
          else
            { expr: "args.#{rust_ident_field(head)}.to_string()", param: nil }
          end
        else
          # `.to_string()` keeps this an owned `String`: a single-component identity is returned
          # unwrapped into a `String` field, and this param is `&str`.
          param = rust_ident_field(head)
          { expr: "#{param}.to_string()", param: "#{param}: &str", head: head }
        end
      end
    end

    def build_identity_expr(components)
      return components.first[:expr] if components.size == 1

      placeholders = components.map { "{}" }.join(":")
      "format!(#{placeholders.inspect}, #{components.map { |c| c[:expr] }.join(', ')})"
    end

    # Value of one `append` field: an argument runs through the `value_rhs` bridge, a literal
    # is built inline. A caller-omittable argument is `Option<T>` in Rust, so it bridges through
    # `optional_value_rhs`; `mark_append_optional_fields!` has already made the field match.
    def append_field_rhs(source, field_attr, command, value_objects_by_name, aggregate = nil)
      parsed = append_field_source(source)
      return state_field_rhs(parsed, field_attr, aggregate) if parsed.is_a?(Hecks::StateRef)
      return literal_rhs_for(parsed, field_attr[:type], value_objects_by_name) unless parsed.is_a?(Symbol)

      arg_attr = command[:attributes].find { |a| a[:name].to_s == parsed.to_s }
      arg_expr = "args.#{rust_ident_field(arg_attr[:name])}"
      if arg_attr[:optional]
        # Same representation on both sides: clone the `Option` as is. Only a cross-type
        # coercion needs a per-element `.map`.
        same_representation = arg_attr[:type] == field_attr[:type] ||
          (effective_scalar_type(arg_attr[:type]) && effective_scalar_type(arg_attr[:type]) == effective_scalar_type(field_attr[:type]))
        return "#{arg_expr}.clone()" if same_representation

        return optional_value_rhs(arg_expr, arg_attr[:type], field_attr[:type], value_objects_by_name)
      end

      rhs = value_rhs(arg_expr, arg_attr[:type], field_attr[:type], value_objects_by_name)
      # The struct field may be `Option<T>` because another command sources it optionally,
      # so a required source still needs `Some(...)`.
      field_attr[:optional] ? "Some(#{rhs})" : rhs
    end

    # Whether any effect reads the record's own state (`state(:field)` in a `set` or `append`);
    # only then does the closure bind `pre`.
    def reads_pre_state?(mutations)
      mutations.any? do |m|
        case m[:op].to_s
        when "set"    then m[:source][:kind] == "state"
        when "append" then m[:fields].values.any? { |source| append_field_source(source).is_a?(Hecks::StateRef) }
        else false
        end
      end
    end

    def pre_state_line = "        let pre = record.clone();"

    # An Integer effect that leaves signed 64-bit is a Fault, never a wrap or panic (C3.3).
    # `amount` is bound once so the wording can quote it.
    CHECKED_OPS = { "+" => "checked_add", "-" => "checked_sub", "*" => "checked_mul" }.freeze

    def checked_arithmetic(op, field_ident, symbol, amount_expr)
      "{ let amount = #{amount_expr}; current.#{field_ident}.#{CHECKED_OPS.fetch(symbol)}(amount)" \
        ".ok_or_else(|| crate::kernel::Refusal::Fault(format!(\"#{op} overflowed: {} #{symbol} {} does not fit in a " \
        "64-bit integer\", current.#{field_ident}, amount)))? }"
    end

    # `state(:field)` into an appended element's field. Records `Option`-wrap non-list fields
    # and
    # elements don't, so scalars unwrap and lists clone as is.
    def state_field_rhs(parsed, field_attr, aggregate)
      expr = "pre.#{rust_ident_field(parsed.name)}.clone()"
      state_attr = aggregate && aggregate[:attributes].find { |a| a[:name].to_s == parsed.name.to_s }
      return expr if state_attr && state_attr[:list]
      return expr if field_attr[:optional]

      "#{expr}.unwrap()"
    end

    # The `value_rhs` bridge run against the value a `.map` closure unwraps from an `Option<T>`.
    def optional_value_rhs(source_expr, source_type, target_type, value_objects_by_name)
      "#{source_expr}.clone().map(|v| #{value_rhs('v', source_type, target_type, value_objects_by_name)})"
    end

    # Makes an appended element's field `Option<T>` when any command sources it from an optional
    # argument, since Ruby stores the omitted nil without complaint. Mutates the shared
    # attribute
    # hash once, before the emitters read it, and never resets a `true`.
    def mark_append_optional_fields!(aggregate, value_objects_by_name)
      aggregate[:attributes].each do |target_attr|
        element = append_element(aggregate, target_attr[:type], value_objects_by_name)
        next unless element

        aggregate[:commands].each do |command|
          command[:mutations].each do |m|
            next unless m[:op].to_s == "append" && m[:target].to_s == target_attr[:name].to_s

            m[:fields].each do |field_name, source|
              # A Symbol is an argument name (optional ones are what this pass wants); else a
              # literal.
              parsed = append_field_source(source)
              next unless parsed.is_a?(Symbol)

              source_attr = command[:attributes].find { |a| a[:name].to_s == parsed.to_s }
              next unless source_attr && source_attr[:optional]

              field_attr = element[:attributes].find { |a| a[:name].to_s == field_name.to_s }
              field_attr[:optional] = true if field_attr
            end
          end
        end
      end
    end

    # Derives the mutations of a `corrects EVENT, reverses: true` command from the commands that
    # emit EVENT: only increment/decrement invert (ADR 0041). Left alone when nothing emits the
    # event
    # or any sibling mutation can't invert, so `command_skip_reason` still refuses it.
    INVERSE_MUTATION_OP = { "increment" => "decrement", "decrement" => "increment" }.freeze

    def derive_reverses_mutations!(aggregate)
      emitted_by = Hash.new { |hash, key| hash[key] = [] }
      aggregate[:commands].each { |command| Array(command[:emits]).each { |event_name| emitted_by[event_name.to_s] << command } }

      aggregate[:commands].each do |command|
        correction = corrects_of(command)
        next unless correction && corrects_reverses?(correction)

        sources = emitted_by[correction[:target].to_s]
        next if sources.empty?

        derived = sources.flat_map { |c| c[:mutations] }.reject { |m| m[:op].to_s == "corrects" }
        next if derived.empty? || derived.any? { |m| !INVERSE_MUTATION_OP.key?(m[:op].to_s) }

        # Never derive twice onto a command that already has mutations, so re-runs stay
        # idempotent.
        # generator re-run over already-derived IR stays idempotent.
        next if command[:mutations].any? { |m| m[:op].to_s != "corrects" }

        derived.each do |m|
          command[:mutations] << { op: INVERSE_MUTATION_OP.fetch(m[:op].to_s), target: m[:target], source: m[:source] }
        end
      end
    end

    # `optional:` is true for an aggregate record (non-list fields are `Option`-wrapped) and
    # false for an entity element.
    def emit_mutation_line(mutation, aggregate, command, value_objects_by_name, optional: true)
      target_field   = rust_ident_field(mutation[:target])
      lifecycle_field = aggregate[:lifecycle] && aggregate[:lifecycle][:field].to_s

      # Callers join these lines with a newline, expecting each to carry its own 8-space indent.
      "        #{emit_mutation_line_body(mutation, aggregate, command, value_objects_by_name, target_field, lifecycle_field, optional)}"
    end

    def emit_mutation_line_body(mutation, aggregate, command, value_objects_by_name, target_field, lifecycle_field, optional)
      case mutation[:op].to_s
      when "append"
        target_attr = aggregate[:attributes].find { |a| a[:name].to_s == mutation[:target].to_s }
        vo_type = rust_ident(target_attr[:type])
        entity = aggregate[:entities].find { |e| e[:name] == target_attr[:type] }
        element = entity || value_objects_by_name[target_attr[:type]]

        fields_assignment = mutation[:fields].map do |field_name, source|
          field_attr = element[:attributes].find { |a| a[:name].to_s == field_name.to_s }
          "#{rust_ident_field(field_name)}: #{append_field_rhs(source, field_attr, command, value_objects_by_name, aggregate)}"
        end

          # An entity element also needs a minted identity and its lifecycle default; no
          # `append:` names them.
        collision_guard = ""
        if entity
          present = mutation[:fields].keys.map(&:to_s)
          id_attr, id_vo = entity_identity_mint(entity, value_objects_by_name)
          if id_attr && !present.include?(id_attr[:name].to_s)
            # One past the highest identity held, never `len() + 1`, which repeats after a
            # shrink (C4.5).
            id_field = rust_ident_field(id_attr[:name])
            vo_field = rust_ident_field(id_vo[:attributes].first[:name])
            mint = "#{rust_ident(id_attr[:type])} { #{vo_field}: record.#{target_field}.iter().map(|e| e.#{id_field}.#{vo_field}).max().unwrap_or(0) + 1 }"
            fields_assignment << "#{rust_ident_field(id_attr[:name])}: #{mint}"
            present << id_attr[:name].to_s
          elsif id_attr && entity[:identified_by].size == 1
            # Caller-supplied identity: refuse a duplicate (`check_entity_collision`), matching
            # rust/codegen byte for byte. Composite identities are excluded: only the first head
            # is seen, so elements sharing it would be false duplicates.
            id_field = rust_ident_field(id_attr[:name])
            _, source = mutation[:fields].find { |field_name, _| field_name.to_s == id_attr[:name].to_s }
            field_attr = entity[:attributes].find { |a| a[:name].to_s == id_attr[:name].to_s }
            id_rhs = append_field_rhs(source, field_attr, command, value_objects_by_name, aggregate)
            entity_lit = entity[:name].to_s.inspect
            aggregate_lit = aggregate[:name].to_s.inspect
            identity_lit = entity[:identified_by].join(", ").inspect
            # Single-field unwrap so `format!` prints the bare scalar; `id_vo` is non-nil here.
            offered_field = rust_ident_field(id_vo[:attributes].first[:name])
            offered_expr = "#{id_rhs}.#{offered_field}"
            collision_guard =
              "if record.#{target_field}.iter().any(|e| e.#{id_field} == #{id_rhs}) " \
              "{ let offered = format!(\"{:?}\", #{offered_expr}); " \
              "return Err(crate::kernel::Refusal::AlreadyExists(crate::kernel::refusal_wording::AlreadyExistsEntityDuplicateArgs " \
              "{ entity: #{entity_lit}, aggregate: #{aggregate_lit}, identity: #{identity_lit}, " \
              "offered: &[offered.as_str()] }.render_args())); }\n        "
          end
          if entity[:lifecycle] && !present.include?(entity[:lifecycle][:field].to_s)
            fields_assignment << "#{rust_ident_field(entity[:lifecycle][:field])}: #{entity[:lifecycle][:default].inspect}.to_string()"
            present << entity[:lifecycle][:field].to_s
          end

          # A list attribute no `append:` binding names starts empty. Ruby's fields Hash just
          # lacks the
          # key, but a Rust struct literal must assign every field.
          entity[:attributes].each do |attr|
            next unless attr[:list]
            next if present.include?(attr[:name].to_s)

            fields_assignment << "#{rust_ident_field(attr[:name])}: Vec::new()"
            present << attr[:name].to_s
          end

          # An optional scalar attribute is `Option<T>` in Rust, so an unmentioned one defaults
          # to `None`.
          entity[:attributes].each do |attr|
            next if attr[:list] || !attr[:optional]
            next if present.include?(attr[:name].to_s)

            fields_assignment << "#{rust_ident_field(attr[:name])}: None"
            present << attr[:name].to_s
          end
        end

        "#{collision_guard}#{Exemplar.render(
          "mutation_append",
          "tmpl_field" => target_field,
          "tmpl_fields_placeholder()" => "#{vo_type} { #{fields_assignment.join(', ')} }"
        )}"
      when "set"
        if mutation[:target].to_s == lifecycle_field
          rhs = mutation_set_rhs(mutation[:source], "String", command, value_objects_by_name)
          Exemplar.render("mutation_set_plain", "tmpl_field" => target_field, "tmpl_rhs_placeholder2()" => rhs)
        else
          target_attr = aggregate[:attributes].find { |a| a[:name].to_s == mutation[:target].to_s }
          rhs = mutation_set_rhs(mutation[:source], target_attr[:type], command, value_objects_by_name, target_list: !!target_attr[:list])
          source_attr = mutation[:source][:kind] == "argument" ? command[:attributes].find { |a| a[:name].to_s == mutation[:source][:name].to_s } : nil

          if target_attr[:list] && optional && list_attr_creation_optional?(aggregate, target_attr[:name], value_objects_by_name)
            # `CardPayment.Authorize`'s redundant `sets :tags`: `list_attr_creation_optional?`
            # already
            # Option-wrapped this field, so the value is assigned straight across.
            Exemplar.render("mutation_set_plain", "tmpl_field" => target_field, "tmpl_rhs_placeholder2()" => rhs)
          elsif target_attr[:list] && source_attr && source_attr[:optional]
            # A record's list field is a plain `Vec<T>` here; an optional source unwraps with a
            # `[]` fallback.
            Exemplar.render("mutation_set_unwrap_or_default", "tmpl_field" => target_field, "tmpl_optional_rhs_placeholder()" => rhs)
          elsif target_attr[:list]
            # Duplicate-identity guard for a whole-list replace of entities
            # (`Ledger.ReplaceEntries`).
            guard, effective_rhs = entity_list_replace_guard(aggregate, target_attr, target_field, rhs, value_objects_by_name)
            "#{guard}#{Exemplar.render("mutation_set_plain", "tmpl_field" => target_field, "tmpl_rhs_placeholder2()" => effective_rhs)}"
          else
            # `wrap` for a per-field `Option<T>` target or a whole-record wrap, unless the
            # source argument
            # is already `Option<T>` (wrapping again would give `Option<Option<T>>`).
            wrap = (optional || target_attr[:optional]) && !(source_attr && source_attr[:optional])
            if wrap
              Exemplar.render("mutation_set_wrapped", "tmpl_field" => target_field, "tmpl_rhs_placeholder2()" => rhs)
            else
              Exemplar.render("mutation_set_plain", "tmpl_field" => target_field, "tmpl_rhs_placeholder2()" => rhs)
            end
          end
        end
      when "increment", "decrement"
        target_attr, integer_field = arithmetic_target_field(mutation, aggregate, value_objects_by_name)
        vo_type = rust_ident(target_attr[:type])
        field_ident = rust_ident_field(integer_field)
        amount_expr = arithmetic_amount_expr(mutation[:source], command, value_objects_by_name, integer_field)
        # The sign comes from the IR's `sign` field (`Bluebook::Mutation.sign_for`), not the op
        # name.
        sign = mutation[:sign].to_s == "1" ? "+" : "-"
        current = optional ? "record.#{target_field}.clone().unwrap()" : "record.#{target_field}.clone()"
        updated = "#{vo_type} { #{field_ident}: #{checked_arithmetic(mutation[:op].to_s, field_ident, sign, amount_expr)}, ..current }"
        Exemplar.render(
          "mutation_arithmetic",
          "tmpl_field" => target_field,
          "tmpl_current_placeholder()" => current,
          "tmpl_updated_placeholder()" => (optional ? "Some(#{updated})" : updated)
        )
      when "multiply"
        # `multiply` shares increment/decrement's Integer-only target and amount pairing but has
        # no
        # `sign`; Float value objects are not reachable here.
        target_attr, integer_field = arithmetic_target_field(mutation, aggregate, value_objects_by_name)
        vo_type = rust_ident(target_attr[:type])
        field_ident = rust_ident_field(integer_field)
        amount_expr = arithmetic_amount_expr(mutation[:source], command, value_objects_by_name, integer_field)
        current = optional ? "record.#{target_field}.clone().unwrap()" : "record.#{target_field}.clone()"
        updated = "#{vo_type} { #{field_ident}: #{checked_arithmetic('multiply', field_ident, '*', amount_expr)}, ..current }"
        Exemplar.render(
          "mutation_arithmetic",
          "tmpl_field" => target_field,
          "tmpl_current_placeholder()" => current,
          "tmpl_updated_placeholder()" => (optional ? "Some(#{updated})" : updated)
        )
      when "clamp"
        # `clamp` bounds the current value into a literal `[min, max]`, so there is no amount
        # argument.
        # `i64::clamp` matches Ruby's `Integer#clamp`.
        target_attr, integer_field = arithmetic_target_field(mutation, aggregate, value_objects_by_name)
        vo_type = rust_ident(target_attr[:type])
        field_ident = rust_ident_field(integer_field)
        min, max = clamp_bounds_ints(mutation[:source])
        current = optional ? "record.#{target_field}.clone().unwrap()" : "record.#{target_field}.clone()"
        updated = "#{vo_type} { #{field_ident}: current.#{field_ident}.clamp(#{min}, #{max}), ..current }"
        Exemplar.render(
          "mutation_arithmetic",
          "tmpl_field" => target_field,
          "tmpl_current_placeholder()" => current,
          "tmpl_updated_placeholder()" => (optional ? "Some(#{updated})" : updated)
        )
      when "remove"
        # `remove:` on an entity-typed list matches by identity field (`remove_field_problems`
        # already
        # confirmed one exists); `retain` keeps every element whose identity differs.
        target_attr = aggregate[:attributes].find { |a| a[:name].to_s == mutation[:target].to_s }
        entity = aggregate[:entities].find { |e| e[:name] == target_attr[:type] }
        id_attr, = entity_identity_mint(entity, value_objects_by_name)
        id_field = rust_ident_field(id_attr[:name])
        source_attr = command[:attributes].find { |a| a[:name].to_s == mutation[:source][:name].to_s }
        match_expr = value_rhs("args.#{rust_ident_field(source_attr[:name])}", source_attr[:type],
                                id_attr[:type], value_objects_by_name)
        Exemplar.render(
          "mutation_remove",
          "tmpl_field" => target_field,
          "tmpl_id_field" => id_field,
          "tmpl_remove_match_placeholder()" => match_expr
        )
      end
    end
  end
end
