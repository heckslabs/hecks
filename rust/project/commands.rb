module RustProjection
  module Projector
    module_function

    def command_skip_reason(command, aggregate, value_objects_by_name)
      unsupported_ops = command[:mutations].reject { |m| %i[append set increment decrement].include?(m[:op]) }.map { |m| m[:op] }.uniq
      return "then_set op(s) #{unsupported_ops.join(', ')} not generated yet (only append/set/increment/decrement are)" if unsupported_ops.any?

      append_problems = append_field_problems(command, aggregate, value_objects_by_name)
      return "then_set append field(s): #{append_problems.join('; ')}" if append_problems.any?

      lifecycle_field = aggregate[:lifecycle] && aggregate[:lifecycle][:field].to_sym
      target_type_for = ->(target) { target == lifecycle_field ? "String" : aggregate[:attributes].find { |a| a[:name] == target }&.dig(:type) }

      # A `:set` mutation's literal source is EITHER a bare scalar (`to:
      # "sold"`) or a raw Ruby Hash (`to: { value: "good" }` —
      # Command::Mutation#classified_source wraps any non-Symbol source as
      # `{kind: "literal", value: source}` UNTOUCHED, unlike `:append`'s
      # `.inspect`'d fields, so a literal value object needs no re-parsing —
      # `literal_hash_rhs`, above, builds its Rust struct literal straight
      # from the Hash). Bridgeable only when every field the target VO
      # declares is actually present in the literal; checked generically (not
      # just "is it a Hash") so nothing NEW and unexpected can crash the run
      # instead of being skipped.
      literal_set_targets = command[:mutations].select do |m|
        next false unless m[:op] == :set && m[:source][:kind] == "literal"

        !literal_set_bridgeable?(m[:source][:value], target_type_for.call(m[:target]), value_objects_by_name)
      end.map { |m| m[:target] }
      return "then_set to: a literal that doesn't bridge to the target's type (#{literal_set_targets.join(', ')}) — not generated yet" if literal_set_targets.any?

      # Ruby's real `apply`, for `:set`, does `Value.for(aggregate, mutation.target,
      # value)` — it coerces whatever arrived into the TARGET attribute's OWN
      # declared type, regardless of what type the SOURCE argument was declared
      # as (found live: the self-hosted grammar sets an `IdentityField`-typed
      # attribute from a `FieldName`-typed argument — different value objects,
      # same one-`value`-field shape). This generator's `:set` just clones the
      # argument's own type straight across, which only compiles when source
      # and target genuinely agree — checked here so a real mismatch is a named
      # skip, not a `cargo build` error with no Ruby-side explanation.
      mismatched_sets = command[:mutations].select do |m|
        next false unless m[:op] == :set && m[:source][:kind] == "argument"

        target_type = target_type_for.call(m[:target])
        source_type = command[:attributes].find { |a| a[:name].to_s == m[:source][:name] }&.dig(:type)
        target_type && source_type && !bridgeable_value_types?(source_type, target_type, value_objects_by_name)
      end.map { |m| m[:target] }
      return "then_set :#{mismatched_sets.join(', ')} sources an argument no single-field rewrap can bridge to the target's type — not generated yet" if mismatched_sets.any?

      # `:increment`/`:decrement` — Ruby's real `arithmetic_value_object`
      # (command_rules/arithmetic.rb, read directly) finds the ONE field
      # that's `Integer` in both the target VO and the (already
      # target-type-coerced) amount, and changes only that field. Bridgeable
      # when the target names such a field AND the amount resolves to a raw
      # integer expression — `arithmetic_amount_expr`, above, is the same
      # "can we generate this" / "here's how" pairing `bridgeable_value_types?`/
      # `value_rhs` already use for `:set`.
      arithmetic_targets = command[:mutations].select { |m| %i[increment decrement].include?(m[:op]) }
      unsupported_arithmetic = arithmetic_targets.reject do |m|
        target = arithmetic_target_field(m, aggregate, value_objects_by_name)
        target && arithmetic_amount_expr(m[:source], command, value_objects_by_name, target[1])
      end.map { |m| m[:target] }
      return "then_set :#{unsupported_arithmetic.join(', ')} increment/decrement amount or target field isn't bridgeable — not generated yet" if unsupported_arithmetic.any?

      optional_problems = optional_source_mismatches(command, aggregate, value_objects_by_name)
      return "optional argument feeds a non-optional target: #{optional_problems.join('; ')} — not generated yet" if optional_problems.any?

      nil
    end

    # `attr[:optional]` (0014/0015) means a caller-omittable ARGUMENT — a
    # fact about the COMMAND. Nothing in this IR ever marks a value
    # object's or entity's OWN attribute `optional: true` by declaration;
    # the only way one becomes `Option<T>`-representable here is by
    # RECEIVING one (an entity attribute this generator Option-wraps
    # because SOME command's optional argument feeds it — `SafeDepositBox
    # ::Visit.note`, via `LogVisit`'s `append`). That works cleanly when
    # the target is ALSO the thing Option-wrapped for the same reason. It
    # does NOT work when an optional argument feeds a field this generator
    # has no OTHER reason to make `Option<T>` — the self-hosted meta
    # grammar's own `Attribute.Declare` is the real example: `default:`/
    # `pattern:`/`admits:` are optional COMMAND arguments, appended onto a
    # `Field` value object whose OWN attributes are never Option-wrapped
    # (nothing else in this corpus ever needs `Field.default` to be
    # absent). Ruby stores `nil` there without complaint — its args hash
    # has no static shape to violate. A generated Rust struct's shape is
    # fixed at compile time, so there is no honest choice here between
    # "leave the target non-optional and lose the omission" and "generate
    # something this domain's OWN declarations never asked for" — skipped,
    # loudly, the same as every other ungenerable shape above.
    def optional_source_mismatches(command, aggregate, value_objects_by_name)
      lifecycle_field = aggregate[:lifecycle] && aggregate[:lifecycle][:field].to_sym
      problems = []

      # `identified_by` (creating commands only — `identity_components`,
      # mutations.rb, is never called for an acting command) is read
      # straight off the command's own arguments to build the record's
      # `id:` at creation time — never Option-wrapped, since a record has
      # no "identity absent" state. An optional argument feeding it
      # (`Member.Declare`'s own `position`) isn't a `then_set` mutation at
      # all, so the checks below never see it; caught here instead.
      if command[:references].nil?
        aggregate[:identified_by].each do |path|
          head, = path.split(".")
          source_attr = command[:attributes].find { |a| a[:name].to_s == head }
          next unless source_attr && source_attr[:optional]

          problems << "identified_by :#{path} sources optional argument #{source_attr[:name]}"
        end
      end

      command[:mutations].each do |m|
        case m[:op]
        when :set
          next unless m[:source][:kind] == "argument"

          source_attr = command[:attributes].find { |a| a[:name].to_s == m[:source][:name].to_s }
          next unless source_attr && source_attr[:optional]

          if m[:target] == lifecycle_field
            problems << "then_set :#{m[:target]} sources optional argument #{source_attr[:name]} into the lifecycle field"
            next
          end

          target_attr = aggregate[:attributes].find { |a| a[:name] == m[:target] }
          # A LIST target is exempt — a record's own list field is
          # ALWAYS plain `Vec<T>` (never `Option`, emit_record's own
          # rule), so `emit_mutation_line`'s `:set` branch already
          # resolves this cleanly with `.unwrap_or_default()` (the
          # SAME fallback `record_fields`' own creation-time case
          # uses) — not a real mismatch to skip over.
          next if target_attr && target_attr[:list]

          problems << "then_set :#{m[:target]} sources optional argument #{source_attr[:name]}" unless target_attr && target_attr[:optional]
        when :append
          target_attr = aggregate[:attributes].find { |a| a[:name] == m[:target] }
          element = target_attr && append_element(aggregate, target_attr[:type], value_objects_by_name)
          next unless element

          m[:fields].each do |field_name, source|
            next if source.to_s.start_with?("{") # a literal, not a caller-omittable argument

            source_attr = command[:attributes].find { |a| a[:name].to_s == source.to_s }
            next unless source_attr && source_attr[:optional]

            field_attr = element[:attributes].find { |a| a[:name].to_s == field_name.to_s }
            problems << "then_set append #{m[:target]}.#{field_name} sources optional argument #{source_attr[:name]}" unless field_attr && field_attr[:optional]
          end
        end
      end

      problems
    end

    # ── ONE emitter for every command shape kernel::dispatch can run —
    # creating or acting, with or without givens or an append mutation.
    # What used to be emit_create_command's implicit, name-matched
    # `assign_creation_attributes` step now lives inside the `Hydrate::Create`
    # `build` closure; what used to be emit_act_command's given/mutation
    # generation is now just data (`GivenSpec`s, a closure) handed to
    # kernel::dispatch instead of hand-assembled control flow.
    def emit_command(command, aggregate, domain_name, value_objects_by_name)
      record = rust_ident(aggregate[:name])
      cmd    = rust_ident(command[:name])
      creates = command[:references].nil?
      identity = identity_components(aggregate, command)
      identity_extra_params = identity.filter_map { |c| c[:param] }

      args_struct = ["pub struct #{cmd}Args {"]
      command[:attributes].each do |attr|
        type = rust_type(attr[:type], list: attr[:list])
        # `optional: true`, no default — a caller-omittable argument
        # (`refuse_absent_arguments`'s own `required = attributes.reject
        # (&:optional?)`, argument_gate.rb, read directly). Modeled as
        # `Option<T>` — 0014/0015's own fix: nothing here used to
        # represent "omitted" at all, so a real, legal call omitting one
        # (`SafeDepositBox.LogVisit`'s own `note:`) failed with a
        # manufactured "missing from JSON args" refusal Ruby never
        # raises. `command_skip_reason` guards the one shape this can't
        # honestly represent yet (an optional source feeding a
        # NON-optional VO/entity field) before generation ever reaches
        # here.
        type = "Option<#{type}>" if attr[:optional]
        args_struct << "    pub #{rust_ident_field(attr[:name])}: #{type},"
      end
      args_struct << "}"

      invariant_checks = command[:attributes].filter_map do |attr|
        next unless value_objects_by_name.key?(attr[:type])
        next if value_objects_by_name[attr[:type]][:closed_set]

        field = rust_ident_field(attr[:name])
        if attr[:optional]
          attr[:list] ? "        if let Some(items) = &args.#{field} { for item in items { item.check_invariants()?; } }" : "        if let Some(v) = &args.#{field} { v.check_invariants()?; }"
        else
          attr[:list] ? "        for item in &args.#{field} { item.check_invariants()?; }" : "        args.#{field}.check_invariants()?;"
        end
      end

      given_specs = command[:givens].map do |given|
        "            crate::kernel::GivenSpec { description: #{given[:description].inspect}, expr: #{ExprEmitter.emit_predicate(given[:canonical])} },"
      end

      ensures_specs = command[:ensures].map do |rule|
        "            crate::kernel::EnsuresSpec { description: #{rule[:description].inspect}, expr: #{ExprEmitter.emit_predicate(rule[:canonical])} },"
      end

      transition = lifecycle_transition_for(command, aggregate)
      transition_arg =
        if transition
          "Some(crate::kernel::TransitionCheck { field: #{transition[:field].inspect}, from_states: &[#{transition[:from_states].map(&:inspect).join(', ')}] })"
        else
          "None"
        end

      mutation_lines = command[:mutations].map { |m| emit_mutation_line(m, aggregate, command, value_objects_by_name) }
      # advance_lifecycle: unconditional once a transition applies at all —
      # see kernel/dispatch.rs's TransitionCheck comment for why this lives
      # here, as one more line in the SAME closure, rather than as its own
      # dispatch() step. Covers commands with no explicit then_set on the
      # lifecycle field (Banking's Freeze/Unfreeze have none) — Purchase's
      # own explicit then_set above already covers itself, redundantly.
      mutation_lines << "        record.#{rust_ident_field(transition[:field])} = #{transition[:to_state].inspect}.to_string();" if transition
      mutation_lines = ["        let _ = record;"] if mutation_lines.empty? # nothing to apply — silence the unused-param warning

      if creates
        record_fields = aggregate[:attributes].map do |attr|
          matched = command[:attributes].find { |a| a[:name] == attr[:name] }
          field = rust_ident_field(attr[:name])
          if matched && matched[:optional]
            # The COMMAND's own attribute is `Option<T>` now — a
            # list-typed record field stays plain `Vec<T>` (emit_record's
            # own rule: lists are never Option-wrapped), so
            # `Option<Vec<T>>` needs unwrapping with the same `[]`
            # fallback `default_for` already gives an UNMATCHED list
            # attribute; a scalar/VO record field is ALREADY `Option<T>`
            # unconditionally, so the optional arg's own `Option<T>`
            # assigns straight across — wrapping it in another `Some(...)`
            # would be `Option<Option<T>>`, not this record field's type.
            attr[:list] ? "            #{field}: args.#{field}.clone().unwrap_or_default()," : "            #{field}: args.#{field}.clone(),"
          elsif matched
            attr[:list] ? "            #{field}: args.#{field}.clone()," : "            #{field}: Some(args.#{field}.clone()),"
          elsif attr[:list]
            "            #{field}: vec![],"
          else
            default_rhs = creation_default_rhs(attr, value_objects_by_name)
            default_rhs ? "            #{field}: Some(#{default_rhs})," : "            #{field}: None,"
          end
        end
        record_fields << "            #{rust_ident_field(aggregate[:lifecycle][:field])}: #{aggregate[:lifecycle][:default].inspect}.to_string()," if aggregate[:lifecycle]

        hydrate = <<~RUST.rstrip
          crate::kernel::Hydrate::Create {
                  id: #{build_identity_expr(identity)},
                  build: Box::new(|| #{record} {
          #{record_fields.join("\n")}
                  }),
              }
        RUST
        fn_signature = (["repo: &mut impl crate::kernel::Repository<#{record}>"] + identity_extra_params + ["args: #{cmd}Args"]).join(", ")
      else
        hydrate = %(crate::kernel::Hydrate::Act { id: id.to_string() })
        fn_signature = "repo: &mut impl crate::kernel::Repository<#{record}>, id: &str, args: #{cmd}Args"
      end

      <<~RUST
        #{emit_fielded_flat("#{cmd}Args", command[:attributes], value_objects_by_name)}

        #[derive(Debug, Clone)]
        #{args_struct.join("\n")}

        pub fn dispatch_#{dispatch_fn_name(cmd)}(
            #{fn_signature},
        ) -> crate::kernel::DispatchResult<#{record}> {
        #{invariant_checks.join("\n")}

            crate::kernel::dispatch(
                repo,
                #{hydrate},
                #{cmd.inspect},
                #{"#{domain_name}::#{aggregate[:name]}".inspect},
                &args,
                &[
        #{given_specs.join("\n")}
                ],
                #{transition_arg},
                |record| {
        #{mutation_lines.join("\n")}
                    Ok(())
                },
                &[
        #{ensures_specs.join("\n")}
                ],
                &[#{command[:emits].map(&:inspect).join(", ")}],
                args.to_json(),
            )
        }
      RUST
    end

    # `entity_command_skip_reason` — deliberately just `command_skip_reason`
    # with `entity` standing in for `aggregate`: an entity's own IR shape
    # (`attributes`/`lifecycle`/`commands`) is the SAME six-key shape an
    # aggregate's is (docs/guides/running-a-runtime.md, "Entities" —
    # exported recursively, identically). The one real divergence —
    # `append_field_problems`/`append_element` reading `aggregate[:entities]`,
    # which an entity node doesn't carry — is why this guards `:append`
    # BEFORE delegating, rather than risking a `nil.find` crash reaching
    # that branch: no entity command in either example domain ever appends
    # to a nested list of its own (an entity addressing one element of
    # ANOTHER entity's list isn't a shape this corpus declares), so this is
    # a real, separate, still-open gap flagged loudly, not silently worked
    # around by the delegation below.
    def entity_command_skip_reason(command, entity, value_objects_by_name)
      return "then_set append: on an entity's own command not generated yet (nested list)" if command[:mutations].any? { |m| m[:op] == :append }

      command_skip_reason(command, entity, value_objects_by_name)
    end

    # ── AN ENTITY COMMAND — `EntityInterpreter#call`'s shorter
    # `DISPATCH_ORDER` (docs/guides/entities.md), ported the same way
    # `emit_command` ports `CommandInterpreter#call`: compile the type
    # shapes, hand the kernel `Expr` data plus closures to interpret.
    # `kernel::dispatch_entity` (dispatch.rs) is the generic, hand-written
    # counterpart to `kernel::dispatch` this reuses — no `Hydrate` branch
    # (an entity command never creates), a `matches` closure in place of
    # `Hydrate::Act`'s bare `id` (an entity is addressed by ITS OWN
    # identity, found via `identity()`, not the parent's), and BOTH a
    # `parent_id` and the entity's own address as separate caller-supplied
    # strings, mirroring `EntityInterpreter#parent`/`#element_of`'s two
    # separate lookups.
    def emit_entity_command(command, entity, parent_aggregate, domain_name, value_objects_by_name)
      parent_record  = rust_ident(parent_aggregate[:name])
      element_record = rust_ident(entity[:name])
      cmd = rust_ident(command[:name])

      # THE PARENT'S LIST ATTRIBUTE HOLDING THIS ENTITY — found the exact
      # way `element_of` finds it at Ruby's own runtime (`a.list? &&
      # a.type == entity_name`), just resolved once here at generation
      # time instead of once per dispatch.
      list_attr = parent_aggregate[:attributes].find { |a| a[:list] && a[:type] == entity[:name] }
      raise "#{entity[:name]}: no list attribute on #{parent_aggregate[:name]} holds it — unsupported_attribute_types should have caught this" unless list_attr

      list_field = rust_ident_field(list_attr[:name])
      args_struct_name = "#{element_record}#{cmd}Args"

      args_struct = ["pub struct #{args_struct_name} {"]
      command[:attributes].each do |attr|
        type = rust_type(attr[:type], list: attr[:list])
        type = "Option<#{type}>" if attr[:optional]
        args_struct << "    pub #{rust_ident_field(attr[:name])}: #{type},"
      end
      args_struct << "}"

      invariant_checks = command[:attributes].filter_map do |attr|
        next unless value_objects_by_name.key?(attr[:type])
        next if value_objects_by_name[attr[:type]][:closed_set]

        field = rust_ident_field(attr[:name])
        if attr[:optional]
          attr[:list] ? "        if let Some(items) = &args.#{field} { for item in items { item.check_invariants()?; } }" : "        if let Some(v) = &args.#{field} { v.check_invariants()?; }"
        else
          attr[:list] ? "        for item in &args.#{field} { item.check_invariants()?; }" : "        args.#{field}.check_invariants()?;"
        end
      end

      given_specs = command[:givens].map do |given|
        "            crate::kernel::GivenSpec { description: #{given[:description].inspect}, expr: #{ExprEmitter.emit_predicate(given[:canonical])} },"
      end

      ensures_specs = command[:ensures].map do |rule|
        "            crate::kernel::EnsuresSpec { description: #{rule[:description].inspect}, expr: #{ExprEmitter.emit_predicate(rule[:canonical])} },"
      end

      # THE ENTITY's OWN lifecycle, not the parent aggregate's —
      # `lifecycle_transition_for`/`emit_mutation_line` (bridging.rb/
      # mutations.rb) already take a "declaring" node generically; passing
      # `entity` here is exactly that, not a special case either helper
      # needs to know about.
      transition = lifecycle_transition_for(command, entity)
      transition_arg =
        if transition
          "Some(crate::kernel::TransitionCheck { field: #{transition[:field].inspect}, from_states: &[#{transition[:from_states].map(&:inspect).join(', ')}] })"
        else
          "None"
        end

      mutation_lines = command[:mutations].map { |m| emit_mutation_line(m, entity, command, value_objects_by_name, optional: false) }
      mutation_lines << "        record.#{rust_ident_field(transition[:field])} = #{transition[:to_state].inspect}.to_string();" if transition
      mutation_lines = ["        let _ = record;"] if mutation_lines.empty?

      qualified_command_name = "#{entity[:name]}.#{command[:name]}"

      <<~RUST
        #{emit_fielded_flat(args_struct_name, command[:attributes], value_objects_by_name)}

        #[derive(Debug, Clone)]
        #{args_struct.join("\n")}

        #{emit_to_json_flat(args_struct_name, command[:attributes], value_objects_by_name)}

        #{emit_from_json_flat(args_struct_name, command[:attributes], value_objects_by_name)}

        pub fn dispatch_entity_#{entity[:name].downcase}_#{dispatch_fn_name(cmd)}(
            repo: &mut impl crate::kernel::Repository<#{parent_record}>, parent_id: &str, element_id: &str, args: #{args_struct_name},
        ) -> crate::kernel::DispatchResult<#{parent_record}> {
        #{invariant_checks.join("\n")}

            crate::kernel::dispatch_entity(
                repo,
                parent_id,
                |r: &#{parent_record}| &r.#{list_field},
                |r: &mut #{parent_record}| &mut r.#{list_field},
                |el: &#{element_record}| el.identity() == element_id,
                #{qualified_command_name.inspect},
                #{"#{domain_name}::#{parent_aggregate[:name]}".inspect},
                &args,
                &[
        #{given_specs.join("\n")}
                ],
                #{transition_arg},
                |record| {
        #{mutation_lines.join("\n")}
                    Ok(())
                },
                &[
        #{ensures_specs.join("\n")}
                ],
                &[#{command[:emits].map(&:inspect).join(", ")}],
                args.to_json(),
            )
        }
      RUST
    end
  end
end
