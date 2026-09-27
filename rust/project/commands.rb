require_relative "skip_reason"

module RustProjection
  module Projector
    module_function

    # The aggregate's own invariant set, passed to every dispatch of its commands.
    # Entity lists are descended into only when the entity declares invariants (C6.2).
    def invariants_fn_name(aggregate) = "#{rust_ident_field(aggregate[:name]).downcase}_invariants"

    def emit_invariants_fn(aggregate)
      aggregate_vec = invariant_specs_vec(aggregate[:invariants], 8)
      entities_vec = entity_invariants_vec(aggregate, 8)
      # Skip the `Expr` import when neither vec built an `Expr::` literal; it would be unused.
      needs_expr = [aggregate_vec, entities_vec].any? { |vec| vec.include?("Expr::") }
      [
        "fn #{invariants_fn_name(aggregate)}() -> crate::kernel::InvariantSet {",
        (needs_expr ? "    use crate::kernel::Expr;" : nil),
        "    crate::kernel::InvariantSet {",
        "        aggregate: #{aggregate_vec},",
        "        entities: #{entities_vec},",
        "    }",
        "}"
      ].compact.join("\n")
    end

    def invariant_specs_vec(rules, indent)
      return "vec![]" if rules.empty?

      pad  = " " * (indent + 4)
      rows = rules.map do |rule|
        "#{pad}crate::kernel::InvariantSpec { description: #{rust_string_literal(rule[:description])}, " \
          "expr: #{ExprEmitter.emit_ast(rule[:ast])} },"
      end
      "vec![\n#{rows.join("\n")}\n#{' ' * indent}]"
    end

    def entity_invariants_vec(owner, indent)
      pieces = owner[:entities].filter_map do |entity|
        next if entity[:invariants].empty?

        list = owner[:attributes].find { |a| a[:list] && a[:type].to_s == entity[:name].to_s }
        next unless list

        [entity, list[:name].to_s]
      end
      return "vec![]" if pieces.empty?

      pad  = " " * (indent + 4)
      rows = pieces.map do |entity, list_field|
        "#{pad}crate::kernel::EntityInvariants { name: #{rust_string_literal(entity[:name])}, " \
          "list_field: #{rust_string_literal(list_field)}, " \
          "specs: #{invariant_specs_vec(entity[:invariants], indent + 4)}, " \
          "nested: #{entity_invariants_vec(entity, indent + 4)} },"
      end
      "vec![\n#{rows.join("\n")}\n#{' ' * indent}]"
    end

    # `None` covers both "no transition" and an unconstrained one (`from: nil`); an empty
    # `from_states` slice would refuse every state instead of admitting every state.
    def transition_check_arg(transition)
      return "None" if transition.nil? || transition[:unconstrained]

      "Some(crate::kernel::TransitionCheck { field: #{transition[:field].inspect}, " \
        "from_states: &[#{transition[:from_states].map(&:inspect).join(', ')}] })"
    end

    # Cross-aggregate dereferences, already resolved by the router into owned data,
    # that every generated dispatch function takes.
    DEREF_PARAMS = ["owner_deref: Vec<(&'static str, crate::kernel::DerefNode)>",
                     "command_deref: Vec<(&'static str, crate::kernel::DerefNode)>"].freeze

    # Deferred tenant-boundary result, aggregate commands only; `dispatch()` checks it where
    # Ruby's `step_save` does.
    TENANT_BOUNDARY_PARAM = "tenant_boundary_check: Result<(), crate::kernel::Refusal>".freeze

    # Binds `WithReferences`. Precedence, highest first: `command_deref`, typed `args`,
    # `owner_deref`, matching the merge chain in `Admissibility#enforce_givens`.
    def with_references_binding
      "let with_references = crate::kernel::WithReferences { command_deref: &command_deref, args: &args, owner_deref: &owner_deref };"
    end

    # Seeds `projects` fields from the same `with_references` (ADR 0025); the field table is
    # always emitted, so an empty spec list is a no-op.
    def seed_projections_binding(aggregate)
      table = screaming_snake(aggregate[:name])
      "let seed_projections = crate::kernel::seeded_projections(&with_references, #{table}_PROJECTED_FIELDS);"
    end

    def command_skip_reason(command, aggregate, value_objects_by_name, creating_possible: true)
      # `remove` is generated only for entity-typed lists matched by identity; value-object
      # lists stay unsupported.
      unsupported_ops = command[:mutations].reject { |m| %w[append set increment decrement multiply clamp remove delegate corrects].include?(m[:op].to_s) }.map { |m| m[:op] }.uniq
      return skip("mutation_op", "sets op(s) #{unsupported_ops.join(', ')} not generated yet (only append/set/increment/decrement/multiply/clamp/remove/delegate/corrects are)") if unsupported_ops.any?

      corrects = corrects_of(command)
      # Skip only when `derive_reverses_mutations!` left this command untouched: a non-invertible
      # sibling op has no reversal design yet (ADR 0041).
      return skip("corrects_reverses", "corrects #{corrects[:target]}, reverses: true — the derived append/remove-reversal shape is a real, separate gap Ruby's own authors haven't finished designing (AggregateBuilder#seal_correction_targets's own comment) — not generated yet") \
        if corrects && corrects_reverses?(corrects) && command[:mutations].none? { |m| m[:op].to_s != "corrects" }

      delegate_problem = delegate_skip_reason(command, aggregate, value_objects_by_name)
      return skip("delegate", delegate_problem) if delegate_problem

      append_problems = append_field_problems(command, aggregate, value_objects_by_name)
      return skip("append_field", "sets append field(s): #{append_problems.join('; ')}") if append_problems.any?
      state_problems = state_source_problems(command, aggregate, value_objects_by_name)
      return skip("state_source", "sets state source(s): #{state_problems.join('; ')}") if state_problems.any?
      remove_problems = remove_field_problems(command, aggregate, value_objects_by_name)
      return skip("remove_field", "sets remove field(s): #{remove_problems.join('; ')}") if remove_problems.any?

      lifecycle_field = aggregate[:lifecycle] && aggregate[:lifecycle][:field].to_s
      target_type_for = ->(target) { target.to_s == lifecycle_field ? "String" : aggregate[:attributes].find { |a| a[:name].to_s == target.to_s }&.dig(:type) }
      # The lifecycle field is never list-typed.
      target_list_for = ->(target) { target.to_s != lifecycle_field && !!aggregate[:attributes].find { |a| a[:name].to_s == target.to_s }&.dig(:list) }

      # A literal `:set` source is a scalar or a raw Hash; a Hash must supply every field of the
      # target value object.
      literal_set_targets = command[:mutations].select do |m|
        next false unless m[:op].to_s == "set" && m[:source][:kind] == "literal"

        !literal_set_bridgeable?(m[:source][:value], target_type_for.call(m[:target]), value_objects_by_name)
      end.map { |m| m[:target] }
      return skip("set_literal", "sets to: a literal that doesn't bridge to the target's type (#{literal_set_targets.join(', ')}) — not generated yet") if literal_set_targets.any?

      # Ruby coerces a `:set` value into the target's declared type; the generated clone only
      # compiles when source and target agree, and cardinality (list vs scalar) must match.
      mismatched_sets = command[:mutations].select do |m|
        next false unless m[:op].to_s == "set" && m[:source][:kind] == "argument"

        target_type = target_type_for.call(m[:target])
        source_attr = command[:attributes].find { |a| a[:name].to_s == m[:source][:name] }
        source_type = source_attr&.dig(:type)
        next false unless target_type && source_type

        target_list_for.call(m[:target]) != !!source_attr[:list] || !bridgeable_value_types?(source_type, target_type, value_objects_by_name)
      end.map { |m| m[:target] }
      return skip("set_argument_bridge", "sets :#{mismatched_sets.join(', ')} sources an argument no single-field rewrap can bridge to the target's type — not generated yet") if mismatched_sets.any?

      # increment/decrement/multiply share one check: the target names an Integer field and the
      # amount resolves to an integer expression.
      arithmetic_targets = command[:mutations].select { |m| %w[increment decrement multiply].include?(m[:op].to_s) }
      unsupported_arithmetic = arithmetic_targets.reject do |m|
        target = arithmetic_target_field(m, aggregate, value_objects_by_name)
        target && arithmetic_amount_expr(m[:source], command, value_objects_by_name, target[1])
      end.map { |m| m[:target] }
      return skip("arithmetic", "sets :#{unsupported_arithmetic.join(', ')} increment/decrement/multiply amount or target field isn't bridgeable — not generated yet") if unsupported_arithmetic.any?

      # `clamp` bounds the current value with a literal [min, max] Integer pair; the target
      # field rule is the same as arithmetic.
      clamp_targets = command[:mutations].select { |m| m[:op].to_s == "clamp" }
      unsupported_clamp = clamp_targets.reject do |m|
        arithmetic_target_field(m, aggregate, value_objects_by_name) && clamp_bounds_ints(m[:source])
      end.map { |m| m[:target] }
      return skip("clamp", "sets :#{unsupported_clamp.join(', ')} clamp target field or bounds isn't bridgeable — not generated yet") if unsupported_clamp.any?

      optional_problems = optional_source_mismatches(command, aggregate, value_objects_by_name, creating_possible: creating_possible)
      return skip("optional_source", "optional argument feeds a non-optional target: #{optional_problems.join('; ')} — not generated yet") if optional_problems.any?

      nil
    end

    # An optional argument feeding a field that is not `Option<T>` cannot be generated: the Rust
    # struct shape is fixed at compile time, while Ruby stores `nil`. Skipped, not guessed.
    def optional_source_mismatches(command, aggregate, value_objects_by_name, creating_possible: true)
      lifecycle_field = aggregate[:lifecycle] && aggregate[:lifecycle][:field].to_s
      problems = []

      # An entity command never creates, so its optional identity argument is not an identity
      # source (`creating_possible: false`).

      # `identified_by` is never Option-wrapped, so an optional argument feeding it is caught
      # here; the `sets` checks below never see it.
      if creating_possible && creates_owner?(aggregate, command, value_objects_by_name)
        aggregate[:identified_by].each do |path|
          head, = path.split(".")
          source_attr = command[:attributes].find { |a| a[:name].to_s == head }
          next unless source_attr && source_attr[:optional]

          problems << "identified_by :#{path} sources optional argument #{source_attr[:name]}"
        end
      end

      command[:mutations].each do |m|
        case m[:op].to_s
        when "set"
          next unless m[:source][:kind] == "argument"

          source_attr = command[:attributes].find { |a| a[:name].to_s == m[:source][:name].to_s }
          next unless source_attr && source_attr[:optional]

          if m[:target].to_s == lifecycle_field
            problems << "sets :#{m[:target]} sources optional argument #{source_attr[:name]} into the lifecycle field"
            next
          end

          target_attr = aggregate[:attributes].find { |a| a[:name].to_s == m[:target].to_s }
          # A list target is exempt: both `Vec<T>` and `Option<Vec<T>>` record fields are handled
          # by the `:set` branch.
          next if target_attr && target_attr[:list]

          # Aggregate-command records hold `Option<T>` fields, so an optional argument assigns
          # straight across; only entity element fields can mismatch.
          next if creating_possible

          problems << "sets :#{m[:target]} sources optional argument #{source_attr[:name]}" unless target_attr && target_attr[:optional]
        when "append"
          target_attr = aggregate[:attributes].find { |a| a[:name].to_s == m[:target].to_s }
          element = target_attr && append_element(aggregate, target_attr[:type], value_objects_by_name)
          next unless element

          m[:fields].each do |field_name, source|
            parsed = append_field_source(source)
            next unless parsed.is_a?(Symbol) # a literal, not a caller-omittable argument

            source_attr = command[:attributes].find { |a| a[:name].to_s == parsed.to_s }
            next unless source_attr && source_attr[:optional]

            field_attr = element[:attributes].find { |a| a[:name].to_s == field_name.to_s }
            problems << "sets append #{m[:target]}.#{field_name} sources optional argument #{source_attr[:name]}" unless field_attr && field_attr[:optional]
          end
        end
      end

      problems
    end

    # Per-attribute admits-constraint and nested-value-object invariant checks, against an
    # already-bound value expression.
    # Usage-level `pattern:` is deliberately not checked: Ruby never enforces it on a command
    # argument (ADR 0010). List attributes skip `admits:` too, since `admit_declared_set` is
    # only reached on the scalar branch.
    def argument_check_lines(attr, value_expr, aggregates_by_name, value_objects_by_name)
      lines = []

      unless attr[:list]
        # Raw field expression: `emit_admits_check` does its own optional handling.
        constraint = emit_admits_check(value_expr, attr, aggregates_by_name, value_objects_by_name)
        lines << "        #{constraint}" if constraint
      end

      if value_objects_by_name.key?(attr[:type]) && !value_objects_by_name[attr[:type]][:closed_set]
        lines << if attr[:optional]
          attr[:list] ? "        if let Some(items) = &#{value_expr} { for item in items { item.check_invariants()?; } }" : "        if let Some(v) = &#{value_expr} { v.check_invariants()?; }"
        else
          attr[:list] ? "        for item in &#{value_expr} { item.check_invariants()?; }" : "        #{value_expr}.check_invariants()?;"
        end
      end

      lines
    end

    # Post-construction copy against the built Args struct, run at the router and again in the
    # dispatch fn; redundant with the interleaved checks in `from_json`, but kept.
    def invariant_checks_for(command, aggregates_by_name, value_objects_by_name)
      command[:attributes].flat_map do |attr|
        field = rust_ident_field(attr[:name])
        argument_check_lines(attr, "args.#{field}", aggregates_by_name, value_objects_by_name)
      end
    end

    # One emitter for every command shape `kernel::dispatch` can run, creating or acting.
    def emit_command(command, aggregate, domain_name, value_objects_by_name, aggregates_by_name)
      record = rust_ident(aggregate[:name])
      cmd    = rust_ident(command[:name])
      creates = creates_owner?(aggregate, command, value_objects_by_name)
      identity = identity_components(aggregate, command)
      identity_extra_params = identity.filter_map { |c| c[:param] }

      # `aggregate_name`/`identity_reading` feed the refusal wording of both `creating_duplicate`
      # and `record_missing`, whatever the command shape.
      aggregate_name    = aggregate[:name].to_s
      identity_reading  = aggregate[:identified_by].join(", ")

      # Reuses `struct_field` only; the Args derive lacks `PartialEq`, unlike `plain_struct`.
      args_struct = ["pub struct #{cmd}Args {"]
      command[:attributes].each do |attr|
        type = rust_type(attr[:type], list: attr[:list])
        # An optional argument is `Option<T>`; `command_skip_reason` guards the one shape that
        # cannot represent it.
        type = "Option<#{type}>" if attr[:optional]
        args_struct << "    #{Exemplar.render('struct_field', 'TmplFieldType' => type, 'tmpl_field' => rust_ident_field(attr[:name]))}"
      end
      args_struct << "}"

      invariant_checks = invariant_checks_for(command, aggregates_by_name, value_objects_by_name)

      given_specs = corrects_given_specs(command) + command[:givens].map do |given|
        "            crate::kernel::GivenSpec { description: #{rust_string_literal(given[:description])}, expr: #{ExprEmitter.emit_ast(given[:ast])}, corrects_event: None },"
      end

      ensures_specs = command[:ensures].map do |rule|
        "            crate::kernel::EnsuresSpec { description: #{rust_string_literal(rule[:description])}, expr: #{ExprEmitter.emit_ast(rule[:ast])} },"
      end

      transition = lifecycle_transition_for(command, aggregate)
      transition_arg =
        transition_check_arg(transition)

      mutation_lines = command[:mutations].reject { |m| m[:op].to_s == "corrects" }
                                          .map { |m| emit_mutation_line(m, aggregate, command, value_objects_by_name) }
      mutation_lines.unshift(pre_state_line) if reads_pre_state?(command[:mutations])
      mutation_lines.concat(corrects_flag_mutation_lines(command, aggregate))
      # Advance the lifecycle unconditionally once a transition applies, even when no explicit
      # set targets the lifecycle field.
      mutation_lines << "        record.#{rust_ident_field(transition[:field])} = #{transition[:to_state].inspect}.to_string();" if transition && transition[:to_state]
      mutation_lines = ["        let _ = record;"] if mutation_lines.empty? # nothing to apply — silence the unused-param warning
      delegation = delegation_of(command, aggregate, value_objects_by_name, domain_name)
      if delegation
        raise "#{command[:name]}: a creating command cannot delegate — nothing exists to delegate to" if creates

        # The element extraction runs first inside the closure, after a successful hydrate.
        mutation_lines = [delegation[:element], delegation[:apply]]
      end
      prelude   = delegation ? delegation[:prelude] : ""
      payload   = delegation ? "delegate_facts.clone()," : "args.to_json(),"
      emits_out = delegation ? delegation[:emits] : command[:emits]

      if creates
        # A `projects` field is never a command argument, so it falls to `None`;
        # `seed_projections` fills it before save.
        record_fields = (aggregate[:attributes] + Projector.projected_field_pseudo_attributes(aggregate)).map do |attr|
          matched = command[:attributes].find { |a| a[:name] == attr[:name] }
          field = rust_ident_field(attr[:name])
          if matched && matched[:optional]
            # An optional argument is already `Option<T>`; a scalar record field takes it as is.
            # A list field does too only when `list_attr_creation_optional?` wrapped it, else it is
            # unwrapped with the `[]` fallback `default_for` gives an unmatched list attribute.
            if attr[:list] && !list_attr_creation_optional?(aggregate, attr[:name], value_objects_by_name)
              "            #{field}: args.#{field}.clone().unwrap_or_default(),"
            elsif attr[:list] || matched[:type] == attr[:type]
              "            #{field}: args.#{field}.clone(),"
            else
              # Same-named cross-aggregate argument of a different type (see `bridging.rb`):
              # bridge it rather than clone.
              "            #{field}: #{optional_value_rhs("args.#{field}", matched[:type], attr[:type], value_objects_by_name)},"
            end
          elsif matched
            if attr[:list] || matched[:type] == attr[:type]
              attr[:list] ? "            #{field}: args.#{field}.clone()," : "            #{field}: Some(args.#{field}.clone()),"
            else
              "            #{field}: Some(#{value_rhs("args.#{field}", matched[:type], attr[:type], value_objects_by_name)}),"
            end
          elsif attr[:list]
            "            #{field}: vec![],"
          else
            default_rhs = creation_default_rhs(attr, value_objects_by_name)
            default_rhs ? "            #{field}: Some(#{default_rhs})," : "            #{field}: None,"
          end
        end
        record_fields << "            #{rust_ident_field(aggregate[:lifecycle][:field])}: #{aggregate[:lifecycle][:default].inspect}.to_string()," if aggregate[:lifecycle]
        correctable_event_names(aggregate).each { |name| record_fields << "            #{corrects_flag_field(name)}: false," }

        # Mirrors `CommandInterpreter#step_hydrate`'s complete-state and state-independent branch.
        state_independent = state_independent_creation?(aggregate, command, value_objects_by_name)
        create_block = <<~RUST.rstrip
          crate::kernel::Hydrate::Create {
                  id: __hydrate_id,
                  build: Box::new(|| #{record} {
          #{record_fields.join("\n")}
                  }),
                  state_independent: #{state_independent},
              }
        RUST

        # Ruby checks the route before choosing create-vs-find. With `complete_state?` a route is
        # validated against the derived identity (`TypeMismatch` on mismatch), then creates;
        # otherwise a route forces find-or-`NotFound` (`Hydrate::Act`).
        complete_state = complete_state_creation?(aggregate, command, value_objects_by_name)
        route_mismatch_message = "#{command[:name]} routes to {:?}, but its identity facts name {:?}"
        route_arm =
          if complete_state
            <<~RUST.rstrip
              Some(__route) => {
                      __route.require_depth(0)?;
                      let __hydrate_id: String = #{build_identity_expr(identity)};
                      if __route.aggregate() != __hydrate_id.as_str() {
                          return Err(crate::kernel::Refusal::TypeMismatch(format!(#{route_mismatch_message.inspect}, __route.aggregate(), __hydrate_id)));
                      }
                      #{create_block}
                  }
            RUST
          else
            <<~RUST.rstrip
              Some(__route) => {
                      __route.require_depth(0)?;
                      crate::kernel::Hydrate::Act { id: __route.aggregate().to_string() }
                  }
            RUST
          end
        hydrate = <<~RUST.rstrip
          match route {
                  #{route_arm}
                  None => { let __hydrate_id: String = #{build_identity_expr(identity)}; #{create_block} }
              }
        RUST
        fn_signature = (["repo: &mut impl crate::kernel::Repository<#{record}>", "route: Option<&crate::kernel::RoutingEnvelope>"] + identity_extra_params +
                        ["args: #{cmd}Args", "mutations: &mut Vec<crate::kernel::MutationRecord>", *DEREF_PARAMS, TENANT_BOUNDARY_PARAM]).join(", ")
      else
        hydrate = %(crate::kernel::Hydrate::Act { id: id.to_string() })
        fn_signature = (["repo: &mut impl crate::kernel::Repository<#{record}>", "id: &str", "args: #{cmd}Args",
                          "mutations: &mut Vec<crate::kernel::MutationRecord>", *DEREF_PARAMS, TENANT_BOUNDARY_PARAM]).join(", ")
      end

      dispatch_fn = Exemplar.render(
        "dispatch_fn",
        "repo: &mut impl crate::kernel::Repository<TmplRecord>, id: &str, args: TmplArgs, mutations: &mut Vec<crate::kernel::MutationRecord>, #{TENANT_BOUNDARY_PARAM}" => fn_signature,
        "dispatch_tmpl" => "dispatch_#{dispatch_fn_name(cmd)}",
        "TmplRecord" => record,
        "tmpl_invariant_check_placeholder()?;" => invariant_checks.join("\n"),
        "let tmpl_eval_fielded = tmpl_with_references_placeholder();" => with_references_binding,
        "&tmpl_eval_fielded," => "&with_references,",
        "let tmpl_seed_projections = tmpl_seed_projections_placeholder();" => seed_projections_binding(aggregate),
        "tmpl_seed_projections," => "seed_projections,",
        "tmpl_hydrate_placeholder()" => hydrate,
        "tmpl_prelude_placeholder();" => prelude,
        '"TmplCmdName"' => cmd.inspect,
        '"TmplQualifiedName"' => "#{domain_name}::#{aggregate[:name]}".inspect,
        '"TmplAggregateName"' => aggregate_name.inspect,
        '"TmplIdentityReading"' => identity_reading.inspect,
        "tmpl_given_spec_placeholder()," => given_specs.join("\n"),
        "tmpl_transition_placeholder()" => transition_arg,
        "tmpl_mutation_lines_placeholder(record);" => mutation_lines.join("\n"),
        "tmpl_ensures_spec_placeholder()," => ensures_specs.join("\n"),
        "tmpl_invariants_placeholder()" => "#{invariants_fn_name(aggregate)}()",
        "tmpl_emit_placeholder()" => emits_out.map(&:inspect).join(", "),
        "args.to_json()," => payload
      )

      "#{emit_fielded_flat("#{cmd}Args", command[:attributes], value_objects_by_name)}\n\n#[derive(Debug, Clone)]\n#{args_struct.join("\n")}\n\n#{dispatch_fn}"
    end

    # `corrects "Event"`: a synthetic prepended GivenSpec reads a per-record flag set when a
    # command emitting the event succeeds. `reverses: true` is refused; Ruby has not finished
    # designing it (ADR 0041).
    def corrects_of(command) = command[:mutations].find { |m| m[:op].to_s == "corrects" }

    def corrects_reverses?(mutation) = !!(mutation[:source].is_a?(Hash) && mutation[:source][:value].is_a?(Hash) && mutation[:source][:value][:reverses])

    # Synthetic snake_case flag field name, e.g. `emitted_fee_applied` for `FeeApplied`.
    def corrects_flag_field(event_name) = "emitted_#{event_name.to_s.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase}"

    def corrects_given_specs(command)
      corrects = corrects_of(command)
      return [] unless corrects

      event_name = corrects[:target].to_s
      ["            crate::kernel::GivenSpec { description: \"\", " \
       "expr: crate::kernel::Expr::Lookup(#{corrects_flag_field(event_name).inspect}), " \
       "corrects_event: Some(#{event_name.inspect}) },"]
    end

    # Event names any command or entity command on this aggregate corrects. The flag lives on
    # the parent record whichever level declares `corrects`; entities have no event stream.
    def correctable_event_names(aggregate)
      names = corrects_targets_of(aggregate[:commands])
      (aggregate[:entities] || []).each { |entity| names.concat(entity_correctable_event_names(entity)) }
      names.uniq
    end

    def entity_correctable_event_names(entity)
      names = corrects_targets_of(entity[:commands])
      (entity[:entities] || []).each { |nested| names.concat(entity_correctable_event_names(nested)) }
      names
    end

    def corrects_targets_of(commands)
      commands.flat_map { |c| c[:mutations] }
              .select { |m| m[:op].to_s == "corrects" }
              .map { |m| m[:target].to_s }
    end

    # `extra_fields:` entries so the flag rides the record's ordinary JSON round-trip.
    def corrects_extra_fields(aggregate)
      correctable_event_names(aggregate).map do |ev|
        field = corrects_flag_field(ev)
        deserialize_rhs = "match v.require(#{field.inspect}, #{aggregate[:name].to_s.inspect})? { " \
          "crate::kernel::Json::Bool(b) => *b, " \
          "_ => return Err(#{json_type_error(aggregate[:name].to_s, field, 'a boolean')}) }"
        [field, "crate::kernel::Json::Bool(self.#{field})", deserialize_rhs]
      end
    end

    # Stamps the flag onto the record when a command emitting a correctable event succeeds;
    # Rust has no ambient event log to consult.
    def corrects_flag_mutation_lines(command, aggregate)
      correctable = correctable_event_names(aggregate)
      Array(command[:emits]).map(&:to_s).uniq.select { |name| correctable.include?(name) }
                            .map { |name| "        record.#{corrects_flag_field(name)} = true;" }
    end

    # `delegates_to "Entity.Command"`: the door's only mutation, run on the record inside the
    # dispatch closure.
    def delegate_of(command) = command[:mutations].find { |m| m[:op].to_s == "delegate" }

    def delegate_mapping(delegation)
      (delegation[:fields] || {}).to_h { |target_key, source_key| [target_key.to_s, source_key.to_s.delete_prefix(":")] }
    end

    def delegate_target(delegation, aggregate)
      entity_name, _dot, command_name = delegation[:target].to_s.rpartition(".")
      entity = (aggregate[:entities] || []).find { |e| e[:name].to_s == entity_name }
      target = entity && entity[:commands].find { |c| c[:name].to_s == command_name }
      [entity, target]
    end

    def delegate_skip_reason(command, aggregate, value_objects_by_name)
      delegation = delegate_of(command)
      return nil unless delegation

      label = "delegates_to #{delegation[:target]}"
      return "#{label} alongside other sets — not generated yet" if command[:mutations].size > 1

      entity, target = delegate_target(delegation, aggregate)
      return "#{label}: #{aggregate[:name]} has no such entity" unless entity
      return "#{label}: #{entity[:name]} declares no such command" unless target
      return "#{label}: #{entity[:name]} cannot be addressed by identity" unless extract_id_supported?(entity)

      target_problem = entity_command_skip_reason(target, entity, value_objects_by_name)
      return "#{label}: #{target_problem}" if target_problem

      mapping = delegate_mapping(delegation)
      target[:attributes].each do |attr|
        source_name = mapping.fetch(attr[:name].to_s, attr[:name].to_s)
        source = command[:attributes].find { |a| a[:name].to_s == source_name }
        next if source.nil? && attr[:optional]
        return "#{label}: target argument #{attr[:name]} has no source on the door" unless source
        return "#{label}: door argument #{source_name} is a list, target wants a scalar (or vice versa) — not generated yet" if !!source[:list] != !!attr[:list]
        # Compare with `bridgeable_value_types?`, not type-name equality: Ruby copies the raw wire
        # value and lets the target's coercion decide (ADR 0045).
        unless bridgeable_value_types?(source[:type].to_s, attr[:type].to_s, value_objects_by_name)
          return "#{label}: door argument #{source_name} is #{source[:type]}, target wants #{attr[:type]} — not generated yet"
        end
        return "#{label}: optional door argument #{source_name} feeds required #{attr[:name]}" if source[:optional] && !attr[:optional]
      end
      entity[:identified_by].each do |path|
        head = path.to_s.split(".").first
        source_name = mapping.fetch(head, head)
        next if command[:attributes].any? { |a| a[:name].to_s == source_name && !a[:optional] }

        return "#{label}: the element's identity #{head} has no source on the door"
      end
      nil
    end

    # The prelude (before `dispatch`), the apply block (the closure body), and the target's
    # events, as `step_emit` answers for a delegation.
    def delegation_of(command, aggregate, value_objects_by_name, domain_name)
      delegation = delegate_of(command)
      return nil unless delegation

      entity, target = delegate_target(delegation, aggregate)
      list_attr = aggregate[:attributes].find { |a| a[:list] && a[:type] == entity[:name] }
      raise "#{entity[:name]}: no list attribute on #{aggregate[:name]} holds it" unless list_attr

      element_record   = rust_ident(entity[:name])
      target_args_name = "#{element_record}#{rust_ident(target[:name])}EntityArgs"
      aliases = delegate_mapping(delegation).map { |target_key, source_key| "(#{target_key.inspect}, #{source_key.inspect})" }
      given_specs = target[:givens].map do |given|
        "            crate::kernel::GivenSpec { description: #{rust_string_literal(given[:description])}, expr: #{ExprEmitter.emit_ast(given[:ast])}, corrects_event: None },"
      end
      ensures_specs = target[:ensures].map do |rule|
        "            crate::kernel::EnsuresSpec { description: #{rust_string_literal(rule[:description])}, expr: #{ExprEmitter.emit_ast(rule[:ast])} },"
      end
      transition = lifecycle_transition_for(target, entity)
      mutation_lines = target[:mutations].map { |m| emit_mutation_line(m, entity, target, value_objects_by_name, optional: false) }
      mutation_lines.unshift(pre_state_line) if reads_pre_state?(target[:mutations])
      mutation_lines << "        record.#{rust_ident_field(transition[:field])} = #{transition[:to_state].inspect}.to_string();" if transition && transition[:to_state]
      mutation_lines = ["        let _ = record;"] if mutation_lines.empty?

      {
        prelude: Exemplar.render(
          "delegate_prelude",
          "tmpl_aliases_placeholder()" => aliases.join(", "),
          "TmplTargetArgs" => target_args_name
        ).lines.map { |l| "    #{l}" }.join.rstrip,
        # Rendered separately: the element extraction must run after `dispatch`'s hydrate, as the
        # first closure lines.
        element: Exemplar.render(
          "delegate_element",
          "TmplElement" => element_record
        ).lines.map { |l| "        #{l}" }.join.rstrip,
        apply: Exemplar.render(
          "delegate_apply",
          "TmplRecord" => rust_ident(aggregate[:name]),
          "tmpl_list_field" => rust_ident_field(list_attr[:name]),
          "TmplElement" => element_record,
          # Bare command name: it feeds refusal text, and Ruby's `hecks_name` is never
          # entity-qualified.
          '"TmplQualifiedCommandName"' => target[:name].to_s.inspect,
          # `apply_entity_command` needs the qualified name to render `NothingToCorrect` should a
          # corrects-flagged given reach this path.
          '"TmplQualifiedName"' => "#{domain_name}::#{aggregate[:name]}".inspect,
          '"TmplAggregateName"' => aggregate[:name].to_s.inspect,
          '"TmplEntityName"' => entity[:name].to_s.inspect,
          '"TmplEntityIdentityReading"' => entity[:identified_by].join(", ").inspect,
          "tmpl_given_spec_placeholder()," => given_specs.join("\n"),
          "tmpl_transition_placeholder()" => transition_check_arg(transition),
          "tmpl_entity_mutation_lines_placeholder(record);" => mutation_lines.join("\n"),
          "tmpl_ensures_spec_placeholder()," => ensures_specs.join("\n")
        ).lines.map { |l| "        #{l}" }.join.rstrip,
        emits: target[:emits]
      }
    end

    # `command_skip_reason` with `entity` standing in for `aggregate`; both share one IR shape.
    def entity_command_skip_reason(command, entity, value_objects_by_name)
      command_skip_reason(command, entity, value_objects_by_name, creating_possible: false)
    end

    # An entity command: `kernel::dispatch_entity` ports `EntityInterpreter#call`, with no
    # `Hydrate` branch; the entity is found by `identity()` within the parent.
    def emit_entity_command(command, entity, parent_aggregate, domain_name, value_objects_by_name, aggregates_by_name,
                            process_managers: [])
      parent_record  = rust_ident(parent_aggregate[:name])
      element_record = rust_ident(entity[:name])
      cmd = rust_ident(command[:name])

      # The parent lookup and the element lookup each need their own bare name and identity
      # reading.
      aggregate_name           = parent_aggregate[:name].to_s
      parent_identity_reading  = parent_aggregate[:identified_by].join(", ")
      entity_name              = entity[:name].to_s
      entity_identity_reading  = entity[:identified_by].join(", ")

      # The parent's list attribute holding this entity, resolved at generation time.
      list_attr = parent_aggregate[:attributes].find { |a| a[:list] && a[:type] == entity[:name] }
      raise "#{entity[:name]}: no list attribute on #{parent_aggregate[:name]} holds it — unsupported_attribute_types should have caught this" unless list_attr

      list_field = rust_ident_field(list_attr[:name])
      # `EntityArgs` suffix keeps a door named after the entity command it delegates to from
      # colliding.
      args_struct_name = "#{element_record}#{cmd}EntityArgs"

      args_struct = ["pub struct #{args_struct_name} {"]
      command[:attributes].each do |attr|
        type = rust_type(attr[:type], list: attr[:list])
        type = "Option<#{type}>" if attr[:optional]
        args_struct << "    #{Exemplar.render('struct_field', 'TmplFieldType' => type, 'tmpl_field' => rust_ident_field(attr[:name]))}"
      end
      args_struct << "}"

      invariant_checks = invariant_checks_for(command, aggregates_by_name, value_objects_by_name)

      # `corrects_given_specs` is prepended as in `emit_command`; `apply_entity_command`
      # evaluates it against the parent record, never the element.
      given_specs = corrects_given_specs(command) + command[:givens].map do |given|
        "            crate::kernel::GivenSpec { description: #{rust_string_literal(given[:description])}, expr: #{ExprEmitter.emit_ast(given[:ast])}, corrects_event: None },"
      end

      ensures_specs = command[:ensures].map do |rule|
        "            crate::kernel::EnsuresSpec { description: #{rust_string_literal(rule[:description])}, expr: #{ExprEmitter.emit_ast(rule[:ast])} },"
      end

      # The entity's own lifecycle, not the parent's.
      transition = lifecycle_transition_for(command, entity)
      transition_arg =
        transition_check_arg(transition)

      # A `:corrects` mutation reaches `emit_mutation_line` unfiltered and yields a blank line, a
      # no-op; the check already ran via `corrects_given_specs`.
      # Not handled: an entity command emitting a correctable event would need the flag set on the
      # parent, but `record` in this closure is the element.
      mutation_lines = command[:mutations].map { |m| emit_mutation_line(m, entity, command, value_objects_by_name, optional: false) }
      mutation_lines.unshift(pre_state_line) if reads_pre_state?(command[:mutations])
      mutation_lines << "        record.#{rust_ident_field(transition[:field])} = #{transition[:to_state].inspect}.to_string();" if transition && transition[:to_state]
      mutation_lines = ["        let _ = record;"] if mutation_lines.empty?

      # Bare name: it feeds refusal text, which Ruby never qualifies.
      qualified_command_name = command[:name].to_s

      entity_dispatch_fn = Exemplar.render(
        "entity_dispatch_fn",
        "dispatch_entity_tmpl" => "dispatch_entity_#{entity[:name].downcase}_#{dispatch_fn_name(cmd)}",
        "TmplRecord" => parent_record,
        "TmplArgs" => args_struct_name,
        "tmpl_deref_params_placeholder: ()" => DEREF_PARAMS.join(", "),
        "tmpl_invariant_check_placeholder()?;" => invariant_checks.join("\n"),
        "let tmpl_eval_fielded = tmpl_with_references_placeholder();" => with_references_binding,
        "&tmpl_eval_fielded," => "&with_references,",
        "let tmpl_seed_projections = tmpl_seed_projections_placeholder();" => seed_projections_binding(parent_aggregate),
        "tmpl_seed_projections," => "seed_projections,",
        "tmpl_list_field" => list_field,
        "TmplElement" => element_record,
        '"TmplQualifiedCommandName"' => qualified_command_name.inspect,
        '"TmplQualifiedName"' => "#{domain_name}::#{parent_aggregate[:name]}".inspect,
        '"TmplAggregateName"' => aggregate_name.inspect,
        '"TmplParentIdentityReading"' => parent_identity_reading.inspect,
        '"TmplEntityName"' => entity_name.inspect,
        '"TmplEntityIdentityReading"' => entity_identity_reading.inspect,
        "tmpl_given_spec_placeholder()," => given_specs.join("\n"),
        "tmpl_transition_placeholder()" => transition_arg,
        "tmpl_entity_mutation_lines_placeholder(record);" => mutation_lines.join("\n"),
        "tmpl_ensures_spec_placeholder()," => ensures_specs.join("\n"),
        "tmpl_invariants_placeholder()" => "#{invariants_fn_name(parent_aggregate)}()",
        "tmpl_emit_placeholder()" => command[:emits].map(&:inspect).join(", ")
      )

      [
        emit_fielded_flat(args_struct_name, command[:attributes], value_objects_by_name),
        "#[derive(Debug, Clone)]\n#{args_struct.join("\n")}",
        emit_to_json_flat(args_struct_name, command[:attributes], value_objects_by_name, sparse: true),
        # Allowlist matches the aggregate-command call site plus the entity's own identity head
        # (`extra_identity_heads:`).
        emit_from_json_flat(args_struct_name, command[:attributes], value_objects_by_name,
                            unknown_argument_allowlist: command_argument_allowlist(
                              parent_aggregate, command, process_managers,
                              extra_identity_heads: entity[:identified_by].map { |path| path.split(".").first }
                            ),
                            command_name: command[:name].to_s, absent_argument_check: true,
                            interleave_checks: true, aggregates_by_name: aggregates_by_name),
        # Argument gates run in `EntityStep::ORDER`; see `emit_argument_gates` (json_codec.rb).
        emit_argument_gates(args_struct_name, command[:name].to_s, command[:attributes],
                            command_argument_allowlist(
                              parent_aggregate, command, process_managers,
                              extra_identity_heads: entity[:identified_by].map { |path| path.split(".").first }
                            )),
        entity_dispatch_fn,
      ].join("\n\n")
    end

    # A command owned by an entity nested two levels deep. The second hop is another
    # `apply_entity_command` inside the first hop's `apply_mutations` closure.
    # The generated function takes plain `&str` ids per hop, so flat-args and routed callers
    # share it. The outer hop has no given/ensures/transition; those belong to the inner call.
    def emit_nested_entity_command(command, nested, entity, parent_aggregate, domain_name, value_objects_by_name, aggregates_by_name,
                                   process_managers: [])
      parent_record = rust_ident(parent_aggregate[:name])
      entity_record = rust_ident(entity[:name])
      nested_record = rust_ident(nested[:name])
      cmd = rust_ident(command[:name])

      aggregate_name          = parent_aggregate[:name].to_s
      parent_identity_reading = parent_aggregate[:identified_by].join(", ")
      entity_name             = entity[:name].to_s
      entity_identity_reading = entity[:identified_by].join(", ")
      nested_name             = nested[:name].to_s
      nested_identity_reading = nested[:identified_by].join(", ")

      # The two list attributes the chain walks: the parent's holding `entity`, and
      # `entity`'s holding `nested`.
      list_attr1 = parent_aggregate[:attributes].find { |a| a[:list] && a[:type] == entity[:name] }
      raise "#{entity[:name]}: no list attribute on #{parent_aggregate[:name]} holds it — unsupported_attribute_types should have caught this" unless list_attr1

      list_attr2 = entity[:attributes].find { |a| a[:list] && a[:type] == nested[:name] }
      raise "#{nested[:name]}: no list attribute on #{entity[:name]} holds it — unsupported_attribute_types should have caught this" unless list_attr2

      list_field1 = rust_ident_field(list_attr1[:name])
      list_field2 = rust_ident_field(list_attr2[:name])

      # `NestedEntityArgs` suffix, distinct from `Args` and `EntityArgs`, for the same reason.
      args_struct_name = "#{nested_record}#{cmd}NestedEntityArgs"

      args_struct = ["pub struct #{args_struct_name} {"]
      command[:attributes].each do |attr|
        type = rust_type(attr[:type], list: attr[:list])
        type = "Option<#{type}>" if attr[:optional]
        args_struct << "    #{Exemplar.render('struct_field', 'TmplFieldType' => type, 'tmpl_field' => rust_ident_field(attr[:name]))}"
      end
      args_struct << "}"

      invariant_checks = invariant_checks_for(command, aggregates_by_name, value_objects_by_name)

      given_specs = command[:givens].map do |given|
        "                    crate::kernel::GivenSpec { description: #{rust_string_literal(given[:description])}, expr: #{ExprEmitter.emit_ast(given[:ast])}, corrects_event: None },"
      end

      ensures_specs = command[:ensures].map do |rule|
        "                    crate::kernel::EnsuresSpec { description: #{rust_string_literal(rule[:description])}, expr: #{ExprEmitter.emit_ast(rule[:ast])} },"
      end

      # The nested entity's own lifecycle.
      transition = lifecycle_transition_for(command, nested)
      transition_arg = transition_check_arg(transition)

      mutation_lines = command[:mutations].map { |m| emit_mutation_line(m, nested, command, value_objects_by_name, optional: false) }
      mutation_lines.unshift(pre_state_line) if reads_pre_state?(command[:mutations])
      mutation_lines << "                record.#{rust_ident_field(transition[:field])} = #{transition[:to_state].inspect}.to_string();" if transition && transition[:to_state]
      mutation_lines = ["                let _ = record;"] if mutation_lines.empty?

      # Bare name, as in `emit_entity_command`.
      qualified_command_name = command[:name].to_s
      fn_name = "dispatch_entity_#{entity[:name].downcase}_#{nested[:name].downcase}_#{dispatch_fn_name(cmd)}"

      # The hop-2 call gets the root aggregate's qualified name only so it compiles; `corrects`
      # admissibility is not generated at this depth, since the inner `record` is the hop-1 entity,
      # not the root.
      # The trailing `parent_in_args` literal is `true`; `rust/codegen/src/commands.rs` needs the
      # same value (`spec/project_rust_pipeline_spec.rb` compares byte for byte).
      nested_dispatch_fn = <<~RUST
        pub fn #{fn_name}(
            repo: &mut impl crate::kernel::Repository<#{parent_record}>, parent_id: &str, hop1_id: &str, hop1_wants: &str,
            hop2_id: &str, hop2_wants: &str, args: #{args_struct_name}, mutations: &mut Vec<crate::kernel::MutationRecord>,
            owner_deref: Vec<(&'static str, crate::kernel::DerefNode)>, command_deref: Vec<(&'static str, crate::kernel::DerefNode)>,
        ) -> crate::kernel::DispatchResult<#{parent_record}> {
        #{invariant_checks.join("\n")}
            #{with_references_binding}
            #{seed_projections_binding(parent_aggregate)}

            crate::kernel::dispatch_entity(
                repo,
                parent_id,
                |r: &#{parent_record}| &r.#{list_field1},
                |r: &mut #{parent_record}| &mut r.#{list_field1},
                |el: &#{entity_record}| el.identity() == hop1_id,
                #{qualified_command_name.inspect},
                #{"#{domain_name}::#{parent_aggregate[:name]}".inspect},
                #{aggregate_name.inspect},
                #{parent_identity_reading.inspect},
                #{entity_name.inspect},
                #{entity_identity_reading.inspect},
                hop1_wants,
                &with_references,
                &[],
                None,
                |nested_owner: &mut #{entity_record}| {
                    crate::kernel::apply_entity_command(
                        nested_owner,
                        hop1_id,
                        |r: &#{entity_record}| &r.#{list_field2},
                        |r: &mut #{entity_record}| &mut r.#{list_field2},
                        |el: &#{nested_record}| el.identity() == hop2_id,
                        #{qualified_command_name.inspect},
                        #{"#{domain_name}::#{aggregate_name}".inspect},
                        #{aggregate_name.inspect},
                        #{nested_name.inspect},
                        #{nested_identity_reading.inspect},
                        hop2_wants,
                        &with_references,
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
                        true,
                    )
                },
                &[],
                &#{invariants_fn_name(parent_aggregate)}(),
                &[#{command[:emits].map(&:inspect).join(', ')}],
                args.to_json(),
                mutations,
                seed_projections,
            )
        }
      RUST

      [
        emit_fielded_flat(args_struct_name, command[:attributes], value_objects_by_name),
        "#[derive(Debug, Clone)]\n#{args_struct.join("\n")}",
        emit_to_json_flat(args_struct_name, command[:attributes], value_objects_by_name, sparse: true),
        # Both hops' identity heads are allowed, matching `ctx.chain.flat_map(&:identity_heads)`
        # (entity_interpreter.rb).
        emit_from_json_flat(args_struct_name, command[:attributes], value_objects_by_name,
                            unknown_argument_allowlist: command_argument_allowlist(
                              parent_aggregate, command, process_managers,
                              extra_identity_heads: (entity[:identified_by] + nested[:identified_by]).map { |path| path.split(".").first }
                            ),
                            command_name: command[:name].to_s, absent_argument_check: true,
                            interleave_checks: true, aggregates_by_name: aggregates_by_name),
        # Argument gates, as in the one-hop entity command above.
        emit_argument_gates(args_struct_name, command[:name].to_s, command[:attributes],
                            command_argument_allowlist(
                              parent_aggregate, command, process_managers,
                              extra_identity_heads: (entity[:identified_by] + nested[:identified_by]).map { |path| path.split(".").first }
                            )),
        nested_dispatch_fn,
      ].join("\n\n")
    end
  end
end
