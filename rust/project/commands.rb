module RustProjection
  module Projector
    module_function

    # The `transition:` argument `dispatch`/`dispatch_entity` take.
    # `None` covers two different "no check" cases on purpose: no
    # transition row at all, and an UNCONSTRAINED row (`from: nil` —
    # admits from any state). The kernel refuses whatever `from_states`
    # does not contain, so an unconstrained transition emitted as an
    # EMPTY slice would refuse every state instead of admitting every
    # state — the exact inversion of what the declaration says.
    def transition_check_arg(transition)
      return "None" if transition.nil? || transition[:unconstrained]

      "Some(crate::kernel::TransitionCheck { field: #{transition[:field].inspect}, " \
        "from_states: &[#{transition[:from_states].map(&:inspect).join(', ')}] })"
    end

    # `owner_deref`/`command_deref` — the two EXTRA parameters every
    # generated `dispatch_*`/`dispatch_entity_*` function now takes,
    # alongside its typed `args`, carrying whatever cross-aggregate
    # dereference (`customer.status`, `parent.account.customer.status`)
    # its OWN `given`/`ensures` clauses might need — already resolved,
    # by the ROUTER (`registry.rb`'s own `aggregate_arms`/`entity_arms`),
    # into plain owned data before this function is ever called
    # (`reference_lookup.rs`'s own header on why that has to happen
    # there, not here). Shared between `emit_command`/`emit_entity_command`
    # — identical shape either way, the same way `invariant_checks_for`
    # already is.
    DEREF_PARAMS = ["owner_deref: Vec<(&'static str, crate::kernel::DerefNode)>",
                     "command_deref: Vec<(&'static str, crate::kernel::DerefNode)>"].freeze

    # The ONE line every generated `dispatch_*`/`dispatch_entity_*` body
    # adds — `crate::kernel::WithReferences`, read directly
    # (reference_lookup.rs): `command_deref` wins ties (an entity
    # command's own `"parent"` entry lives in THAT list, appended by the
    # router), the untouched typed `args` struct is checked second,
    # `owner_deref` (an aggregate's own STORED reference fields) is
    # checked last — the exact precedence `CommandRules::Admissibility
    # #enforce_givens`'s own three-way `.merge` chain already has.
    def with_references_binding
      "let with_references = crate::kernel::WithReferences { command_deref: &command_deref, args: &args, owner_deref: &owner_deref };"
    end

    # THE SYNCHRONOUS HALF OF `projects` (S12, ADR 0025) — the ONE line
    # every generated `dispatch_*`/`dispatch_entity_*` body adds right
    # after `with_references_binding`, mirroring that same line's own
    # shape: `crate::kernel::seeded_projections`, read directly
    # (reference_lookup.rs), off the SAME `with_references` just built —
    # no new router-level parameter needed the way `owner_deref`/
    # `command_deref` themselves are, since a projected field's own
    # source (whichever reference `with_references` already resolves)
    # is exactly what `owner_deref`/`command_deref` exist to answer.
    # `#{AGGREGATE}_PROJECTED_FIELDS` (types.rb's own `emit_projected_
    # field_table`) is always emitted, even empty — `seeded_projections`
    # over an empty spec list is a real, cheap no-op, not a branch this
    # generator needs to special-case away.
    def seed_projections_binding(aggregate)
      table = screaming_snake(aggregate[:name])
      "let seed_projections = crate::kernel::seeded_projections(&with_references, #{table}_PROJECTED_FIELDS);"
    end

    def command_skip_reason(command, aggregate, value_objects_by_name, creating_possible: true)
      unsupported_ops = command[:mutations].reject { |m| %w[append set increment decrement multiply clamp delegate corrects].include?(m[:op].to_s) }.map { |m| m[:op] }.uniq
      return "sets op(s) #{unsupported_ops.join(', ')} not generated yet (only append/set/increment/decrement/multiply/clamp/delegate/corrects are)" if unsupported_ops.any?

      corrects = corrects_of(command)
      return "corrects #{corrects[:target]}, reverses: true — the derived append/remove-reversal shape is a real, separate gap Ruby's own authors haven't finished designing (AggregateBuilder#seal_correction_targets's own comment) — not generated yet" if corrects && corrects_reverses?(corrects)

      delegate_problem = delegate_skip_reason(command, aggregate, value_objects_by_name)
      return delegate_problem if delegate_problem

      append_problems = append_field_problems(command, aggregate, value_objects_by_name)
      return "sets append field(s): #{append_problems.join('; ')}" if append_problems.any?
      state_problems = state_source_problems(command, aggregate, value_objects_by_name)
      return "sets state source(s): #{state_problems.join('; ')}" if state_problems.any?

      lifecycle_field = aggregate[:lifecycle] && aggregate[:lifecycle][:field].to_s
      target_type_for = ->(target) { target.to_s == lifecycle_field ? "String" : aggregate[:attributes].find { |a| a[:name].to_s == target.to_s }&.dig(:type) }

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
        next false unless m[:op].to_s == "set" && m[:source][:kind] == "literal"

        !literal_set_bridgeable?(m[:source][:value], target_type_for.call(m[:target]), value_objects_by_name)
      end.map { |m| m[:target] }
      return "sets to: a literal that doesn't bridge to the target's type (#{literal_set_targets.join(', ')}) — not generated yet" if literal_set_targets.any?

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
        next false unless m[:op].to_s == "set" && m[:source][:kind] == "argument"

        target_type = target_type_for.call(m[:target])
        source_type = command[:attributes].find { |a| a[:name].to_s == m[:source][:name] }&.dig(:type)
        target_type && source_type && !bridgeable_value_types?(source_type, target_type, value_objects_by_name)
      end.map { |m| m[:target] }
      return "sets :#{mismatched_sets.join(', ')} sources an argument no single-field rewrap can bridge to the target's type — not generated yet" if mismatched_sets.any?

      # `:increment`/`:decrement`/`:multiply` — Ruby's real
      # `arithmetic_value_object`/`multiply` (command_rules/arithmetic.rb,
      # read directly) both find the ONE field that's `Integer` in both the
      # target VO and the (already target-type-coerced) amount, and change
      # only that field — `multiply` differs from `arithmetic_value_object`
      # ONLY in which Proc does the combining (`{ |c, a| c * a }` vs `current
      # + sign*amount`), never in which field is eligible or how the amount
      # is resolved, so this generator's own eligibility check and amount-
      # resolution are shared across all three ops, matching Ruby's own
      # shared `unwrap_single_numeric_field`/shared-numeric-field-matching
      # machinery. Bridgeable when the target names such a field AND the
      # amount resolves to a raw integer expression — `arithmetic_amount_
      # expr`, above, is the same "can we generate this" / "here's how"
      # pairing `bridgeable_value_types?`/`value_rhs` already use for `:set`.
      arithmetic_targets = command[:mutations].select { |m| %w[increment decrement multiply].include?(m[:op].to_s) }
      unsupported_arithmetic = arithmetic_targets.reject do |m|
        target = arithmetic_target_field(m, aggregate, value_objects_by_name)
        target && arithmetic_amount_expr(m[:source], command, value_objects_by_name, target[1])
      end.map { |m| m[:target] }
      return "sets :#{unsupported_arithmetic.join(', ')} increment/decrement/multiply amount or target field isn't bridgeable — not generated yet" if unsupported_arithmetic.any?

      # `:clamp` — Ruby's real `Arithmetic#clamp` (read directly): "a
      # genuinely different shape [from #arithmetic/#multiply] -- its
      # source is always a literal [min, max] pair, never an argument
      # reference -- and it bounds the CURRENT value rather than
      # combining it with an amount." No `arithmetic_amount_expr` to
      # resolve at all — the ELIGIBLE TARGET half is identical to
      # increment/decrement/multiply (`arithmetic_target_field`, the
      # same Integer-VO-field scope, not widened here either), but the
      # bounds themselves need their own check: a literal two-element
      # Array of Integers, exactly the shape `classified_source` always
      # produces for a `clamp:` mutation (`clamp_bounds_ints`, below).
      clamp_targets = command[:mutations].select { |m| m[:op].to_s == "clamp" }
      unsupported_clamp = clamp_targets.reject do |m|
        arithmetic_target_field(m, aggregate, value_objects_by_name) && clamp_bounds_ints(m[:source])
      end.map { |m| m[:target] }
      return "sets :#{unsupported_clamp.join(', ')} clamp target field or bounds isn't bridgeable — not generated yet" if unsupported_clamp.any?

      optional_problems = optional_source_mismatches(command, aggregate, value_objects_by_name, creating_possible: creating_possible)
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
    def optional_source_mismatches(command, aggregate, value_objects_by_name, creating_possible: true)
      lifecycle_field = aggregate[:lifecycle] && aggregate[:lifecycle][:field].to_s
      problems = []

      # An ENTITY command never creates — it acts on one already-addressed
      # element — so its own (optional) identity argument (a chess
      # `Pawn.Promote`'s `id`, declared optional so the crowning policy's
      # projection may name it) is not an identity source at all, and
      # `creates_owner?`'s bare-name heuristic must not read it as one:
      # `creating_possible: false` from `entity_command_skip_reason`.

      # `identified_by` (creating commands only — `identity_components`,
      # mutations.rb, is never called for an acting command) is read
      # straight off the command's own arguments to build the record's
      # `id:` at creation time — never Option-wrapped, since a record has
      # no "identity absent" state. An optional argument feeding it
      # (`Member.Declare`'s own `position`) isn't a `sets` mutation at
      # all, so the checks below never see it; caught here instead.
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
          # A LIST target is exempt — a record's own list field is
          # EITHER plain `Vec<T>` (`emit_record`'s default rule, resolved
          # cleanly via `.unwrap_or_default()`) OR `Option<Vec<T>>`
          # (`list_attr_creation_optional?` — `CardPayment.tags`, resolved
          # cleanly via a straight assignment) — `emit_mutation_line`'s
          # `:set` branch already handles both. Not a real mismatch to
          # skip over either way.
          next if target_attr && target_attr[:list]

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

    # Shared by `emit_command`/`emit_entity_command` — identical logic
    # either way, since an entity command's own `command[:attributes]` has
    # the exact same shape an aggregate command's does. Two independent
    # concerns per attribute: the EXISTING nested-VO-invariant recursion
    # (`args.field.check_invariants()?`, unchanged), and a command/entity-
    # command argument's own usage-level `admits:` constraint
    # (`constraints.rb`) — the OTHER door from `types.rb`'s own value-
    # object-field-level check.
    #
    # `pattern:` at THIS usage-level door is deliberately NOT checked —
    # docs/decisions/0043/0051 found, by tracing `Runtime::
    # CommandInterpreter`'s full dispatch pipeline exhaustively and
    # confirming live against Ruby's real interpreter, that a bare
    # command-attribute's OWN `pattern:` is NEVER enforced by Ruby: `Value#
    # check_patterns` fires only from `build`, which fires only when the
    # attribute's type resolves to an actual value object and gets
    # rebuilt — a usage-level `pattern:` on a scalar command argument has
    # no VO to build at all, so it is silently accepted, whether or not
    # that argument is ever a mutation source. Generating a check here
    # made Rust STRICTER than Ruby (the opposite direction from every
    # other gap this plan closed) — removed rather than kept, per ADR
    # 0010 (Ruby is the reference implementation; Rust conforms to it,
    # not the other way around). `admits:` at this SAME door is genuinely
    # different: it fires unconditionally from `normalize_args`'s own
    # `admit_declared_set` call, for every declared argument present in
    # the payload, regardless of mutation usage — confirmed enforced,
    # kept exactly as it was.
    #
    # `attr[:list]` attributes are skipped for the `admits:` check too —
    # `admit_declared_set` is reached only via `Value.for_attribute`'s
    # SCALAR branch (a list attribute returns early into
    # `hydrate_entity_list` instead, before ever reaching it) — so a list
    # attribute's own `admits:`/`pattern:` is unenforced by Ruby exactly
    # like a scalar's `pattern:` is; no check is generated for either, on
    # any list attribute, matching that silent acceptance rather than
    # refusing to generate the command at all (this file used to refuse
    # via `constraint_list_problems`, since removed — real, confirmed
    # non-enforcement isn't a gap to name, it's the actual answer).
    def invariant_checks_for(command, aggregates_by_name, value_objects_by_name)
      command[:attributes].flat_map do |attr|
        field = rust_ident_field(attr[:name])
        lines = []

        unless attr[:list]
          # RAW FIELD EXPRESSION, UNCONDITIONALLY — `types.rb`'s own value-
          # object-field door (the OTHER caller of `emit_admits_check`)
          # passes `self.#{field}` raw and never wraps the result itself,
          # trusting `constraints.rb`'s own internal `optional_scalar_expr`/
          # `wrap_if_optional` to do the ENTIRE optional-handling, self-
          # contained.
          value_expr = "args.#{field}"
          constraint = emit_admits_check(value_expr, attr, aggregates_by_name, value_objects_by_name)
          lines << "        #{constraint}" if constraint
        end

        if value_objects_by_name.key?(attr[:type]) && !value_objects_by_name[attr[:type]][:closed_set]
          lines << if attr[:optional]
            attr[:list] ? "        if let Some(items) = &args.#{field} { for item in items { item.check_invariants()?; } }" : "        if let Some(v) = &args.#{field} { v.check_invariants()?; }"
          else
            attr[:list] ? "        for item in &args.#{field} { item.check_invariants()?; }" : "        args.#{field}.check_invariants()?;"
          end
        end

        lines
      end
    end

    # ── ONE emitter for every command shape kernel::dispatch can run —
    # creating or acting, with or without givens or an append mutation.
    # What used to be emit_create_command's implicit, name-matched
    # `assign_creation_attributes` step now lives inside the `Hydrate::Create`
    # `build` closure; what used to be emit_act_command's given/mutation
    # generation is now just data (`GivenSpec`s, a closure) handed to
    # kernel::dispatch instead of hand-assembled control flow.
    def emit_command(command, aggregate, domain_name, value_objects_by_name, aggregates_by_name)
      record = rust_ident(aggregate[:name])
      cmd    = rust_ident(command[:name])
      creates = creates_owner?(aggregate, command, value_objects_by_name)
      identity = identity_components(aggregate, command)
      identity_extra_params = identity.filter_map { |c| c[:param] }

      # `aggregate_name`/`identity_reading` — the bare (never domain-
      # qualified) name `CommandInterpreter#hydrate`'s own refusal wording
      # quotes, and its declared identity reading (`Identity.reading`,
      # identity.rb: `construct.identity_paths.join(", ")`) — the SAME
      # join `domain_generator.rb`'s own `reference_checks` already
      # computes for `reference_target_missing`'s `heads`. Needed by BOTH
      # `creating_duplicate` and `record_missing` inside `kernel::dispatch`
      # regardless of whether THIS command creates or acts, so this is
      # computed once here rather than duplicated in the `if creates`
      # branch below.
      aggregate_name    = aggregate[:name].to_s
      identity_reading  = aggregate[:identified_by].join(", ")

      # `struct_field` reused directly (not the whole `plain_struct`
      # wrapper, types.rb) — an Args struct's own surrounding derive is
      # `#[derive(Debug, Clone)]`, no `PartialEq` (never compared),
      # different from `plain_struct`'s baked-in one, so only the ONE
      # already-proven-valid piece that's actually identical (a single
      # field declaration line) is worth sharing here.
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
        args_struct << "    #{Exemplar.render('struct_field', 'TmplFieldType' => type, 'tmpl_field' => rust_ident_field(attr[:name]))}"
      end
      args_struct << "}"

      invariant_checks = invariant_checks_for(command, aggregates_by_name, value_objects_by_name)

      given_specs = corrects_given_specs(command) + command[:givens].map do |given|
        "            crate::kernel::GivenSpec { description: #{rust_string_literal(given[:description])}, expr: #{ExprEmitter.emit_predicate(given[:canonical])}, corrects_event: None },"
      end

      ensures_specs = command[:ensures].map do |rule|
        "            crate::kernel::EnsuresSpec { description: #{rust_string_literal(rule[:description])}, expr: #{ExprEmitter.emit_predicate(rule[:canonical])} },"
      end

      transition = lifecycle_transition_for(command, aggregate)
      transition_arg =
        transition_check_arg(transition)

      mutation_lines = command[:mutations].reject { |m| m[:op].to_s == "corrects" }
                                          .map { |m| emit_mutation_line(m, aggregate, command, value_objects_by_name) }
      mutation_lines.concat(corrects_flag_mutation_lines(command, aggregate))
      # advance_lifecycle: unconditional once a transition applies at all —
      # see kernel/dispatch.rs's TransitionCheck comment for why this lives
      # here, as one more line in the SAME closure, rather than as its own
      # dispatch() step. Covers commands with no explicit sets on the
      # lifecycle field (Banking's Freeze/Unfreeze have none) — Purchase's
      # own explicit sets above already covers itself, redundantly.
      mutation_lines << "        record.#{rust_ident_field(transition[:field])} = #{transition[:to_state].inspect}.to_string();" if transition && transition[:to_state]
      mutation_lines = ["        let _ = record;"] if mutation_lines.empty? # nothing to apply — silence the unused-param warning
      delegation = delegation_of(command, aggregate, value_objects_by_name)
      if delegation
        raise "#{command[:name]}: a creating command cannot delegate — nothing exists to delegate to" if creates

        mutation_lines = [delegation[:apply]]
      end
      prelude   = delegation ? delegation[:prelude] : ""
      payload   = delegation ? "delegate_facts.clone()," : "args.to_json(),"
      emits_out = delegation ? delegation[:emits] : command[:emits]

      if creates
        # `projected_field_pseudo_attributes` — a `projects` field is
        # never a command argument (never `matched` below), so this
        # always falls to the plain `None,` branch: correct, since
        # `seed_projections` (this same dispatch's own trailing step,
        # right before save) is what actually populates it, not
        # anything a creating command's own args could set.
        record_fields = (aggregate[:attributes] + Projector.projected_field_pseudo_attributes(aggregate)).map do |attr|
          matched = command[:attributes].find { |a| a[:name] == attr[:name] }
          field = rust_ident_field(attr[:name])
          if matched && matched[:optional]
            # The COMMAND's own attribute is `Option<T>` now. A scalar/VO
            # record field is ALREADY `Option<T>` unconditionally, so the
            # optional arg's own `Option<T>` assigns straight across —
            # wrapping it in another `Some(...)` would be
            # `Option<Option<T>>`, not this record field's type. A
            # list-typed record field is the SAME shape ONLY when
            # `list_attr_creation_optional?` also Option-wrapped it
            # (`CardPayment.tags`, types.rb's own matching check) —
            # otherwise (emit_record's default rule: lists are never
            # Option-wrapped) it needs unwrapping with the same `[]`
            # fallback `default_for` gives an UNMATCHED list attribute.
            if attr[:list] && !list_attr_creation_optional?(aggregate, attr[:name], value_objects_by_name)
              "            #{field}: args.#{field}.clone().unwrap_or_default(),"
            elsif attr[:list] || matched[:type] == attr[:type]
              "            #{field}: args.#{field}.clone(),"
            else
              # A CROSS-AGGREGATE argument, same name as the owner's own
              # field but a DIFFERENT declared type — `bridging.rb`'s own
              # header (`SafeDepositBox.Rent`'s `attribute :customer,
              # CustomerNumber`, bridged into the owner's own `customer:
              # Reference<Customer>` field). A blind `.clone()` here
              # assumed the two types were always identical, which this
              # generic name-match never actually required.
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

        hydrate = <<~RUST.rstrip
          crate::kernel::Hydrate::Create {
                  id: #{build_identity_expr(identity)},
                  build: Box::new(|| #{record} {
          #{record_fields.join("\n")}
                  }),
              }
        RUST
        fn_signature = (["repo: &mut impl crate::kernel::Repository<#{record}>"] + identity_extra_params +
                        ["args: #{cmd}Args", "mutations: &mut Vec<crate::kernel::MutationRecord>", *DEREF_PARAMS]).join(", ")
      else
        hydrate = %(crate::kernel::Hydrate::Act { id: id.to_string() })
        fn_signature = (["repo: &mut impl crate::kernel::Repository<#{record}>", "id: &str", "args: #{cmd}Args",
                          "mutations: &mut Vec<crate::kernel::MutationRecord>", *DEREF_PARAMS]).join(", ")
      end

      dispatch_fn = Exemplar.render(
        "dispatch_fn",
        "repo: &mut impl crate::kernel::Repository<TmplRecord>, id: &str, args: TmplArgs, mutations: &mut Vec<crate::kernel::MutationRecord>" => fn_signature,
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
        "tmpl_emit_placeholder()" => emits_out.map(&:inspect).join(", "),
        "args.to_json()," => payload
      )

      "#{emit_fielded_flat("#{cmd}Args", command[:attributes], value_objects_by_name)}\n\n#[derive(Debug, Clone)]\n#{args_struct.join("\n")}\n\n#{dispatch_fn}"
    end

    # `corrects "EventName", reason: "..."` — `CommandRules::Admissibility
    # #enforce_correction_target`, read directly: "structural, before the
    # declared givens... has THIS record actually [emitted the named
    # event] yet." Ported as a synthetic, PREPENDED GivenSpec (see
    # `corrects_given_specs`) whose `expr` reads a per-record boolean
    # field this same generator also arranges to set — `corrects_flag_field`
    # names it, `corrects_flag_targets` (domain_generator.rb) finds every
    # aggregate needing one, and `mutations.rb`'s own corrects-flag mutation
    # line sets it whenever a command emitting the named event succeeds.
    #
    # `reverses: true` is the SEPARATE, harder derived-mutation shape
    # `AggregateBuilder#seal_correction_targets`'s own comment (read
    # directly) says Ruby's OWN authors have not finished designing
    # ("append/remove reversal LOOK symmetric but are not reliably so...
    # a real gap, left for a follow-on round") — refused here rather than
    # guessed at, matching that same deferral.
    def corrects_of(command) = command[:mutations].find { |m| m[:op].to_s == "corrects" }

    def corrects_reverses?(mutation) = !!(mutation[:source].is_a?(Hash) && mutation[:source][:value].is_a?(Hash) && mutation[:source][:value][:reverses])

    # `emitted_fee_applied`, from `"FeeApplied"` — a plain, deterministic
    # snake_case rendering (never bluebook-author-visible; this is a
    # SYNTHETIC field name, not a spelling the language exposes), shared
    # between the record's own struct field and every reader/writer of it.
    def corrects_flag_field(event_name) = "emitted_#{event_name.to_s.gsub(/([a-z0-9])([A-Z])/, '\1_\2').downcase}"

    def corrects_given_specs(command)
      corrects = corrects_of(command)
      return [] unless corrects

      event_name = corrects[:target].to_s
      ["            crate::kernel::GivenSpec { description: \"\", " \
       "expr: crate::kernel::Expr::Lookup(#{corrects_flag_field(event_name).inspect}), " \
       "corrects_event: Some(#{event_name.inspect}) },"]
    end

    # Every event name ANY command on this aggregate names in a `corrects`
    # mutation — the set a record needs its own flag field for at all.
    # Aggregate-wide (not per-command), the same scope `AggregateBuilder
    # #seal_correction_targets`'s own build-time check already reads
    # (`command_skip_reason`'s own header on that check's other half).
    def correctable_event_names(aggregate)
      aggregate[:commands].flat_map { |c| c[:mutations] }
                          .select { |m| m[:op].to_s == "corrects" }
                          .map { |m| m[:target].to_s }.uniq
    end

    # `extra_fields:` entries for `corrects`'s own per-record flag fields
    # (`emit_to_json_flat`/`emit_from_json_state`, json_codec.rb) — the
    # SAME mechanism `lifecycle_extra_field` already uses for the
    # lifecycle field, reused rather than duplicated so this rides along
    # with the record's own ordinary JSON round-trip automatically (and
    # therefore with whatever generic snapshot mechanism a host already
    # persists that JSON through — `rust/host`'s own `hecks_lambda_
    # snapshot.seed jsonb` column, confirmed by reading `journal.rs`
    # directly, needs no schema change of its own for this).
    def corrects_extra_fields(aggregate)
      correctable_event_names(aggregate).map do |ev|
        field = corrects_flag_field(ev)
        deserialize_rhs = "match v.require(#{field.inspect}, #{aggregate[:name].to_s.inspect})? { " \
          "crate::kernel::Json::Bool(b) => *b, " \
          "_ => return Err(#{json_type_error(aggregate[:name].to_s, field, 'a boolean')}) }"
        [field, "crate::kernel::Json::Bool(self.#{field})", deserialize_rhs]
      end
    end

    # THE OTHER HALF of `corrects` — read directly, `MutationApplier#apply`'s
    # own `:corrects` branch is a no-op (nothing here targets a field on
    # the SAME command's own instance), but a LATER command's own
    # `enforce_correction_target` needs to observe that this event
    # happened at all. Ruby's real `@registry.event_log` (a full, ambient
    # history) makes this free; this generator has no such history to
    # consult, so it stamps the SAME fact forward onto the record itself,
    # at the moment the correctable event is actually emitted — an
    # ADDITIVE mutation line, appended after every declared one, for
    # every command whose own `emits` list names an event some `corrects`
    # mutation elsewhere on this aggregate targets.
    def corrects_flag_mutation_lines(command, aggregate)
      correctable = correctable_event_names(aggregate)
      Array(command[:emits]).map(&:to_s).uniq.select { |name| correctable.include?(name) }
                            .map { |name| "        record.#{corrects_flag_field(name)} = true;" }
    end

    # `delegates_to "Entity.Command", with: { … }` — the `:delegate`
    # mutation (`CommandInterpreter#step_delegate_to_entity`, read
    # directly; the exemplar's own `delegate_prelude`/`delegate_apply`
    # comment has the shape). One per command, and the command's only
    # mutation: the door's entire effect IS the target entity command,
    # run on the record inside the door's own `dispatch` closure.
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
        # `bridgeable_value_types?`, not exact type-name equality — the
        # SAME question `mutation_set_rhs` already answers for a `sets`
        # RHS, and the right one here too: `with_aliases`/`from_json`
        # (`CommandInterpreter#step_delegate_to_entity`, read directly —
        # `ctx.args.merge(delegation.source.to_h { |target_key,
        # source_key| [target_key, ctx.args[source_key]] })`) copies the
        # door's OWN raw wire value under the target's key and lets the
        # TARGET's own coercion (`Value.for`) make sense of it — Ruby
        # never once compares the two ARGUMENTS' declared type names to
        # each other. Confirmed empirically (docs/decisions/0045): a
        # purpose-built door whose own argument was a differently-named
        # single-field VO wrapping the identical scalar as the target's
        # own declared type dispatched correctly through real Ruby, no
        # refusal — exact-name equality was refusing something Ruby
        # genuinely supports. `bridgeable_value_types?` is the already-
        # audited "is copying source into target semantically sound"
        # check (field-name alignment for two VOs, closed-set member
        # coverage, scalar-representation equivalence) — exactly the
        # question the JSON-level alias-then-deserialize mechanism cares
        # about, since it never does a typed Rust-level field copy either.
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

    # The three rendered pieces a delegating door needs: the prelude
    # (before `dispatch`), the apply block (its whole closure body), and
    # the events it emits — the TARGET's, exactly as `step_emit` answers
    # `ctx.delegated_events` in place of the door's own.
    def delegation_of(command, aggregate, value_objects_by_name)
      delegation = delegate_of(command)
      return nil unless delegation

      entity, target = delegate_target(delegation, aggregate)
      list_attr = aggregate[:attributes].find { |a| a[:list] && a[:type] == entity[:name] }
      raise "#{entity[:name]}: no list attribute on #{aggregate[:name]} holds it" unless list_attr

      element_record   = rust_ident(entity[:name])
      target_args_name = "#{element_record}#{rust_ident(target[:name])}EntityArgs"
      aliases = delegate_mapping(delegation).map { |target_key, source_key| "(#{target_key.inspect}, #{source_key.inspect})" }
      given_specs = target[:givens].map do |given|
        "            crate::kernel::GivenSpec { description: #{rust_string_literal(given[:description])}, expr: #{ExprEmitter.emit_predicate(given[:canonical])}, corrects_event: None },"
      end
      ensures_specs = target[:ensures].map do |rule|
        "            crate::kernel::EnsuresSpec { description: #{rust_string_literal(rule[:description])}, expr: #{ExprEmitter.emit_predicate(rule[:canonical])} },"
      end
      transition = lifecycle_transition_for(target, entity)
      mutation_lines = target[:mutations].map { |m| emit_mutation_line(m, entity, target, value_objects_by_name, optional: false) }
      mutation_lines << "        record.#{rust_ident_field(transition[:field])} = #{transition[:to_state].inspect}.to_string();" if transition && transition[:to_state]
      mutation_lines = ["        let _ = record;"] if mutation_lines.empty?

      {
        prelude: Exemplar.render(
          "delegate_prelude",
          "tmpl_aliases_placeholder()" => aliases.join(", "),
          "TmplTargetArgs" => target_args_name,
          "TmplElement" => element_record
        ).lines.map { |l| "    #{l}" }.join.rstrip,
        apply: Exemplar.render(
          "delegate_apply",
          "TmplRecord" => rust_ident(aggregate[:name]),
          "tmpl_list_field" => rust_ident_field(list_attr[:name]),
          "TmplElement" => element_record,
          # BARE, not "#{entity[:name]}.#{target[:name]}" — this feeds
          # straight into refusal-message TEXT (`dispatch_entity`'s own
          # `"{command_name} refused — ..."`), and Ruby's own message
          # construction (`CommandRules::Admissibility#enforce_givens`,
          # `"#{command.hecks_name} refused — ..."`) reads a bare
          # `hecks_name` — never entity-qualified (`Command#hecks_name =
          # name.to_s`, `lib/hecks/bluebook/command.rb`). The placeholder
          # is misnamed (never actually "qualified" on the Ruby side) but
          # left as-is to avoid an unrelated rename churning both codegen
          # paths' templates.
          '"TmplQualifiedCommandName"' => target[:name].to_s.inspect,
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

    # `entity_command_skip_reason` — deliberately just `command_skip_reason`
    # with `entity` standing in for `aggregate`: an entity's own IR shape
    # (`attributes`/`lifecycle`/`commands`) is the SAME six-key shape an
    # aggregate's is (docs/implemented/guides/running-a-runtime.md, "Entities" —
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
      command_skip_reason(command, entity, value_objects_by_name, creating_possible: false)
    end

    # ── AN ENTITY COMMAND — `EntityInterpreter#call`'s shorter
    # `DISPATCH_ORDER` (docs/implemented/guides/entities.md), ported the same way
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
    def emit_entity_command(command, entity, parent_aggregate, domain_name, value_objects_by_name, aggregates_by_name)
      parent_record  = rust_ident(parent_aggregate[:name])
      element_record = rust_ident(entity[:name])
      cmd = rust_ident(command[:name])

      # `record_missing` (the parent lookup) and `entity_element_missing`
      # (the element lookup) each need their OWN bare name/identity
      # reading — the parent aggregate's and the entity's are almost never
      # the same text (`SafeDepositBox` vs `Visit`), so both pairs are
      # computed here rather than reusing `emit_command`'s single pair.
      aggregate_name           = parent_aggregate[:name].to_s
      parent_identity_reading  = parent_aggregate[:identified_by].join(", ")
      entity_name              = entity[:name].to_s
      entity_identity_reading  = entity[:identified_by].join(", ")

      # THE PARENT'S LIST ATTRIBUTE HOLDING THIS ENTITY — found the exact
      # way `element_of` finds it at Ruby's own runtime (`a.list? &&
      # a.type == entity_name`), just resolved once here at generation
      # time instead of once per dispatch.
      list_attr = parent_aggregate[:attributes].find { |a| a[:list] && a[:type] == entity[:name] }
      raise "#{entity[:name]}: no list attribute on #{parent_aggregate[:name]} holds it — unsupported_attribute_types should have caught this" unless list_attr

      list_field = rust_ident_field(list_attr[:name])
      # `EntityArgs` — see domain_generator.rb's own routing entry: a door
      # named after the entity command it delegates to must not collide.
      args_struct_name = "#{element_record}#{cmd}EntityArgs"

      args_struct = ["pub struct #{args_struct_name} {"]
      command[:attributes].each do |attr|
        type = rust_type(attr[:type], list: attr[:list])
        type = "Option<#{type}>" if attr[:optional]
        args_struct << "    #{Exemplar.render('struct_field', 'TmplFieldType' => type, 'tmpl_field' => rust_ident_field(attr[:name]))}"
      end
      args_struct << "}"

      invariant_checks = invariant_checks_for(command, aggregates_by_name, value_objects_by_name)

      given_specs = command[:givens].map do |given|
        "            crate::kernel::GivenSpec { description: #{rust_string_literal(given[:description])}, expr: #{ExprEmitter.emit_predicate(given[:canonical])}, corrects_event: None },"
      end

      ensures_specs = command[:ensures].map do |rule|
        "            crate::kernel::EnsuresSpec { description: #{rust_string_literal(rule[:description])}, expr: #{ExprEmitter.emit_predicate(rule[:canonical])} },"
      end

      # THE ENTITY's OWN lifecycle, not the parent aggregate's —
      # `lifecycle_transition_for`/`emit_mutation_line` (bridging.rb/
      # mutations.rb) already take a "declaring" node generically; passing
      # `entity` here is exactly that, not a special case either helper
      # needs to know about.
      transition = lifecycle_transition_for(command, entity)
      transition_arg =
        transition_check_arg(transition)

      mutation_lines = command[:mutations].map { |m| emit_mutation_line(m, entity, command, value_objects_by_name, optional: false) }
      mutation_lines << "        record.#{rust_ident_field(transition[:field])} = #{transition[:to_state].inspect}.to_string();" if transition && transition[:to_state]
      mutation_lines = ["        let _ = record;"] if mutation_lines.empty?

      # BARE, not entity-qualified — same reasoning as delegation_of's own
      # identical fix above: feeds straight into refusal-message text,
      # which Ruby's own `command.hecks_name` never qualifies.
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
        "tmpl_emit_placeholder()" => command[:emits].map(&:inspect).join(", ")
      )

      [
        emit_fielded_flat(args_struct_name, command[:attributes], value_objects_by_name),
        "#[derive(Debug, Clone)]\n#{args_struct.join("\n")}",
        # NOT `sparse: true` — same reasoning as the aggregate-command
        # call site (domain_generator.rb's own comment): real, tested,
        # deliberately left unwired to avoid diverging from
        # `hecks-codegen`'s own separate reimplementation.
        emit_to_json_flat(args_struct_name, command[:attributes], value_objects_by_name, sparse: true),
        emit_from_json_flat(args_struct_name, command[:attributes], value_objects_by_name),
        entity_dispatch_fn,
      ].join("\n\n")
    end
  end
end
